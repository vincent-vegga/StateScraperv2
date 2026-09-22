-- ============================================================
-- Periodo por años en Organismos, Movimientos y Empresas
-- ============================================================
--
-- Aplicada el 22/09/2026. Después: `select public.refrescar_organismos();`.
--
-- El buscador de organismos decía "16 contratos" y la ficha del mismo
-- organismo "18". El buscador leía `organismos_por_prefijo`, que solo
-- contaba los dos últimos años; la ficha contaba sin límite. Con los
-- sectores de la empresa de uniformidad policial, 647 de 2.113 organismos daban cifras distintas.
--
-- Decidido el 22/09/2026:
--   - Sin tope de dos años en el resumen de organismos.
--   - Un selector de años en las tres pantallas de mercado, por defecto
--     el último año con datos. El usuario elige; ninguna consulta
--     recorta el periodo por su cuenta.
--
-- Qué años se ofrecen lo decide `anios_de_mi_sector`: los que tienen al
-- menos el 2 % de los contratos del año más lleno. Así no aparecen los
-- restos sueltos de 2021-2023 (una docena de contratos contra miles), y
-- cuando se importe más histórico esos años entran solos.
--
-- Movimientos pasa a calcular cifras y rankings en el servidor sobre el
-- periodo entero: con un año, la lista son miles de contratos y el
-- navegador solo recibe los más recientes.
--
-- Las funciones antiguas (`movimientos_mercado(dias)`, `pulso_mercado`,
-- `competencia`, `mi_seguimiento`) se quedan para la web que ya está
-- publicada; las nuevas llevan otro nombre. Se pueden borrar cuando la
-- web nueva lleve un tiempo fuera.
-- ============================================================


-- ------------------------------------------------------------
-- Respaldo
-- ------------------------------------------------------------
create table if not exists public.respaldo_funciones_periodo_20260922 as
select p.proname as nombre, pg_get_function_identity_arguments(p.oid) as argumentos,
       pg_get_functiondef(p.oid) as definicion, now() as guardado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('refrescar_organismos', 'refrescar_organismos_por_prefijo',
                    'ficha_organismo', 'ficha_empresa');
alter table public.respaldo_funciones_periodo_20260922 enable row level security;
revoke all on public.respaldo_funciones_periodo_20260922 from anon, authenticated;


-- ------------------------------------------------------------
-- Si una fecha cae dentro de los años elegidos
-- ------------------------------------------------------------
-- Nulo en un extremo es "sin límite" por ese lado. En hora española: un
-- contrato del 31 de diciembre a las 23:30 es de ese año, no del
-- siguiente.
--
-- Sin `set search_path` para que se expanda en línea dentro de cada
-- consulta y pueda usar los índices por fecha.
create or replace function public.en_periodo(
    fecha timestamptz, desde integer, hasta integer)
returns boolean
language sql
stable
as $function$
    select (desde is null
            or fecha >= make_timestamptz(desde, 1, 1, 0, 0, 0, 'Europe/Madrid'))
       and (hasta is null
            or fecha < make_timestamptz(hasta + 1, 1, 1, 0, 0, 0, 'Europe/Madrid'))
$function$;

revoke execute on function public.en_periodo(timestamptz, integer, integer)
    from public, anon;
grant execute on function public.en_periodo(timestamptz, integer, integer)
    to authenticated;


-- ------------------------------------------------------------
-- Los años que ofrece el selector
-- ------------------------------------------------------------
-- Con su volumen, para dibujar la barrita de cada año. Seguidos, sin
-- huecos: un año sin nada entre dos con datos se enseña a cero.
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
        select extract(year from l.fecha_actualizacion
                       at time zone 'Europe/Madrid')::int as anio,
               count(*)::int as n
        from yo
        join public.licitaciones l
          on l.prefijo_principal = any(yo.prefijos)
         and l.adjudicatario_cif is not null
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

revoke execute on function public.anios_de_mi_sector() from public, anon;
grant execute on function public.anios_de_mi_sector() to authenticated;


-- ------------------------------------------------------------
-- Organismos: sin tope de dos años
-- ------------------------------------------------------------
create or replace function public.refrescar_organismos()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    sello   timestamptz := now();   -- constante dentro de la transacción
    metidas int;
    barridas int;
begin
    if auth.uid() is not null then
        raise exception 'refrescar_organismos: solo con clave de servicio';
    end if;

    -- Todo el histórico, sin ventana de dos años: con ella el buscador
    -- y la ficha de un mismo organismo daban cifras distintas. El
    -- periodo lo elige el usuario en la ficha.
    insert into public.organismos_por_prefijo
        (prefijo_principal, organo, provincia, contratos, importe, actualizado)
    select l.prefijo_principal,
           l.organo,
           (array_agg(l.provincia order by l.fecha_actualizacion desc))[1],
           count(*)::int,
           coalesce(sum(l.importe_adjudicacion), 0),
           sello
    from public.licitaciones l
    where l.adjudicatario_cif is not null
      and l.organo is not null
      and l.prefijo_principal is not null
    group by l.prefijo_principal, l.organo
    on conflict (prefijo_principal, organo) do update
        set provincia   = excluded.provincia,
            contratos   = excluded.contratos,
            importe     = excluded.importe,
            actualizado = excluded.actualizado;

    get diagnostics metidas = row_count;

    -- Lo que no se ha tocado en esta pasada ya no existe.
    delete from public.organismos_por_prefijo where actualizado < sello;
    get diagnostics barridas = row_count;

    raise notice 'organismos: % al día, % barridos', metidas, barridas;
    return metidas;
end;
$function$;


create or replace function public.refrescar_organismos_por_prefijo(prefijos text[] default null::text[])
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
    -- Solo con clave de servicio. Con sesión de usuario, auth.uid()
    -- devuelve algo y aquí se para. Mismo criterio que
    -- `perfil_permitido`.
    if auth.uid() is not null then
        raise exception 'refrescar_organismos_por_prefijo: solo con clave de servicio';
    end if;

    objetivo := coalesce(prefijos, array(
        select distinct trim(x)
        from public.perfiles p,
             unnest(string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
        where p.activo and trim(x) <> ''));

    foreach uno in array objetivo loop
        -- Se borra y se rehace el prefijo entero: un organismo que
        -- desaparece del histórico tiene que desaparecer de aquí.
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
          and l.organo is not null
        group by l.prefijo_principal, l.organo;

        get diagnostics n = row_count;
        metidas := metidas + n;
    end loop;

    return metidas;
end;
$function$;


-- La ficha, con el periodo elegido y sobre TODOS sus contratos del
-- periodo. Sin la muestra de 800 ni la caché de 24 horas: con el
-- periodo acotado por años la consulta es rápida, y la caché por perfil
-- y organismo no distinguía periodos.
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
    suyas as (
        select l.*, yo.cif as mi_cif
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
            from (select * from suyas
                  order by fecha_actualizacion desc limit 40) u)
    ) into resultado;

    return resultado;
end;
$function$;


-- ------------------------------------------------------------
-- Movimientos
-- ------------------------------------------------------------
-- Lo común a la lista y al resumen: las licitaciones adjudicadas del
-- sector en el periodo, sin las que el cribado del mercado descartó.
create or replace function public.mercado_del_periodo(
    desde integer default null, hasta integer default null,
    provincia_elegida text default null)
returns setof public.licitaciones
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
    select l.*
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


-- La lista: los más recientes del periodo, con todos sus ganadores.
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
    recientes as (
        select * from public.mercado_del_periodo(desde, hasta, provincia_elegida)
        order by fecha_actualizacion desc
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
    from recientes r
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
    order by r.fecha_actualizacion desc;
$function$;

revoke execute on function public.movimientos_periodo(integer, integer, text, integer)
    from public, anon;
grant execute on function public.movimientos_periodo(integer, integer, text, integer)
    to authenticated;


-- Cifras y rankings sobre el periodo ENTERO, no sobre la lista.
--
-- Cada fila de ranking trae sus tres contratos mayores y el resto
-- sumado: es lo que dibuja la barra por tramos.
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
        select m.id_licitacion, m.titulo, m.organo, a.cif, a.nombre, a.importe,
               a.cif = yo.cif as es_mia,
               exists (select 1 from public.seguimiento s
                       where s.perfil_id = yo.id and s.cif = a.cif) as la_sigo
        from movidas m
        join public.adjudicaciones_empresa a on a.id_licitacion = m.id_licitacion
        cross join yo
    ),
    por_empresa as (
        select g.cif as clave,
               (array_agg(g.nombre))[1] as nombre,
               count(*)::int as n,
               coalesce(sum(g.importe), 0) as euros,
               bool_or(g.es_mia) as es_mia,
               bool_or(g.la_sigo) as la_sigo
        from ganadores g group by g.cif
        order by coalesce(sum(g.importe), 0) desc, count(*) desc
        limit 6
    ),
    por_organo as (
        select m.organo as clave, m.organo as nombre,
               (array_agg(m.provincia))[1] as provincia,
               count(*)::int as n,
               coalesce(sum(m.importe_adjudicacion), 0) as euros
        from movidas m where m.organo is not null
        group by m.organo
        order by coalesce(sum(m.importe_adjudicacion), 0) desc, count(*) desc
        limit 6
    )
    select jsonb_build_object(
        'contratos', (select count(*) from movidas),
        'importe', (select coalesce(sum(importe_adjudicacion), 0) from movidas),
        'empresas', (select count(distinct cif) from ganadores),
        'mias', (select count(distinct id_licitacion) from ganadores where es_mia),
        'importe_medio', (select round(avg(importe_adjudicacion))
                          from movidas where importe_adjudicacion > 0),
        -- Las provincias salen del periodo SIN filtrar por provincia: si
        -- no, al elegir una el desplegable se quedaba solo con ella.
        'provincias', (select jsonb_agg(t.provincia order by t.provincia)
                       from (select distinct provincia from todas
                             where provincia is not null) t),
        'por_empresa', (
            select jsonb_agg(jsonb_build_object(
                       'clave', e.clave, 'nombre', e.nombre, 'n', e.n,
                       'euros', e.euros, 'es_mia', e.es_mia, 'la_sigo', e.la_sigo,
                       'tramos', (select jsonb_agg(jsonb_build_object(
                                      'titulo', t.titulo, 'quien', t.organo,
                                      'importe', t.importe)
                                    order by t.importe desc nulls last)
                                  from (select * from ganadores g
                                        where g.cif = e.clave
                                        order by g.importe desc nulls last
                                        limit 3) t),
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
                       'clave', o.clave, 'nombre', o.nombre, 'provincia', o.provincia,
                       'n', o.n, 'euros', o.euros, 'es_mia', false, 'la_sigo', false,
                       'tramos', (select jsonb_agg(jsonb_build_object(
                                      'titulo', t.titulo, 'quien', t.adjudicatario,
                                      'importe', t.importe_adjudicacion)
                                    order by t.importe_adjudicacion desc nulls last)
                                  from (select * from movidas m
                                        where m.organo = o.clave
                                        order by m.importe_adjudicacion desc nulls last
                                        limit 3) t),
                       'resto_n', greatest(o.n - 3, 0),
                       'resto_importe', (select coalesce(sum(r.importe_adjudicacion), 0) from (
                                            select m.importe_adjudicacion from movidas m
                                            where m.organo = o.clave
                                            order by m.importe_adjudicacion desc nulls last
                                            offset 3) r))
                     order by o.euros desc, o.n desc)
            from por_organo o)
    );
$function$;

revoke execute on function public.resumen_periodo(integer, integer, text)
    from public, anon;
grant execute on function public.resumen_periodo(integer, integer, text)
    to authenticated;


-- ------------------------------------------------------------
-- Empresas
-- ------------------------------------------------------------
-- Quién gana en los sectores del perfil en el periodo. Sobre todas las
-- licitaciones del periodo, no sobre una muestra de las N más recientes
-- por prefijo como `competencia`.
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
           (array_agg(a.nombre order by m.fecha_actualizacion desc))[1],
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

revoke execute on function public.competencia_periodo(integer, integer)
    from public, anon;
grant execute on function public.competencia_periodo(integer, integer)
    to authenticated;


-- Las empresas que sigue, con lo que ganaron en el periodo (en todos
-- los sectores, no solo en los del perfil: se sigue a la empresa).
create or replace function public.seguimiento_periodo(
    desde integer default null, hasta integer default null)
returns table(cif text, nombre text, contratos integer, importe numeric,
              ultimo timestamp with time zone)
language sql
stable security definer
set search_path to 'public'
as $function$
    select s.cif,
           coalesce(s.nombre, (array_agg(a.nombre order by l.fecha_actualizacion desc))[1]),
           count(l.id_licitacion)::int,
           -- Solo lo del periodo: el filtro de fechas va en el join, y sin
           -- esto se sumaban también los contratos de fuera.
           coalesce(sum(a.importe) filter (where l.id_licitacion is not null), 0),
           max(l.fecha_actualizacion)
    from public.seguimiento s
    left join public.adjudicaciones_empresa a on a.cif = s.cif
    left join public.licitaciones l
      on l.id_licitacion = a.id_licitacion
     and public.en_periodo(l.fecha_actualizacion, desde, hasta)
    where s.perfil_id = public.mi_perfil_id()
    group by s.cif, s.nombre, s.creado
    order by s.creado desc;
$function$;

revoke execute on function public.seguimiento_periodo(integer, integer)
    from public, anon;
grant execute on function public.seguimiento_periodo(integer, integer)
    to authenticated;


-- La ficha de una empresa, con periodo. Sin periodo, todo su historial,
-- que es lo que la web anterior y el alta esperan.
drop function if exists public.ficha_empresa(text);
create or replace function public.ficha_empresa(
    cif_buscado text, desde integer default null, hasta integer default null)
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
            select s.titulo, s.organo, s.sector, s.fecha_actualizacion,
                   a.nombre, a.importe as suyo, a.lotes
            from public.adjudicaciones_empresa a
            join public.licitaciones s on s.id_licitacion = a.id_licitacion
            where a.cif = limpio
              and public.en_periodo(s.fecha_actualizacion, desde, hasta)
        )
        select jsonb_build_object(
            'cif', limpio,
            'desde', desde,
            'hasta', hasta,
            -- El nombre, de todo su historial: si en el periodo no ganó
            -- nada, la ficha tiene que decir de quién es.
            'nombre', (select a.nombre
                       from public.adjudicaciones_empresa a
                       join public.licitaciones s on s.id_licitacion = a.id_licitacion
                       where a.cif = limpio
                       order by s.fecha_actualizacion desc limit 1),
            'contratos', count(*),
            'lotes', coalesce(sum(l.lotes), 0),
            'importe', coalesce(sum(l.suyo), 0),
            'primero', min(l.fecha_actualizacion),
            'ultimo', max(l.fecha_actualizacion),
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
                           'fecha', u.fecha_actualizacion)
                         order by u.fecha_actualizacion desc)
                from (select s.titulo, s.organo, s.suyo, s.fecha_actualizacion
                      from suyas s
                      order by s.fecha_actualizacion desc limit 8) u
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

revoke execute on function public.ficha_empresa(text, integer, integer) from public, anon;
grant execute on function public.ficha_empresa(text, integer, integer) to authenticated, service_role;


-- La lista de organismos guardada por perfil venía del resumen con
-- ventana de dos años.
delete from public.organismos_guardados;


-- ------------------------------------------------------------
-- DESPUÉS de aplicar, a mano (tarda):
--
--   select public.refrescar_organismos();
-- ------------------------------------------------------------
