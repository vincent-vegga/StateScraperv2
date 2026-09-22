-- ============================================================
-- Importes por empresa: ni totales imposibles ni el contrato entero
-- para quien solo ganó un lote
-- ============================================================
--
-- Aplicada el 22/09/2026, en dos tramos (datos y funciones), con los
-- tres agregados recalculados después. Soltec: 83,9 M€ -> 2,77 M€.
--
-- Soltec Pro Uniformidad (B72798408) salía con 83,9 M€ adjudicados. Su
-- cifra real ronda los 2,8 M€. Dos fallos que se suman:
--
-- 1. IMPORTES DE LICITACIÓN IMPOSIBLES. Un acuerdo marco de uniformidad
--    del Consorci Català pel Desenvolupament Local (7 lotes, 13
--    adjudicatarios, 26 M€ de presupuesto) tenía 81 M€ adjudicados.
--    `procesar_historico.py` sumaba los lotes SIN las dos defensas que
--    ya tenía `lector_atom.resumir_adjudicaciones` (acuerdo marco con
--    varios lotes → sin importe; suma > 1,5× presupuesto → el lote
--    mayor), y `completar_explicacion` sobrescribe el importe con lo
--    que manda el histórico. Resultado en toda la base: 3.092
--    licitaciones con 72.382 M€ que no existen, el 18 % de todo el
--    importe adjudicado.
--
-- 2. EL TOTAL ENTERO PARA EL "PRINCIPAL". Todas las cifras por empresa
--    (Mi cuenta, Empresas, Movimientos, Organismos) sumaban
--    `importe_adjudicacion`, que es el total del expediente, a
--    `adjudicatario_cif`, que es solo quien más se llevó. En las 46.093
--    licitaciones con varios adjudicatarios, el principal se apuntaba
--    también los lotes de los demás.
--
-- Arreglo:
--   - Se limpian los importes con la misma regla que el lector en vivo.
--   - `importe_de_empresa` devuelve la parte de UNA empresa: el total si
--     ganó sola, la suma de sus lotes si hubo varios ganadores, y nada
--     si no se sabe (mejor un hueco que un número falso).
--   - Las funciones que atribuyen dinero a una empresa usan esa parte.
--     Las que dan el total de un organismo o del mercado siguen con el
--     total del expediente, que para eso sí es correcto.
--
-- Después de aplicarla hay que recalcular los agregados (al final).
-- ============================================================


-- ------------------------------------------------------------
-- Respaldo: lo que se va a sobrescribir, por si hay que volver atrás
-- ------------------------------------------------------------
create table if not exists public.respaldo_funciones_importes_20260922 as
select p.proname as nombre, pg_get_functiondef(p.oid) as definicion,
       now() as guardado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('mi_panel', 'buscar_empresa', 'ficha_empresa',
                    'ultimos_ganados', 'competencia', 'movimientos_mercado',
                    'ranking_mercado', 'organismos_del_sector',
                    'ficha_organismo', 'refrescar_catalogo_empresas',
                    'refrescar_empresas');

create table if not exists public.respaldo_importes_20260922 as
select id_licitacion, importe_adjudicacion, importe_sin_iva
from public.licitaciones
where importe_adjudicacion is not null
  and (sistema in ('Acuerdo marco', 'Sistema dinámico de adquisición')
       and jsonb_array_length(coalesce(adjudicaciones, '[]'::jsonb)) > 1
       or importe_adjudicacion
          > greatest(presupuesto_base, presupuesto, valor_estimado) * 1.5);

alter table public.respaldo_funciones_importes_20260922 enable row level security;
alter table public.respaldo_importes_20260922 enable row level security;
revoke all on public.respaldo_funciones_importes_20260922 from anon, authenticated;
revoke all on public.respaldo_importes_20260922 from anon, authenticated;


-- ------------------------------------------------------------
-- La parte de una empresa en una licitación
-- ------------------------------------------------------------
-- Sin `set search_path`: no toca tablas, y así el planificador puede
-- expandirla en línea dentro de cada consulta.
create or replace function public.importe_de_empresa(
    total numeric, lotes jsonb, de_cif text, ganadores integer)
returns numeric
language sql
immutable
as $function$
    select case
        when total is null then null
        when coalesce(ganadores, 0) <= 1 then total
        else (select least(nullif(sum((a->>'importe')::numeric), 0), total)
              from jsonb_array_elements(coalesce(lotes, '[]'::jsonb)) a
              where a->>'cif' = de_cif
                and jsonb_typeof(a->'importe') = 'number')
    end
$function$;

revoke execute on function public.importe_de_empresa(numeric, jsonb, text, integer)
    from public, anon, authenticated;


-- ------------------------------------------------------------
-- Limpieza de los importes imposibles
-- ------------------------------------------------------------
-- Idéntica a `lector_atom.resumir_adjudicaciones`, salvo que el techo
-- mira el mayor presupuesto publicado (base, licitación o estimado) y no
-- solo la base: muchas filas del histórico no traen base.
with limpias as (
    select l.id_licitacion,
           case
               when l.sistema in ('Acuerdo marco', 'Sistema dinámico de adquisición')
                    and jsonb_array_length(coalesce(l.adjudicaciones, '[]'::jsonb)) > 1
               then null
               when l.importe_adjudicacion
                    > greatest(l.presupuesto_base, l.presupuesto, l.valor_estimado) * 1.5
               then nullif((select max((a->>'importe')::numeric)
                            from jsonb_array_elements(l.adjudicaciones) a
                            where jsonb_typeof(a->'importe') = 'number'), 0)
               else l.importe_adjudicacion
           end as importe
    from public.licitaciones l
    where l.importe_adjudicacion is not null
)
update public.licitaciones l
   set importe_adjudicacion = x.importe,
       importe_sin_iva      = x.importe
  from limpias x
 where l.id_licitacion = x.id_licitacion
   and x.importe is distinct from l.importe_adjudicacion;


-- ------------------------------------------------------------
-- Mi cuenta
-- ------------------------------------------------------------
create or replace function public.mi_panel()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
    select jsonb_build_object(
        'empresa', p.empresa,
        'cif', p.cif,
        'email', p.email,
        'actividad', p.descripcion,
        'que_buscamos', p.que_buscamos,
        'contratos_ganados', p.contratos_ganados,
        'criterio_version', p.criterio_version,
        'criterio_fecha', p.criterio_fecha,
        'alta', p.fecha_alta,
        'avisos', p.avisos,
        'correcciones', (
            select jsonb_build_object(
                'total', count(*),
                'sin_aplicar', count(*) filter (where not aplicada)
            )
            from public.correcciones c where c.perfil_id = p.id
        ),
        -- Las mismas condiciones que `mis_oportunidades`.
        'oportunidades', (
            select count(*)
            from public.veredictos v
            join public.licitaciones l on l.id_licitacion = v.id_licitacion
            left join public.correcciones c
                   on c.id_licitacion = v.id_licitacion and c.perfil_id = v.perfil_id
            where v.perfil_id = p.id
              and v.veredicto in ('si', 'quizas')
              and coalesce(l.estado_licitacion, '') = 'PUB'
              and (l.fecha_limite is not null and l.fecha_limite >= now()
                   or l.fecha_limite is null
                      and l.fecha_actualizacion >= now() - interval '14 days')
              and (c.interesa is null or c.interesa)
              and not l.sustituida
        ),
        'sectores', (
            select jsonb_agg(jsonb_build_object(
                       'sector', t.sector, 'contratos', t.n, 'importe', t.euros)
                     order by t.euros desc nulls last, t.n desc)
            from (
                select l.sector, count(*)::int as n,
                       coalesce(sum(public.importe_de_empresa(
                           l.importe_adjudicacion, l.adjudicaciones,
                           l.adjudicatario_cif, l.adjudicatarios)), 0) as euros
                from public.licitaciones l
                where l.adjudicatario_cif = p.cif and l.sector is not null
                group by l.sector order by euros desc nulls last limit 10
            ) t
        ),
        'importe_ganado', (
            select sum(public.importe_de_empresa(
                       l.importe_adjudicacion, l.adjudicaciones,
                       l.adjudicatario_cif, l.adjudicatarios))
            from public.licitaciones l
            where l.adjudicatario_cif = p.cif
        ),
        'organos', (
            select jsonb_agg(jsonb_build_object(
                       'organo', o.organo, 'contratos', o.n, 'importe', o.euros)
                     order by o.n desc)
            from (
                select l.organo, count(*)::int as n,
                       coalesce(sum(public.importe_de_empresa(
                           l.importe_adjudicacion, l.adjudicaciones,
                           l.adjudicatario_cif, l.adjudicatarios)), 0) as euros
                from public.licitaciones l
                where l.adjudicatario_cif = p.cif and l.organo is not null
                group by l.organo order by count(*) desc limit 8
            ) o
        )
    )
    from public.perfiles p
    where p.id = public.mi_perfil_id();
$function$;


-- ------------------------------------------------------------
-- Empresas
-- ------------------------------------------------------------
create or replace function public.buscar_empresa(cif_buscado text default null::text, nombre_buscado text default null::text)
returns table(cif text, nombre text, contratos integer, importe_total numeric, ultimo timestamp with time zone, sectores jsonb)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio text := upper(regexp_replace(coalesce(cif_buscado, ''), '[^a-zA-Z0-9]', '', 'g'));
    patron text := public.normalizar_nombre(nombre_buscado);
begin
    if limpio <> '' then
        return query
        select s.adjudicatario_cif,
               (array_agg(s.adjudicatario order by s.fecha_actualizacion desc))[1],
               count(*)::int,
               sum(public.importe_de_empresa(s.importe_adjudicacion, s.adjudicaciones,
                                             s.adjudicatario_cif, s.adjudicatarios)),
               max(s.fecha_actualizacion),
               (select jsonb_agg(jsonb_build_object('sector', t.sector,
                                                    'contratos', t.n)
                                 order by t.n desc)
                from (select l.sector, count(*)::int as n
                      from public.licitaciones l
                      where l.adjudicatario_cif = limpio and l.sector is not null
                      group by l.sector order by n desc limit 12) t)
        from public.licitaciones s
        where s.adjudicatario_cif = limpio
        group by s.adjudicatario_cif;
        return;
    end if;

    if patron = '' then
        return;
    end if;

    return query
    select e.cif, e.nombre, e.contratos, e.importe_total, e.ultimo,
           (select jsonb_agg(jsonb_build_object('sector', t.sector,
                                                'contratos', t.n)
                             order by t.n desc)
            from (select l.sector, count(*)::int as n
                  from public.licitaciones l
                  where l.adjudicatario_cif = e.cif and l.sector is not null
                  group by l.sector order by n desc limit 12) t)
    from public.empresas e
    where e.nombre_norm like patron || '%'
       or e.nombre_norm like '% ' || patron || '%'
    order by e.contratos desc
    limit 10;
end;
$function$;


create or replace function public.ficha_empresa(cif_buscado text)
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
            select s.*, public.importe_de_empresa(
                       s.importe_adjudicacion, s.adjudicaciones,
                       s.adjudicatario_cif, s.adjudicatarios) as suyo
            from public.licitaciones s
            where s.adjudicatario_cif = limpio
        )
        select jsonb_build_object(
            'cif', limpio,
            'nombre', (select adjudicatario from suyas
                       order by fecha_actualizacion desc limit 1),
            'contratos', count(*),
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


create or replace function public.ultimos_ganados(cif_buscado text, tope integer default 5)
returns table(titulo text, organo text, importe numeric, fecha timestamp with time zone, sector text)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
begin
    return query
    select l.titulo, l.organo,
           public.importe_de_empresa(l.importe_adjudicacion, l.adjudicaciones,
                                     l.adjudicatario_cif, l.adjudicatarios),
           l.fecha_actualizacion, l.sector
    from public.licitaciones l
    where l.adjudicatario_cif = limpio
    order by l.fecha_actualizacion desc nulls last
    limit tope;
end;
$function$;


create or replace function public.competencia(anios integer default 2)
returns table(cif text, nombre text, contratos integer, importe numeric, sigo boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    mi_perfil uuid;
    mi_cif    text;
    prefijos  text[];
    uno       text;
    cola      fila_competencia[] := '{}';
    desde     timestamptz := now() - (anios || ' years')::interval;
    guardado  jsonb;
    cuando    timestamptz;
    cuantos   int;
    n_pref    int;
begin
    select p.id, p.cif,
           array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mi_perfil, mi_cif, prefijos
    from public.perfiles p where p.id = public.mi_perfil_id();

    if mi_perfil is null then return; end if;

    if prefijos is null or array_length(prefijos, 1) is null then
        return;
    end if;

    select cg.datos, cg.calculado into guardado, cuando
    from public.competencia_guardada cg where cg.perfil_id = mi_perfil;

    if guardado is not null and cuando > now() - interval '1 day' then
        return query
        select x->>'cif', x->>'nombre', (x->>'contratos')::int,
               (x->>'importe')::numeric, false
        from jsonb_array_elements(guardado) as x;
        return;
    end if;

    -- Hasta cuatro prefijos, 1.000 cada uno: es lo que ya había y
    -- cabe de sobra. A partir de ahí se reparte un total de 2.500,
    -- con un suelo de 150 para que un perfil con treinta prefijos
    -- siga viendo algo de cada uno.
    n_pref  := array_length(prefijos, 1);
    cuantos := case when n_pref <= 4 then 1000
                    else greatest(150, (2500 / n_pref)::int) end;

    foreach uno in array prefijos loop
        cola := cola || array(
            select (l.adjudicatario, l.adjudicatario_cif,
                    public.importe_de_empresa(l.importe_adjudicacion,
                        l.adjudicaciones, l.adjudicatario_cif, l.adjudicatarios),
                    l.id_licitacion,
                    l.fecha_actualizacion)::fila_competencia
            from public.licitaciones l
            where l.prefijo_principal = uno
              and l.adjudicatario_cif is not null
            order by l.fecha_actualizacion desc
            limit cuantos);
    end loop;

    with limpias as (
        select c.* from unnest(cola) c
        left join public.veredictos_mercado v
          on v.id_licitacion = c.id_licitacion and v.perfil_id = mi_perfil
        where coalesce(v.del_sector, true)
          and c.adjudicatario_cif is distinct from mi_cif
          and c.fecha_actualizacion >= desde
    ),
    top as (
        select c.adjudicatario_cif as cif,
               (array_agg(c.adjudicatario))[1] as nombre,
               count(*)::int as contratos,
               coalesce(sum(c.importe_adjudicacion), 0) as importe
        from limpias c
        where not exists (
            select 1 from public.seguimiento sg
            where sg.perfil_id = mi_perfil and sg.cif = c.adjudicatario_cif)
        group by c.adjudicatario_cif
        order by count(*) desc
        limit 25
    )
    select coalesce(jsonb_agg(to_jsonb(t) order by t.contratos desc), '[]'::jsonb)
    into guardado from top t;

    insert into public.competencia_guardada (perfil_id, datos, calculado)
    values (mi_perfil, guardado, now())
    on conflict (perfil_id) do update
        set datos = excluded.datos, calculado = excluded.calculado;

    return query
    select x->>'cif', x->>'nombre', (x->>'contratos')::int,
           (x->>'importe')::numeric, false
    from jsonb_array_elements(guardado) as x;
end;
$function$;


-- ------------------------------------------------------------
-- Movimientos
-- ------------------------------------------------------------
create or replace function public.movimientos_mercado(dias integer default 30)
returns table(id_licitacion text, titulo text, organo text, provincia text, sector text, empresa text, cif text, importe numeric, presupuesto numeric, fecha timestamp with time zone, enlace text, es_mia boolean, la_sigo boolean, grupo text)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif,
               array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    ),
    -- Se acota PRIMERO por sector y fecha, y se cruza con los veredictos
    -- después. Cruzando antes, el planificador recorría el millón de
    -- licitaciones antes de descartar nada y la consulta agotaba el
    -- tiempo.
    recientes as (
        select l.*
        from yo
        cross join public.licitaciones l
        where l.prefijo_principal = any(yo.prefijos)
          and l.adjudicatario_cif is not null
          and l.fecha_actualizacion >= now() - (dias || ' days')::interval
        order by l.fecha_actualizacion desc
        limit 600
    )
    select r.id_licitacion, r.titulo, r.organo, r.provincia, r.sector,
           r.adjudicatario, r.adjudicatario_cif,
           public.importe_de_empresa(r.importe_adjudicacion, r.adjudicaciones,
                                     r.adjudicatario_cif, r.adjudicatarios),
           r.presupuesto,
           r.fecha_actualizacion, r.enlace,
           r.adjudicatario_cif = yo.cif,
           exists (select 1 from public.seguimiento s
                   where s.perfil_id = yo.id and s.cif = r.adjudicatario_cif),
           coalesce(r.organo, '') || ' ·· ' || coalesce(r.titulo_normal, r.titulo)
    from recientes r
    cross join yo
    where coalesce((select v.del_sector from public.veredictos_mercado v
                    where v.perfil_id = yo.id
                      and v.id_licitacion = r.id_licitacion), true)
    order by r.fecha_actualizacion desc
    limit 500;
$function$;


create or replace function public.ranking_mercado(dias integer default 30)
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif,
               array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    ),
    movidas as (
        select l.*, yo.cif as mi_cif, yo.id as mi_perfil,
               public.importe_de_empresa(l.importe_adjudicacion, l.adjudicaciones,
                                         l.adjudicatario_cif, l.adjudicatarios) as suyo
        from public.licitaciones l, yo
        where l.prefijos && yo.prefijos
          and l.adjudicatario_cif is not null
          and l.fecha_actualizacion >= now() - (dias || ' days')::interval
    )
    select jsonb_build_object(
        'empresas', (
            select jsonb_agg(jsonb_build_object(
                       'nombre', t.nombre, 'cif', t.cif,
                       'contratos', t.n, 'importe', t.euros,
                       'es_mia', t.es_mia, 'la_sigo', t.la_sigo)
                     order by t.n desc, t.euros desc nulls last)
            from (
                select m.adjudicatario_cif as cif,
                       (array_agg(m.adjudicatario
                        order by m.fecha_actualizacion desc))[1] as nombre,
                       count(*)::int as n,
                       coalesce(sum(m.suyo), 0) as euros,
                       bool_or(m.adjudicatario_cif = m.mi_cif) as es_mia,
                       bool_or(exists (
                           select 1 from public.seguimiento s
                           where s.perfil_id = m.mi_perfil
                             and s.cif = m.adjudicatario_cif)) as la_sigo
                from movidas m
                group by m.adjudicatario_cif
                order by count(*) desc, sum(m.suyo) desc nulls last
                limit 6
            ) t
        ),
        'organos', (
            select jsonb_agg(jsonb_build_object(
                       'organo', t.organo, 'provincia', t.provincia,
                       'contratos', t.n, 'importe', t.euros)
                     order by t.n desc, t.euros desc nulls last)
            from (
                select m.organo,
                       (array_agg(m.provincia))[1] as provincia,
                       count(*)::int as n,
                       coalesce(sum(m.importe_adjudicacion), 0) as euros
                from movidas m
                where m.organo is not null
                group by m.organo
                order by count(*) desc, sum(m.importe_adjudicacion) desc nulls last
                limit 6
            ) t
        )
    );
$function$;


-- ------------------------------------------------------------
-- Organismos
-- ------------------------------------------------------------
-- El total del organismo sigue siendo el de los expedientes; lo que
-- cambia es cuánto de eso se lleva cada empresa (líder, concentración,
-- lista de empresas y de contratos).
create or replace function public.organismos_del_sector(desde integer default null::integer, hasta integer default null::integer)
returns table(organo text, provincia text, contratos integer, importe numeric, empresas integer, concentracion integer, lider text, lider_cif text, lider_es_mio boolean, ultimo timestamp with time zone)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif,
               array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    ),
    suyas as (
        select l.organo, l.provincia, l.adjudicatario, l.adjudicatario_cif,
               coalesce(l.importe_adjudicacion, 0) as importe,
               coalesce(public.importe_de_empresa(
                   l.importe_adjudicacion, l.adjudicaciones,
                   l.adjudicatario_cif, l.adjudicatarios), 0) as de_empresa,
               l.fecha_actualizacion, l.id_licitacion, yo.cif as mi_cif
        from public.licitaciones l, yo
        where l.prefijos && yo.prefijos
          and l.adjudicatario_cif is not null
          and l.organo is not null
          and (desde is null
               or extract(year from l.fecha_actualizacion) >= desde)
          and (hasta is null
               or extract(year from l.fecha_actualizacion) <= hasta)
    ),
    por_organo as (
        select organo,
               (array_agg(provincia))[1] as provincia,
               count(*)::int as contratos,
               sum(importe) as importe,
               count(distinct adjudicatario_cif)::int as empresas,
               max(fecha_actualizacion) as ultimo
        from suyas group by organo
    ),
    lideres as (
        select distinct on (organo)
               organo, adjudicatario, adjudicatario_cif,
               sum(de_empresa) as suyo,
               bool_or(adjudicatario_cif = mi_cif) as es_mio
        from suyas
        group by organo, adjudicatario, adjudicatario_cif
        order by organo, sum(de_empresa) desc
    )
    select o.organo, o.provincia, o.contratos, o.importe, o.empresas,
           case when o.importe > 0
                then round(l.suyo / o.importe * 100)::int
                else null end,
           l.adjudicatario, l.adjudicatario_cif, l.es_mio, o.ultimo
    from por_organo o
    join lideres l on l.organo = o.organo
    order by o.importe desc nulls last
    limit 40;
$function$;


create or replace function public.ficha_organismo(organo_buscado text, desde integer default null::integer, hasta integer default null::integer)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    mi_perfil uuid;
    guardado  jsonb;
    cuando    timestamptz;
begin
    select id into mi_perfil from public.perfiles where id = public.mi_perfil_id();
    if mi_perfil is null then return '{}'::jsonb; end if;

    select f.datos, f.calculado into guardado, cuando
    from public.fichas_organismo f
    where f.perfil_id = mi_perfil and f.organo = organo_buscado;

    if guardado is not null and cuando > now() - interval '1 day' then
        return guardado;
    end if;

    with yo as (
        select p.cif,
               array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = mi_perfil
    ),
    -- 800 y lo más reciente primero. Todo lo que se calcula aquí son
    -- promedios y repartos, no sumas: con 800 contratos salen
    -- prácticamente iguales que con 3.000, y la consulta baja de tres
    -- segundos a menos de uno.
    suyas as (
        select l.*, yo.cif as mi_cif,
               public.importe_de_empresa(l.importe_adjudicacion, l.adjudicaciones,
                                         l.adjudicatario_cif, l.adjudicatarios) as suyo
        from yo
        cross join public.licitaciones l
        where l.organo = organo_buscado
          and l.prefijo_principal = any(yo.prefijos)
          and l.adjudicatario_cif is not null
        order by l.fecha_actualizacion desc
        limit 800
    )
    select jsonb_build_object(
        'organo', organo_buscado,
        'provincia', (select provincia from suyas limit 1),
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
                select s.adjudicatario_cif as cif,
                       (array_agg(s.adjudicatario
                        order by s.fecha_actualizacion desc))[1] as nombre,
                       count(*)::int as n,
                       coalesce(sum(s.suyo), 0) as euros,
                       bool_or(s.adjudicatario_cif = s.mi_cif) as es_mia
                from suyas s group by s.adjudicatario_cif
                order by count(*) desc limit 20
            ) t),
        'contratos_lista', (
            select jsonb_agg(jsonb_build_object(
                       'titulo', u.titulo, 'empresa', u.adjudicatario,
                       'cif', u.adjudicatario_cif,
                       'importe', u.suyo,
                       'fecha', u.fecha_actualizacion,
                       'es_mia', u.adjudicatario_cif = u.mi_cif,
                       'licitadores', u.licitadores,
                       'oferta_baja', u.oferta_baja, 'oferta_alta', u.oferta_alta,
                       'baja', public.baja_real(u.presupuesto_base,
                                 u.importe_sin_iva, u.lotes, u.sistema))
                     order by u.fecha_actualizacion desc)
            from (select * from suyas
                  order by fecha_actualizacion desc limit 40) u)
    ) into guardado;

    insert into public.fichas_organismo (perfil_id, organo, datos, calculado)
    values (mi_perfil, organo_buscado, guardado, now())
    on conflict (perfil_id, organo) do update
        set datos = excluded.datos, calculado = excluded.calculado;

    return guardado;
end;
$function$;


-- ------------------------------------------------------------
-- Agregados nocturnos de empresas
-- ------------------------------------------------------------
create or replace function public.refrescar_catalogo_empresas(desde timestamp with time zone default null::timestamp with time zone)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare n integer;
begin
    insert into public.empresas (cif, nombre, nombre_norm, contratos,
                                 importe_total, ultimo)
    select l.adjudicatario_cif,
           (array_agg(l.adjudicatario order by l.fecha_actualizacion desc))[1],
           public.normalizar_nombre(
               (array_agg(l.adjudicatario order by l.fecha_actualizacion desc))[1]),
           count(*)::int,
           sum(public.importe_de_empresa(l.importe_adjudicacion, l.adjudicaciones,
                                         l.adjudicatario_cif, l.adjudicatarios)),
           max(l.fecha_actualizacion)
    from public.licitaciones l
    where l.adjudicatario_cif is not null and l.adjudicatario is not null
      and (desde is null or l.adjudicatario_cif in (
            select distinct c.adjudicatario_cif from public.licitaciones c
            where c.adjudicatario_cif is not null
              and c.fecha_actualizacion >= desde))
    group by l.adjudicatario_cif
    on conflict (cif) do update set
        nombre        = excluded.nombre,
        nombre_norm   = excluded.nombre_norm,
        contratos     = excluded.contratos,
        importe_total = excluded.importe_total,
        ultimo        = excluded.ultimo;

    get diagnostics n = row_count;
    return n;
end;
$function$;


create or replace function public.refrescar_empresas()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    sello   timestamptz := now();
    metidas int;
begin
    if auth.uid() is not null then
        raise exception 'refrescar_empresas: solo con clave de servicio';
    end if;

    insert into public.empresas_por_cif
        (cif, nombre, contratos, importe, ultima_fecha, actualizado)
    select l.adjudicatario_cif,
           (array_agg(l.adjudicatario order by l.fecha_actualizacion desc))[1],
           count(*)::int,
           coalesce(sum(public.importe_de_empresa(
               l.importe_adjudicacion, l.adjudicaciones,
               l.adjudicatario_cif, l.adjudicatarios)), 0),
           max(l.fecha_actualizacion),
           sello
    from public.licitaciones l
    where l.adjudicatario_cif is not null
    group by l.adjudicatario_cif
    on conflict (cif) do update
        set nombre       = excluded.nombre,
            contratos    = excluded.contratos,
            importe      = excluded.importe,
            ultima_fecha = excluded.ultima_fecha,
            actualizado  = excluded.actualizado;

    get diagnostics metidas = row_count;

    delete from public.empresas_por_cif where actualizado < sello;

    return metidas;
end;
$function$;


-- ------------------------------------------------------------
-- Cachés por perfil: se tiran para que nadie vea las cifras viejas
-- durante las próximas 24 horas.
-- ------------------------------------------------------------
delete from public.competencia_guardada;
delete from public.fichas_organismo;
delete from public.organismos_guardados;


-- ------------------------------------------------------------
-- DESPUÉS de aplicar, a mano y por separado (tardan):
--
--   select public.refrescar_catalogo_empresas(null);
--   select public.refrescar_empresas();
--   select public.refrescar_organismos();
-- ------------------------------------------------------------
