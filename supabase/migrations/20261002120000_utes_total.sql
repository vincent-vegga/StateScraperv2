-- ============================================================
-- utes_y_socios: también cuántas UTEs hay en total
-- ============================================================
--
-- La lista se corta en las 30 más recientes, y la web contaba las que
-- llegaban: a Dragados (38 UTEs) el botón le decía 30. Ahora la función
-- devuelve además `n_utes`, el total en el periodo, para el botón y para
-- avisar de que la lista está recortada.
--
-- Igual que 20261001120000_utes_socios.sql salvo `n_utes`. Solo toca la
-- función de las UTEs.
-- ============================================================

create or replace function public.utes_y_socios(
    cif_buscado text, desde integer default null::integer,
    hasta integer default null::integer)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
begin
    if public.mi_perfil_id() is null then return '{}'::jsonb; end if;

    return (
        with todas as (
            select s.ute_cif,
                   (array_agg(a.nombre order by a.fecha desc nulls last))[1] as nombre,
                   count(*)::int as n,
                   coalesce(sum(a.importe), 0) as euros,
                   max(a.fecha) as ultimo
            from public.ute_socios s
            join public.adjudicaciones_empresa a on a.cif = s.ute_cif
            where s.socio_cif = limpio
              and not a.es_menor and not a.es_homologacion
              and public.en_periodo(a.fecha, desde, hasta)
            group by s.ute_cif
        )
        select jsonb_build_object(
            'n_utes', (select count(*) from todas),
            'utes', (
                select jsonb_agg(jsonb_build_object(
                           'cif', t.ute_cif, 'nombre', t.nombre,
                           'contratos', t.n, 'importe_ute', t.euros,
                           'ultimo', t.ultimo,
                           'socios', (
                               select jsonb_agg(jsonb_build_object(
                                          'cif', o.socio_cif,
                                          'nombre', coalesce(e.nombre, o.socio_cif))
                                        order by e.nombre)
                               from public.ute_socios o
                               left join public.empresas e on e.cif = o.socio_cif
                               where o.ute_cif = t.ute_cif and o.socio_cif <> limpio))
                         order by t.ultimo desc nulls last)
                from (select * from todas
                      order by ultimo desc nulls last limit 30) t
            ),
            'socios', (
                select jsonb_agg(jsonb_build_object(
                           'cif', o.socio_cif,
                           'nombre', coalesce(e.nombre, o.socio_cif))
                         order by e.nombre)
                from public.ute_socios o
                left join public.empresas e on e.cif = o.socio_cif
                where o.ute_cif = limpio
            )
        )
    );
end;
$function$;

revoke execute on function public.utes_y_socios(text, integer, integer) from public, anon;
grant execute on function public.utes_y_socios(text, integer, integer) to authenticated;
