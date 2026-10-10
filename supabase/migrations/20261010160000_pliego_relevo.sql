-- ============================================================
-- Pregúntale al pliego: el relevo de GitHub para el portal vasco
-- ============================================================
--
-- Decisión 57. Las funciones de Supabase no pueden descargar del portal
-- de contratación vasco: su cliente de red rechaza el certificado
-- ("invalid peer certificate: BadSignature"). Desde GitHub Actions se
-- descarga bien (el lector de solvencia lee cientos de pliegos suyos).
--
-- EL RELEVO
--   1. La función `pliego` no puede descargar un documento por el
--      certificado: lanza el workflow `relevo-pliego.yml` con la
--      licitación y apunta `relevo` (la hora del aviso).
--   2. El workflow (relevo_pliego.py) descarga los documentos de esa
--      licitación que la función no alcanza y los deja en el almacén
--      privado `relevo`, con el nombre del SHA-256 de su URL. Al acabar
--      apunta `relevo_hecho` y borra `relevo`.
--   3. La función, que esperaba, coge los ficheros del almacén, los sube a
--      OpenAI como siempre y los BORRA del almacén. Los pliegos no se
--      archivan (Decisión 16): están ahí un par de minutos.
--
-- Si el relevo tampoco consigue un documento, `relevo_hecho` evita
-- pedirlo otra vez en bucle: se da por no descargable.
-- ============================================================

alter table public.pliegos_openai add column if not exists relevo timestamptz;
alter table public.pliegos_openai add column if not exists relevo_hecho timestamptz;

insert into storage.buckets (id, name, public)
values ('relevo', 'relevo', false)
on conflict (id) do nothing;
