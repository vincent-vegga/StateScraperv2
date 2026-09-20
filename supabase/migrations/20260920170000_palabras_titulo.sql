-- ============================================================
-- PALABRAS DE TÍTULO PRECALCULADAS
-- "quién ha ganado antes este mismo contrato", de 18 s a 0,37 s
-- ============================================================
--
-- Aplicada el 20/09/2026.
--
-- EL PROBLEMA
-- Dos funciones comparan el título de un contrato con los de su mismo
-- órgano y familia CPV, y las dos eran inviables en grupos grandes
-- (medido sobre uno de 5.365 contratos, contra un límite de 8 s):
--
--   incumbencia .............. 17.963 ms   -> la pestaña de viabilidad
--   ediciones_anteriores ..... 20.659 ms   -> sin conectar todavía
--
-- La causa: parecido_util(a,b) ejecuta palabras_utiles() sobre sus dos
-- argumentos EN CADA FILA. Procesar el mismo texto un millón de veces
-- al día para obtener siempre el mismo resultado.
--
--
-- POR QUÉ UNA TABLA APARTE Y NO UNA COLUMNA
--
-- El primer intento fue una columna en `licitaciones`. No salió, y el
-- motivo merece quedar escrito porque volverá a aparecer:
--
--   · Rellenarla exige un UPDATE de un millón de filas, y cada UPDATE
--     dispara los cinco triggers BEFORE de la tabla y deja una tupla
--     muerta por fila.
--   · El backfill se frenaba a sí mismo: cada pasada dejaba la tabla
--     más hinchada y la siguiente tardaba más, hasta dejar de caber en
--     el tiempo disponible.
--   · No había forma de dejarlo corriendo desatendido. Un bloque
--     `do $$ $$` es una sola transacción y al cortarse pierde todo el
--     trabajo aunque esté troceado. Un PROCEDURE con COMMIT sí
--     confirma por lotes, pero el editor SQL de Supabase envuelve lo
--     que ejecuta en una transacción y ahí COMMIT es ilegal.
--
-- Con tabla aparte el relleno es un INSERT ... SELECT: no dispara
-- ningún trigger de `licitaciones`, no la hincha (quedó en 0 tuplas
-- muertas), y es reanudable con un `not exists`. Se completó en cinco
-- pasadas de 200-250 mil filas.
--
-- El precio es un join por clave primaria. Sale muy a cuenta.
--
--
-- EL PREFILTRO `&&` ES EXACTO, NO APROXIMADO
--
-- parecido_arrays es |intersección| / min(|a|,|b|) — el coeficiente de
-- solapamiento de Szymkiewicz-Simpson. Para que sea >= 0.4 la
-- intersección tiene que ser >= 1, es decir, las dos listas comparten
-- al menos una palabra: justo lo que comprueba `&&`. Por eso se puede
-- usar como prefiltro sin descartar nada que el criterio aceptaría.
--
-- Esto es lo que NO daban los trigramas, que se probaron antes: miden
-- otra cosa, así que como prefiltro perdían resultados (22 de 4.845) y
-- encima no ahorraban tiempo.
--
--
-- LA OTRA MITAD DEL ARREGLO
--
-- `incumbencia` recorría el grupo DOS veces: una para `mismas` y otra
-- para `familia`, aunque `familia` solo se usa cuando `mismas` tiene
-- menos de dos filas. Ahora es un solo barrido con una marca. Eso solo
-- llevó de 855 ms a 351 ms.
--
--
-- VERIFICACIÓN antes de sustituir nada
--   incumbencia ............ 150 licitaciones vivas, 150 idénticas
--   ediciones_anteriores ... 60 licitaciones, 46 filas por versión,
--                            cero diferencias en ambas direcciones
--
--
-- RESULTADO (rol authenticated, caché caliente)
--   incumbencia caso peor ......... 17.963 -> 370 ms
--   viabilidad caso peor .......... 10.830 -> 1.261 ms
--   viabilidad normal ....................... 44 ms
--   ediciones_anteriores caso peor  20.659 -> 1.885 ms
--
--
-- ACOPLAMIENTO A RECORDAR
-- Si cambia la definición de palabras_utiles(), esta tabla se queda
-- mintiendo y hay que vaciarla y rehacerla entera:
--
--   truncate public.palabras_titulo;
--   -- y repetir el INSERT ... SELECT de abajo por lotes
--
--
-- PENDIENTE
-- `ediciones_anteriores` sigue sin conectar a la interfaz y sin
-- permiso para `authenticated`. Es la versión completa del "quién ganó
-- esto antes, por cuánto y contra cuántos" —devuelve la lista concreta
-- donde incumbencia da solo el resumen— y ya es lo bastante rápida
-- para exponerla. Al conectarla hará falta:
--
--   grant execute on function public.ediciones_anteriores(text, real)
--         to authenticated;
-- ============================================================


create table if not exists public.palabras_titulo (
    id_licitacion text primary key,
    palabras      text[] not null
);

alter table public.palabras_titulo enable row level security;
-- Sin políticas: solo se lee desde funciones SECURITY DEFINER.

comment on table public.palabras_titulo is
    'palabras_utiles(titulo) precalculado por licitación. Lo mantiene '
    'trg_sync_palabras_titulo. Si cambia palabras_utiles(), hay que '
    'vaciar y rehacer esta tabla entera.';


-- Sin clave foránea a propósito: la comprobación por fila encarecería
-- el relleno de un millón de filas, y de `licitaciones` no se borra.
-- Si algún día se borrara, quedarían huérfanas que no molestan.


create or replace function public.sync_palabras_titulo()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    -- Solo cuando el título cambia de verdad: el scraper reescribe
    -- filas enteras en cada pasada aunque el título sea el mismo.
    if tg_op = 'UPDATE' and new.titulo is not distinct from old.titulo then
        return null;
    end if;

    if new.titulo is null then
        delete from public.palabras_titulo where id_licitacion = new.id_licitacion;
        return null;
    end if;

    insert into public.palabras_titulo (id_licitacion, palabras)
    values (new.id_licitacion, public.palabras_utiles(new.titulo))
    on conflict (id_licitacion) do update set palabras = excluded.palabras;
    return null;
end;
$function$;

drop trigger if exists trg_sync_palabras_titulo on public.licitaciones;
create trigger trg_sync_palabras_titulo
    after insert or update on public.licitaciones
    for each row execute function public.sync_palabras_titulo();


-- Misma fórmula que parecido_util, sobre arrays ya calculados.
create or replace function public.parecido_arrays(a text[], b text[])
returns real
language sql
immutable
set search_path to 'public'
as $$
    select case
        when array_length(a, 1) is null or array_length(b, 1) is null then 0
        else (select count(*) from (
                select unnest(a) intersect select unnest(b)) c)::real
             / least(array_length(a, 1), array_length(b, 1))
    end;
$$;

revoke execute on function public.parecido_arrays(text[], text[]) from public, anon;
grant  execute on function public.parecido_arrays(text[], text[]) to authenticated;


-- ------------------------------------------------------------
-- RELLENO INICIAL · repetir hasta que devuelva 0 filas.
-- Ya ejecutado el 20/09/2026 (1.061.075 filas, cinco pasadas).
-- ------------------------------------------------------------
--   insert into public.palabras_titulo (id_licitacion, palabras)
--   select l.id_licitacion, public.palabras_utiles(l.titulo)
--   from public.licitaciones l
--   where l.titulo is not null
--     and not exists (select 1 from public.palabras_titulo p
--                     where p.id_licitacion = l.id_licitacion)
--   limit 250000
--   on conflict (id_licitacion) do nothing;
--
--   analyze public.palabras_titulo;
--
-- Los cuerpos nuevos de incumbencia y ediciones_anteriores están en
-- las migraciones `incumbencia_definitiva` y
-- `ediciones_anteriores_definitiva`.

-- ------------------------------------------------------------
-- 20/09/2026, más tarde: ediciones_anteriores queda expuesta.
--
--   grant execute on function public.ediciones_anteriores(text, real)
--         to authenticated;
--
-- Comprobado: devuelve 12 filas para un usuario con sesión y sigue
-- cerrada a `anon`. Es SECURITY DEFINER y no recibe identificador de
-- perfil, solo una ficha; lo que devuelve son adjudicaciones públicas
-- del mismo órgano, no datos de ningún cliente.
--
-- CONECTADA el 20/09/2026 a la pestaña de viabilidad, bajo el resumen
-- de incumbencia. Se pide en paralelo con viabilidad (no en cadena) y
-- su fallo no tumba la pantalla: si no llega, esa sección no aparece y
-- el análisis se enseña igual.
-- ------------------------------------------------------------
