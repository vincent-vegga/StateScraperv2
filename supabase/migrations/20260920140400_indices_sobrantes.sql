-- ============================================================
-- ÍNDICES SOBRANTES EN `licitaciones`
-- ============================================================
--
-- PENDIENTE DE APLICAR. Son borrados: revísalos tú.
--
-- La tabla tiene 20 índices. Cada uno se paga en cada escritura, y el
-- scraper reescribe la tabla entera en cada pasada: solo el 2% de los
-- 49.154 updates fueron HOT, precisamente porque los triggers tocan
-- columnas indexadas. Quitar índices inútiles acelera al scraper y
-- reduce la presión sobre autovacuum.
--
-- 1 · DUPLICADOS EXACTOS (los detecta el linter de Supabase).
--     No hay nada que decidir: son el mismo índice dos veces.

drop index if exists public.idx_licitaciones_sector_fecha;
-- ^ idéntico a idx_licitaciones_prefijo_fecha
--   (prefijo_principal, fecha_actualizacion DESC) WHERE adjudicatario_cif IS NOT NULL

drop index if exists public.idx_licitaciones_prefijos_todo;
-- ^ idéntico a idx_licitaciones_prefijos, gin (prefijos)

-- 2 · NUNCA USADOS.
--     OJO: las estadísticas de uso se recogieron cuando la tabla NO
--     tenía ANALYZE, así que el planificador elegía mal y puede haber
--     descartado índices que ahora sí usaría. Lo prudente es dejar
--     pasar unos días con los betatesters dentro, volver a mirar
--     pg_stat_user_indexes, y borrar entonces.
--
--     Comprobación antes de decidir:
--       select indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid))
--       from pg_stat_user_indexes where relname = 'licitaciones'
--       order by idx_scan, pg_relation_size(indexrelid) desc;
--
--     Candidatos que dio el linter el 20/09/2026, sin ejecutar:
--       idx_licitaciones_titulo_trgm      idx_licitaciones_sector
--       idx_licitaciones_nuts             idx_licitaciones_estado_licitacion
--       idx_licitaciones_cribado          idx_licitaciones_subjetivo
--       idx_licitaciones_licitadores      idx_licitaciones_verificacion
--       idx_licitaciones_deteccion
