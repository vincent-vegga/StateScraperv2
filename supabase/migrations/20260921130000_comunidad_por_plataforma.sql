-- ============================================================
-- COMUNIDAD POR PLATAFORMA: QUE NINGÚN CONTRATO SE QUEDE SIN TERRITORIO
-- ============================================================
--
-- Aplicada el 21/09/2026, después de 20260921120000 y 20260921123000.
--
-- LO QUE QUEDABA
-- Tras deducir la provincia por el órgano seguían 570 contratos
-- abiertos sin provincia. Por qué, medido:
--
--     órgano de varias provincias (sin 90% de acuerdo)   ~310
--     órgano que no aparece en ninguna otra licitación   ~155
--     órgano con uno o dos casos                          ~100
--
-- El primer grupo no tiene arreglo por el órgano porque no hay nada
-- que arreglar: son departamentos de la Generalitat, consejerías de la
-- Junta, la Xunta, el Gobierno Vasco. Contratan para toda la comunidad.
--
-- LO QUE SÍ SE SABE SIEMPRE
-- La comunidad: la da la plataforma. Todo lo que publica
-- contractaciopublica.cat es de Cataluña. Con la comunidad, la web
-- enseña estos contratos a quien filtra por cualquiera de sus
-- provincias, marcados como "provincia sin precisar", en vez de
-- esconderlos.
--
-- Y Murcia (www.carm.es) se suma a las plataformas uniprovinciales:
-- ahí la comunidad ya da la provincia.
--
-- `provincia_origen = 'fuente'` también cuando solo se deduce la
-- comunidad: así el disparador la recalcula si llega una prueba mejor.
-- ============================================================

create or replace function public.comunidad_de_plataforma(enlace text)
returns text
language sql
immutable
as $function$
    select case split_part(coalesce(enlace, ''), '/', 3)
        when 'contractaciopublica.cat'             then 'Cataluña'
        when 'www.contratacion.euskadi.eus'        then 'País Vasco'
        when 'www.juntadeandalucia.es'             then 'Andalucía'
        when 'www.contratosdegalicia.gal'          then 'Galicia'
        when 'contratos-publicos.comunidad.madrid' then 'Comunidad de Madrid'
        when 'hacienda.navarra.es'                 then 'Navarra'
        when 'www.larioja.org'                     then 'La Rioja'
        when 'www.carm.es'                         then 'Región de Murcia'
    end
$function$;

create or replace function public.rellenar_territorio()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    encontrado record;
begin
    -- Lo deducido se recalcula siempre: si ha llegado una prueba
    -- directa, tiene que ganar.
    if new.provincia_origen in ('organo', 'fuente') then
        new.provincia := null;
        new.comunidad := null;
        new.provincia_origen := null;
    end if;

    -- Preferencia al código postal, que baja a municipio; el NUTS solo
    -- llega a provincia y a veces solo a comunidad.
    if new.codigo_postal is not null and new.codigo_postal <> '' then
        select p.provincia, p.comunidad into encontrado
        from public.provincias p
        where p.prefijo = public.provincia_de_cp(new.codigo_postal);
        if found then
            new.provincia := coalesce(new.provincia, encontrado.provincia);
            new.comunidad := coalesce(new.comunidad, encontrado.comunidad);
            new.provincia_origen := coalesce(new.provincia_origen, 'cp');
            return new;
        end if;
    end if;

    if new.nuts is not null and new.nuts <> '' then
        select n.provincia, n.comunidad into encontrado
        from public.nuts n where n.codigo = new.nuts;
        if found then
            if new.provincia is null and nullif(encontrado.provincia, '') is not null then
                new.provincia_origen := 'nuts';
            end if;
            new.provincia := coalesce(new.provincia,
                                      nullif(encontrado.provincia, ''));
            new.comunidad := coalesce(new.comunidad, encontrado.comunidad);
        end if;
    end if;

    if new.provincia is not null then
        return new;
    end if;

    -- El órgano, si se sabe dónde está. Solo cuando no contradice la
    -- comunidad que haya dado el NUTS.
    if new.organo is not null and new.organo <> '' then
        select o.provincia, o.comunidad into encontrado
        from public.organos_provincia o where o.organo = new.organo;
        if found and (new.comunidad is null
                      or new.comunidad is not distinct from encontrado.comunidad) then
            new.provincia := encontrado.provincia;
            new.comunidad := encontrado.comunidad;
            new.provincia_origen := 'organo';
            return new;
        end if;
    end if;

    -- La plataforma da al menos la comunidad.
    if new.comunidad is null then
        new.comunidad := public.comunidad_de_plataforma(new.enlace);
        if new.comunidad is not null then
            new.provincia_origen := 'fuente';
        end if;
    end if;

    -- Y si la comunidad es uniprovincial, también la provincia.
    if new.comunidad is not null then
        select min(p.provincia) into new.provincia
        from public.provincias p
        where p.comunidad = new.comunidad
        having count(distinct p.provincia) = 1;
        if new.provincia is not null then
            new.provincia_origen := 'fuente';
        end if;
    end if;

    return new;
end;
$function$;

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

    -- Comunidad uniprovincial, sabida o dada por la plataforma: la
    -- provincia es esa. Filtrado con `= any(...)` y no con un cruce, que
    -- el planificador convertía en un recorrido por comunidad (ver
    -- 20260921123000).
    select array_agg(comunidad) into uniprovinciales
    from (select comunidad from public.provincias
          group by comunidad
          having count(distinct provincia) = 1) u;

    with lote as (
        select l.id_licitacion,
               coalesce(l.comunidad, public.comunidad_de_plataforma(l.enlace)) as comunidad
        from public.licitaciones l
        where l.provincia is null
          and coalesce(l.comunidad, public.comunidad_de_plataforma(l.enlace))
              = any(uniprovinciales)
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

    -- Lo que quede: al menos la comunidad de la plataforma.
    with lote as (
        select l.id_licitacion, public.comunidad_de_plataforma(l.enlace) as comunidad
        from public.licitaciones l
        where l.provincia is null
          and l.comunidad is null
          and public.comunidad_de_plataforma(l.enlace) is not null
        limit case when tope is null then null
                   else greatest(tope - rellenadas, 0) end
    )
    update public.licitaciones l
       set comunidad = lote.comunidad,
           provincia_origen = 'fuente'
      from lote
     where l.id_licitacion = lote.id_licitacion;
    get diagnostics filas = row_count;
    rellenadas := rellenadas + filas;

    return rellenadas;
end;
$function$;

revoke execute on function public.rellenar_provincias_pendientes(integer) from public, anon, authenticated;

-- El relleno de las filas existentes se lanzó aparte, por lotes, con
--   select public.rellenar_provincias_pendientes(<tope>);
-- hasta que devolvió menos que el tope.
