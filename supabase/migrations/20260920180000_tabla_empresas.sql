-- ============================================================
-- BUSCAR EMPRESA POR NOMBRE: el caso Acciona / ACS
-- ============================================================
--
-- Aplicada el 20/09/2026.
--
-- EL FALLO REPORTADO
-- "Para Acciona y ACS dice que no encuentra empresa."
--
-- Y la búsqueda tenía razón:
--
--   A08001851  Acciona S.A. (matriz) .................  0 contratos
--   A28004885  ACS Actividades de Construcción .......  0 contratos
--   A81638108  Acciona Construcción .................. 73 contratos
--   A08175994  Acciona Facility Services ............ 148 contratos
--
-- Las matrices de los grupos NO licitan. Licitan sus filiales, cada
-- una con su propio CIF. Quien escribe el CIF que conoce se queda
-- fuera aunque su grupo tenga cientos de adjudicaciones.
--
-- No era un fallo técnico sino de producto, y lo destapó justamente la
-- decisión de esta misma mañana de retirar la búsqueda por nombre. El
-- razonamiento de entonces —"si el CIF es exacto y no encuentra nada,
-- es que no hay nada"— era correcto sobre la entidad jurídica y falso
-- sobre lo que la persona entiende por "su empresa".
--
--
-- POR QUÉ AHORA SÍ SE PUEDE
-- Se retiró porque recorría las 965.337 filas de `licitaciones`
-- aplicando regexp_replace a cada una: 12 s contra un límite de 8.
--
-- Sobre empresas DISTINTAS el problema es cinco veces menor: 193.312
-- filas. Ahí sí cabe un índice de trigramas, y ocupa 13 MB (el que se
-- descartó sobre `licitaciones` habría pesado 407 MB).
--
--   'DELOITTE' ....... 12.294 ms -> 7 ms
--   'ACCIONA' ................... 60 ms
--   'CONSTRUCCIONES' ........... 467 ms
--
--
-- Y DE PASO CORRIGE UN ERROR DE DATOS
-- La versión anterior se protegía con un `limit 4000` sobre las
-- candidatas, y ese límite cortaba ANTES de agrupar: los recuentos
-- salían truncados y el orden era falso. Para 'FERROVIAL' daba 106
-- contratos a Serveo Servicios cuando tiene 1.126, y ponía primera a
-- Ferrovial Construcción, que tiene 237.
--
-- Verificado: para 'ACCIONA' y 'DELOITTE' la lista de CIF es idéntica
-- a la anterior; para 'FERROVIAL' difiere, y difiere porque la nueva
-- es la correcta.
--
--
-- MANTENIMIENTO
-- `empresas` se recalcula entera con refrescar_empresas(): 33,5 s, muy
-- por encima del statement_timeout de 8 s de PostgREST. Es decir, el
-- scraper NO puede llamarla por RPC y la tabla se habría quedado
-- congelada en silencio, con las empresas nuevas invisibles.
--
-- Se intentó un refresco incremental por fecha, pero sigue costando
-- ~20 s: no hay índice sobre `fecha_actualizacion` a secas y encontrar
-- lo reciente exige recorrer la tabla. Añadir ese índice por esto solo
-- no compensa.
--
-- Se resuelve con pg_cron, que corre DENTRO de la base y no tiene
-- límite HTTP: un refresco completo diario a las 06:40 UTC, cuarenta
-- minutos después de la pasada del scraper (06:00).
--
-- Consecuencia a tener presente: la búsqueda POR NOMBRE puede ir hasta
-- un día por detrás. La búsqueda POR CIF no, porque consulta
-- `licitaciones` directamente; por eso se dejó así a propósito.
-- ============================================================

create table if not exists public.empresas (
    cif           text primary key,
    nombre        text not null,
    nombre_norm   text not null,
    contratos     integer not null,
    importe_total numeric,
    ultimo        timestamptz
);

alter table public.empresas enable row level security;
-- Sin políticas: solo se lee desde funciones SECURITY DEFINER.

comment on table public.empresas is
    'Un adjudicatario por CIF, derivado de licitaciones. Lo recalcula '
    'refrescar_empresas(), programada con pg_cron a las 06:40 UTC.';

-- `nombre_norm` guarda EXACTAMENTE la misma normalización que usaba
-- buscar_empresa (mayúsculas y fuera lo que no sea letra o dígito),
-- para que el comportamiento de búsqueda no cambie.
create index if not exists idx_empresas_nombre_trgm
    on public.empresas using gin (nombre_norm gin_trgm_ops);

-- El cuerpo de refrescar_empresas(timestamptz) está en la migración
-- `refrescar_empresas_incremental`, y el de buscar_empresa en
-- `buscar_empresa_definitiva`.
--
-- Carga inicial y programación, ya ejecutadas:
--   select public.refrescar_empresas();      -- 193.312 empresas
--   analyze public.empresas;
--   select cron.schedule('refrescar-empresas', '40 6 * * *',
--                        $$select public.refrescar_empresas()$$);
--
-- Vigilancia:
--   select jobid, schedule, active from cron.job;
--   select * from cron.job_run_details order by start_time desc limit 5;
