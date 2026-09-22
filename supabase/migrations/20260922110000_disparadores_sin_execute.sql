-- ============================================================
-- DISPARADORES SIN PERMISO DE EJECUCIÓN PARA LA API
-- ============================================================
--
-- El asesor de seguridad de Supabase avisaba de que estas tres funciones
-- SECURITY DEFINER se podían ejecutar sin iniciar sesión por
-- /rest/v1/rpc/. Las tres devuelven `trigger`, y Postgres no deja
-- llamarlas si no es como disparador, así que el riesgo real era nulo.
-- Pero el permiso no hace falta para nada: el EXECUTE de una función de
-- disparador se comprueba al CREAR el disparador, no cada vez que salta.
--
-- Ensayado el 22/09/2026 en una transacción deshecha: con el permiso ya
-- retirado, un usuario normal insertó en `seguimiento` y el disparador
-- (olvidar_competencia) funcionó igual.
--
--   olvidar_competencia    -> seguimiento.trg_olvidar_competencia
--   rellenar_territorio    -> licitaciones.trg_territorio
--   sync_palabras_titulo   -> licitaciones.trg_sync_palabras_titulo
-- ============================================================

revoke execute on function public.olvidar_competencia()  from public, anon, authenticated;
revoke execute on function public.rellenar_territorio()  from public, anon, authenticated;
revoke execute on function public.sync_palabras_titulo() from public, anon, authenticated;
