-- ============================================================
-- Mi cartera: el disparador de correcciones, con las reglas de la
-- cartera
-- ============================================================
--
-- Afina `cartera_desde_correccion` (20261007160000), por la auditoría
-- del 07/10/2026:
--   · Solo contratos abiertos (publicados, con plazo vigente o sin plazo,
--     y no sustituidos), como el relleno de la migración de la cartera.
--   · El plazo visto es el de la copia vigente (`licitacion_vigente`): si
--     no, en un republicado la web diría "el organismo ha cambiado el
--     plazo" nada más guardarlo.
--   · El tope de 1.000 contratos por perfil de `poner_en_cartera`.
-- Sigue sin pisar lo que ya está en la cartera (`do nothing`): cuando
-- llega desde `poner_en_cartera`, el contrato ya está y no hace nada.
-- ============================================================

create or replace function public.cartera_desde_correccion()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v public.licitaciones%rowtype;
begin
    if not new.interesa or (tg_op = 'UPDATE' and old.interesa is not distinct from true) then
        return null;
    end if;
    if exists (select 1 from public.cartera
               where perfil_id = new.perfil_id and id_licitacion = new.id_licitacion)
       or (select count(*) from public.cartera where perfil_id = new.perfil_id) >= 1000 then
        return null;
    end if;
    v := public.licitacion_vigente(new.id_licitacion);
    if v.id_licitacion is null
       or coalesce(v.estado_licitacion, '') <> 'PUB'
       or coalesce(v.sustituida, false)
       or (v.fecha_limite is not null and v.fecha_limite < now()) then
        return null;
    end if;
    insert into public.cartera (perfil_id, id_licitacion, estado, plazo_visto)
    values (new.perfil_id, new.id_licitacion, 'interesa', v.fecha_limite)
    on conflict (perfil_id, id_licitacion) do nothing;
    return null;
end;
$function$;

revoke execute on function public.cartera_desde_correccion() from public, anon, authenticated;
