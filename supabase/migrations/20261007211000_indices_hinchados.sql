-- ============================================================
-- Índices hinchados: reconstruirlos sin bloquear (~1,4 GB menos)
-- ============================================================
--
-- APLICADO el 07/10/2026, sentencia a sentencia. Cada reconstrucción
-- tardó 34-39 s, ninguna quedó inválida. Resultado real:
--
--   idx_licitaciones_organo_periodo     609 -> 316 MB
--   idx_licitaciones_periodo            589 -> 244 MB
--   idx_adjudicaciones_empresa_cuentan  387 -> 144 MB
--   idx_licitaciones_organo_cuentan     373 -> 200 MB
--   idx_licitaciones_cuentan            350 -> 156 MB
--   adjudicaciones_empresa_pkey         257 -> 159 MB
--   licitaciones_pkey                   256 -> 144 MB
--   idx_licitaciones_organo_expediente  180 -> 127 MB
--
--   Base entera (con 20261007212000): 6.810 -> 5.233 MB
--
-- El VACUUM de adjudicaciones_empresa no hizo falta lanzarlo a mano: lo
-- hizo autovacuum en cuanto se aplicaron los umbrales de 20261007212000.
-- Las dos extensiones de diagnóstico ya se quitaron.
--
-- Si hay que repetirlo algún día: NO ES UNA MIGRACIÓN DE UNA SOLA
-- PASADA. Se ejecuta a mano en el SQL Editor, sentencia a sentencia (ver
-- "Cómo se ejecuta" más abajo). Para medir antes cómo de llenos están:
--   create extension pgstattuple with schema extensions;
--   select * from extensions.pgstatindex('public.<índice>');  -- avg_leaf_density
--
-- EL PROBLEMA
-- La base ocupa 6,8 GB; la mitad son índices de `licitaciones` (2,65 GB,
-- más que los propios datos: 1,96 GB). Medido el 07/10/2026 con
-- pgstatindex(), los índices grandes tienen las hojas medio vacías. Un
-- índice recién construido queda al 90 %:
--
--   índice                                 tamaño  lleno  tras rehacer
--   idx_licitaciones_organo_periodo        609 MB   48 %     ~320 MB
--   idx_licitaciones_periodo               589 MB   38 %     ~245 MB
--   idx_adjudicaciones_empresa_cuentan     387 MB   42 %     ~180 MB
--   idx_licitaciones_organo_cuentan        373 MB   49 %     ~205 MB
--   idx_licitaciones_cuentan               350 MB   41 %     ~160 MB
--   adjudicaciones_empresa_pkey            257 MB   62 %     ~175 MB
--   licitaciones_pkey                      256 MB   52 %     ~150 MB
--   idx_licitaciones_organo_expediente     180 MB   65 %     ~130 MB
--                                         -------           -------
--                                         3,0 GB            ~1,6 GB
--
-- Viene de los rellenos masivos (provincia, fecha de formalización,
-- duración...): cada UPDATE que no es HOT deja una entrada nueva en cada
-- índice, y el VACUUM libera la vieja pero no junta las páginas.
--
-- POR QUÉ IMPORTA PARA LA WEB, NO SOLO PARA EL DISCO
-- La instancia tiene 512 MB de shared_buffers para 6,8 GB de base. Un
-- índice a la mitad de lleno necesita el doble de páginas para lo mismo:
-- el doble de lecturas de disco con la caché fría y la mitad de cosas
-- caben en memoria. Una lectura de disco cuesta ~0,6 ms (medido: 3.861
-- lecturas, 2,4 s).
--
-- Además, `adjudicaciones_empresa` no ha pasado NUNCA por autovacuum
-- (224.372 filas muertas). Sin VACUUM no hay mapa de visibilidad, y sus
-- "index only scan" van a la tabla fila a fila: `repartos_del_periodo`
-- hizo 10.795 Heap Fetches para 10.850 filas. El VACUUM lo arregla, y la
-- migración siguiente evita que vuelva a pasar.
--
-- QUÉ NO CAMBIA
-- Ningún dato, ninguna definición de índice, ningún plan de consulta.
-- `reindex concurrently` construye una copia al lado, la cambia por la
-- vieja con un bloqueo de milisegundos y borra la vieja. Lecturas y
-- escrituras siguen durante todo el proceso.
--
-- Espacio: durante cada reconstrucción conviven la vieja y la nueva (como
-- mucho +320 MB, más el WAL que genera). Por eso UNA A UNA, y de menor a
-- mayor.
--
-- Los índices de clave primaria volverán a hincharse algo (los id no
-- llegan en orden), pero lejos de donde están: un btree con inserciones
-- al azar se estabiliza en torno al 70 %.
-- ============================================================
--
-- CÓMO SE EJECUTA
--
-- 1. En una pestaña del SQL Editor, sola:
--
--      set statement_timeout = '30min';
--
--    Dura lo que dure esa conexión. No cambia nada global.
--
-- 2. En ESA MISMA pestaña, cada sentencia de abajo de una en una (Run con
--    solo esa línea seleccionada). `vacuum` y `reindex concurrently` no
--    pueden ir dentro de una transacción ni juntos en el mismo Run.
--
-- 3. Después de cada `reindex`, la comprobación del final. Si una se
--    corta a medias deja un índice `..._ccnew` inválido: se borra con
--    `drop index concurrently` y se repite.
-- ============================================================


-- Paso 1 · VACUUM de la tabla que nunca lo ha tenido (~1 min).
vacuum (analyze, verbose) public.adjudicaciones_empresa;

-- Paso 2 · Reconstrucciones, de menor a mayor.
reindex index concurrently public.idx_licitaciones_organo_expediente;
reindex index concurrently public.licitaciones_pkey;
reindex index concurrently public.adjudicaciones_empresa_pkey;
reindex index concurrently public.idx_licitaciones_cuentan;
reindex index concurrently public.idx_licitaciones_organo_cuentan;
reindex index concurrently public.idx_adjudicaciones_empresa_cuentan;
reindex index concurrently public.idx_licitaciones_periodo;
reindex index concurrently public.idx_licitaciones_organo_periodo;

-- Paso 3 · VACUUM de licitaciones, para que el mapa de visibilidad quede
-- al día con los índices nuevos (autovacuum lo haría solo, más tarde).
vacuum (analyze) public.licitaciones;


-- ------------------------------------------------------------
-- Comprobaciones (solo lectura)
-- ------------------------------------------------------------

-- Índices inválidos que hayan quedado de una reconstrucción cortada.
-- Tiene que salir vacío:
--
--   select c.relname
--   from pg_index i join pg_class c on c.oid = i.indexrelid
--   where not i.indisvalid;

-- Tamaños después:
--
--   select pg_size_pretty(pg_database_size(current_database())) as base,
--          pg_size_pretty(pg_indexes_size('public.licitaciones')) as indices_licitaciones,
--          pg_size_pretty(pg_indexes_size('public.adjudicaciones_empresa')) as indices_adjudicaciones;


-- ------------------------------------------------------------
-- Limpieza de herramientas
-- ------------------------------------------------------------
-- Para medir todo esto el 07/10/2026 se instalaron dos extensiones de
-- solo diagnóstico, que no hacen nada si nadie las llama:
--   pgstattuple  (pgstatindex: cómo de lleno está un índice)
--   hypopg       (esconder un índice al planificador en una sesión)
-- Se pueden quitar cuando se quiera:
--
--   drop extension if exists hypopg;
--   drop extension if exists pgstattuple;
