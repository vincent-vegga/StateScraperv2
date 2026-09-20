-- ============================================================
-- 2/2 · QUE NADIE PUEDA PEDIR EL PERFIL DE OTRO
-- ============================================================
--
-- Aplicada el 20/09/2026, junto con la 1/2.
--
-- EL PROBLEMA
-- Tres funciones reciben el perfil como PARÁMETRO y se fían de él.
-- Quien las llama elige de quién quiere los datos:
--
--   pendientes_de_perfil(perfil uuid, tope int)
--   mercado_sin_cribar_de(perfil uuid, dias int)
--   guardar_criba_mercado(datos jsonb, perfil uuid)   <- además ESCRIBE
--
-- `guardar_criba_mercado` sí mira auth.uid(), pero solo como plan B:
--
--     mi_perfil := coalesce(perfil, (select id from perfiles
--                                    where usuario_id = auth.uid()));
--
-- Si se pasa `perfil`, el coalesce se queda con él y auth.uid() no
-- llega a evaluarse. El comentario del código explica por qué se
-- hizo así: la función Edge usa la clave de servicio y allí
-- auth.uid() no resuelve a nadie. La necesidad es legítima; lo que
-- falla es que el atajo vale para todo el mundo.
--
-- EL ARREGLO
-- Se conserva el parámetro, que la función Edge necesita, pero se
-- exige que coincida con el perfil de quien llama SIEMPRE QUE haya
-- alguien identificado. Con clave de servicio auth.uid() es null y
-- la función sigue trabajando como hasta ahora.
--
-- Traducido: sin sesión -> nada; con sesión -> solo lo tuyo;
-- con clave de servicio -> todo, como antes.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- Función auxiliar: ¿puede quien llama tocar este perfil?
--
-- Es STABLE y SECURITY DEFINER para poder leer `perfiles` sin
-- depender de las políticas RLS de la tabla, que es justo lo que
-- las funciones DEFINER que la usan ya hacen.
-- ------------------------------------------------------------
create or replace function public.perfil_permitido(perfil uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
    select
        -- Clave de servicio (o cualquier contexto sin usuario):
        -- se mantiene el acceso completo que ya tenía.
        auth.uid() is null
        -- Con sesión: solo el perfil propio.
        or exists (select 1 from public.perfiles p
                   where p.id = perfil and p.usuario_id = auth.uid());
$$;

revoke execute on function public.perfil_permitido(uuid) from public, anon, authenticated;


-- ------------------------------------------------------------
-- 1 · pendientes_de_perfil
--     Se antepone la comprobación; el resto del cuerpo no cambia.
-- ------------------------------------------------------------
create or replace function public.pendientes_de_perfil(perfil uuid, tope integer default 300)
returns table(id_licitacion text, titulo text, organo text,
              presupuesto numeric, cpvs jsonb, enlace text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
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
    where p.id = perfil and p.activo and p.criterio is not null;

    if mis_pref is null or array_length(mis_pref, 1) is null then
        return;
    end if;

    -- Los prefijos van en una variable, no en un cruce con `perfiles`:
    -- mezclando las dos tablas, el planificador no usa el índice GIN.
    return query
    select l.id_licitacion, l.titulo, l.organo, l.presupuesto,
           l.cpvs, l.enlace
    from public.licitaciones l
    where coalesce(l.estado_licitacion, '') = 'PUB'
      and l.prefijos && mis_pref
      and (l.fecha_limite is null or l.fecha_limite >= now())
      and not exists (
          select 1 from public.veredictos v
          where v.perfil_id = perfil and v.id_licitacion = l.id_licitacion)
    order by l.fecha_limite asc nulls last
    limit tope;
end;
$function$;


-- ------------------------------------------------------------
-- 2 · mercado_sin_cribar_de
-- ------------------------------------------------------------
create or replace function public.mercado_sin_cribar_de(perfil uuid, dias integer default 30)
returns table(id_licitacion text, titulo text, organo text, empresa text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    mis_pref text[];
begin
    if not public.perfil_permitido(perfil) then
        return;
    end if;

    select array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mis_pref
    from public.perfiles p where p.id = perfil;

    if mis_pref is null or array_length(mis_pref, 1) is null then
        return;
    end if;

    return query
    select l.id_licitacion, l.titulo, l.organo, l.adjudicatario
    from public.licitaciones l
    where l.prefijo_principal = any(mis_pref)
      and l.adjudicatario_cif is not null
      and l.fecha_actualizacion >= now() - (dias || ' days')::interval
      and not exists (
          select 1 from public.veredictos_mercado v
          where v.perfil_id = perfil and v.id_licitacion = l.id_licitacion)
    order by l.fecha_actualizacion desc
    limit 400;
end;
$function$;


-- ------------------------------------------------------------
-- 3 · guardar_criba_mercado
--     El coalesce se mantiene, pero ahora el perfil resultante
--     tiene que estar permitido antes de escribir nada.
-- ------------------------------------------------------------
create or replace function public.guardar_criba_mercado(datos jsonb, perfil uuid default null::uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    mi_perfil uuid;
    metidas   int;
begin
    mi_perfil := coalesce(
        perfil,
        (select id from public.perfiles where usuario_id = auth.uid()));
    if mi_perfil is null then return 0; end if;

    -- Añadido: el perfil elegido debe ser el de quien llama, salvo
    -- que se venga con clave de servicio (auth.uid() nulo).
    if not public.perfil_permitido(mi_perfil) then return 0; end if;

    with nuevas as (
        insert into public.veredictos_mercado (perfil_id, id_licitacion, del_sector)
        select mi_perfil, x->>'id', (x->>'del_sector')::boolean
        from jsonb_array_elements(datos) as x
        on conflict (perfil_id, id_licitacion) do nothing
        returning 1
    )
    select count(*)::int into metidas from nuevas;
    return metidas;
end;
$function$;

-- CREATE OR REPLACE conserva la ACL previa; pendientes_de_perfil se
-- reescribe aquí, así que se le devuelve el permiso explícitamente.
grant execute on function public.pendientes_de_perfil(uuid, integer) to authenticated;

commit;


-- ============================================================
-- PENDIENTE, y no lo resuelve esta migración:
--
-- `completar_adjudicatarios`, `completar_criterios` y
-- `completar_explicacion` escriben en `licitaciones` sin ninguna
-- noción de quién llama. No tienen arreglo interno posible: son
-- tareas de servidor y lo correcto es que solo las alcance la
-- clave de servicio. Eso ya lo hace la migración 1/2 al no
-- devolverles el permiso.
-- ============================================================
