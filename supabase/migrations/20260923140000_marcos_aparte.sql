-- ============================================================
-- Acuerdos marco sin importe: fuera de las métricas, en su propio bloque
-- ============================================================
--
-- Aplicada el 23/09/2026, en tres tramos: (1) columna, función y
-- disparador; (2) relleno e índices, fuera de transacción; (3) funciones
-- de lectura.
--
-- El problema: un acuerdo marco cuyos lotes no publican importe (o
-- repiten el total del marco) contaba como "1 contrato" sin dinero. El
-- dinero llega después por los contratos basados en ese marco, que sí
-- cuentan: el Consorci Català pel Desenvolupament Local (26 M€, 29 lotes
-- a 0 €) salía junto a Begur y Mollet, que son contratos derivados de él.
-- Contaba dos veces el mismo negocio e inflaba los recuentos.
--
-- Decidido el 23/09/2026:
--   - Un acuerdo marco o sistema dinámico SIN IMPORTE atribuible es una
--     homologación, no un contrato: no cuenta en recuentos, rankings,
--     Movimientos, competencia ni "A quién le vende".
--   - En la ficha de empresa sale aparte: "Acuerdos marco en los que
--     está homologada", con organismo, lotes y fecha de formalización.
--     Estar dentro de un marco es información valiosa (cualquier
--     organismo adherido le puede encargar sin licitar).
--   - Los que SÍ tienen importe por lote (Oviedo, decisión del mismo día)
--     siguen contando como contratos.
--
-- Medido el 23/09/2026: 2.749 acuerdos marco, 20.427 filas de
-- ganadores, 9.389 empresas.
-- ============================================================


-- ------------------------------------------------------------
-- (1) Qué es una homologación
-- ------------------------------------------------------------
-- IMMUTABLE y en línea, como `fecha_mercado`: la usan los índices
-- parciales del tramo 2 y las consultas del 3 con el mismo texto.
create or replace function public.es_homologacion(sistema text, importe numeric)
returns boolean
language sql
immutable
as $function$
    select coalesce(sistema in ('Acuerdo marco', 'Sistema dinámico de adquisición'), false)
       and importe is null
$function$;

revoke execute on function public.es_homologacion(text, numeric) from public, anon;
grant execute on function public.es_homologacion(text, numeric) to authenticated, service_role;

alter table public.adjudicaciones_empresa
    add column if not exists es_homologacion boolean not null default false;

-- El disparador copia la marca, igual que `es_menor`.
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
       and new.prefijo_principal is not distinct from old.prefijo_principal
       and new.procedimiento is not distinct from old.procedimiento
       and new.sistema is not distinct from old.sistema
       and new.fecha_formalizacion is not distinct from old.fecha_formalizacion
       and new.fecha_adjudicacion is not distinct from old.fecha_adjudicacion
       and new.fecha_formalizacion_estimada is not distinct from old.fecha_formalizacion_estimada
       and new.fecha_actualizacion is not distinct from old.fecha_actualizacion
    then
        return null;
    end if;

    delete from public.adjudicaciones_empresa
    where id_licitacion = new.id_licitacion;

    insert into public.adjudicaciones_empresa
        (id_licitacion, cif, nombre, importe, lotes, principal,
         prefijo_principal, fecha, es_menor, es_homologacion)
    select new.id_licitacion, r.cif, r.nombre, r.importe, r.lotes, r.principal,
           new.prefijo_principal,
           public.fecha_mercado(coalesce(r.formalizacion, new.fecha_formalizacion),
                                new.fecha_adjudicacion,
                                new.fecha_formalizacion_estimada,
                                new.fecha_actualizacion),
           coalesce(new.procedimiento = 'Contrato menor', false),
           public.es_homologacion(new.sistema, new.importe_adjudicacion)
    from public.reparto_adjudicacion(new.adjudicaciones, new.adjudicatario,
                                     new.adjudicatario_cif,
                                     new.importe_adjudicacion) r;
    return null;
end;
$function$;

drop trigger if exists trg_adjudicaciones_empresa on public.licitaciones;
create trigger trg_adjudicaciones_empresa
    after insert or update of adjudicaciones, adjudicatario, adjudicatario_cif,
                              importe_adjudicacion, prefijo_principal,
                              fecha_actualizacion, fecha_adjudicacion,
                              fecha_formalizacion, fecha_formalizacion_estimada,
                              procedimiento, sistema
    on public.licitaciones
    for each row execute function public.sincronizar_adjudicaciones_empresa();


-- ------------------------------------------------------------
-- (2) Relleno e índices (fuera de transacción, sentencia a sentencia)
-- ------------------------------------------------------------
update public.adjudicaciones_empresa a
   set es_homologacion = true
  from public.licitaciones l
 where l.id_licitacion = a.id_licitacion
   and public.es_homologacion(l.sistema, l.importe_adjudicacion)
   and not a.es_homologacion;

-- Los mismos índices de 20260923100100, con las homologaciones fuera.
create index concurrently if not exists idx_adjudicaciones_empresa_cuentan
on public.adjudicaciones_empresa (prefijo_principal, fecha)
include (id_licitacion, cif, nombre, importe)
where not es_menor and not es_homologacion;

create index concurrently if not exists idx_licitaciones_cuentan
on public.licitaciones (
    prefijo_principal,
    public.fecha_mercado(fecha_formalizacion, fecha_adjudicacion,
                         fecha_formalizacion_estimada, fecha_actualizacion))
include (id_licitacion, importe_adjudicacion, organo, provincia,
         fecha_formalizacion, fecha_adjudicacion, fecha_formalizacion_estimada,
         fecha_actualizacion)
where adjudicatario_cif is not null
  and procedimiento is distinct from 'Contrato menor'
  and not public.es_homologacion(sistema, importe_adjudicacion);

create index concurrently if not exists idx_licitaciones_organo_cuentan
on public.licitaciones (
    organo, prefijo_principal,
    public.fecha_mercado(fecha_formalizacion, fecha_adjudicacion,
                         fecha_formalizacion_estimada, fecha_actualizacion))
include (id_licitacion, importe_adjudicacion, presupuesto_base, importe_sin_iva,
         lotes, sistema, licitadores, procedimiento, provincia,
         fecha_formalizacion, fecha_adjudicacion, fecha_formalizacion_estimada,
         fecha_actualizacion)
where adjudicatario_cif is not null
  and procedimiento is distinct from 'Contrato menor'
  and not public.es_homologacion(sistema, importe_adjudicacion);

-- Cuando el tramo 3 esté aplicado:
--   drop index concurrently public.idx_adjudicaciones_empresa_mercado;
--   drop index concurrently public.idx_licitaciones_mercado;
--   drop index concurrently public.idx_licitaciones_organo_mercado;


-- ------------------------------------------------------------
-- (3) Funciones de lectura
-- ------------------------------------------------------------
-- Las de 20260923100200 (y `anios_de_mi_sector` de 20260923120000) con
-- las homologaciones fuera: `not public.es_homologacion(...)` en las que
-- leen `licitaciones` (el mismo texto que el predicado de los índices) y
-- `not a.es_homologacion` en las que leen `adjudicaciones_empresa`.
-- `ficha_empresa` devuelve además `marcos`.

create or replace function public.mercado_del_periodo(
    desde integer default null::integer, hasta integer default null::integer,
    provincia_elegida text default null::text)
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
    select l.id_licitacion,
           public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                l.fecha_formalizacion_estimada, l.fecha_actualizacion),
           l.importe_adjudicacion, l.organo, l.provincia
    from yo
    join public.licitaciones l
      on l.prefijo_principal = any(yo.prefijos)
     and l.adjudicatario_cif is not null
     and l.procedimiento is distinct from 'Contrato menor'
     and not public.es_homologacion(l.sistema, l.importe_adjudicacion)
    where public.en_periodo(public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                l.fecha_formalizacion_estimada, l.fecha_actualizacion),
                            desde, hasta)
      and (provincia_elegida is null or l.provincia = provincia_elegida)
      and coalesce((select v.del_sector from public.veredictos_mercado v
                    where v.perfil_id = yo.id
                      and v.id_licitacion = l.id_licitacion), true);
$function$;


create or replace function public.repartos_del_periodo(
    desde integer default null::integer, hasta integer default null::integer)
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
     and not a.es_menor and not a.es_homologacion
    where public.en_periodo(a.fecha, desde, hasta);
$function$;


create or replace function public.resumen_periodo(
    desde integer default null::integer, hasta integer default null::integer,
    provincia_elegida text default null::text)
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
        'importe_mediano', (select round(percentile_cont(0.5)
                                         within group (order by importe)::numeric)
                            from movidas where importe > 0),
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


create or replace function public.movimientos_periodo(
    desde integer default null::integer, hasta integer default null::integer,
    provincia_elegida text default null::text, tope integer default 300)
returns table(id_licitacion text, titulo text, organo text, provincia text,
              sector text, empresa text, cif text, importe numeric,
              presupuesto numeric, fecha timestamptz, enlace text,
              es_mia boolean, la_sigo boolean, grupo text, total numeric,
              ganadores jsonb)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif from public.perfiles p
        where p.id = public.mi_perfil_id()
    ),
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
           u.fecha, r.enlace,
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


create or replace function public.ficha_empresa(
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
    return (
        with suyas as (
            select s.titulo, s.organo, s.sector, a.fecha,
                   a.nombre, a.importe as suyo, a.lotes
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
                           'fecha', u.fecha)
                         order by u.fecha desc)
                from (select s.titulo, s.organo, s.suyo, s.fecha
                      from suyas s
                      order by s.fecha desc limit 8) u
            ),
            -- Acuerdos marco sin importe: no cuentan como contratos, se
            -- enseñan aparte (20260923140000).
            'marcos', (
                select jsonb_agg(jsonb_build_object(
                           'organo', m.organo, 'titulo', m.titulo,
                           'lotes', m.lotes, 'fecha', m.fecha,
                           'valor_marco', m.valor_marco)
                         order by m.fecha desc)
                from (select s.organo, s.titulo, a.lotes, a.fecha,
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


create or replace function public.ficha_organismo(
    organo_buscado text, desde integer default null::integer,
    hasta integer default null::integer)
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
    -- Solo columnas de `idx_licitaciones_organo_cuentan`: todo lo que se
    -- calcula aquí sale del índice sin leer la tabla. La fila entera se
    -- lee solo para los 40 contratos de la lista.
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
                         l.oferta_baja, l.oferta_alta
                  from (select * from suyas
                        order by fecha desc limit 40) s
                  join public.licitaciones l on l.id_licitacion = s.id_licitacion) u)
    ) into resultado;

    return resultado;
end;
$function$;


create or replace function public.seguimiento_periodo(
    desde integer default null::integer, hasta integer default null::integer)
returns table(cif text, nombre text, contratos integer, importe numeric,
              ultimo timestamptz)
language sql
stable security definer
set search_path to 'public'
as $function$
    select s.cif,
           coalesce(s.nombre, (array_agg(a.nombre order by a.fecha desc))[1]),
           count(l.id_licitacion)::int,
           coalesce(sum(a.importe) filter (where l.id_licitacion is not null), 0),
           max(a.fecha) filter (where l.id_licitacion is not null)
    from public.seguimiento s
    left join public.adjudicaciones_empresa a on a.cif = s.cif
    left join public.licitaciones l
      on l.id_licitacion = a.id_licitacion
     and not a.es_menor and not a.es_homologacion
     and public.en_periodo(a.fecha, desde, hasta)
    where s.perfil_id = public.mi_perfil_id()
    group by s.cif, s.nombre, s.creado
    order by s.creado desc;
$function$;


create or replace function public.anios_de_mi_sector()
returns table(anio integer, contratos integer)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    ),
    suyas as materialized (
        select public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                    l.fecha_formalizacion_estimada,
                                    l.fecha_actualizacion) as fecha,
               l.fecha_actualizacion
        from yo
        join public.licitaciones l
          on l.prefijo_principal = any(yo.prefijos)
         and l.adjudicatario_cif is not null
         and l.procedimiento is distinct from 'Contrato menor'
         and not public.es_homologacion(l.sistema, l.importe_adjudicacion)
    ),
    por_anio as (
        select extract(year from fecha at time zone 'Europe/Madrid')::int as anio,
               count(*)::int as n
        from suyas group by 1
    ),
    -- Por fecha de publicación: qué años del histórico hay cargados.
    cargados as (
        select extract(year from fecha_actualizacion at time zone 'Europe/Madrid')::int as anio,
               count(*)::int as n
        from suyas group by 1
    ),
    primero as (
        select min(anio) as anio from cargados
        where n >= 0.02 * (select max(n) from cargados)
    ),
    validos as (
        select anio from por_anio
        where n >= 0.02 * (select max(n) from por_anio)
          and anio >= (select anio from primero)
    )
    select s.anio::int, coalesce(pa.n, 0)
    from generate_series((select min(anio) from validos),
                         (select max(anio) from validos)) as s(anio)
    left join por_anio pa on pa.anio = s.anio
    order by 1;
$function$;

create or replace function public.anios_de_organismo(organo_buscado text)
returns table(anio integer, contratos integer)
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
    select extract(year from public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                l.fecha_formalizacion_estimada, l.fecha_actualizacion)
                             at time zone 'Europe/Madrid')::int,
           count(*)::int
    from yo
    cross join public.licitaciones l
    where l.organo = organo_buscado
      and l.prefijo_principal = any(yo.prefijos)
      and l.adjudicatario_cif is not null
      and l.procedimiento is distinct from 'Contrato menor'
      and not public.es_homologacion(l.sistema, l.importe_adjudicacion)
    group by 1 order by 1;
$function$;


create or replace function public.refrescar_organismos_por_prefijo(
    prefijos text[] default null::text[])
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    objetivo text[];
    uno      text;
    metidas  int := 0;
    n        int;
begin
    if auth.uid() is not null then
        raise exception 'refrescar_organismos_por_prefijo: solo con clave de servicio';
    end if;

    objetivo := coalesce(prefijos, array(
        select distinct trim(x)
        from public.perfiles p,
             unnest(string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
        where p.activo and trim(x) <> ''));

    foreach uno in array objetivo loop
        delete from public.organismos_por_prefijo
        where prefijo_principal = uno;

        insert into public.organismos_por_prefijo
            (prefijo_principal, organo, provincia, contratos, importe, actualizado)
        select l.prefijo_principal,
               l.organo,
               (array_agg(l.provincia order by l.fecha_actualizacion desc))[1],
               count(*)::int,
               coalesce(sum(l.importe_adjudicacion), 0),
               now()
        from public.licitaciones l
        where l.prefijo_principal = uno
          and l.adjudicatario_cif is not null
          and l.procedimiento is distinct from 'Contrato menor'
          and not public.es_homologacion(l.sistema, l.importe_adjudicacion)
          and l.organo is not null
        group by l.prefijo_principal, l.organo;

        get diagnostics n = row_count;
        metidas := metidas + n;
    end loop;

    return metidas;
end;
$function$;
