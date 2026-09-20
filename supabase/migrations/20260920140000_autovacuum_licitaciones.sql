-- ============================================================
-- QUE AUTOVACUUM NO VUELVA A DESENTENDERSE DE `licitaciones`
-- ============================================================
--
-- Aplicada el 20/09/2026.
--
-- LO QUE PASÓ
-- La tabla llegó a 1.061.075 filas sin un solo ANALYZE ni VACUUM en
-- toda su vida: autovacuum_count = 0, analyze_count = 0. Dos efectos,
-- los dos graves:
--
--   · Sin estadísticas, el planificador creía que la tabla tenía
--     626.000 filas y elegía planes disparatados.
--   · Sin mapa de visibilidad, cada index only scan bajaba al heap.
--     Un `select count(*)` tardaba 50 segundos.
--
-- De ahí salían los 153 "canceling statement due to statement timeout"
-- de los logs, y las tasas de fallo del 43% en pendientes_de_perfil y
-- del 38% en buscar_organismo.
--
-- Tras ejecutar ANALYZE y VACUUM a mano: count(*) de 50,8 s a 1,37 s,
-- 48.156 tuplas muertas a 0, Heap Fetches a 0.
--
-- POR QUÉ NO SALTABA SOLO
-- Con los factores por defecto hacen falta ~212.000 filas muertas para
-- el vacuum y ~106.000 modificaciones para el analyze. El scraper
-- reescribe la tabla entera en cada pasada (49.154 updates para 1
-- millón de filas, solo un 2% HOT porque los triggers tocan columnas
-- indexadas y hay 20 índices), así que la tabla se degradaba mucho
-- antes de alcanzar el umbral.
-- ============================================================

alter table public.licitaciones set (
    autovacuum_vacuum_scale_factor  = 0.02,   -- ~21.000 filas muertas
    autovacuum_vacuum_threshold     = 5000,
    autovacuum_analyze_scale_factor = 0.01,   -- ~10.600 cambios
    autovacuum_analyze_threshold    = 2500,
    autovacuum_vacuum_cost_delay    = 2
);

-- Vigilancia: esto debería dejar de dar cero.
--   select relname, autovacuum_count, autoanalyze_count, last_autoanalyze
--   from pg_stat_user_tables where relname = 'licitaciones';
