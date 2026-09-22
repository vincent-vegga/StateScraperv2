-- ============================================================
-- Periodo por años: los ganadores también, por índice
-- ============================================================
--
-- Aplicada el 22/09/2026, después de 20260922171000.
--
-- Con el índice de `licitaciones` el resumen de Movimientos seguía en
-- 15 s en frío: faltaba cruzar cada licitación con sus ganadores, y eran
-- 19.000 búsquedas sueltas en `adjudicaciones_empresa` (420 MB).
--
-- Arreglo: cada fila de `adjudicaciones_empresa` lleva el sector y la
-- fecha de su licitación (los copia el disparador), y un índice por esos
-- dos campos con lo que hace falta dentro. Los ganadores de un sector y
-- un periodo se leen juntos y se cruzan en memoria.
--
-- Medido con el perfil más grande (una editorial educativa, 10 sectores,
-- 55.000 contratos de 2024 a 2026), todo el histórico:
--   resumen_periodo 1,7 s · movimientos_periodo 1,1 s ·
--   competencia_periodo 1,4 s · anios_de_mi_sector 0,09 s.
--
-- Pasos que se hicieron aparte, fuera de transacción:
--
--   -- Relleno, en tres tandas por páginas:
--   update public.adjudicaciones_empresa a
--      set prefijo_principal = l.prefijo_principal, fecha = l.fecha_actualizacion
--     from public.licitaciones l
--    where l.id_licitacion = a.id_licitacion and a.fecha is null;
--
--   create index concurrently idx_adjudicaciones_empresa_periodo
--   on public.adjudicaciones_empresa (prefijo_principal, fecha)
--   include (id_licitacion, cif, nombre, importe);            -- 209 MB
--
--   vacuum (analyze) public.adjudicaciones_empresa;
-- ============================================================

alter table public.adjudicaciones_empresa
    add column if not exists prefijo_principal text,
    add column if not exists fecha timestamptz;

create or replace function public.sincronizar_adjudicaciones_empresa()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    if tg_op = 'UPDATE'
       and new.adjudicaciones is not distinct from old.adjudicaciones
       and new.adjudicatario is not distinct from old.adjudicatario
       and new.adjudicatario_cif is not distinct from old.adjudicatario_cif
       and new.importe_adjudicacion is not distinct from old.importe_adjudicacion
    then
        -- El reparto no cambia, pero el sector o la fecha sí pueden: se
        -- copian para que el índice por periodo siga cuadrando.
        if new.prefijo_principal is distinct from old.prefijo_principal
           or new.fecha_actualizacion is distinct from old.fecha_actualizacion then
            update public.adjudicaciones_empresa
               set prefijo_principal = new.prefijo_principal,
                   fecha = new.fecha_actualizacion
             where id_licitacion = new.id_licitacion;
        end if;
        return null;
    end if;

    delete from public.adjudicaciones_empresa
    where id_licitacion = new.id_licitacion;

    insert into public.adjudicaciones_empresa
        (id_licitacion, cif, nombre, importe, lotes, principal,
         prefijo_principal, fecha)
    select new.id_licitacion, r.cif, r.nombre, r.importe, r.lotes, r.principal,
           new.prefijo_principal, new.fecha_actualizacion
    from public.reparto_adjudicacion(new.adjudicaciones, new.adjudicatario,
                                     new.adjudicatario_cif,
                                     new.importe_adjudicacion) r;
    return null;
end;
$function$;

drop trigger if exists trg_adjudicaciones_empresa on public.licitaciones;
create trigger trg_adjudicaciones_empresa
    after insert or update of adjudicaciones, adjudicatario,
                              adjudicatario_cif, importe_adjudicacion,
                              prefijo_principal, fecha_actualizacion
    on public.licitaciones
    for each row execute function public.sincronizar_adjudicaciones_empresa();


-- Los ganadores del periodo, leídos por `idx_adjudicaciones_empresa_periodo`.
create or replace function public.repartos_del_periodo(
    desde integer default null, hasta integer default null)
returns table(id_licitacion text, cif text, nombre text, importe numeric)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    )
    select a.id_licitacion, a.cif, a.nombre, a.importe
    from yo
    join public.adjudicaciones_empresa a
      on a.prefijo_principal = any(yo.prefijos)
    where public.en_periodo(a.fecha, desde, hasta);
$function$;
revoke execute on function public.repartos_del_periodo(integer, integer)
    from public, anon, authenticated;


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
    repartos as materialized (
        select * from public.repartos_del_periodo(desde, hasta)
    ),
    ganadores as materialized (
        select m.id_licitacion, m.organo, r.cif, r.nombre, r.importe,
               r.cif = yo.cif as es_mia
        from movidas m
        join repartos r on r.id_licitacion = m.id_licitacion
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
    ),
    movidas as materialized (
        select m.id_licitacion, m.fecha
        from public.mercado_del_periodo(desde, hasta, null) m
    ),
    repartos as materialized (
        select * from public.repartos_del_periodo(desde, hasta)
    )
    select r.cif,
           (array_agg(r.nombre order by m.fecha desc))[1],
           count(*)::int,
           coalesce(sum(r.importe), 0),
           false
    from movidas m
    join repartos r on r.id_licitacion = m.id_licitacion
    cross join yo
    where r.cif is distinct from yo.cif
      and not exists (select 1 from public.seguimiento sg
                      where sg.perfil_id = yo.id and sg.cif = r.cif)
    group by r.cif
    order by count(*) desc, coalesce(sum(r.importe), 0) desc
    limit 25;
$function$;
