-- ============================================================
-- Pregúntale al pliego: leerlo antes de que pregunten
-- ============================================================
--
-- Decisión 57, segunda parte. La primera pregunta de un pliego tardaba
-- 20-30 s porque había que descargarlo, subirlo y que OpenAI lo leyera.
-- Licitandum carga los pliegos al seguir una licitación y El Vínculo al
-- abrirla: cuando se pregunta, ya están leídos. Aquí se empieza a leer al
-- abrir la ficha y al guardar el contrato en la cartera.
--
-- Con dos caminos que pueden preparar el mismo pliego a la vez (la ficha
-- y la pregunta), hace falta un reclamo: quien lo consigue prepara y los
-- demás esperan. `reclamar_pliego` lo hace en una sola sentencia.
--
--   preparando     desde cuándo alguien lo está preparando (3 min de
--                  validez: si la función muere a medias, otro lo retoma)
--   preparado_por  el perfil que lo pidió, para el tope diario
--   fallo          no se pudo leer nada (escaneado, sin documentos
--                  legibles): no se reintenta en 24 h, para no descargar
--                  lo mismo cada vez que alguien abre la ficha
-- ============================================================

alter table public.pliegos_openai alter column vector_store_id drop not null;
alter table public.pliegos_openai add column if not exists preparando timestamptz;
alter table public.pliegos_openai add column if not exists preparado_por uuid;
alter table public.pliegos_openai add column if not exists fallo timestamptz;

-- Para el tope diario de preparaciones por perfil.
create index if not exists idx_pliegos_openai_preparado_por
    on public.pliegos_openai (preparado_por, creado);

-- Se queda con la preparación de un pliego si nadie la tiene (o quien la
-- tenía lleva más de 3 minutos) y el almacén sigue siendo el que el que
-- llama vio caducado (`viejo`, null si no había). Devuelve si lo consiguió.
create or replace function public.reclamar_pliego(licitacion text, perfil uuid, viejo text)
returns boolean
language sql
security definer
set search_path to 'public'
as $function$
    with reclamo as (
        insert into public.pliegos_openai as p
            (id_licitacion, vector_store_id, preparando, preparado_por, creado, usado)
        values (licitacion, null, now(), perfil, now(), now())
        on conflict (id_licitacion) do update
            set preparando = now(), preparado_por = excluded.preparado_por,
                creado = now(), vector_store_id = null, fallo = null
            where p.vector_store_id is not distinct from viejo
              and (p.preparando is null or p.preparando < now() - interval '3 minutes')
        returning 1
    )
    select exists (select 1 from reclamo);
$function$;

revoke execute on function public.reclamar_pliego(text, uuid, text) from public, anon, authenticated;
grant execute on function public.reclamar_pliego(text, uuid, text) to service_role;
