-- Ficha de empresa, pestaña Contratos: "N más en otros años" solo con
-- años que se pueden elegir.
--
-- Con "Todos los años" elegido decía "169 más en otros años": la empresa
-- tiene adjudicaciones sueltas de 2005 y de 2019-2022, pero el selector
-- solo ofrece los años con datos del sector (desde 2023). Señalar años que
-- no se pueden elegir confunde. La web pasa ahora el rango del selector
-- (`rango_desde`, `rango_hasta`) y solo se cuenta lo que cae dentro.
-- Lo demás, como en 20261009120000.

drop function if exists public.contratos_empresa(text, integer, integer, text, text, text, text, integer, integer);

create or replace function public.contratos_empresa(
    cif_buscado text,
    desde integer default null,
    hasta integer default null,
    buscar text default null,
    sector_elegido text default null,
    organo_elegido text default null,
    orden text default 'fecha',
    saltar integer default 0,
    cuantos integer default 20,
    rango_desde integer default null,
    rango_hasta integer default null)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio   text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
    -- Cada palabra tiene que estar en el título o en el organismo, en
    -- cualquier orden: "limpieza colegios" encuentra "Servicio de limpieza
    -- de los colegios públicos".
    palabras text[] := array_remove(regexp_split_to_array(
                           public.texto_buscable(trim(buscar)), '\s+'), '');
    tope     int := least(greatest(coalesce(cuantos, 20), 1), 100);
    desde_n  int := greatest(coalesce(saltar, 0), 0);
begin
    return (
        with suyas as (
            select s.titulo, s.organo, s.sector, a.fecha, a.importe as suyo,
                   a.lotes, s.duracion_meses, s.enlace,
                   public.en_periodo(a.fecha, desde, hasta) as dentro
            from public.adjudicaciones_empresa a
            join public.licitaciones s on s.id_licitacion = a.id_licitacion
            where a.cif = limpio
              and not a.es_menor and not a.es_homologacion
              and (sector_elegido is null or s.sector = sector_elegido)
              and (organo_elegido is null or s.organo = organo_elegido)
              and (cardinality(palabras) = 0 or not exists (
                    select 1 from unnest(palabras) p
                    where strpos(public.texto_buscable(
                              s.titulo || ' ' || coalesce(s.organo, '')), p) = 0))
        ),
        ordenadas as (
            select t.*, row_number() over (order by
                       case when orden = 'importe' then t.suyo end desc nulls last,
                       t.fecha desc nulls last, t.titulo) as n
            from suyas t
            where t.dentro
        )
        select jsonb_build_object(
            'total', (select count(*) from ordenadas),
            -- Los que cumplen lo pedido pero caen fuera del periodo: para
            -- decir "ninguno en 2025 · 3 en otros años" en vez de "no hay".
            'fuera_del_periodo', (select count(*) from suyas
                                  where not dentro
                                    and public.en_periodo(fecha, rango_desde, rango_hasta)),
            'contratos', coalesce((
                select jsonb_agg(jsonb_build_object(
                           'titulo', c.titulo, 'organo', c.organo, 'sector', c.sector,
                           'importe', c.suyo, 'lotes', c.lotes,
                           'duracion_meses', c.duracion_meses,
                           'enlace', c.enlace, 'fecha', c.fecha)
                         order by c.n)
                from ordenadas c
                where c.n > desde_n and c.n <= desde_n + tope), '[]'::jsonb))
    );
end;
$function$;

revoke execute on function public.contratos_empresa(text, integer, integer, text, text, text, text, integer, integer, integer, integer) from public, anon;
grant execute on function public.contratos_empresa(text, integer, integer, text, text, text, text, integer, integer, integer, integer) to authenticated;
