-- ============================================================
-- muestra_de_familias SIN EL TOPE DE 1.000 FILAS DE LA API
-- ============================================================
--
-- Aplicada el 24/09/2026.
--
-- EL FALLO
-- PostgREST devuelve como mucho 1.000 filas de una función que devuelve
-- un conjunto (db-max-rows). Un alta con ocho familias pedía unas 5.000:
-- llegaban solo las primeras por orden de código, las de dos familias.
-- La pantalla enseñaba ejemplos solo bajo esas dos, y el filtro se
-- construía con ellas: un alta de suministro a centros educativos salió
-- con 35 códigos, todos de ropa y material sanitario. No se vio en la
-- prueba de vecinos.ts porque esa leía los contratos por otro camino.
--
-- LA SOLUCIÓN
-- La misma consulta, devuelta como UN valor jsonb: una sola fila, sin
-- tope. La función antigua se queda (no molesta) hasta que no la use
-- nadie.
-- ============================================================

create or replace function public.muestra_de_familias_json(familias text[], tope integer default 6000)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb)
    from public.muestra_de_familias(familias, tope) m;
$function$;

revoke all on function public.muestra_de_familias_json(text[], integer) from public, anon, authenticated;
grant execute on function public.muestra_de_familias_json(text[], integer) to service_role;
