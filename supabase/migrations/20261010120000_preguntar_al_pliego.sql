-- ============================================================
-- Pregúntale al pliego
-- ============================================================
--
-- Informe de competencia del 09/10/2026: preguntar al pliego ya lo da
-- casi todo el mundo, incluso gratis (Licitandum, El Vínculo, LICAI,
-- Tendios). Decisión 57.
--
-- CÓMO FUNCIONA
--   La función `pliego` (supabase/functions/pliego) descarga los
--   documentos de la licitación (los enlaces de `condiciones.documentos`,
--   Decisión 54) y los sube a OpenAI, que extrae el texto y lo indexa en
--   un almacén de búsqueda (vector store). Cada pregunta busca ahí los
--   trozos que hacen falta y el modelo responde citando documento y frase.
--   Leer un pliego de 100 páginas no cabe en una función de Supabase (2 s
--   de CPU, 256 MB): por eso lo hace OpenAI.
--
-- LOS PLIEGOS NO SE ARCHIVAN (Decisión 16)
--   El almacén caduca a los 7 días sin preguntas y los ficheros a los 7
--   días de subirse. Es una caché temporal, no un archivo: si alguien
--   vuelve a preguntar después, se vuelven a descargar del portal.
--   Aquí solo se guarda qué almacén corresponde a cada licitación.
--
-- EL GASTO
--   Cada pregunta guarda su coste (fichas del modelo más la búsqueda). La
--   función se niega a responder si el perfil ha hecho 25 preguntas hoy o
--   si entre todos se han gastado 2 $ hoy (topes en la función).
-- ============================================================

create table if not exists public.pliegos_openai (
    id_licitacion   text primary key,
    vector_store_id text not null,
    -- [{nombre, url, tipo, file_id | null, motivo (si no se subió)}]
    documentos      jsonb not null default '[]',
    creado          timestamptz not null default now(),
    usado           timestamptz not null default now()
);

comment on table public.pliegos_openai is
  'Almacén temporal de OpenAI con los documentos de cada licitación por la '
  'que se ha preguntado. Caduca a los 7 días sin uso (Decisión 57).';

alter table public.pliegos_openai enable row level security;
revoke all on public.pliegos_openai from anon, authenticated;


create table if not exists public.preguntas_pliego (
    id            bigint generated always as identity primary key,
    perfil_id     uuid not null references public.perfiles(id) on delete cascade,
    id_licitacion text not null,
    pregunta      text not null check (char_length(pregunta) between 3 and 500),
    respuesta     text,
    citas         jsonb not null default '[]',   -- [{nombre, url}]
    coste         numeric not null default 0,    -- dólares
    error         text,
    creado        timestamptz not null default now()
);

comment on table public.preguntas_pliego is
  'Preguntas hechas a los pliegos, con la respuesta y lo que costó. La '
  'escribe la función pliego con la clave de servicio (Decisión 57).';

create index if not exists idx_preguntas_pliego_perfil
    on public.preguntas_pliego (perfil_id, id_licitacion, creado desc);
-- Para el tope de gasto del día, que suma todo lo de hoy.
create index if not exists idx_preguntas_pliego_creado
    on public.preguntas_pliego (creado);

alter table public.preguntas_pliego enable row level security;
revoke all on public.preguntas_pliego from anon, authenticated;


-- Lo preguntado por el perfil activo sobre una licitación, lo último
-- primero. La web lo enseña al abrir la ficha.
create or replace function public.mis_preguntas_pliego(licitacion text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    select coalesce(jsonb_agg(jsonb_build_object(
               'pregunta', q.pregunta, 'respuesta', q.respuesta,
               'citas', q.citas, 'creado', q.creado)
             order by q.creado desc), '[]')
    from (select * from public.preguntas_pliego
          where perfil_id = public.mi_perfil_id()
            and id_licitacion = licitacion
            and respuesta is not null
          order by creado desc
          limit 20) q;
$function$;

revoke execute on function public.mis_preguntas_pliego(text) from public, anon;
grant execute on function public.mis_preguntas_pliego(text) to authenticated;
