-- ============================================================
-- 1/2 · CERRAR LAS FUNCIONES AL VISITANTE ANÓNIMO
-- ============================================================
--
-- Aplicada el 20/09/2026.
--
-- EL PROBLEMA
-- Al crear una función, PostgreSQL concede EXECUTE a PUBLIC por
-- defecto. El rol `anon` hereda de PUBLIC y PostgREST publica el
-- esquema `public`: toda función creada aquí queda invocable desde
-- Internet sin cuenta. El linter de Supabase lo confirma con 39
-- avisos `anon_security_definer_function_executable`.
--
-- Las políticas RLS de este proyecto están BIEN (todas atadas a
-- auth.uid() a través de `perfiles`). Da igual: una función
-- SECURITY DEFINER lee las tablas con los permisos de quien la
-- creó, así que se salta la política por completo.
--
-- CUIDADO CON LAS EXTENSIONES
-- `pg_trgm` está instalado en `public`, así que un revoke a ciegas
-- sobre el esquema alcanzaría a similarity(), show_trgm() y los
-- operadores GIN, y rompería las búsquedas por parecido de la web.
-- Por eso se excluyen las funciones que pertenecen a una extensión
-- (pg_depend.deptype = 'e').
--
-- EL CRITERIO
--   Grupo A · las llama web/index.html con sesión -> `authenticated`
--   Grupo B · el resto -> solo con clave de servicio
--
-- `service_role` no se ve afectado: tiene sus permisos por separado.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Quitar el permiso heredado de PUBLIC en las funciones
--    propias del proyecto. Las de extensión quedan intactas.
-- ------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as firma
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      -- Las funciones de trigger no se invocan por RPC; da igual,
      -- pero se excluyen para no tocar lo que no hace falta.
      and p.prorettype <> 'trigger'::regtype
      and not exists (
        select 1 from pg_depend d
        where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.firma);
  end loop;
end $$;


-- ------------------------------------------------------------
-- 2. GRUPO A · Devolver el permiso al usuario con sesión.
--    Son exactamente las que llama el navegador. Sin esto, la
--    aplicación deja de funcionar para los clientes.
--
--    OJO: `authenticated` es cualquiera con cuenta, no el dueño
--    del dato. `pendientes_de_perfil` recibe el perfil como
--    parámetro y no comprobaba de quién era; eso lo arregla la migración 2/2,
--    que debe aplicarse junto con esta.
-- ------------------------------------------------------------
do $$
declare
  f record;
  -- Las 19 que llama el navegador. Tres de ellas ('analizables',
  -- 'movimientos_mercado', 'pulso_mercado') no aparecen como texto
  -- literal: van por el envoltorio `pedir(nombre, args)` de
  -- web/index.html:3618, que recibe el nombre en una variable.
  -- Buscar solo `.rpc('...')` las dejaba fuera y habría roto las
  -- pantallas de mercado y de análisis.
  permitidas text[] := array[
    'analizables', 'anios_de_organismo', 'buscar_organismo',
    'cambiar_avisos', 'canjear_codigo', 'competencia', 'corregir',
    'ficha_empresa', 'ficha_organismo', 'marcar_bienvenida',
    'marcar_visita', 'mercado_sin_cribar', 'mi_panel',
    'mi_seguimiento', 'movimientos_mercado', 'pendientes_de_perfil',
    'pulso_mercado', 'seguir', 'viabilidad'
  ];
begin
  for f in
    select p.oid::regprocedure as firma
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.proname = any(permitidas)
  loop
    execute format('grant execute on function %s to authenticated', f.firma);
  end loop;
end $$;


-- ------------------------------------------------------------
-- 3. GRUPO B · No se devuelve el permiso a nadie.
--
--    Quedan solo para la clave de servicio. Las que servían datos
--    a cualquiera, comprobado en producción el 20/09/2026:
--
--      perfiles_con_novedades   <- la lista de clientes con su correo
--      novedades_de_perfil      <- las oportunidades de cualquier perfil
--      mercado_sin_cribar_de    <- ídem
--      buscar_empresa           <- histórico de adjudicaciones
--      ultimos_ganados          historial_empresa
--      cpvs_de_empresa          prefijos_de_empresa
--      material_de_empresa      licitaciones_del_vecindario
--      licitaciones_por_prefijo licitaciones_por_afinidad
--      incumbencia              ediciones_anteriores
--      organismos_del_sector    ranking_mercado
--      utilidad_palabras
--
--    Y las que ESCRIBEN sin comprobar nada:
--
--      completar_adjudicatarios  completar_criterios
--      completar_explicacion     guardar_criba_mercado
--      refrescar_resumen_cpv     rellenar_* (5)
-- ------------------------------------------------------------


-- ------------------------------------------------------------
-- 4. Que no vuelva a pasar.
--    ALTER DEFAULT PRIVILEGES actúa por rol creador: esta línea
--    cubre a quien ejecute la migración. Si las funciones se crean
--    desde el panel con otro rol, repetir con `for role <ese rol>`.
-- ------------------------------------------------------------
alter default privileges in schema public
  revoke execute on functions from public;

commit;

-- Comprobación: tras aplicar, get_advisors(security) no debería
-- devolver avisos `anon_security_definer_function_executable`.
