-- ============================================================
-- VUELTA ATRÁS de las migraciones del 20/09/2026
-- ============================================================
-- Solo si algo se rompe y hace falta volver al estado anterior.
-- Devuelve los permisos tal y como estaban: EXECUTE para `anon` y
-- `authenticated` en todas las funciones del esquema público.
--
-- ESTO REABRE LOS AGUJEROS. Úsalo como parada de emergencia, no
-- como solución: la lista de clientes con sus correos vuelve a
-- quedar accesible sin cuenta.
--
-- El respaldo de la ACL original se tomó antes de aplicar: todas
-- las funciones propias tenían exactamente
--   =X/postgres anon=X/postgres authenticated=X/postgres
--   service_role=X/postgres
-- así que restaurar es uniforme y no hace falta caso por caso.
-- ============================================================

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as firma
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prorettype <> 'trigger'::regtype
      and not exists (
        select 1 from pg_depend d
        where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('grant execute on function %s to public, anon, authenticated', f.firma);
  end loop;
end $$;

alter default privileges in schema public
  grant execute on functions to public;

-- La migración 2/2 solo AÑADIÓ una comprobación de propiedad dentro
-- de tres funciones. No hace falta revertirla salvo que se demuestre
-- que rompe la función Edge; en ese caso, la condición a revisar es
-- `public.perfil_permitido(uuid)`, que devuelve true cuando
-- auth.uid() es null (es decir, con clave de servicio).
