-- ============================================================
-- PROVINCIA DEDUCIDA DEL ÓRGANO PARA LAS PLATAFORMAS AUTONÓMICAS
-- ============================================================
--
-- EL FALLO, medido el 21/09/2026 sobre las licitaciones abiertas:
--
--     fuente                                 abiertas   sin provincia
--     contrataciondelestado.es                  2.569               6
--     contractaciopublica.cat                   1.075             946
--     contratacion.euskadi.eus                    329             326
--     contratos-publicos.comunidad.madrid         154             154
--     juntadeandalucia.es                         154             143
--     hacienda.navarra.es                         104              85
--     contratosdegalicia.gal                       92              91
--     larioja.org                                  23              23
--
-- La provincia sale del código postal (trg_provincia) o del NUTS
-- (trg_territorio), y las plataformas autonómicas no publican ninguno
-- de los dos en sus anuncios: solo 35 de 946 catalanas traen NUTS, y a
-- nivel de comunidad. En la web, filtrar por Barcelona enseñaba 4
-- contratos de unos 200 catalanes: el resto no tenía provincia y el
-- filtro los descartaba en silencio.
--
-- LA IDEA
-- El órgano sí viene siempre, y casi todos los órganos aparecen en
-- otras licitaciones —las del Estado, o las adjudicaciones del
-- histórico— que sí traen código postal o NUTS. Si un órgano cae en la
-- misma provincia en al menos el 90% de sus casos, y tiene tres o más,
-- esa es su provincia.
--
-- Validado sobre una muestra del 5% de filas con código postal:
-- 39.066 aciertos y 77 fallos (99,8%), con 2.682 órganos.
--
-- Recupera 1.204 de las 1.774 abiertas sin provincia (68%). Madrid,
-- Navarra y La Rioja salen enteras: son comunidades uniprovinciales y,
-- aunque el órgano no se conozca, la plataforma basta.
--
-- ES LA MISMA APROXIMACIÓN QUE YA SE HACÍA
-- El código postal del Estado suele ser el de la sede del órgano, no el
-- del lugar de ejecución (ver extraer_codigo_postal en lector_atom.py).
-- Deducirlo del órgano no empeora eso: lo extiende a quien no lo tenía.
--
-- SIN REALIMENTACIÓN
-- `provincia_origen` dice de dónde salió cada provincia. La tabla de
-- órganos se construye solo con pruebas directas (código postal o
-- NUTS; las filas anteriores a esta migración, con origen nulo, lo son
-- todas). Sin esa marca, lo deducido ayer contaría como prueba hoy y
-- un error se iría confirmando a sí mismo.
--
-- Y lo deducido cede ante una prueba: si más tarde llega el código
-- postal o el NUTS de una fila, el disparador lo recalcula.
--
-- PARA DESHACERLO
--   select cron.unschedule('refrescar-organos-provincia');
--   update public.licitaciones set provincia = null, comunidad = null,
--          provincia_origen = null
--    where provincia_origen in ('organo', 'fuente');
--   -- y restaurar rellenar_territorio y trg_territorio desde la
--   -- definición anterior, que se copia al final de este archivo.
--   drop function public.refrescar_organos_provincia();
--   drop function public.rellenar_provincias_pendientes(integer);
--   drop function public.reconstruir_organos_provincia();
--   drop table public.organos_provincia;
--   alter table public.licitaciones drop column provincia_origen;
-- ============================================================

set local statement_timeout = '15min';

-- Añadir una columna sin valor por defecto no reescribe la tabla.
alter table public.licitaciones add column if not exists provincia_origen text;

comment on column public.licitaciones.provincia_origen is
  'De dónde sale la provincia: cp, nuts, organo o fuente. Nulo en filas '
  'anteriores al 21/09/2026, que son todas de cp o nuts.';

create table if not exists public.organos_provincia (
    organo       text primary key,
    provincia    text not null,
    comunidad    text,
    casos        integer not null,
    acuerdo      numeric not null,
    actualizado  timestamptz not null default now()
);

comment on table public.organos_provincia is
  'Provincia de cada órgano, deducida de sus licitaciones con código postal '
  'o NUTS. La rehace cada noche refrescar_organos_provincia().';

-- Tabla interna: solo la leen el disparador y la función de refresco.
alter table public.organos_provincia enable row level security;
revoke all on public.organos_provincia from anon, authenticated;

-- ------------------------------------------------------------
-- El disparador
-- ------------------------------------------------------------
--
-- SECURITY DEFINER porque ahora lee `organos_provincia`: si quien
-- inserta no tuviera permiso sobre ella, fallaría la inserción entera
-- de la licitación, no solo su provincia.
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

    -- La plataforma de una comunidad uniprovincial dice la provincia
    -- sin necesidad de nada más.
    if new.comunidad is null then
        new.comunidad := case split_part(coalesce(new.enlace, ''), '/', 3)
            when 'contratos-publicos.comunidad.madrid' then 'Comunidad de Madrid'
            when 'hacienda.navarra.es'                 then 'Navarra'
            when 'www.larioja.org'                     then 'La Rioja'
        end;
    end if;

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

-- También cuando cambian el órgano o el enlace, que ahora cuentan.
drop trigger if exists trg_territorio on public.licitaciones;
create trigger trg_territorio
    before insert or update of codigo_postal, nuts, organo, enlace
    on public.licitaciones
    for each row execute function public.rellenar_territorio();

-- ------------------------------------------------------------
-- La tabla de órganos
-- ------------------------------------------------------------
--
-- Recorre la tabla entera de licitaciones, así que va por pg_cron y no
-- por RPC: por PostgREST tendría el límite de 8 s (ver
-- 20260920235000_agregados_por_cron.sql).
create or replace function public.reconstruir_organos_provincia()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    filas integer;
begin
    delete from public.organos_provincia;

    insert into public.organos_provincia (organo, provincia, comunidad, casos, acuerdo)
    select organo, provincia, comunidad, tot, round(n::numeric / tot, 3)
    from (
        select l.organo, l.provincia, min(l.comunidad) as comunidad,
               count(*) as n,
               sum(count(*)) over (partition by l.organo) as tot,
               row_number() over (partition by l.organo
                                  order by count(*) desc, l.provincia) as rk
        from public.licitaciones l
        where l.provincia is not null
          and l.organo is not null and l.organo <> ''
          -- Solo pruebas directas: lo deducido no cuenta.
          and coalesce(l.provincia_origen, 'cp') in ('cp', 'nuts')
        group by l.organo, l.provincia
    ) x
    where rk = 1 and tot >= 3 and n::numeric / tot >= 0.9;

    get diagnostics filas = row_count;
    return filas;
end;
$function$;

-- ------------------------------------------------------------
-- Rellenar lo que siga sin provincia, por lotes
-- ------------------------------------------------------------
--
-- Con `tope` para el relleno inicial: son unas 120.000 filas sin
-- provincia y de una sola vez sería una transacción larga sobre la
-- tabla que escribe el scraper. Por la noche se llama sin tope: para
-- entonces solo quedan las nuevas del día.
--
-- Se escribe la columna directamente: el disparador no salta con
-- `provincia`, y así no se rehacen el sector ni los prefijos.
create or replace function public.rellenar_provincias_pendientes(tope integer default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    rellenadas integer := 0;
    filas integer;
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
    with uni as (
        select comunidad, min(provincia) as provincia
        from public.provincias
        group by comunidad
        having count(distinct provincia) = 1
    ),
    lote as (
        select l.id_licitacion, u.comunidad, u.provincia
        from public.licitaciones l
        join uni u on u.comunidad = coalesce(l.comunidad,
            case split_part(coalesce(l.enlace, ''), '/', 3)
                when 'contratos-publicos.comunidad.madrid' then 'Comunidad de Madrid'
                when 'hacienda.navarra.es'                 then 'Navarra'
                when 'www.larioja.org'                     then 'La Rioja'
            end)
        where l.provincia is null
        limit case when tope is null then null
                   else greatest(tope - rellenadas, 0) end
    )
    update public.licitaciones l
       set provincia = lote.provincia,
           comunidad = lote.comunidad,
           provincia_origen = 'fuente'
      from lote
     where l.id_licitacion = lote.id_licitacion;
    get diagnostics filas = row_count;
    rellenadas := rellenadas + filas;

    return rellenadas;
end;
$function$;

create or replace function public.refrescar_organos_provincia()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    perform public.reconstruir_organos_provincia();
    return public.rellenar_provincias_pendientes(null);
end;
$function$;

revoke execute on function public.reconstruir_organos_provincia() from public, anon, authenticated;
revoke execute on function public.rellenar_provincias_pendientes(integer) from public, anon, authenticated;
revoke execute on function public.refrescar_organos_provincia() from public, anon, authenticated;

-- La tabla de órganos se construye ahora. El relleno de las filas
-- existentes NO va aquí: se lanzó aparte, por lotes, con
--   select public.rellenar_provincias_pendientes(<tope>);
-- hasta que devolvió 0.
select public.reconstruir_organos_provincia();

-- Cada noche, después de la pasada del scraper (06:00 UTC) y antes de
-- refrescar los organismos (06:30), para que sus agregados ya tengan
-- las provincias nuevas.
select cron.schedule('refrescar-organos-provincia', '20 6 * * *',
                     $$select public.refrescar_organos_provincia()$$);

-- ------------------------------------------------------------
-- Definición anterior, para deshacer
-- ------------------------------------------------------------
--
-- create or replace function public.rellenar_territorio()
--  returns trigger language plpgsql as $function$
-- declare
--     encontrado record;
-- begin
--     if new.codigo_postal is not null and new.codigo_postal <> '' then
--         select p.provincia, p.comunidad into encontrado
--         from public.provincias p
--         where p.prefijo = public.provincia_de_cp(new.codigo_postal);
--         if found then
--             new.provincia := coalesce(new.provincia, encontrado.provincia);
--             new.comunidad := coalesce(new.comunidad, encontrado.comunidad);
--             return new;
--         end if;
--     end if;
--     if new.nuts is not null and new.nuts <> '' then
--         select n.provincia, n.comunidad into encontrado
--         from public.nuts n where n.codigo = new.nuts;
--         if found then
--             new.provincia := coalesce(new.provincia,
--                                       nullif(encontrado.provincia, ''));
--             new.comunidad := coalesce(new.comunidad, encontrado.comunidad);
--         end if;
--     end if;
--     return new;
-- end;
-- $function$;
--
-- drop trigger if exists trg_territorio on public.licitaciones;
-- create trigger trg_territorio
--     before insert or update of codigo_postal, nuts
--     on public.licitaciones
--     for each row execute function public.rellenar_territorio();
