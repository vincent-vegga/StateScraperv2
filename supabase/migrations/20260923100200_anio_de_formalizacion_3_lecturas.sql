-- ============================================================
-- Año de formalización (3 de 3): lo que lee la web
-- ============================================================
--
-- Aplicada el 23/09/2026, después del paso 2 (sin sus índices, estas
-- consultas agotarían el tiempo de espera). Hechos también los tres
-- pasos de "después de aplicar".
--
-- Medido con el perfil de uniformidad, cada año de 2024 a 2026:
-- resumen_periodo 163-192 ms, ficha_empresa 14-56 ms,
-- movimientos_periodo 775 ms, competencia_periodo 106 ms,
-- ficha_organismo 13 ms, anios_de_mi_sector 48 ms.
--
-- Tres cambios en todas las pantallas de mercado (Movimientos, Empresas,
-- Organismos y los años del selector):
--
--   1. Cada contrato cuenta en el AÑO EN QUE SE FORMALIZA (`fecha_mercado`,
--      paso 1), y cada empresa en el de SUS lotes, no en el de la primera
--      versión vista.
--   2. Los contratos menores no cuentan. Siguen guardados.
--   3. El resumen de Movimientos da el importe MEDIANO, no el medio.
--      Con la media, 2024 salía a 347.000 € en uniformidad por tres o
--      cuatro contratos de 35-65 M€, y 2025 a 87.000 € por los 3.441
--      menores. Medianas sin menores, por año de adjudicación (antes de
--      reprocesar): 30.579 / 25.456 / 19.680 €.
--
-- `competencia_periodo` no se toca: lee de `mercado_del_periodo` y
-- `repartos_del_periodo`, y cambia con ellas.
--
-- Después de aplicar:
--   select public.refrescar_organismos();   -- rehace organismos_por_prefijo
--   delete from public.organismos_guardados; -- la lista cacheada, 1 día
--   drop index concurrently public.idx_adjudicaciones_empresa_periodo;
--
-- Para volver atrás: las definiciones anteriores están en
-- `respaldo_funciones_formalizacion_20260923` (paso 1).
-- ============================================================


-- ------------------------------------------------------------
-- Los contratos del periodo
-- ------------------------------------------------------------
-- `fecha` pasa a ser la de mercado: es la que ordena Movimientos.
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
    where public.en_periodo(public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                l.fecha_formalizacion_estimada, l.fecha_actualizacion),
                            desde, hasta)
      and (provincia_elegida is null or l.provincia = provincia_elegida)
      and coalesce((select v.del_sector from public.veredictos_mercado v
                    where v.perfil_id = yo.id
                      and v.id_licitacion = l.id_licitacion), true);
$function$;


-- ------------------------------------------------------------
-- Los ganadores del periodo
-- ------------------------------------------------------------
-- `a.fecha` ya es la de mercado (la copia el disparador del paso 1).
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
     and not a.es_menor
    where public.en_periodo(a.fecha, desde, hasta);
$function$;


-- ------------------------------------------------------------
-- Resumen de Movimientos: mediana en vez de media
-- ------------------------------------------------------------
-- La clave cambia de nombre (`importe_mediano`) para que la web vieja,
-- que lee `importe_medio`, simplemente no enseñe la cifra en vez de
-- enseñar una mediana llamándola media.
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


-- ------------------------------------------------------------
-- Lista de Movimientos
-- ------------------------------------------------------------
-- Igual que antes; la fecha que devuelve es la de mercado (`u.fecha`).
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


-- ------------------------------------------------------------
-- Ficha de empresa
-- ------------------------------------------------------------
-- Sin menores y por fecha de mercado. El nombre se sigue buscando entre
-- todos sus contratos, menores incluidos: una empresa que solo tiene
-- menores en el periodo sale con nombre y "no tiene contratos en este
-- periodo", no como NIF desconocido.
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
              and not a.es_menor
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
            'sigo', exists (
                select 1 from public.seguimiento sg
                join public.perfiles p on p.id = sg.perfil_id
                where p.id = public.mi_perfil_id() and sg.cif = limpio)
        )
        from suyas l
    );
end;
$function$;


-- ------------------------------------------------------------
-- Ficha de organismo
-- ------------------------------------------------------------
-- Igual que antes, con `fecha` (de mercado) donde ponía
-- `fecha_actualizacion`, y sin menores. Sigue leyendo solo del índice
-- (`idx_licitaciones_organo_mercado`, paso 2).
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
    -- Solo columnas de `idx_licitaciones_organo_mercado`: todo lo que se
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


-- ------------------------------------------------------------
-- Empresas que sigo, en el periodo
-- ------------------------------------------------------------
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
     and not a.es_menor
     and public.en_periodo(a.fecha, desde, hasta)
    where s.perfil_id = public.mi_perfil_id()
    group by s.cif, s.nombre, s.creado
    order by s.creado desc;
$function$;


-- ------------------------------------------------------------
-- Años del selector
-- ------------------------------------------------------------
-- Por año de adjudicación y sin menores. Con los menores dentro, 2025
-- tenía el triple que los demás y el umbral del 2 % escondía años.
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
    por_anio as (
        select extract(year from public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                l.fecha_formalizacion_estimada, l.fecha_actualizacion)
                                 at time zone 'Europe/Madrid')::int as anio,
               count(*)::int as n
        from yo
        join public.licitaciones l
          on l.prefijo_principal = any(yo.prefijos)
         and l.adjudicatario_cif is not null
         and l.procedimiento is distinct from 'Contrato menor'
        group by 1
    ),
    validos as (
        select anio from por_anio
        where n >= 0.02 * (select max(n) from por_anio)
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
    group by 1 order by 1;
$function$;


-- ------------------------------------------------------------
-- Lista de Organismos (agregado nocturno), sin menores
-- ------------------------------------------------------------
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
          and l.organo is not null
        group by l.prefijo_principal, l.organo;

        get diagnostics n = row_count;
        metidas := metidas + n;
    end loop;

    return metidas;
end;
$function$;
