-- ============================================================
-- Lo que viene: el refresco diario de `vencimientos`, con tiempo
-- ============================================================
--
-- `refrescar_vencimientos()` sin argumentos recorre `licitaciones`
-- entera (estimado en el LEEME de la hoja de ruta: 1,5-2,5 minutos). Por
-- `pg_cron` corre con el tope de sentencia por defecto (2 minutos), y el
-- 06/10/2026 a las 14:45 se cortó ("canceling statement due to statement
-- timeout", en `meses_de_prorroga`): la tabla se quedó con lo calculado a
-- mano esa mañana. Su hermana `refrescar_vencimientos_nueva` ya lleva
-- 600 s; esta, lo mismo.
-- ============================================================

alter function public.refrescar_vencimientos(text[]) set statement_timeout to '600s';
