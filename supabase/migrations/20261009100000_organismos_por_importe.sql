-- La ficha de empresa, "a quién le vende": también por dinero.
--
-- `organos` trae los 8 organismos con más contratos. Con un interruptor la
-- web los ordena por importe, pero reordenar esos 8 no basta: el organismo
-- que le paga más puede tener un solo contrato y quedarse fuera. Se añade
-- `organos_importe`, los 8 con más importe. El resto de la función queda
-- como estaba.

create or replace function public.ficha_empresa(cif_buscado text, desde integer default null::integer, hasta integer default null::integer)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
    limpio text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
begin
    return (
        with suyas as (
            select s.titulo, s.organo, s.sector, a.fecha,
                   a.nombre, a.importe as suyo, a.lotes,
                   s.duracion_meses, s.enlace
            from public.adjudicaciones_empresa a
            join public.licitaciones s on s.id_licitacion = a.id_licitacion
            where a.cif = limpio
              and not a.es_menor and not a.es_homologacion
              and public.en_periodo(a.fecha, desde, hasta)
        )
        select jsonb_build_object(
            'cif', limpio,
            'desde', desde,
            'hasta', hasta,
            'nombre', (select a.nombre
                       from public.adjudicaciones_empresa a
                       where a.cif = limpio
                       order by a.fecha desc nulls last limit 1),
            'contratos', count(*),
            'lotes', coalesce(sum(l.lotes), 0),
            'importe', coalesce(sum(l.suyo), 0),
            'primero', min(l.fecha),
            'ultimo', max(l.fecha),
            'sectores', (
                select jsonb_agg(jsonb_build_object(
                           'sector', t.sector, 'contratos', t.n, 'importe', t.euros)
                         order by t.euros desc nulls last)
                from (select s.sector, count(*)::int as n,
                             coalesce(sum(s.suyo), 0) as euros
                      from suyas s
                      where s.sector is not null
                      group by s.sector order by euros desc nulls last limit 10) t
            ),
            'organos', (
                select jsonb_agg(jsonb_build_object(
                           'organo', o.organo, 'contratos', o.n, 'importe', o.euros)
                         order by o.n desc)
                from (select s.organo, count(*)::int as n,
                             coalesce(sum(s.suyo), 0) as euros
                      from suyas s
                      where s.organo is not null
                      group by s.organo order by count(*) desc limit 8) o
            ),
            'organos_importe', (
                select jsonb_agg(jsonb_build_object(
                           'organo', o.organo, 'contratos', o.n, 'importe', o.euros)
                         order by o.euros desc, o.n desc)
                from (select s.organo, count(*)::int as n,
                             coalesce(sum(s.suyo), 0) as euros
                      from suyas s
                      where s.organo is not null
                      group by s.organo
                      order by coalesce(sum(s.suyo), 0) desc, count(*) desc limit 8) o
            ),
            'ultimos', (
                select jsonb_agg(jsonb_build_object(
                           'titulo', u.titulo, 'organo', u.organo,
                           'importe', u.suyo,
                           'duracion_meses', u.duracion_meses,
                           'enlace', u.enlace,
                           'fecha', u.fecha)
                         order by u.fecha desc)
                from (select s.titulo, s.organo, s.suyo, s.fecha, s.duracion_meses,
                             s.enlace
                      from suyas s
                      order by s.fecha desc limit 8) u
            ),
            'marcos', (
                select jsonb_agg(jsonb_build_object(
                           'organo', m.organo, 'titulo', m.titulo,
                           'lotes', m.lotes, 'fecha', m.fecha,
                           'enlace', m.enlace,
                           'valor_marco', m.valor_marco)
                         order by m.fecha desc)
                from (select s.organo, s.titulo, a.lotes, a.fecha, s.enlace,
                             coalesce(s.valor_estimado, s.presupuesto) as valor_marco
                      from public.adjudicaciones_empresa a
                      join public.licitaciones s on s.id_licitacion = a.id_licitacion
                      where a.cif = limpio
                        and a.es_homologacion
                        and public.en_periodo(a.fecha, desde, hasta)
                      order by a.fecha desc limit 20) m
            ),
            'sigo', exists (
                select 1 from public.seguimiento sg
                join public.perfiles p on p.id = sg.perfil_id
                where p.id = public.mi_perfil_id() and sg.cif = limpio)
        )
        from suyas l
    );
end;
$function$;
