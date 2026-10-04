-- Enlace al expediente en las fichas de organismo y de empresa.
--
-- `licitaciones.enlace` ya se guarda para todos los contratos, pero las
-- fichas no lo devolvían: la lista de contratos de un organismo, los
-- últimos contratos de una empresa y sus acuerdos marco salían sin él.
-- Se añade `enlace` a esas tres listas. El resto de la función queda como
-- estaba.
--
-- Además se arreglan 280 enlaces de Navarra y Bilbao: la fuente los publica
-- con un resto de concatenación SQL (`&' || 'Ticket=…`) pegado a la URL.

update public.licitaciones
   set enlace = replace(enlace, '&'' || ''', '&')
 where enlace like '%'' || ''%';


create or replace function public.ficha_organismo(organo_buscado text, desde integer default null::integer, hasta integer default null::integer)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
    resultado jsonb;
begin
    if public.mi_perfil_id() is null then return '{}'::jsonb; end if;

    with yo as (
        select p.cif,
               array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    ),
    suyas as materialized (
        select l.id_licitacion,
               public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                l.fecha_formalizacion_estimada, l.fecha_actualizacion) as fecha,
               l.provincia,
               l.importe_adjudicacion, l.presupuesto_base, l.importe_sin_iva,
               l.lotes, l.sistema, l.licitadores, l.procedimiento,
               yo.cif as mi_cif
        from yo
        cross join public.licitaciones l
        where l.organo = organo_buscado
          and l.prefijo_principal = any(yo.prefijos)
          and l.adjudicatario_cif is not null
          and l.procedimiento is distinct from 'Contrato menor'
          and not public.es_homologacion(l.sistema, l.importe_adjudicacion)
          and public.en_periodo(public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                l.fecha_formalizacion_estimada, l.fecha_actualizacion),
                                desde, hasta)
    ),
    ganadores as (
        select s.id_licitacion, s.fecha, s.mi_cif,
               a.cif, a.nombre, a.importe, a.principal
        from suyas s
        join public.adjudicaciones_empresa a on a.id_licitacion = s.id_licitacion
    )
    select jsonb_build_object(
        'organo', organo_buscado,
        'desde', desde,
        'hasta', hasta,
        'provincia', (select provincia from suyas
                      order by fecha desc limit 1),
        'contratos', (select count(*) from suyas),
        'n_empresas', (select count(distinct cif) from ganadores),
        'importe', (select coalesce(sum(importe_adjudicacion), 0) from suyas),
        'baja_sector', null,
        'licitadores_sector', null,
        'baja_media', (
            select round(avg(public.baja_real(s.presupuesto_base,
                       s.importe_sin_iva, s.lotes, s.sistema)))
            from suyas s
            where public.baja_real(s.presupuesto_base, s.importe_sin_iva,
                                   s.lotes, s.sistema) is not null),
        'con_baja', (
            select count(*) from suyas s
            where public.baja_real(s.presupuesto_base, s.importe_sin_iva,
                                   s.lotes, s.sistema) is not null),
        'licitadores_medio', (select round(avg(licitadores), 1) from suyas
                              where licitadores is not null),
        'sin_competencia', (select count(*) from suyas where licitadores = 1),
        'con_licitadores', (select count(*) from suyas
                            where licitadores is not null),
        'procedimientos', (
            select jsonb_agg(jsonb_build_object('cual', t.procedimiento,
                                                'cuantos', t.n) order by t.n desc)
            from (select procedimiento, count(*)::int as n from suyas
                  where procedimiento is not null
                  group by procedimiento order by n desc limit 4) t),
        'empresas', (
            select jsonb_agg(jsonb_build_object(
                       'nombre', t.nombre, 'cif', t.cif, 'contratos', t.n,
                       'importe', t.euros, 'es_mia', t.es_mia)
                     order by t.n desc, t.euros desc nulls last)
            from (
                select g.cif,
                       (array_agg(g.nombre order by g.fecha desc))[1] as nombre,
                       count(*)::int as n,
                       coalesce(sum(g.importe), 0) as euros,
                       bool_or(g.cif = g.mi_cif) as es_mia
                from ganadores g group by g.cif
                order by count(*) desc limit 20
            ) t),
        'contratos_lista', (
            select jsonb_agg(jsonb_build_object(
                       'titulo', u.titulo, 'empresa', u.adjudicatario,
                       'cif', u.adjudicatario_cif,
                       'enlace', u.enlace,
                       'importe', (select g.importe from ganadores g
                                   where g.id_licitacion = u.id_licitacion
                                     and g.principal),
                       'total', u.importe_adjudicacion,
                       'otros', (select count(*) - 1 from ganadores g
                                 where g.id_licitacion = u.id_licitacion),
                       'cifs', (select jsonb_agg(g.cif) from ganadores g
                                where g.id_licitacion = u.id_licitacion),
                       'partes', (select jsonb_object_agg(g.cif, g.importe)
                                  from ganadores g
                                  where g.id_licitacion = u.id_licitacion),
                       'fecha', u.fecha,
                       'es_mia', exists (select 1 from ganadores g
                                         where g.id_licitacion = u.id_licitacion
                                           and g.cif = u.mi_cif),
                       'licitadores', u.licitadores,
                       'oferta_baja', u.oferta_baja, 'oferta_alta', u.oferta_alta,
                       'baja', public.baja_real(u.presupuesto_base,
                                 u.importe_sin_iva, u.lotes, u.sistema))
                     order by u.fecha desc)
            from (select s.*, l.titulo, l.adjudicatario, l.adjudicatario_cif,
                         l.oferta_baja, l.oferta_alta, l.enlace
                  from (select * from suyas
                        order by fecha desc limit 40) s
                  join public.licitaciones l on l.id_licitacion = s.id_licitacion) u)
    ) into resultado;

    return resultado;
end;
$function$;


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
