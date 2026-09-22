-- ============================================================
-- SECTORES DE CADA EMPRESA: CPV POR DEBAJO, NOMBRES POR ENCIMA
-- ============================================================
--
-- Un filtro por sector en la lista de contratos, y la base del futuro
-- configurador de avisos por correo (por sector y por territorio).
--
-- Por debajo son prefijos CPV: los mismos de `perfiles.cpv_prefijos` con
-- los que `pendientes_de_perfil` elige los contratos. El cliente no ve
-- ningún código: ve 2-6 sectores con nombre ("Alumbrado público",
-- "Señalización y balizamiento") que el modelo escribe agrupando SUS
-- prefijos a partir de sus contratos.
--
-- Por qué no el catálogo `sectores_cpv`: son 45 familias de 2 cifras,
-- demasiado gruesas. A la consultora TIC sus 12 prefijos le caían todos en
-- "Servicios informáticos" (una sola opción), y a una empresa de alumbrado público la
-- señalización (3492) le salía como "Vehículos y transporte".
--
-- Tabla y no jsonb en `perfiles`: los avisos por sector necesitarán
-- apuntar a un sector concreto por su id.
--
-- Un contrato está en un sector si alguno de sus CPV empieza por alguno
-- de los prefijos del sector: la misma regla con la que entró en la lista.
-- Puede estar en más de uno.
-- ============================================================

create table if not exists public.sectores_perfil (
    id        uuid primary key default gen_random_uuid(),
    perfil_id uuid not null references public.perfiles(id) on delete cascade,
    nombre    text not null check (length(nombre) between 2 and 60),
    prefijos  text[] not null check (cardinality(prefijos) > 0),
    orden     integer not null default 0,
    -- `cpv_prefijos` del perfil cuando se generó. Si el filtro se rehace,
    -- los prefijos cambian y estos sectores dejan de valer.
    base      text not null,
    creado    timestamptz not null default now()
);
create index if not exists idx_sectores_perfil on public.sectores_perfil (perfil_id, orden);

alter table public.sectores_perfil enable row level security;
revoke all on public.sectores_perfil from anon;
revoke insert, update, delete on public.sectores_perfil from authenticated;

drop policy if exists "sectores propios: leer" on public.sectores_perfil;
create policy "sectores propios: leer" on public.sectores_perfil
    for select to authenticated
    using (exists (select 1 from public.perfiles p
                   where p.id = sectores_perfil.perfil_id
                     and p.usuario_id = (select auth.uid())));

-- Si cambian los prefijos (rehacer el filtro, ajustes), los sectores
-- viejos se borran: la web los regenera la próxima vez que se abra la
-- lista.
create or replace function public.olvidar_sectores()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    delete from public.sectores_perfil where perfil_id = new.id;
    return new;
end;
$$;
revoke execute on function public.olvidar_sectores() from public, anon, authenticated;

drop trigger if exists trg_olvidar_sectores on public.perfiles;
create trigger trg_olvidar_sectores
    after update of cpv_prefijos on public.perfiles
    for each row
    when (old.cpv_prefijos is distinct from new.cpv_prefijos)
    execute function public.olvidar_sectores();

-- ---------- Lo que lee el modelo para ponerles nombre ----------
-- Por cada prefijo del perfil: cuántos de sus contratos (sí/quizás) caen
-- ahí y unos cuantos títulos. Los títulos dicen mucho mejor que el código
-- de qué va cada prefijo PARA ESTA EMPRESA.
create or replace function public.muestras_por_prefijo(perfil uuid)
returns table(prefijo text, contratos integer, titulos text[])
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if not public.perfil_permitido(perfil) then
        return;
    end if;

    return query
    with pre as (
        select distinct trim(x) as p
        from public.perfiles pf,
             unnest(string_to_array(coalesce(pf.cpv_prefijos, ''), ',')) as x
        where pf.id = perfil and trim(x) <> ''
    ),
    mias as materialized (
        select l.titulo, l.cpvs
        from public.veredictos v
        join public.licitaciones l on l.id_licitacion = v.id_licitacion
        where v.perfil_id = perfil and v.veredicto in ('si', 'quizas')
    )
    select pre.p,
           count(m.titulo)::int,
           (array_agg(m.titulo order by length(m.titulo))
              filter (where m.titulo is not null))[1:4]
    from pre
    left join mias m on exists (
        select 1 from jsonb_array_elements_text(m.cpvs) c where c like pre.p || '%')
    group by pre.p
    order by 2 desc, 1;
end;
$$;
revoke all on function public.muestras_por_prefijo(uuid) from public, anon;
grant execute on function public.muestras_por_prefijo(uuid) to authenticated;

-- ---------- Guardar lo que propone el modelo ----------
-- Todo o nada, y solo si los prefijos no han cambiado mientras el modelo
-- pensaba (dos dispositivos, o un ajuste a la vez). Se quedan solo los
-- prefijos que de verdad son del perfil.
create or replace function public.guardar_sectores(perfil uuid, base text, datos jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    actuales text[];
begin
    if not public.perfil_permitido(perfil) then
        return false;
    end if;
    perform pg_advisory_xact_lock(hashtext('sectores:' || perfil::text));

    select array(select trim(x) from unnest(string_to_array(coalesce(p.cpv_prefijos, ''), ',')) x
                 where trim(x) <> '')
      into actuales
    from public.perfiles p
    where p.id = perfil and coalesce(p.cpv_prefijos, '') = coalesce(base, '');
    if actuales is null then
        return false;   -- los prefijos cambiaron: lo propuesto ya no vale
    end if;

    delete from public.sectores_perfil where perfil_id = perfil;

    insert into public.sectores_perfil (perfil_id, nombre, prefijos, orden, base)
    select perfil, left(trim(s.valor ->> 'nombre'), 60), pr.lista, s.n::int, base
    from jsonb_array_elements(datos) with ordinality as s(valor, n)
    cross join lateral (
        select array(select distinct x
                     from jsonb_array_elements_text(s.valor -> 'prefijos') x
                     where x = any(actuales)) as lista
    ) pr
    where cardinality(pr.lista) > 0
      and length(trim(coalesce(s.valor ->> 'nombre', ''))) >= 2;

    return true;
end;
$$;
revoke all on function public.guardar_sectores(uuid, text, jsonb) from public, anon;
grant execute on function public.guardar_sectores(uuid, text, jsonb) to authenticated;
