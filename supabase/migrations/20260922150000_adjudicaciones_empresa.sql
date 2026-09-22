-- ============================================================
-- adjudicaciones_empresa: una fila por licitación y empresa ganadora
-- ============================================================
--
-- Aplicada el 22/09/2026, tramo a tramo. Relleno: 1.231.866 filas,
-- 220.197 empresas (16.453 más que antes, las que solo ganaban lotes
-- secundarios). la empresa de uniformidad policial: 66 contratos, 70 lotes, 2.763.797 €.
--
-- Hasta ahora todas las cifras por empresa salían de
-- `licitaciones.adjudicatario_cif`, que guarda UN ganador por
-- expediente: el que más se llevó. Quien ganaba un lote sin ser el
-- principal no existía para ese contrato. Medido el 22/09/2026:
-- 190.488 lotes de 47.933 licitaciones, de 42.013 empresas, con
-- 52.614 M€ fuera de acuerdos marco que no se apuntaba nadie (frente a
-- 282.416 M€ atribuidos). la empresa de uniformidad policial ganó lotes en 2 licitaciones que no
-- le contaban. Una empresa que SOLO gana lotes secundarios ni siquiera
-- aparecía en el catálogo, así que no podía darse de alta.
--
-- Esta tabla reparte cada licitación entre todos sus ganadores:
--
--   - `lotes`: cuántos lotes ganó esa empresa en ese expediente. Una
--     licitación cuenta como UN contrato aunque gane tres lotes; los
--     lotes van aparte (decidido el 22/09/2026).
--   - `importe`: su parte. El total si ganó sola; la suma de sus lotes
--     si hubo varios ganadores y los lotes cuadran con el total; nada
--     si no cuadran (acuerdos marco, lotes que repiten el importe del
--     expediente entero). Mejor un hueco que un número falso.
--   - `principal`: si es la que figura en `adjudicatario_cif`.
--
-- La mantiene un disparador sobre `licitaciones`, así que el lector, el
-- histórico y `refrescar_licitaciones` no cambian.
--
-- Orden de aplicación (cada tramo por separado):
--   1. Tabla, reparto y disparador.
--   2. Relleno, por tandas de páginas (al final del fichero).
--   3. Funciones que leen de aquí.
--   4. Agregados: catálogo de empresas, empresas_por_cif.
-- ============================================================


-- ============================================================
-- TRAMO 1: tabla, reparto y disparador
-- ============================================================

create table if not exists public.adjudicaciones_empresa (
    id_licitacion text not null
        references public.licitaciones (id_licitacion) on delete cascade,
    cif        text    not null,
    nombre     text,
    importe    numeric,
    lotes      integer not null default 1,
    principal  boolean not null default false,
    primary key (id_licitacion, cif)
);

create index if not exists idx_adjudicaciones_empresa_cif
    on public.adjudicaciones_empresa (cif);

-- Solo se lee a través de funciones con SECURITY DEFINER.
alter table public.adjudicaciones_empresa enable row level security;
revoke all on public.adjudicaciones_empresa from anon, authenticated;


-- El reparto de una licitación entre sus ganadores.
--
-- Sin `set search_path`: no toca tablas, y así se expande en línea.
create or replace function public.reparto_adjudicacion(
    adjudicaciones jsonb, nombre_principal text, cif_principal text,
    total numeric)
returns table(cif text, nombre text, importe numeric, lotes integer,
              principal boolean)
language sql
immutable
as $function$
    with lote as (
        select a.value->>'cif' as cif,
               nullif(a.value->>'adjudicatario', '') as nombre,
               case when jsonb_typeof(a.value->'importe') = 'number'
                    then (a.value->>'importe')::numeric end as importe
        from jsonb_array_elements(
                 case when jsonb_typeof(adjudicaciones) = 'array'
                      then adjudicaciones else '[]'::jsonb end) a
        where coalesce(a.value->>'cif', '') <> ''
    ),
    por_cif as (
        select lote.cif,
               (array_agg(lote.nombre) filter (where lote.nombre is not null))[1] as nombre,
               count(*)::int as n,
               sum(lote.importe) as suma
        from lote group by lote.cif
        -- El principal siempre tiene su fila, aunque su lote no traiga
        -- CIF: es lo que ya se contaba antes de esta tabla.
        union all
        select cif_principal, nombre_principal, 1, null
        where coalesce(cif_principal, '') <> ''
          and not exists (select 1 from lote where lote.cif = cif_principal)
    ),
    cuadre as (
        select (select count(*) from por_cif) as ganadores,
               -- Los lotes solo se pueden repartir si suman el total. En
               -- un acuerdo marco cada lote publica el marco entero, y la
               -- suma se dispara.
               (select coalesce(sum(lote.importe), 0) from lote)
                   <= total * 1.01 as cuadra
    )
    select p.cif,
           case when p.cif = cif_principal
                then coalesce(nombre_principal, p.nombre) else p.nombre end,
           case when total is null then null
                when c.ganadores = 1 then total
                -- Con `case` y no con `least(nullif(suma, 0), total)`:
                -- `least` ignora los nulos, y una empresa sin importe en
                -- sus lotes se quedaba con el total entero. Pasaba en
                -- 3.292 licitaciones al rellenar la tabla por primera vez.
                when c.cuadra and p.suma > 0 then least(p.suma, total)
                else null end,
           p.n,
           p.cif is not distinct from cif_principal
    from por_cif p cross join cuadre c
$function$;

revoke execute on function public.reparto_adjudicacion(jsonb, text, text, numeric)
    from public, anon, authenticated;


create or replace function public.sincronizar_adjudicaciones_empresa()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    -- El scraper reescribe filas enteras en cada pasada: solo se rehace
    -- si cambió algo que afecta al reparto.
    if tg_op = 'UPDATE'
       and new.adjudicaciones is not distinct from old.adjudicaciones
       and new.adjudicatario is not distinct from old.adjudicatario
       and new.adjudicatario_cif is not distinct from old.adjudicatario_cif
       and new.importe_adjudicacion is not distinct from old.importe_adjudicacion
    then
        return null;
    end if;

    delete from public.adjudicaciones_empresa
    where id_licitacion = new.id_licitacion;

    insert into public.adjudicaciones_empresa
        (id_licitacion, cif, nombre, importe, lotes, principal)
    select new.id_licitacion, r.cif, r.nombre, r.importe, r.lotes, r.principal
    from public.reparto_adjudicacion(new.adjudicaciones, new.adjudicatario,
                                     new.adjudicatario_cif,
                                     new.importe_adjudicacion) r;
    return null;
end;
$function$;

revoke execute on function public.sincronizar_adjudicaciones_empresa()
    from public, anon, authenticated;

drop trigger if exists trg_adjudicaciones_empresa on public.licitaciones;
create trigger trg_adjudicaciones_empresa
    after insert or update of adjudicaciones, adjudicatario,
                              adjudicatario_cif, importe_adjudicacion
    on public.licitaciones
    for each row execute function public.sincronizar_adjudicaciones_empresa();


-- ============================================================
-- TRAMO 2: relleno (se ejecutó por tandas de páginas, así)
-- ============================================================
--
--   insert into public.adjudicaciones_empresa
--       (id_licitacion, cif, nombre, importe, lotes, principal)
--   select l.id_licitacion, r.cif, r.nombre, r.importe, r.lotes, r.principal
--   from public.licitaciones l
--   cross join lateral public.reparto_adjudicacion(
--       l.adjudicaciones, l.adjudicatario, l.adjudicatario_cif,
--       l.importe_adjudicacion) r
--   where l.ctid >= '(DESDE,0)'::tid and l.ctid < '(HASTA,0)'::tid
--   on conflict do nothing;


-- ============================================================
-- TRAMO 3: las funciones leen de adjudicaciones_empresa
-- ============================================================
--
-- Reglas comunes:
--   - Contratos de una empresa: licitaciones en las que ganó algo.
--     Los lotes van aparte (`lotes`).
--   - Euros de una empresa: su parte (`adjudicaciones_empresa.importe`).
--   - Euros de un organismo o del mercado: el total del expediente.
--   - "Tu empresa" / "la sigues": si está ENTRE los ganadores, no solo
--     si es la principal.

create table if not exists public.respaldo_funciones_reparto_20260922 as
select p.proname as nombre, pg_get_functiondef(p.oid) as definicion,
       now() as guardado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('mi_panel', 'buscar_empresa', 'ficha_empresa',
                    'ultimos_ganados', 'competencia', 'movimientos_mercado',
                    'pulso_mercado', 'ranking_mercado', 'organismos_del_sector',
                    'ficha_organismo', 'refrescar_catalogo_empresas',
                    'refrescar_empresas', 'prefijos_de_empresa',
                    'material_de_empresa', 'importe_de_empresa');
alter table public.respaldo_funciones_reparto_20260922 enable row level security;
revoke all on public.respaldo_funciones_reparto_20260922 from anon, authenticated;


-- ------------------------------------------------------------
-- Mi cuenta
-- ------------------------------------------------------------
-- `contratos_ganados` se calcula al momento en vez de leer el que se
-- guardó en el alta: ese se quedaba congelado y además no contaba los
-- lotes secundarios.
create or replace function public.mi_panel()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
    with suyas as (
        select a.importe as suyo, a.lotes, l.sector, l.organo
        from public.perfiles p
        join public.adjudicaciones_empresa a on a.cif = p.cif
        join public.licitaciones l on l.id_licitacion = a.id_licitacion
        where p.id = public.mi_perfil_id()
    )
    select jsonb_build_object(
        'empresa', p.empresa,
        'cif', p.cif,
        'email', p.email,
        'actividad', p.descripcion,
        'que_buscamos', p.que_buscamos,
        'contratos_ganados', coalesce(
            nullif((select count(*) from suyas), 0), p.contratos_ganados),
        'lotes_ganados', (select sum(lotes) from suyas),
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
                select s.sector, count(*)::int as n,
                       coalesce(sum(s.suyo), 0) as euros
                from suyas s where s.sector is not null
                group by s.sector order by euros desc nulls last limit 10
            ) t
        ),
        'importe_ganado', (select sum(suyo) from suyas),
        'organos', (
            select jsonb_agg(jsonb_build_object(
                       'organo', o.organo, 'contratos', o.n, 'importe', o.euros)
                     order by o.n desc)
            from (
                select s.organo, count(*)::int as n,
                       coalesce(sum(s.suyo), 0) as euros
                from suyas s where s.organo is not null
                group by s.organo order by count(*) desc limit 8
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
        select a.cif,
               (array_agg(a.nombre order by l.fecha_actualizacion desc))[1],
               count(*)::int,
               sum(a.importe),
               max(l.fecha_actualizacion),
               (select jsonb_agg(jsonb_build_object('sector', t.sector,
                                                    'contratos', t.n)
                                 order by t.n desc)
                from (select s.sector, count(*)::int as n
                      from public.adjudicaciones_empresa b
                      join public.licitaciones s on s.id_licitacion = b.id_licitacion
                      where b.cif = limpio and s.sector is not null
                      group by s.sector order by n desc limit 12) t)
        from public.adjudicaciones_empresa a
        join public.licitaciones l on l.id_licitacion = a.id_licitacion
        where a.cif = limpio
        group by a.cif;
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
            from (select s.sector, count(*)::int as n
                  from public.adjudicaciones_empresa b
                  join public.licitaciones s on s.id_licitacion = b.id_licitacion
                  where b.cif = e.cif and s.sector is not null
                  group by s.sector order by n desc limit 12) t)
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
            select s.titulo, s.organo, s.sector, s.fecha_actualizacion,
                   a.nombre, a.importe as suyo, a.lotes
            from public.adjudicaciones_empresa a
            join public.licitaciones s on s.id_licitacion = a.id_licitacion
            where a.cif = limpio
        )
        select jsonb_build_object(
            'cif', limpio,
            'nombre', (select nombre from suyas
                       order by fecha_actualizacion desc limit 1),
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
    select l.titulo, l.organo, a.importe, l.fecha_actualizacion, l.sector
    from public.adjudicaciones_empresa a
    join public.licitaciones l on l.id_licitacion = a.id_licitacion
    where a.cif = limpio
    order by l.fecha_actualizacion desc nulls last
    limit tope;
end;
$function$;


-- Se acota por sector igual que antes (las N licitaciones más recientes
-- de cada prefijo) y DESPUÉS se reparte entre sus ganadores.
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
            select (a.nombre, a.cif, a.importe, r.id_licitacion,
                    r.fecha_actualizacion)::fila_competencia
            from (select l.id_licitacion, l.fecha_actualizacion
                  from public.licitaciones l
                  where l.prefijo_principal = uno
                    and l.adjudicatario_cif is not null
                  order by l.fecha_actualizacion desc
                  limit cuantos) r
            join public.adjudicaciones_empresa a
              on a.id_licitacion = r.id_licitacion);
    end loop;

    with limpias as (
        -- Una licitación de dos prefijos del perfil entra dos veces en
        -- la cola; se cuenta una.
        select distinct c.* from unnest(cola) c
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
-- Una fila por licitación, como antes. Se añaden:
--   - `total`: el importe del expediente (`importe` sigue siendo la
--     parte de la principal, para que la web anterior no cambie).
--   - `ganadores`: todas las empresas, con su parte y sus lotes. La web
--     enseña "X y 12 más" y reparte el ranking entre todas.
-- `es_mia` y `la_sigo` pasan a mirar a TODOS los ganadores.
drop function if exists public.movimientos_mercado(integer);
create function public.movimientos_mercado(dias integer default 30)
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
    where coalesce((select v.del_sector from public.veredictos_mercado v
                    where v.perfil_id = yo.id
                      and v.id_licitacion = r.id_licitacion), true)
    order by r.fecha_actualizacion desc
    limit 500;
$function$;

revoke execute on function public.movimientos_mercado(integer) from public, anon;
grant execute on function public.movimientos_mercado(integer) to authenticated;


create or replace function public.pulso_mercado(dias integer default 30)
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
    -- Se acota igual que en `movimientos_mercado`: por sector y fecha,
    -- con tope. Sin el límite, un sector grande arrastraba decenas de
    -- miles de filas para calcular cuatro cifras.
    movidas as (
        select l.id_licitacion, l.importe_adjudicacion, yo.cif as mi_cif
        from yo
        cross join public.licitaciones l
        where l.prefijo_principal = any(yo.prefijos)
          and l.adjudicatario_cif is not null
          and l.fecha_actualizacion >= now() - (dias || ' days')::interval
        limit 2000
    ),
    ganadores as (
        select a.cif, a.id_licitacion, m.mi_cif
        from movidas m
        join public.adjudicaciones_empresa a on a.id_licitacion = m.id_licitacion
    )
    select jsonb_build_object(
        'contratos', (select count(*) from movidas),
        'importe', (select coalesce(sum(importe_adjudicacion), 0) from movidas),
        'empresas', (select count(distinct cif) from ganadores),
        'mias', (select count(distinct id_licitacion) from ganadores
                 where cif = mi_cif),
        'importe_medio', (select round(avg(importe_adjudicacion))
                          from movidas where importe_adjudicacion > 0)
    );
$function$;


-- Sin uso en la web; se mantiene coherente con el resto.
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
        select l.*, yo.cif as mi_cif, yo.id as mi_perfil
        from public.licitaciones l, yo
        where l.prefijos && yo.prefijos
          and l.adjudicatario_cif is not null
          and l.fecha_actualizacion >= now() - (dias || ' days')::interval
    ),
    ganadores as (
        select a.cif, a.nombre, a.importe, m.fecha_actualizacion,
               m.mi_cif, m.mi_perfil
        from movidas m
        join public.adjudicaciones_empresa a on a.id_licitacion = m.id_licitacion
    )
    select jsonb_build_object(
        'empresas', (
            select jsonb_agg(jsonb_build_object(
                       'nombre', t.nombre, 'cif', t.cif,
                       'contratos', t.n, 'importe', t.euros,
                       'es_mia', t.es_mia, 'la_sigo', t.la_sigo)
                     order by t.n desc, t.euros desc nulls last)
            from (
                select g.cif,
                       (array_agg(g.nombre order by g.fecha_actualizacion desc))[1] as nombre,
                       count(*)::int as n,
                       coalesce(sum(g.importe), 0) as euros,
                       bool_or(g.cif = g.mi_cif) as es_mia,
                       bool_or(exists (
                           select 1 from public.seguimiento s
                           where s.perfil_id = g.mi_perfil
                             and s.cif = g.cif)) as la_sigo
                from ganadores g
                group by g.cif
                order by count(*) desc, sum(g.importe) desc nulls last
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
-- Sin uso en la web; se mantiene coherente. La concentración pasa a ser
-- la parte del líder sobre el total, con el reparto por lotes.
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
        select l.organo, l.provincia, l.id_licitacion,
               coalesce(l.importe_adjudicacion, 0) as importe,
               l.fecha_actualizacion, yo.cif as mi_cif
        from public.licitaciones l, yo
        where l.prefijos && yo.prefijos
          and l.adjudicatario_cif is not null
          and l.organo is not null
          and (desde is null
               or extract(year from l.fecha_actualizacion) >= desde)
          and (hasta is null
               or extract(year from l.fecha_actualizacion) <= hasta)
    ),
    ganadores as (
        select s.organo, a.cif, a.nombre, coalesce(a.importe, 0) as de_empresa,
               s.mi_cif
        from suyas s
        join public.adjudicaciones_empresa a on a.id_licitacion = s.id_licitacion
    ),
    por_organo as (
        select s.organo,
               (array_agg(s.provincia))[1] as provincia,
               count(*)::int as contratos,
               sum(s.importe) as importe,
               (select count(distinct g.cif) from ganadores g
                where g.organo = s.organo)::int as empresas,
               max(s.fecha_actualizacion) as ultimo
        from suyas s group by s.organo
    ),
    lideres as (
        select distinct on (g.organo)
               g.organo, (array_agg(g.nombre))[1] as nombre, g.cif,
               sum(g.de_empresa) as suyo,
               bool_or(g.cif = g.mi_cif) as es_mio
        from ganadores g
        group by g.organo, g.cif
        order by g.organo, sum(g.de_empresa) desc
    )
    select o.organo, o.provincia, o.contratos, o.importe, o.empresas,
           case when o.importe > 0
                then round(l.suyo / o.importe * 100)::int
                else null end,
           l.nombre, l.cif, l.es_mio, o.ultimo
    from por_organo o
    join lideres l on l.organo = o.organo
    order by o.importe desc nulls last
    limit 40;
$function$;


-- `contratos_lista` sigue siendo una fila por licitación, y añade:
--   `total`, `otros` (cuántos ganadores más), `cifs` (todos, para que
--   al señalar una empresa salgan también los contratos donde ganó un
--   lote) y `partes` (cif -> su importe).
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
        select l.*, yo.cif as mi_cif
        from yo
        cross join public.licitaciones l
        where l.organo = organo_buscado
          and l.prefijo_principal = any(yo.prefijos)
          and l.adjudicatario_cif is not null
        order by l.fecha_actualizacion desc
        limit 800
    ),
    ganadores as (
        select s.id_licitacion, s.fecha_actualizacion, s.mi_cif,
               a.cif, a.nombre, a.importe, a.principal
        from suyas s
        join public.adjudicaciones_empresa a on a.id_licitacion = s.id_licitacion
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
    ) into guardado;

    insert into public.fichas_organismo (perfil_id, organo, datos, calculado)
    values (mi_perfil, organo_buscado, guardado, now())
    on conflict (perfil_id, organo) do update
        set datos = excluded.datos, calculado = excluded.calculado;

    return guardado;
end;
$function$;


-- ------------------------------------------------------------
-- Alta: qué ha ganado la empresa
-- ------------------------------------------------------------
-- Con los lotes secundarios, una empresa que casi nunca es la principal
-- ya tiene historial del que deducir sus sectores.
create or replace function public.prefijos_de_empresa(cif_buscado text, minimo integer default 2)
returns table(prefijo text, contratos integer)
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
begin
    return query
    select left(cpv, 4), count(distinct l.id_licitacion)::int
    from public.adjudicaciones_empresa a
    join public.licitaciones l on l.id_licitacion = a.id_licitacion,
         jsonb_array_elements_text(l.cpvs) as cpv
    where a.cif = limpio
      and length(cpv) >= 4
    group by 1
    having count(distinct l.id_licitacion) >= minimo
    order by 2 desc;
end;
$function$;


create or replace function public.material_de_empresa(cif_buscado text, prefijos text[], tope integer default 30)
returns setof licitaciones
language sql
stable security definer
set search_path to 'public'
as $function$
    with limpio as (
        select upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g')) as cif
    ),
    -- Cuántos contratos ha ganado en cada familia: de ahí sale el
    -- reparto del material, para que si el 90 % de su historial es una
    -- familia, el 90 % de los ejemplos lo sean.
    pesos as (
        select p as prefijo, count(distinct l.id_licitacion)::int as suyos
        from unnest(prefijos) as p
        join public.adjudicaciones_empresa a
          on a.cif = (select cif from limpio)
        join public.licitaciones l
          on l.id_licitacion = a.id_licitacion
         and l.prefijos @> array[p]
        group by p
    ),
    total as (select nullif(sum(suyos), 0) as n from pesos),
    cupos as (
        select pe.prefijo,
               greatest(1, round(tope * pe.suyos::numeric / t.n))::int as cupo
        from pesos pe, total t
        where t.n is not null
    ),
    -- Se numeran dentro de cada familia para cortar por el cupo sin
    -- bucle ni tabla temporal. Fuera todo lo que ganó, también como
    -- ganadora de un lote.
    elegidas as (
        select id_licitacion from (
            select l.id_licitacion, c.cupo,
                   row_number() over (partition by c.prefijo
                                      order by l.fecha_actualizacion desc) as puesto
            from cupos c
            join public.licitaciones l on l.prefijos @> array[c.prefijo]
            where not exists (
                      select 1 from public.adjudicaciones_empresa a
                      where a.id_licitacion = l.id_licitacion
                        and a.cif = (select cif from limpio))
              and l.fecha_actualizacion >= now() - interval '2 years'
        ) x
        where x.puesto <= x.cupo
    )
    select l.* from public.licitaciones l
    where l.id_licitacion in (select id_licitacion from elegidas);
$function$;


-- ------------------------------------------------------------
-- Agregados de empresas
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
    select a.cif,
           (array_agg(a.nombre order by l.fecha_actualizacion desc))[1],
           public.normalizar_nombre(
               (array_agg(a.nombre order by l.fecha_actualizacion desc))[1]),
           count(*)::int,
           sum(a.importe),
           max(l.fecha_actualizacion)
    from public.adjudicaciones_empresa a
    join public.licitaciones l on l.id_licitacion = a.id_licitacion
    where a.nombre is not null
      and (desde is null or a.cif in (
            select distinct b.cif
            from public.adjudicaciones_empresa b
            join public.licitaciones c on c.id_licitacion = b.id_licitacion
            where c.fecha_actualizacion >= desde))
    group by a.cif
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
    select a.cif,
           (array_agg(a.nombre order by l.fecha_actualizacion desc))[1],
           count(*)::int,
           coalesce(sum(a.importe), 0),
           max(l.fecha_actualizacion),
           sello
    from public.adjudicaciones_empresa a
    join public.licitaciones l on l.id_licitacion = a.id_licitacion
    group by a.cif
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


-- La sustituye la tabla. Tenía además el mismo fallo de `least` con
-- nulos que se corrigió en `reparto_adjudicacion`.
drop function if exists public.importe_de_empresa(numeric, jsonb, text, integer);

delete from public.competencia_guardada;
delete from public.fichas_organismo;


-- ============================================================
-- TRAMO 4: agregados, a mano y por separado (tardan)
-- ============================================================
--
--   select public.refrescar_catalogo_empresas(null);
--   select public.refrescar_empresas();
