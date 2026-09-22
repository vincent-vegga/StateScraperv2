-- ============================================================
-- CONFIGURADOR DE AVISOS: POR SECTOR Y POR ZONA
-- ============================================================
--
-- Cada empresa elige qué le llega en el aviso diario por correo:
--
--   · Zona: provincias. Vacío = toda España. Elegir una comunidad en la
--     web es elegir todas sus provincias; aquí solo se guardan provincias.
--   · Sectores: los de `sectores_perfil`. Ninguno = todos.
--
-- Se aplica en `novedades_de_perfil`, por donde pasa todo lo que envía
-- `alertador.py` (y `perfiles_con_novedades` cuenta con ella), así que el
-- alertador no cambia.
--
-- MISMAS REGLAS QUE LA LISTA DE LA WEB, para que el correo y la pantalla
-- no se contradigan:
--   · Un contrato está en un sector si alguno de sus CPV empieza por
--     alguno de los prefijos del sector.
--   · Un contrato sin provincia precisa entra si es de la comunidad de
--     alguna provincia elegida, y si tampoco se sabe la comunidad, entra
--     siempre. Uno de más es mejor que perder uno.
--
-- Si los sectores se regeneran (se rehace el filtro), las elecciones de
-- sector se borran en cascada y el aviso vuelve a "todos": una
-- preferencia caducada nunca debe hacer perder contratos.
-- ============================================================

create table if not exists public.avisos_perfil (
    perfil_id   uuid primary key references public.perfiles(id) on delete cascade,
    provincias  text[] not null default '{}',
    actualizado timestamptz not null default now()
);

create table if not exists public.avisos_sectores (
    perfil_id uuid not null references public.perfiles(id) on delete cascade,
    sector_id uuid not null references public.sectores_perfil(id) on delete cascade,
    primary key (perfil_id, sector_id)
);

alter table public.avisos_perfil   enable row level security;
alter table public.avisos_sectores enable row level security;
revoke all on public.avisos_perfil, public.avisos_sectores from anon;
revoke insert, update, delete on public.avisos_perfil, public.avisos_sectores from authenticated;

drop policy if exists "avisos propios: leer" on public.avisos_perfil;
create policy "avisos propios: leer" on public.avisos_perfil
    for select to authenticated
    using (exists (select 1 from public.perfiles p
                   where p.id = avisos_perfil.perfil_id
                     and p.usuario_id = (select auth.uid())));

drop policy if exists "avisos propios: leer" on public.avisos_sectores;
create policy "avisos propios: leer" on public.avisos_sectores
    for select to authenticated
    using (exists (select 1 from public.perfiles p
                   where p.id = avisos_sectores.perfil_id
                     and p.usuario_id = (select auth.uid())));

-- ---------- Catálogo de zonas para el configurador ----------
-- `nuts` no tiene políticas de lectura; esto expone solo los nombres.
create or replace function public.zonas_espana()
returns table(comunidad text, provincia text)
language sql
stable
security definer
set search_path = public
as $$
    select distinct n.comunidad, n.provincia
    from public.nuts n
    where coalesce(n.provincia, '') <> '' and coalesce(n.comunidad, '') <> ''
    order by 1, 2
$$;
revoke all on function public.zonas_espana() from public, anon;
grant execute on function public.zonas_espana() to authenticated;

-- ---------- Leer y guardar, siempre de la empresa activa ----------
create or replace function public.mis_avisos()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'avisos', p.avisos,
        'provincias', to_jsonb(coalesce(a.provincias, '{}')),
        'sectores', coalesce((select jsonb_agg(s.sector_id)
                              from public.avisos_sectores s
                              where s.perfil_id = p.id), '[]'::jsonb))
    from public.perfiles p
    left join public.avisos_perfil a on a.perfil_id = p.id
    where p.id = public.mi_perfil_id()
$$;
revoke all on function public.mis_avisos() from public, anon;
grant execute on function public.mis_avisos() to authenticated;

create or replace function public.guardar_avisos(provincias text[], sectores uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    mio uuid := public.mi_perfil_id();
begin
    if mio is null then
        return jsonb_build_object('ok', false, 'error', 'sin_perfil');
    end if;

    -- Solo nombres de provincia reales: lo que no case con `licitaciones`
    -- dejaría fuera contratos sin que nadie lo notara.
    insert into public.avisos_perfil (perfil_id, provincias, actualizado)
    values (mio,
            array(select distinct x from unnest(coalesce(provincias, '{}')) x
                  where exists (select 1 from public.nuts n where n.provincia = x)
                  order by 1),
            now())
    on conflict (perfil_id) do update
        set provincias = excluded.provincias, actualizado = now();

    -- Solo sectores de esta empresa.
    delete from public.avisos_sectores where perfil_id = mio;
    insert into public.avisos_sectores (perfil_id, sector_id)
    select mio, s.id from public.sectores_perfil s
    where s.perfil_id = mio and s.id = any(coalesce(sectores, '{}'));

    return public.mis_avisos() || jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.guardar_avisos(text[], uuid[]) from public, anon;
grant execute on function public.guardar_avisos(text[], uuid[]) to authenticated;

-- ---------- El correo respeta las preferencias ----------
-- Misma firma y mismas columnas que antes; solo se añaden los dos
-- filtros del final.
create or replace function public.novedades_de_perfil(perfil uuid, horas integer default 26)
returns table(id_licitacion text, titulo text, organo text, provincia text,
              codigo_postal text, presupuesto numeric, enlace text,
              fecha_limite timestamp with time zone, veredicto text, motivo text)
language sql
stable
security definer
set search_path = public
as $function$
    select l.id_licitacion, l.titulo, l.organo, l.provincia, l.codigo_postal,
           l.presupuesto, l.enlace, l.fecha_limite, v.veredicto, v.motivo
    from public.licitaciones l
    join public.veredictos v
      on v.id_licitacion = l.id_licitacion and v.perfil_id = perfil
    left join public.correcciones c
      on c.id_licitacion = l.id_licitacion and c.perfil_id = perfil
    left join public.avisos_perfil a
      on a.perfil_id = perfil
    where v.veredicto in ('si', 'quizas')
      and coalesce(l.estado_licitacion, '') = 'PUB'
      and (l.fecha_limite is null or l.fecha_limite >= now())
      -- Lo descartado por el cliente no se le vuelve a mandar.
      and (c.interesa is null or c.interesa)
      and not l.sustituida
      -- Novedad: capturado en la última pasada. La ventana es algo mayor
      -- que un día para absorber los retrasos del cron.
      and l.fecha_deteccion >= now() - (horas || ' hours')::interval
      -- Sectores elegidos (ninguno = todos).
      and (not exists (select 1 from public.avisos_sectores s where s.perfil_id = perfil)
           or exists (
               select 1
               from public.avisos_sectores s
               join public.sectores_perfil sp on sp.id = s.sector_id
               cross join lateral unnest(sp.prefijos) pre
               cross join lateral jsonb_array_elements_text(l.cpvs) cpv
               where s.perfil_id = perfil and cpv like pre || '%'))
      -- Zona elegida (vacía = toda España). Sin provincia precisa: entra
      -- si es de la comunidad, y si no se sabe ni eso, entra.
      and (coalesce(cardinality(a.provincias), 0) = 0
           or l.provincia = any(a.provincias)
           or (l.provincia is null
               and (l.comunidad is null
                    or l.comunidad in (select n.comunidad from public.nuts n
                                       where n.provincia = any(a.provincias)))))
    order by l.fecha_limite asc nulls last;
$function$;
