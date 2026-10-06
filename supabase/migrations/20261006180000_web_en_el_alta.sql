-- ============================================================
-- La web de la empresa en el alta sin NIF (decisión 49)
-- ============================================================
--
-- En el alta sin NIF el cliente puede dar su web. La función `alta` la
-- lee y saca a qué se dedica (`descripcion_web`) y sus productos o
-- servicios (`web_lineas`), que el cliente revisa y puede corregir.
--
--   web              la dirección, normalizada (https://...).
--   descripcion_web  lo que dice su web que hace; el filtro del historial
--                    sintético, el criterio y el juez (puntuador.py) lo
--                    leen detrás de `descripcion`.
--   web_lineas       sus líneas: se buscan contratos parecidos a cada una.
--
-- Sin web, las tres quedan a null y todo sigue como antes. Las políticas
-- de `perfiles` (perfil propio: leer / editar) ya cubren las columnas
-- nuevas.
-- ============================================================

alter table public.perfiles
  add column if not exists web text,
  add column if not exists descripcion_web text,
  add column if not exists web_lineas text[];

comment on column public.perfiles.web is
  'Web de la empresa que dio en el alta sin NIF (decisión 49).';
comment on column public.perfiles.descripcion_web is
  'Lo que dice su web que hace, revisado por el cliente. Va detrás de descripcion para el filtro, el criterio y el juez.';
comment on column public.perfiles.web_lineas is
  'Productos o servicios de su web, revisados por el cliente: se buscan contratos parecidos a cada uno.';
