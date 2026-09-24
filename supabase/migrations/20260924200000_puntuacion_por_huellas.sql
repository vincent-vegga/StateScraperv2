-- ============================================================
-- PUNTUACIÓN POR HUELLAS (perfiles con NIF e historial)
-- ============================================================
--
-- Para las empresas dadas de alta con NIF y con 15 o más contratos
-- ganados, la selección deja de hacerla la puerta CPV + juez con criterio
-- en prosa y la hace `puntuador.py` (GitHub Actions): parecido de títulos
-- con lo que la empresa ha ganado, sus pares y el CPV como peso, y un juez
-- que ve sus contratos más parecidos. Medido en el banco de pruebas
-- (docs/afinar-seleccion/RESULTADOS.md): de recuperar el 76 % de lo que
-- la empresa acaba ganando a recuperar el 95 %.
--
-- El puntuador escribe en `veredictos` como el cribado de siempre, así
-- que la web, el correo y los contadores no cambian. Lo que añade esta
-- migración:
--
--   perfiles.sistema            'criterio' (el de siempre) o 'huellas'.
--                               Lo pone a 'huellas' el puntuador la
--                               primera vez que juzga entero el perfil.
--   perfiles.puntuado_en        última pasada completa del puntuador.
--   perfiles.puntuacion_pedida  cuándo se le pidió una pasada (alta,
--                               correcciones). La web espera hasta que
--                               puntuado_en la alcance.
--
--   pendientes_de_perfil        no devuelve nada a los perfiles 'huellas':
--                               así ni cribador.py ni la acción `cribar`
--                               los vuelven a pasar por el juez antiguo.
--
-- Aditiva y reversible: con todos los perfiles en 'criterio' todo
-- funciona exactamente igual que antes. Para volver atrás un perfil:
--   update perfiles set sistema = 'criterio' where id = '...';
-- (el cribado de siempre le rellena lo que falte en su siguiente pasada).
-- ============================================================

alter table public.perfiles
    add column if not exists sistema text not null default 'criterio',
    add column if not exists puntuado_en timestamptz,
    add column if not exists puntuacion_pedida timestamptz;

do $$
begin
    if not exists (select 1 from pg_constraint where conname = 'perfiles_sistema_valido') then
        alter table public.perfiles
            add constraint perfiles_sistema_valido check (sistema in ('criterio', 'huellas'));
    end if;
end $$;

-- Igual que la versión en vigor (20260920140200 y siguientes), con una
-- sola condición más al leer el perfil: `p.sistema = 'criterio'`.
create or replace function public.pendientes_de_perfil(perfil uuid, tope integer default 300)
returns table(id_licitacion text, titulo text, organo text, presupuesto numeric,
              cpvs jsonb, enlace text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    -- NO `prefijos`: la tabla tiene una columna con ese nombre y la
    -- referencia resulta ambigua.
    mis_pref text[];
begin
    if not public.perfil_permitido(perfil) then
        return;
    end if;

    select array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mis_pref
    from public.perfiles p
    where p.id = perfil and p.activo and p.criterio is not null
      -- Los perfiles por huellas los criba puntuador.py.
      and p.sistema = 'criterio';

    if mis_pref is null or array_length(mis_pref, 1) is null then
        return;
    end if;

    -- ORDEN DE FILTRADO: primero las vivas (idx_licitaciones_vivas_pref),
    -- luego los prefijos sobre ese conjunto pequeño. La CTE es
    -- MATERIALIZED a propósito: sin eso el planificador vuelve a colar el
    -- GIN de prefijos dentro y se pierde todo (ver
    -- 20260920140200_pendientes_de_perfil_rapida.sql).
    return query
    with vivas as materialized (
        select l.id_licitacion, l.fecha_limite, l.prefijos, l.sustituida
        from public.licitaciones l
        where coalesce(l.estado_licitacion, '') = 'PUB'
          and coalesce(l.fecha_limite, 'infinity'::timestamptz) >= now()
    ),
    elegidas as (
        select v.id_licitacion, v.fecha_limite
        from vivas v
        where v.prefijos && mis_pref
          and not v.sustituida
          and not exists (
              select 1 from public.veredictos w
              where w.perfil_id = perfil and w.id_licitacion = v.id_licitacion)
        order by v.fecha_limite asc nulls last
        limit tope
    )
    select l.id_licitacion, l.titulo, l.organo, l.presupuesto, l.cpvs, l.enlace
    from elegidas e
    join public.licitaciones l on l.id_licitacion = e.id_licitacion
    order by e.fecha_limite asc nulls last;
end;
$function$;
