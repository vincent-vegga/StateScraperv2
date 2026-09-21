-- ============================================================
-- LOS AGREGADOS, DESPUÉS DEL SCRAPER Y NO ANTES
-- ============================================================
--
-- Aplicada el 21/09/2026.
--
-- EL FALLO
-- Los trabajos de pg_cron se programaron a las 06:20-06:50 UTC contando
-- con que el scraper, programado a las 06:00, habría terminado. Pero
-- GitHub retrasa los cron de Actions, y mucho. Ejecuciones reales:
--
--     15/09  06:12 -> 06:55
--     17/09  11:16 -> 12:05
--     18/09  10:49 -> 11:22
--     19/09  10:33 -> 10:53
--     20/09  10:55 -> 11:38
--
-- Los agregados se calculaban cinco horas ANTES de que entrara lo del
-- día: Movimientos, Organismos y Empresas iban siempre un día por
-- detrás, y la tabla de órganos no veía los órganos nuevos hasta el
-- día siguiente.
--
-- LA SOLUCIÓN
-- Moverlos a las 14:00-14:30 UTC, con dos horas de margen sobre la
-- peor ejecución vista. Mismo orden que antes: primero las provincias,
-- para que los organismos ya las tengan.
--
-- Si algún día el scraper se programa a otra hora, o deja de sufrir
-- estos retrasos, hay que mover esto con él.
-- ============================================================

select cron.schedule('refrescar-organos-provincia', '0 14 * * *',
                     $$select public.refrescar_organos_provincia()$$);
select cron.schedule('refrescar-organismos', '10 14 * * *',
                     $$select public.refrescar_organismos()$$);
select cron.schedule('refrescar-empresas-por-cif', '20 14 * * *',
                     $$select public.refrescar_empresas()$$);
select cron.schedule('refrescar-catalogo-empresas', '30 14 * * *',
                     $$select public.refrescar_catalogo_empresas()$$);
