-- ============================================================
-- Periodo por años: que quepa en el tiempo de la API
-- ============================================================
--
-- Aplicada el 22/09/2026, justo después de 20260922170000.
--
-- Con un perfil de cinco sectores (una distribuidora industrial, 19.181 contratos de 2024 a
-- 2026) el resumen de Movimientos tardaba 25 s y la API corta a los 8.
-- No era el cálculo: con las páginas en memoria la misma consulta tarda
-- 51 ms. Era leer del disco 16.675 páginas de `licitaciones`, una por
-- contrato, repartidas por 2,5 GB.
--
-- Arreglo:
--   - `idx_licitaciones_periodo`: sector y fecha, con las columnas que
--     necesitan los resúmenes dentro del índice (id, importe, órgano,
--     provincia). Postgres responde leyendo solo el índice, donde los
--     contratos de un sector y un periodo están juntos. 218 MB. Se creó
--     aparte con CONCURRENTLY para no bloquear al scraper:
--
--       create index concurrently idx_licitaciones_periodo
--       on public.licitaciones (prefijo_principal, fecha_actualizacion)
--       include (id_licitacion, importe_adjudicacion, organo, provincia)
--       where adjudicatario_cif is not null;
--
--   - `mercado_del_periodo` devuelve solo esas columnas, y la tabla
--     completa se lee únicamente para lo que se enseña: los 300 de la
--     lista y los tres contratos mayores de cada fila de ranking.
-- ============================================================

drop function if exists public.mercado_del_periodo(integer, integer, text);
create function public.mercado_del_periodo(
    desde integer default null, hasta integer default null,
    provincia_elegida text default null)
returns table(id_licitacion text, fecha timestamptz, importe numeric,
              organo text, provincia text)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id,
               array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    )
    select l.id_licitacion, l.fecha_actualizacion, l.importe_adjudicacion,
           l.organo, l.provincia
    from yo
    join public.licitaciones l
      on l.prefijo_principal = any(yo.prefijos)
     and l.adjudicatario_cif is not null
    where public.en_periodo(l.fecha_actualizacion, desde, hasta)
      and (provincia_elegida is null or l.provincia = provincia_elegida)
      and coalesce((select v.del_sector from public.veredictos_mercado v
                    where v.perfil_id = yo.id
                      and v.id_licitacion = l.id_licitacion), true);
$function$;

revoke execute on function public.mercado_del_periodo(integer, integer, text)
    from public, anon, authenticated;


create or replace function public.movimientos_periodo(
    desde integer default null, hasta integer default null,
    provincia_elegida text default null, tope integer default 300)
returns table(id_licitacion text, titulo text, organo text, provincia text,
              sector text, empresa text, cif text, importe numeric,
              presupuesto numeric, fecha timestamp with time zone, enlace text,
              es_mia boolean, la_sigo boolean, grupo text,
              total numeric, ganadores jsonb)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif from public.perfiles p
        where p.id = public.mi_perfil_id()
    ),
    -- Los más recientes, por el índice; la fila entera solo de estos.
    ultimos as (
        select m.id_licitacion, m.fecha
        from public.mercado_del_periodo(desde, hasta, provincia_elegida) m
        order by m.fecha desc
        limit least(coalesce(tope, 300), 1000)
    )
    select r.id_licitacion, r.titulo, r.organo, r.provincia, r.sector,
           r.adjudicatario, r.adjudicatario_cif,
           (select a.importe from public.adjudicaciones_empresa a
            where a.id_licitacion = r.id_licitacion and a.principal),
           r.presupuesto,
           r.fecha_actualizacion, r.enlace,
           g.es_mia, g.la_sigo,
           coalesce(r.organo, '') || ' ·· ' || coalesce(r.titulo_normal, r.titulo),
           r.importe_adjudicacion,
           g.lista
    from ultimos u
    join public.licitaciones r on r.id_licitacion = u.id_licitacion
    cross join yo
    cross join lateral (
        select coalesce(bool_or(x.es_mia), false) as es_mia,
               coalesce(bool_or(x.la_sigo), false) as la_sigo,
               jsonb_agg(jsonb_build_object(
                   'cif', x.cif, 'nombre', x.nombre, 'importe', x.importe,
                   'lotes', x.lotes, 'es_mia', x.es_mia, 'la_sigo', x.la_sigo)
                   order by x.principal desc, x.importe desc nulls last) as lista
        from (
            select a.*, a.cif = yo.cif as es_mia,
                   exists (select 1 from public.seguimiento s
                           where s.perfil_id = yo.id and s.cif = a.cif) as la_sigo
            from public.adjudicaciones_empresa a
            where a.id_licitacion = r.id_licitacion
        ) x
    ) g
    order by u.fecha desc;
$function$;


create or replace function public.resumen_periodo(
    desde integer default null, hasta integer default null,
    provincia_elegida text default null)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif from public.perfiles p
        where p.id = public.mi_perfil_id()
    ),
    todas as materialized (
        select * from public.mercado_del_periodo(desde, hasta, null)
    ),
    movidas as materialized (
        select * from todas
        where provincia_elegida is null or provincia = provincia_elegida
    ),
    ganadores as materialized (
        select m.id_licitacion, m.organo, a.cif, a.nombre, a.importe,
               a.cif = yo.cif as es_mia
        from movidas m
        join public.adjudicaciones_empresa a on a.id_licitacion = m.id_licitacion
        cross join yo
    ),
    por_empresa as materialized (
        select g.cif as clave,
               (array_agg(g.nombre))[1] as nombre,
               count(*)::int as n,
               coalesce(sum(g.importe), 0) as euros,
               bool_or(g.es_mia) as es_mia
        from ganadores g group by g.cif
        order by coalesce(sum(g.importe), 0) desc, count(*) desc
        limit 6
    ),
    por_organo as materialized (
        select m.organo as clave,
               (array_agg(m.provincia))[1] as provincia,
               count(*)::int as n,
               coalesce(sum(m.importe), 0) as euros
        from movidas m where m.organo is not null
        group by m.organo
        order by coalesce(sum(m.importe), 0) desc, count(*) desc
        limit 6
    )
    select jsonb_build_object(
        'contratos', (select count(*) from movidas),
        'importe', (select coalesce(sum(importe), 0) from movidas),
        'empresas', (select count(distinct cif) from ganadores),
        'mias', (select count(distinct id_licitacion) from ganadores where es_mia),
        'importe_medio', (select round(avg(importe))
                          from movidas where importe > 0),
        -- Las provincias salen del periodo SIN filtrar por provincia: si
        -- no, al elegir una el desplegable se quedaba solo con ella.
        'provincias', (select jsonb_agg(t.provincia order by t.provincia)
                       from (select distinct provincia from todas
                             where provincia is not null) t),
        'por_empresa', (
            select jsonb_agg(jsonb_build_object(
                       'clave', e.clave, 'nombre', e.nombre, 'n', e.n,
                       'euros', e.euros, 'es_mia', e.es_mia,
                       'la_sigo', exists (select 1 from public.seguimiento s, yo
                                          where s.perfil_id = yo.id and s.cif = e.clave),
                       'tramos', (select jsonb_agg(jsonb_build_object(
                                      'titulo', l.titulo, 'quien', t.organo,
                                      'importe', t.importe)
                                    order by t.importe desc nulls last)
                                  from (select * from ganadores g
                                        where g.cif = e.clave
                                        order by g.importe desc nulls last
                                        limit 3) t
                                  join public.licitaciones l
                                    on l.id_licitacion = t.id_licitacion),
                       'resto_n', greatest(e.n - 3, 0),
                       'resto_importe', (select coalesce(sum(r.importe), 0) from (
                                            select g.importe from ganadores g
                                            where g.cif = e.clave
                                            order by g.importe desc nulls last
                                            offset 3) r))
                     order by e.euros desc, e.n desc)
            from por_empresa e),
        'por_organo', (
            select jsonb_agg(jsonb_build_object(
                       'clave', o.clave, 'nombre', o.clave, 'provincia', o.provincia,
                       'n', o.n, 'euros', o.euros, 'es_mia', false, 'la_sigo', false,
                       'tramos', (select jsonb_agg(jsonb_build_object(
                                      'titulo', l.titulo, 'quien', l.adjudicatario,
                                      'importe', t.importe)
                                    order by t.importe desc nulls last)
                                  from (select * from movidas m
                                        where m.organo = o.clave
                                        order by m.importe desc nulls last
                                        limit 3) t
                                  join public.licitaciones l
                                    on l.id_licitacion = t.id_licitacion),
                       'resto_n', greatest(o.n - 3, 0),
                       'resto_importe', (select coalesce(sum(r.importe), 0) from (
                                            select m.importe from movidas m
                                            where m.organo = o.clave
                                            order by m.importe desc nulls last
                                            offset 3) r))
                     order by o.euros desc, o.n desc)
            from por_organo o)
    );
$function$;


create or replace function public.competencia_periodo(
    desde integer default null, hasta integer default null)
returns table(cif text, nombre text, contratos integer, importe numeric, sigo boolean)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif from public.perfiles p
        where p.id = public.mi_perfil_id()
    )
    select a.cif,
           (array_agg(a.nombre order by m.fecha desc))[1],
           count(*)::int,
           coalesce(sum(a.importe), 0),
           false
    from public.mercado_del_periodo(desde, hasta, null) m
    join public.adjudicaciones_empresa a on a.id_licitacion = m.id_licitacion
    cross join yo
    where a.cif is distinct from yo.cif
      and not exists (select 1 from public.seguimiento sg
                      where sg.perfil_id = yo.id and sg.cif = a.cif)
    group by a.cif
    order by count(*) desc, coalesce(sum(a.importe), 0) desc
    limit 25;
$function$;
