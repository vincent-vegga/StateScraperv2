-- ============================================================
-- `pendientes_de_perfil`: 23,6 s -> 1,4 s
-- ============================================================
--
-- Aplicada el 20/09/2026. Requiere idx_licitaciones_vivas (140100).
--
-- EL PROBLEMA, medido:
--
--   Bitmap Index Scan on idx_licitaciones_prefijos_abiertas
--       -> 24.964 filas
--   Bitmap Heap Scan   Heap Blocks: exact=21693
--       Filter: (fecha_limite is null or fecha_limite >= now())
--       Rows Removed by Filter: 24045
--   Execution Time: 23636 ms
--
-- Empezaba por el índice GIN de prefijos, bajaba al heap a por 24.964
-- licitaciones y tiraba 24.045 por plazo vencido. El 96% del trabajo,
-- a la basura. Contra un timeout de 8 s, fallaba el 43% de las veces:
-- es la pantalla principal del producto.
--
-- LA IDEA
-- Invertir el orden. Solo 4.517 de las 177.641 PUB siguen vivas, así
-- que se empieza por ahí y los prefijos se filtran después, sobre un
-- conjunto 40 veces menor.
--
-- TRES DETALLES QUE IMPORTAN
--   · `coalesce(fecha_limite,'infinity') >= now()` en vez del OR:
--     permite barrido de rango y conserva el orden `nulls last`.
--   · La CTE es MATERIALIZED a propósito. Sin eso el planificador
--     vuelve a meter el GIN dentro y se pierde la mejora entera
--     (comprobado: 8,5 s).
--   · La CTE lleva solo columnas estrechas. Arrastrar `titulo` y
--     `cpvs` por las 4.517 filas escribía a disco temporal y costaba
--     4,6 s; recogiéndolas al final solo de las 300 que salen, 2,5 s.
--
-- Medido de punta a punta sobre un perfil real: 1,43 s.
-- ============================================================

create or replace function public.pendientes_de_perfil(perfil uuid, tope integer default 300)
returns table(id_licitacion text, titulo text, organo text,
              presupuesto numeric, cpvs jsonb, enlace text)
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
    where p.id = perfil and p.activo and p.criterio is not null;

    if mis_pref is null or array_length(mis_pref, 1) is null then
        return;
    end if;

    return query
    with vivas as materialized (
        select l.id_licitacion, l.fecha_limite, l.prefijos
        from public.licitaciones l
        where coalesce(l.estado_licitacion, '') = 'PUB'
          and coalesce(l.fecha_limite, 'infinity'::timestamptz) >= now()
    ),
    elegidas as (
        select v.id_licitacion, v.fecha_limite
        from vivas v
        where v.prefijos && mis_pref
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

grant execute on function public.pendientes_de_perfil(uuid, integer) to authenticated;
