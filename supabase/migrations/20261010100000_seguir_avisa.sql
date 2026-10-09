-- ============================================================
-- Que seguir avise: empresas, organismos y contratos que vencen
-- ============================================================
--
-- Propuesta 3 del informe de competencia del 09/10/2026 y Decisión 56.
-- Hasta hoy, seguir a una empresa solo la subía en la pestaña Empresas:
-- no avisaba de nada, y era la razón que más falta para volver cada día.
-- Licitandum y LICAI avisan cuando gana un competidor.
--
-- TRES COSAS QUE SE SIGUEN
--   Empresas    (`seguimiento`, ya existía): avisa de lo que ganan.
--   Organismos  (`seguimiento_organismos`, nueva): avisa de lo que
--               publican en las familias CPV del perfil, aunque el filtro
--               no lo haya elegido. Seguir un organismo es una señal
--               fuerte: quiere ver todo lo suyo de su ramo, no solo lo que
--               el filtro da por bueno.
--   Contratos   (`vigilados`, nueva): un contrato de "Lo que viene"
--               (Decisión 48). Avisa cuando sale su nueva licitación.
--
-- QUÉ DISPARA EL CORREO Y QUÉ NO
--   El 10/09/2026 se quitaron del correo las adjudicaciones de la
--   competencia: "el correo es para lo que caduca, y una adjudicación ya
--   cerrada no exige actuar hoy". Se respeta así:
--   - Lo de los organismos y los contratos vigilados es una licitación
--     ABIERTA: caduca, y dispara el correo como cualquier novedad.
--   - Lo que gana la competencia va DENTRO del correo cuando hay otra
--     cosa que contar. Solo, como mucho una vez por semana: un resumen,
--     no un correo diario por cada contrato de un rival grande.
--
-- LO VIGILADO: DOS GRADOS DE CERTEZA
--   Seguro: la pareja de `vencimientos_nueva` (Decisión 52: mismo órgano
--   y CPV, palabras raras del título, emparejamiento único). Cubre poco,
--   unos 300 de 84.000.
--   Posible: una licitación nueva del mismo órgano y el mismo CPV
--   principal. Medido del 05 al 09/10/2026: como mucho 2-4 licitaciones
--   nuevas al día por pareja órgano-CPV, así que el ruido es poco, y se
--   dice "puede ser la nueva licitación", nunca que lo es.
--   El contrato se guarda con sus datos (título, órgano, CPV, vence)
--   porque `vencimientos` lo borra cuando vence, y la nueva licitación
--   puede salir después.
--
-- NADA SE AVISA DOS VECES
--   `avisos_seguimiento` guarda lo enviado. Lo escribe el correo diario
--   SOLO cuando el correo sale; en simulacro no. Las ventanas son de días
--   (no de 26 h) para que una caída del robot no pierda nada: la tabla es
--   la que evita repetir.
--
-- No toca `licitaciones`, `mis_oportunidades`, `lo_que_viene` ni las
-- fichas: la web cruza lo seguido por su cuenta con `mis_seguimientos()`.
-- ============================================================

-- ------------------------------------------------------------
-- Tablas
-- ------------------------------------------------------------

create table if not exists public.seguimiento_organismos (
    perfil_id uuid not null references public.perfiles(id) on delete cascade,
    organo    text not null,
    creado    timestamptz not null default now(),
    primary key (perfil_id, organo)
);

comment on table public.seguimiento_organismos is
  'Organismos que sigue cada perfil. Se escribe solo con seguir_organismo '
  '(Decisión 56).';

-- Para el correo, que busca por órgano lo publicado.
create index if not exists idx_seguimiento_organismos_organo
    on public.seguimiento_organismos (organo);

alter table public.seguimiento_organismos enable row level security;
revoke all on public.seguimiento_organismos from anon, authenticated;
grant select on public.seguimiento_organismos to authenticated;

drop policy if exists "organismos seguidos propios: leer" on public.seguimiento_organismos;
create policy "organismos seguidos propios: leer" on public.seguimiento_organismos
    for select to authenticated
    using (exists (select 1 from public.perfiles p
                   where p.id = seguimiento_organismos.perfil_id
                     and p.usuario_id = (select auth.uid())));


create table if not exists public.vigilados (
    perfil_id         uuid not null references public.perfiles(id) on delete cascade,
    id_licitacion     text not null,
    titulo            text,
    organo            text,
    prefijo_principal text,
    empresa           text,
    importe           numeric,
    enlace            text,
    vence             date,
    creado            timestamptz not null default now(),
    primary key (perfil_id, id_licitacion)
);

comment on table public.vigilados is
  'Contratos de "Lo que viene" que un perfil vigila para enterarse de su '
  'nueva licitación. Copia sus datos: vencimientos los borra al vencer. '
  'Se escribe solo con vigilar (Decisión 56).';

alter table public.vigilados enable row level security;
revoke all on public.vigilados from anon, authenticated;
grant select on public.vigilados to authenticated;

drop policy if exists "vigilados propios: leer" on public.vigilados;
create policy "vigilados propios: leer" on public.vigilados
    for select to authenticated
    using (exists (select 1 from public.perfiles p
                   where p.id = vigilados.perfil_id
                     and p.usuario_id = (select auth.uid())));


create table if not exists public.avisos_seguimiento (
    perfil_id     uuid not null references public.perfiles(id) on delete cascade,
    tipo          text not null check (tipo in ('gana', 'organismo', 'vigilado')),
    id_licitacion text not null,
    referencia    text,            -- el CIF, el órgano o el contrato vigilado
    enviado       timestamptz not null default now(),
    primary key (perfil_id, tipo, id_licitacion)
);

comment on table public.avisos_seguimiento is
  'Lo ya avisado por correo de lo que se sigue, para no repetirlo. Lo '
  'escribe alertador.py al enviar (Decisión 56).';

alter table public.avisos_seguimiento enable row level security;
revoke all on public.avisos_seguimiento from anon, authenticated;


-- ------------------------------------------------------------
-- Escribir (desde la web)
-- ------------------------------------------------------------

-- Seguir o dejar de seguir un organismo. Como `seguir`, alterna y dice
-- cómo queda.
create or replace function public.seguir_organismo(organo_elegido text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    perfil uuid := public.mi_perfil_id();
    limpio text := nullif(trim(organo_elegido), '');
begin
    if perfil is null or limpio is null then
        return false;
    end if;

    if exists (select 1 from public.seguimiento_organismos
               where perfil_id = perfil and organo = limpio) then
        delete from public.seguimiento_organismos
        where perfil_id = perfil and organo = limpio;
        return false;
    end if;

    -- Solo órganos que existen (por índice): evita guardar basura desde
    -- la consola. Y un tope holgado.
    if not exists (select 1 from public.licitaciones where organo = limpio) then
        return false;
    end if;
    if (select count(*) from public.seguimiento_organismos
        where perfil_id = perfil) >= 200 then
        return false;
    end if;

    insert into public.seguimiento_organismos (perfil_id, organo)
    values (perfil, limpio);
    return true;
end;
$function$;


-- Vigilar o dejar de vigilar un contrato de "Lo que viene". Copia sus
-- datos de `vencimientos` (o, si ya no está, de `licitaciones`).
create or replace function public.vigilar(licitacion text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    perfil uuid := public.mi_perfil_id();
begin
    if perfil is null or licitacion is null then
        return false;
    end if;

    if exists (select 1 from public.vigilados
               where perfil_id = perfil and id_licitacion = licitacion) then
        delete from public.vigilados
        where perfil_id = perfil and id_licitacion = licitacion;
        return false;
    end if;

    if (select count(*) from public.vigilados where perfil_id = perfil) >= 500 then
        return false;
    end if;

    insert into public.vigilados
        (perfil_id, id_licitacion, titulo, organo, prefijo_principal,
         empresa, importe, enlace, vence)
    select perfil, v.id_licitacion, v.titulo, v.organo, v.prefijo_principal,
           v.empresa, v.importe, v.enlace, v.vence
    from public.vencimientos v
    where v.id_licitacion = licitacion;

    if not found then
        insert into public.vigilados
            (perfil_id, id_licitacion, titulo, organo, prefijo_principal,
             empresa, importe, enlace)
        select perfil, l.id_licitacion, l.titulo, l.organo, l.prefijo_principal,
               l.adjudicatario, l.importe_adjudicacion, l.enlace
        from public.licitaciones l
        where l.id_licitacion = licitacion;
        if not found then
            return false;
        end if;
    end if;
    return true;
end;
$function$;


-- ------------------------------------------------------------
-- Leer (desde la web)
-- ------------------------------------------------------------

-- Todo lo que sigue el perfil activo, para marcar botones y para el
-- panel de avisos. Los vigilados llevan su nueva licitación si ya se
-- emparejó con seguridad.
create or replace function public.mis_seguimientos()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    with yo as (select public.mi_perfil_id() as id)
    select jsonb_build_object(
        'empresas', coalesce((
            select jsonb_agg(jsonb_build_object('cif', s.cif, 'nombre', s.nombre)
                             order by s.creado desc)
            from public.seguimiento s, yo where s.perfil_id = yo.id), '[]'),
        'organismos', coalesce((
            select jsonb_agg(jsonb_build_object('organo', o.organo)
                             order by o.creado desc)
            from public.seguimiento_organismos o, yo where o.perfil_id = yo.id), '[]'),
        'vigilados', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'id_licitacion', v.id_licitacion, 'titulo', v.titulo,
                       'organo', v.organo, 'empresa', v.empresa,
                       'enlace', v.enlace, 'vence', v.vence,
                       'nueva', (select jsonb_build_object(
                                     'titulo', n.titulo, 'enlace', n.enlace,
                                     'fecha_limite', n.fecha_limite)
                                 from public.vencimientos_nueva vn
                                 join public.licitaciones n on n.id_licitacion = vn.nueva
                                 where vn.anterior = v.id_licitacion
                                   and n.estado_licitacion = 'PUB'
                                   and n.fecha_limite >= now()))
                   order by v.vence nulls last)
            from public.vigilados v, yo where v.perfil_id = yo.id), '[]'),
        'avisos', (select p.avisos from public.perfiles p, yo where p.id = yo.id)
    );
$function$;


-- ------------------------------------------------------------
-- El correo diario (solo con clave de servicio)
-- ------------------------------------------------------------

-- Lo que hay que contar de lo seguido y aún no se ha contado.
--   gana       adjudicado desde 30 días antes de empezar a seguirla (la
--              adjudicación se publica tarde) y en los últimos 45 días.
--   organismo  publicado en sus familias CPV desde que lo sigue, en los
--              últimos 3 días de detección y 7 de publicación (un
--              relleno que vuelve a detectar lo viejo no inunda).
--   vigilado   la nueva licitación, segura o posible (ver cabecera).
-- `ultimo_gana` es el último aviso de competencia: el correo lo usa
-- para mandar el resumen semanal cuando no hay otra cosa.
create or replace function public.novedades_de_seguimiento(perfil uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id,
               array(select distinct left(trim(x), 2)
                     from unnest(string_to_array(coalesce(p.cpv_prefijos, ''), ',')) x
                     where trim(x) ~ '^\d{2}') as familias
        from public.perfiles p
        where p.id = perfil
    ),
    gana as (
        select distinct on (a.id_licitacion, a.cif)
               a.cif, coalesce(s.nombre, a.nombre) as empresa,
               l.id_licitacion, l.titulo, l.organo, a.importe, l.enlace,
               coalesce(l.fecha_adjudicacion, a.fecha::date) as fecha
        from yo
        join public.seguimiento s on s.perfil_id = yo.id
        join public.adjudicaciones_empresa a
          on a.cif = s.cif and not a.es_menor and not a.es_homologacion
        join public.licitaciones l
          on l.id_licitacion = a.id_licitacion and not coalesce(l.sustituida, false)
        where coalesce(l.fecha_adjudicacion, a.fecha::date)
                  >= greatest(s.creado::date - 30, current_date - 45)
          and not exists (select 1 from public.avisos_seguimiento x
                          where x.perfil_id = yo.id and x.tipo = 'gana'
                            and x.id_licitacion = l.id_licitacion)
        order by a.id_licitacion, a.cif
    ),
    organismo as (
        select l.id_licitacion, l.titulo, l.organo, l.codigo_postal,
               l.presupuesto, l.fecha_limite, l.enlace
        from yo
        join public.seguimiento_organismos o on o.perfil_id = yo.id
        join public.licitaciones l on l.organo = o.organo
        where l.estado_licitacion = 'PUB'
          and (l.fecha_limite is null or l.fecha_limite >= now())
          and not coalesce(l.sustituida, false)
          and l.procedimiento is distinct from 'Contrato menor'
          and l.fecha_deteccion >= greatest(o.creado, now() - interval '3 days')
          and coalesce(l.fecha_publicacion, l.fecha_deteccion) >= now() - interval '7 days'
          and (cardinality(yo.familias) = 0 or l.prefijos && yo.familias)
          and not exists (select 1 from public.avisos_seguimiento x
                          where x.perfil_id = yo.id and x.tipo = 'organismo'
                            and x.id_licitacion = l.id_licitacion)
    ),
    vigilado as (
        select distinct on (n.id_licitacion)
               n.id_licitacion, n.titulo, n.organo, n.codigo_postal,
               n.presupuesto, n.fecha_limite, n.enlace,
               v.id_licitacion as anterior, v.titulo as anterior_titulo,
               v.empresa as anterior_empresa, c.seguro
        from yo
        join public.vigilados v on v.perfil_id = yo.id
        cross join lateral (
            select vn.nueva as id, true as seguro
            from public.vencimientos_nueva vn
            where vn.anterior = v.id_licitacion
            union all
            select l.id_licitacion, false
            from public.licitaciones l
            where l.organo = v.organo
              and l.prefijo_principal = v.prefijo_principal
              and l.id_licitacion <> v.id_licitacion
              and l.estado_licitacion = 'PUB'
              and l.procedimiento is distinct from 'Contrato menor'
              and l.fecha_deteccion >= greatest(v.creado, now() - interval '3 days')
              and coalesce(l.fecha_publicacion, l.fecha_deteccion) >= now() - interval '7 days'
        ) c
        join public.licitaciones n on n.id_licitacion = c.id
        where n.estado_licitacion = 'PUB'
          and (n.fecha_limite is null or n.fecha_limite >= now())
          and not coalesce(n.sustituida, false)
          and not exists (select 1 from public.avisos_seguimiento x
                          where x.perfil_id = yo.id and x.tipo = 'vigilado'
                            and x.id_licitacion = n.id_licitacion)
        -- Si una nueva casa con dos vigilados, se queda la segura.
        order by n.id_licitacion, c.seguro desc, v.vence nulls last
    )
    select jsonb_build_object(
        'gana', coalesce((select jsonb_agg(to_jsonb(g) order by g.fecha desc, g.importe desc nulls last)
                          from (select * from gana order by fecha desc limit 200) g), '[]'),
        'organismo', coalesce((select jsonb_agg(to_jsonb(o) order by o.fecha_limite nulls last)
                               from (select * from organismo limit 100) o), '[]'),
        'vigilado', coalesce((select jsonb_agg(to_jsonb(v) order by v.seguro desc, v.fecha_limite nulls last)
                              from (select * from vigilado limit 100) v), '[]'),
        'ultimo_gana', (select max(enviado) from public.avisos_seguimiento
                        where perfil_id = perfil and tipo = 'gana')
    );
$function$;


-- Apunta lo enviado: [{"tipo", "id_licitacion", "referencia"}, ...].
create or replace function public.marcar_avisos_seguimiento(perfil uuid, avisos jsonb)
returns integer
language sql
security definer
set search_path to 'public'
as $function$
    with metidas as (
        insert into public.avisos_seguimiento (perfil_id, tipo, id_licitacion, referencia)
        select perfil, a->>'tipo', a->>'id_licitacion', a->>'referencia'
        from jsonb_array_elements(coalesce(avisos, '[]')) a
        where a->>'tipo' in ('gana', 'organismo', 'vigilado')
          and a->>'id_licitacion' is not null
        on conflict do nothing
        returning 1
    )
    select count(*)::int from metidas;
$function$;


-- ------------------------------------------------------------
-- Permisos
-- ------------------------------------------------------------

revoke execute on function public.seguir_organismo(text) from public, anon;
revoke execute on function public.vigilar(text) from public, anon;
revoke execute on function public.mis_seguimientos() from public, anon;
grant execute on function public.seguir_organismo(text) to authenticated;
grant execute on function public.vigilar(text) to authenticated;
grant execute on function public.mis_seguimientos() to authenticated;

revoke execute on function public.novedades_de_seguimiento(uuid) from public, anon, authenticated;
revoke execute on function public.marcar_avisos_seguimiento(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.novedades_de_seguimiento(uuid) to service_role;
grant execute on function public.marcar_avisos_seguimiento(uuid, jsonb) to service_role;
