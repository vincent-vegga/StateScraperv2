-- ============================================================
-- Cuatro índices que nadie usa, y autovacuum para adjudicaciones_empresa
-- ============================================================
--
-- APLICADO el 07/10/2026 (los cuatro seguían a 0 usos justo antes). El
-- autovacuum de adjudicaciones_empresa entró solo al minuto de cambiar
-- los umbrales.
--
-- Se ejecuta en el SQL Editor. Los `drop index concurrently` no pueden ir
-- dentro de una transacción: cada uno en su propio Run.
--
-- 1 · ÍNDICES SIN USO (~68 MB, y menos trabajo en cada escritura)
--
-- Es la parte 2 de `20260920140400_indices_sobrantes.sql`, que pedía
-- esperar a tener uso real antes de borrar. Mirado el 07/10/2026, con la
-- base viva desde el 04/09 y betatesters dentro desde el 20/09:
--
--   índice                         usos  tamaño  por qué sobra
--   idx_licitaciones_licitadores      0   19 MB  ninguna consulta filtra por esa columna
--   idx_licitaciones_sector           0   18 MB  ídem
--   idx_licitaciones_cribado          0   16 MB  la columna está vacía en todas las filas
--   idx_licitaciones_nuts             0   15 MB  ninguna consulta filtra por esa columna
--
-- Comprobado también en el código: ninguna función, vista, Edge Function
-- ni script filtra por `licitadores`, `sector` o `nuts`. El único que
-- mira `cribado_veredicto` es `generar_interfaz.py`, que ya no corre en
-- ningún workflow.
--
-- Se QUEDAN, aunque se usan poco, por prudencia:
--   idx_licitaciones_prefijos (GIN, 0 usos): es el único camino para
--     `prefijos && ...` sobre toda la tabla (alta sin NIF con
--     solo_vivas = false). Que no se haya usado no quiere decir que no
--     se vaya a necesitar.
--   idx_licitaciones_verificacion (0 usos, 7 MB): sirve a
--     `pendientes_de_verificar`, del robot.
--   idx_licitaciones_deteccion, _origen, _estado_licitacion: se usan
--     poco, pero se usan.
--
-- Borrar un índice no toca datos. Para volver atrás, las definiciones
-- están al final de este fichero.
-- ============================================================

drop index concurrently if exists public.idx_licitaciones_licitadores;
drop index concurrently if exists public.idx_licitaciones_sector;
drop index concurrently if exists public.idx_licitaciones_cribado;
drop index concurrently if exists public.idx_licitaciones_nuts;


-- ============================================================
-- 2 · AUTOVACUUM PARA adjudicaciones_empresa
-- ============================================================
--
-- Con los valores por defecto (20 % de la tabla), autovacuum no entra
-- hasta ~277.000 filas muertas o insertadas: en un mes no ha entrado ni
-- una vez. Mientras tanto el mapa de visibilidad se queda viejo y los
-- "index only scan" de `idx_adjudicaciones_empresa_cuentan` (los que usa
-- `repartos_del_periodo`, o sea Empresas y Movimientos) van a la tabla
-- fila a fila.
--
-- Los mismos umbrales que ya tiene `licitaciones` desde
-- `20260920140000_autovacuum_licitaciones.sql`, más el de inserciones,
-- que es el que mantiene el mapa de visibilidad en una tabla que sobre
-- todo crece.
-- ============================================================

alter table public.adjudicaciones_empresa set (
    autovacuum_vacuum_scale_factor        = 0.02,
    autovacuum_vacuum_threshold           = 5000,
    autovacuum_vacuum_insert_scale_factor = 0.02,
    autovacuum_vacuum_insert_threshold    = 5000,
    autovacuum_analyze_scale_factor       = 0.01,
    autovacuum_analyze_threshold          = 2500
);


-- ------------------------------------------------------------
-- Marcha atrás (solo si hiciera falta)
-- ------------------------------------------------------------
--   create index concurrently idx_licitaciones_licitadores
--       on public.licitaciones (licitadores) where licitadores is not null;
--   create index concurrently idx_licitaciones_sector
--       on public.licitaciones (sector) where sector is not null;
--   create index concurrently idx_licitaciones_cribado
--       on public.licitaciones (cribado_veredicto);
--   create index concurrently idx_licitaciones_nuts
--       on public.licitaciones (nuts) where nuts is not null;
--
--   alter table public.adjudicaciones_empresa reset (
--       autovacuum_vacuum_scale_factor, autovacuum_vacuum_threshold,
--       autovacuum_vacuum_insert_scale_factor, autovacuum_vacuum_insert_threshold,
--       autovacuum_analyze_scale_factor, autovacuum_analyze_threshold);
