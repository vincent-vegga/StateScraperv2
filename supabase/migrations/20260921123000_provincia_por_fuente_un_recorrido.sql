-- ============================================================
-- rellenar_provincias_pendientes: el paso "por fuente" en un recorrido
-- ============================================================
--
-- Aplicada el 21/09/2026, justo después de 20260921120000.
--
-- EL FALLO, en el relleno por lotes de la migración anterior
-- El paso por fuente cruzaba las licitaciones con las comunidades
-- uniprovinciales mediante un JOIN. El planificador estimaba UNA
-- comunidad (son nueve) y montaba un bucle anidado con ella fuera:
--
--     Nested Loop
--       ->  GroupAggregate (provincias)        rows=1   (reales: 9)
--       ->  Seq Scan on licitaciones           filtro provincia is null
--
-- Un recorrido del millón de filas por cada comunidad. Y como solo hay
-- unas 2.800 candidatas, el LIMIT del lote no se alcanzaba nunca y los
-- nueve recorridos se hacían enteros: dos lotes seguidos agotaron los
-- 120 s. La transacción entera se deshizo, así que no quedó nada a
-- medias.
--
-- LA SOLUCIÓN
-- Las comunidades se reducen a un array y se filtra con `= any(...)`:
-- un solo recorrido, sin cruce que el planificador pueda equivocar. La
-- provincia se busca después, solo para las filas del lote.
-- ============================================================

create or replace function public.rellenar_provincias_pendientes(tope integer default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    rellenadas integer := 0;
    filas integer;
    uniprovinciales text[];
begin
    -- Por el órgano.
    with lote as (
        select l.id_licitacion, o.provincia, o.comunidad
        from public.licitaciones l
        join public.organos_provincia o on o.organo = l.organo
        where l.provincia is null
          and (l.comunidad is null or l.comunidad = o.comunidad)
        limit tope
    )
    update public.licitaciones l
       set provincia = lote.provincia,
           comunidad = lote.comunidad,
           provincia_origen = 'organo'
      from lote
     where l.id_licitacion = lote.id_licitacion;
    get diagnostics filas = row_count;
    rellenadas := rellenadas + filas;

    -- Por la plataforma, si es de una comunidad uniprovincial; y por la
    -- comunidad, si ya se sabía y es uniprovincial (el histórico cuyo
    -- NUTS solo llegaba a comunidad).
    select array_agg(comunidad) into uniprovinciales
    from (select comunidad from public.provincias
          group by comunidad
          having count(distinct provincia) = 1) u;

    with lote as (
        select l.id_licitacion,
               coalesce(l.comunidad,
                   case split_part(coalesce(l.enlace, ''), '/', 3)
                       when 'contratos-publicos.comunidad.madrid' then 'Comunidad de Madrid'
                       when 'hacienda.navarra.es'                 then 'Navarra'
                       when 'www.larioja.org'                     then 'La Rioja'
                   end) as comunidad
        from public.licitaciones l
        where l.provincia is null
          and (l.comunidad = any(uniprovinciales)
               or (l.comunidad is null
                   and split_part(coalesce(l.enlace, ''), '/', 3) in
                       ('contratos-publicos.comunidad.madrid',
                        'hacienda.navarra.es', 'www.larioja.org')))
        limit case when tope is null then null
                   else greatest(tope - rellenadas, 0) end
    )
    update public.licitaciones l
       set provincia = p.provincia,
           comunidad = lote.comunidad,
           provincia_origen = 'fuente'
      from lote
      join public.provincias p on p.comunidad = lote.comunidad
     where l.id_licitacion = lote.id_licitacion;
    get diagnostics filas = row_count;
    rellenadas := rellenadas + filas;

    return rellenadas;
end;
$function$;

revoke execute on function public.rellenar_provincias_pendientes(integer) from public, anon, authenticated;
