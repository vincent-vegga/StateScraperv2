-- ============================================================
-- ÍNDICE PARA "LICITACIONES VIVAS"
-- ============================================================
-- Aplicada el 20/09/2026. Va con 20260920140200_pendientes_de_perfil.
--
-- De las 177.641 licitaciones en estado PUB, solo 4.517 siguen vivas.
-- La condición `fecha_limite is null or fecha_limite >= now()` no
-- permite barrido de rango por culpa del OR. Escrita como
-- `coalesce(fecha_limite,'infinity') >= now()` sí, con el mismo
-- significado y el mismo orden ('infinity' al final, igual que
-- `nulls last`).
--
-- No se puede meter now() en el predicado de un índice parcial (no es
-- inmutable), así que el índice cubre todo PUB y es el rango el que se
-- queda con las vivas.
create index if not exists idx_licitaciones_vivas
    on public.licitaciones (coalesce(fecha_limite, 'infinity'::timestamptz))
    where coalesce(estado_licitacion, '') = 'PUB';
