-- ============================================================
-- QUE `pendientes_de_perfil` GANE LA CARRERA DE LOS 4 SEGUNDOS
-- ============================================================
--
-- POR QUÉ IMPORTA MÁS DE LO QUE PARECE
-- En web/index.html, arrancar() —que se ejecuta en CADA entrada a la
-- aplicación— llama a pendientes_de_perfil dentro de un
-- Promise.race contra un timeout de 4 segundos:
--
--     const pend = await Promise.race([
--       sb.rpc('pendientes_de_perfil', { perfil: perfil.id, tope: 1 }),
--       new Promise(res => setTimeout(() => res(null), 4000)),
--     ]);
--
-- Si pierde la carrera, el usuario entra sin que se haya cribado lo
-- pendiente y puede encontrarse la lista vacía o desactualizada. Antes
-- de los arreglos de hoy la función tardaba 23,6 s: perdía SIEMPRE, y
-- ese cribado previo no se ejecutaba nunca.
--
-- Tras reordenar el filtrado bajó a 3,1 s. Gana, pero por 0,9 s de
-- margen: con la caché fría o algo de carga vuelve a perder.
--
-- DE DÓNDE SALEN ESOS 3,1 s
-- El recorrido por idx_licitaciones_vivas encuentra las 4.517
-- licitaciones vivas en el índice, pero para comprobar `prefijos` de
-- cada una tiene que bajar al heap: ~4.333 bloques de lectura
-- aleatoria, casi uno por fila.
--
-- LA SOLUCIÓN
-- Llevar `prefijos` DENTRO del índice con INCLUDE. Así el filtro por
-- CPV se resuelve en el propio índice y el heap solo se toca para las
-- filas que de verdad salen. Requiere el mapa de visibilidad al día,
-- que ya lo está desde el VACUUM de hoy.
--
-- Sustituye a idx_licitaciones_vivas, que se puede borrar después de
-- comprobar que el plan usa el nuevo.
-- ============================================================

-- APLICADA el 20/09/2026. Medido después:
--   pendientes_de_perfil(tope=1): 4.807 ms -> 214 ms
--
-- OJO, esto no es opcional: mientras existían los dos índices, el
-- planificador seguía eligiendo el viejo por ser más pequeño (1,6 MB
-- frente a 14 MB) y luego bajaba al heap igualmente. El nuevo solo
-- sirve si se retira el anterior.

create index concurrently if not exists idx_licitaciones_vivas_pref
    on public.licitaciones (coalesce(fecha_limite, 'infinity'::timestamptz))
    include (prefijos)
    where coalesce(estado_licitacion, '') = 'PUB';

-- Ya ejecutado tras comprobar el plan:
--   drop index concurrently if exists public.idx_licitaciones_vivas;
