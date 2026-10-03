-- ============================================================
-- socios_de_utes: quién forma cada UTE de una lista de NIF
-- ============================================================
--
-- Para la ficha de organismo (03/10/2026): las UTEs salen en su lista
-- de empresas y de contratos como una empresa más, con nombres opacos
-- ("UTE BAJO SELLA 2025"). La web le pasa los NIF que va a enseñar y
-- marca los que son UTE, con sus socios cuando se conocen
-- (`ute_socios`, decisión 42).
--
-- No toca `ficha_organismo`: la web la llama aparte, y si falla la
-- ficha sale igual, sin las marcas. Tampoco cambia ninguna cifra: la
-- UTE sigue contando como una empresa.
--
-- Devuelve {nif: [{cif, nombre}, ...]} solo de los NIF con socios.
-- ============================================================

create or replace function public.socios_de_utes(cifs text[])
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
begin
    if public.mi_perfil_id() is null then return '{}'::jsonb; end if;

    return coalesce((
        select jsonb_object_agg(t.ute_cif, t.socios)
        from (
            select o.ute_cif,
                   jsonb_agg(jsonb_build_object(
                       'cif', o.socio_cif,
                       'nombre', coalesce(e.nombre, o.socio_cif))
                     order by e.nombre) as socios
            from public.ute_socios o
            left join public.empresas e on e.cif = o.socio_cif
            -- Tope: la ficha enseña 10 empresas y 40 contratos.
            where o.ute_cif = any(cifs[1:100])
            group by o.ute_cif
        ) t
    ), '{}'::jsonb);
end;
$function$;

revoke execute on function public.socios_de_utes(text[]) from public, anon;
grant execute on function public.socios_de_utes(text[]) to authenticated;
