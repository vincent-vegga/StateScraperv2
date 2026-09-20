-- ============================================================
-- AFINAR LA BÚSQUEDA POR NOMBRE
-- ============================================================
--
-- Aplicada el 21/09/2026, tras probar la aplicación en el navegador
-- con una sesión real. Dos fallos que solo se ven usándola.
--
--
-- 1 · LA NORMALIZACIÓN PEGABA LA FORMA SOCIETARIA AL NOMBRE
--
-- Buscar "ACS" devolvía ALVAC S.A., GERALVEZ PROYECTOS CONTRAC SL,
-- DISHOSPAC SL, SOLITIUM NOVAC S.L.U... y ninguna era ACS.
--
-- La normalización heredada quitaba TODO lo que no fuera letra o
-- dígito, así que:
--
--     ALVAC, S.A.   -> ALVACSA      contiene "ACS"
--     DISHOSPAC SL  -> DISHOSPACSL  contiene "ACS"
--
-- Cualquier empresa acabada en "AC" más su forma societaria coincidía.
-- Yo había conservado esa normalización a propósito, para no cambiar
-- el comportamiento al mover la búsqueda a la tabla `empresas`. Era
-- razonable entonces y claramente malo en cuanto se usó de verdad.
--
-- Ahora los separadores pasan a espacio y los espacios se colapsan:
--     ALVAC, S.A. -> ALVAC S A   ya no coincide
--     ACSA OBRAS  -> ACSA OBRAS  sigue coincidiendo
--
--
-- 2 · COINCIDÍA DENTRO DE PALABRA
--
-- Aun con espacios, "ACS" seguía devolviendo FACSA, PACSA, DACSA,
-- PWACS, SACSIS. Con siglas cortas —lo que la gente escribe— eso es
-- ruido. Ahora se exige coincidencia en INICIO DE PALABRA.
--
-- No se pierde nada con nombres normales: "DELOITTE" encuentra las
-- mismas 16 empresas que antes.
--
--
-- RESULTADO (rol authenticated)
--     ACCIONA ............  19 ms   las 10, todas de Acciona
--     ACS ................  60 ms   ACSA OBRAS, ACS MATERIAL
--     SERVEO .............  64 ms
--     DELOITTE ...........  509 ms
--     FERROVIAL .......... 1.815 ms
--     CONSTRUCCIONES ..... 2.413 ms
--
--
-- LÍMITE QUE CONVIENE CONOCER
-- A ACS no se la encuentra ni por CIF ni por nombre, y es correcto:
-- no tiene NI UN contrato a su nombre en los datos. Sus obras las
-- firman filiales que no llevan "ACS" en la razón social. Ninguna
-- búsqueda textual puede resolver eso; haría falta una tabla de
-- grupos empresariales, que no existe.
-- ============================================================

create or replace function public.normalizar_nombre(t text)
returns text
language sql
immutable
set search_path to 'public'
as $$
    select trim(regexp_replace(upper(coalesce(t, '')), '[^A-Z0-9]+', ' ', 'g'));
$$;

revoke execute on function public.normalizar_nombre(text) from public, anon;
grant  execute on function public.normalizar_nombre(text) to authenticated;

-- Los cuerpos nuevos de buscar_empresa y refrescar_catalogo_empresas
-- están en las migraciones `buscar_empresa_inicio_de_palabra` y
-- `normalizar_nombres_conservando_espacios`.
--
-- Reconstrucción de la columna, ya ejecutada:
--   update public.empresas set nombre_norm = public.normalizar_nombre(nombre)
--   where nombre_norm is distinct from public.normalizar_nombre(nombre);
--   analyze public.empresas;
