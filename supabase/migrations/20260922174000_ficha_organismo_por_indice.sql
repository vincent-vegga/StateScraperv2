-- ============================================================
-- Ficha de organismo: por índice, también con muchos contratos
-- ============================================================
--
-- Aplicada el 22/09/2026. Con tres años, el organismo con más contratos
-- de un sector (5.442) tardaba 4,6 s en frío: leía de la tabla una fila
-- entera por contrato. Ahora las cifras salen de un índice por
-- organismo, sector y fecha con las columnas que usan dentro, y la fila
-- entera solo se lee para los 40 contratos que se enseñan.
--
-- Creado aparte, con CONCURRENTLY (281 MB):
--
--   create index concurrently idx_licitaciones_organo_periodo
--   on public.licitaciones (organo, prefijo_principal, fecha_actualizacion)
--   include (id_licitacion, importe_adjudicacion, presupuesto_base,
--            importe_sin_iva, lotes, sistema, licitadores, procedimiento,
--            provincia)
--   where adjudicatario_cif is not null;
--
-- Y se quitaron tres que ya no hacían falta, porque los nuevos empiezan
-- por las mismas columnas (153 MB):
--
--   drop index concurrently idx_licitaciones_organo_prefijo;  -- organo, prefijo
--   drop index concurrently idx_licitaciones_mercado;         -- prefijo, fecha
--   drop index concurrently idx_licitaciones_prefijo_fecha;   -- prefijo, fecha desc
-- ============================================================

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
    -- Solo las columnas de `idx_licitaciones_organo_periodo`: todo lo
    -- que se calcula aquí sale del índice sin leer la tabla. La fila
    -- entera se lee solo para los 40 contratos de la lista.
    suyas as materialized (
        select l.id_licitacion, l.fecha_actualizacion, l.provincia,
               l.importe_adjudicacion, l.presupuesto_base, l.importe_sin_iva,
               l.lotes, l.sistema, l.licitadores, l.procedimiento,
               yo.cif as mi_cif
        from yo
        cross join public.licitaciones l
        where l.organo = organo_buscado
          and l.prefijo_principal = any(yo.prefijos)
          and l.adjudicatario_cif is not null
          and public.en_periodo(l.fecha_actualizacion, desde, hasta)
    ),
    ganadores as (
        select s.id_licitacion, s.fecha_actualizacion, s.mi_cif,
               a.cif, a.nombre, a.importe, a.principal
        from suyas s
        join public.adjudicaciones_empresa a on a.id_licitacion = s.id_licitacion
    )
    select jsonb_build_object(
        'organo', organo_buscado,
        'desde', desde,
        'hasta', hasta,
        'provincia', (select provincia from suyas
                      order by fecha_actualizacion desc limit 1),
        'contratos', (select count(*) from suyas),
        -- Todas las empresas del periodo; la lista de abajo se corta en 20.
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
                       (array_agg(g.nombre order by g.fecha_actualizacion desc))[1] as nombre,
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
                       'fecha', u.fecha_actualizacion,
                       'es_mia', exists (select 1 from ganadores g
                                         where g.id_licitacion = u.id_licitacion
                                           and g.cif = u.mi_cif),
                       'licitadores', u.licitadores,
                       'oferta_baja', u.oferta_baja, 'oferta_alta', u.oferta_alta,
                       'baja', public.baja_real(u.presupuesto_base,
                                 u.importe_sin_iva, u.lotes, u.sistema))
                     order by u.fecha_actualizacion desc)
            from (select s.*, l.titulo, l.adjudicatario, l.adjudicatario_cif,
                         l.oferta_baja, l.oferta_alta
                  from (select * from suyas
                        order by fecha_actualizacion desc limit 40) s
                  join public.licitaciones l on l.id_licitacion = s.id_licitacion) u)
    ) into resultado;

    return resultado;
end;
$function$;
