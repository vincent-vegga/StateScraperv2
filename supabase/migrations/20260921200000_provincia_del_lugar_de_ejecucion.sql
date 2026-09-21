-- ============================================================
-- LA PROVINCIA ES LA DE LA OBRA, NO LA DE LA SEDE DEL ÓRGANO
-- ============================================================
--
-- Aplicada el 21/09/2026.
--
-- EL FALLO
-- El código postal manda sobre el NUTS, y el código postal muchas
-- veces es la dirección del órgano: extraer_codigo_postal (lector_atom.py)
-- lee primero el del lugar de ejecución, pero si no hay, coge cualquiera
-- del anuncio. Resultado: las obras de ADIF en Gipuzkoa, Asturias o
-- Cáceres salían como "Madrid"; un suministro de TRAGSA en Asturias,
-- también. Quien filtra por su provincia no las veía, y quien filtra
-- por Madrid veía obras a 500 km.
--
-- Medido: 23.788 licitaciones con código postal y NUTS de provincias
-- distintas (47 abiertas ahora mismo).
--
-- LA REGLA
-- El NUTS solo se lee de <cac:RealizedLocation>, el lugar de ejecución,
-- así que cuando llega a provincia es la respuesta correcta. Orden:
--
--   1. NUTS de provincia (lugar de ejecución)
--   2. Código postal (de la ejecución o, si no, de la sede)
--   3. NUTS de comunidad, el órgano, la plataforma (como antes)
--
-- Cuando el código postal es de la ejecución coincide casi siempre con
-- el NUTS, así que no se pierde nada. Lo que se pierde es solo el error.
-- ============================================================

set local statement_timeout = '10min';

create or replace function public.rellenar_territorio()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    encontrado record;
    -- Texto y no record: leer un record que no se ha llegado a rellenar
    -- (anuncio sin NUTS) es un error en PL/pgSQL y tumbaría la inserción.
    nuts_provincia text;
    nuts_comunidad text;
begin
    -- Lo deducido se recalcula siempre: si ha llegado una prueba
    -- directa, tiene que ganar.
    if new.provincia_origen in ('organo', 'fuente') then
        new.provincia := null;
        new.comunidad := null;
        new.provincia_origen := null;
    end if;

    -- 1. El NUTS del lugar de ejecución, si llega a provincia.
    if new.nuts is not null and new.nuts <> '' then
        select nullif(n.provincia, ''), n.comunidad
          into nuts_provincia, nuts_comunidad
        from public.nuts n where n.codigo = new.nuts;
        if nuts_provincia is not null then
            new.provincia := nuts_provincia;
            new.comunidad := nuts_comunidad;
            new.provincia_origen := 'nuts';
            return new;
        end if;
    end if;

    -- 2. El código postal: baja a municipio, pero puede ser el de la sede.
    if new.codigo_postal is not null and new.codigo_postal <> '' then
        select p.provincia, p.comunidad into encontrado
        from public.provincias p
        where p.prefijo = public.provincia_de_cp(new.codigo_postal);
        if found then
            new.provincia := encontrado.provincia;
            new.comunidad := encontrado.comunidad;
            new.provincia_origen := 'cp';
            return new;
        end if;
    end if;

    -- 3. El NUTS que solo llega a comunidad.
    if nuts_comunidad is not null then
        new.comunidad := coalesce(new.comunidad, nuts_comunidad);
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

-- Las que ya estaban mal: NUTS de provincia distinto de la provincia
-- guardada. Se escriben las columnas directamente; el disparador no
-- salta con ellas.
--
-- Son 23.788 filas: NO se lanzó así de una vez, sino por lotes de 6.000
-- con esta misma condición y un `limit` sobre id_licitacion, hasta que
-- no quedó ninguna. Se deja entera como referencia de lo que se hizo.
update public.licitaciones l
   set provincia = n.provincia,
       comunidad = n.comunidad,
       provincia_origen = 'nuts'
  from public.nuts n
 where n.codigo = l.nuts
   and nullif(n.provincia, '') is not null
   and l.provincia is distinct from n.provincia;
