-- ============================================================
-- LOS DOS AGREGADOS SE REHACEN ENTEROS CADA NOCHE
-- ============================================================
--
-- Aplicada el 20/09/2026. Sustituye al refresco por prefijo de la
-- migración anterior y añade el agregado de empresas.
--
-- POR QUÉ ENTERO Y NO SOLO LOS SECTORES CON CLIENTE
--
-- Porque entrar en una tanda de betatesters con sectores nuevos y que
-- alguno vea la pestaña vacía no es una opción. Refrescando solo los
-- sectores de los clientes actuales, uno que se diera de alta en un
-- sector nuevo vería su primer día la foto de cuando se construyó la
-- tabla. Rehaciendo los 1.240, cualquiera entra con los datos de
-- anoche.
--
-- Y además no sale más caro. MEDIDO:
--
--     refrescar_organismos()  los 1.240 sectores    67,8 s
--     refrescar_empresas()    las 193.312 empresas  ~50 s
--
-- El primer intento creía que serían 29 s: ese número era solo la
-- parte de LEER. Escribir las 227.655 filas es el resto. Por eso el
-- techo de service_role sube a 300 s —4,4x de margen sobre el total—,
-- y sigue sin tocar a `anon` (3 s) ni a `authenticated` (8 s).
--
-- MARCAR Y BARRER, no borrar y rehacer: primero se actualiza todo
-- poniendo `actualizado` a la hora de la pasada, y después se borra lo
-- no tocado. Así la tabla nunca se queda vacía a medias: o entra la
-- pasada entera o no entra nada.
--
-- LA LISTA DE SEGUIMIENTO TENÍA LA MISMA TRAMPA
--
-- `mi_seguimiento` cruzaba `licitaciones` por CIF sin ventana ni tope:
-- por cada empresa seguida sumaba todo su historial. Con cinco
-- empresas grandes (10.924 contratos) en frío eran 4,6 s, el 58% del
-- presupuesto de 8 s. Con ocho o diez, la pestaña de Empresas se caía
-- igual que se caía la de Organismos.
--
-- Una ventana de dos años NO lo arreglaba: el índice es solo por CIF,
-- así que hay que traer cada fila del disco antes de poder mirar la
-- fecha, y de 10.924 filas el filtro descartaba 483. Con el agregado
-- son 1 ms, y conserva el significado de siempre (histórico completo),
-- así que la columna «Contratos» sigue diciendo lo mismo.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1 · Margen para el robot. Solo para service_role.
-- ------------------------------------------------------------
alter role service_role set statement_timeout = '300s';


-- ------------------------------------------------------------
-- 2 · Organismos: los 1.240 sectores de una pasada.
-- ------------------------------------------------------------
create or replace function public.refrescar_organismos()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    sello    timestamptz := now();   -- constante dentro de la transacción
    metidas  int;
    barridas int;
begin
    if auth.uid() is not null then
        raise exception 'refrescar_organismos: solo con clave de servicio';
    end if;

    insert into public.organismos_por_prefijo
        (prefijo_principal, organo, provincia, contratos, importe, actualizado)
    select l.prefijo_principal,
           l.organo,
           (array_agg(l.provincia order by l.fecha_actualizacion desc))[1],
           count(*)::int,
           coalesce(sum(l.importe_adjudicacion), 0),
           sello
    from public.licitaciones l
    where l.adjudicatario_cif is not null
      and l.organo is not null
      and l.prefijo_principal is not null
      and l.fecha_actualizacion >= now() - interval '2 years'
    group by l.prefijo_principal, l.organo
    on conflict (prefijo_principal, organo) do update
        set provincia   = excluded.provincia,
            contratos   = excluded.contratos,
            importe     = excluded.importe,
            actualizado = excluded.actualizado;

    get diagnostics metidas = row_count;

    delete from public.organismos_por_prefijo where actualizado < sello;
    get diagnostics barridas = row_count;

    raise notice 'organismos: % al día, % barridos', metidas, barridas;
    return metidas;
end;
$function$;

revoke execute on function public.refrescar_organismos() from public, anon, authenticated;
grant execute on function public.refrescar_organismos() to service_role;


-- ------------------------------------------------------------
-- 3 · Empresas: el agregado por CIF.
-- ------------------------------------------------------------
create table if not exists public.empresas_por_cif (
    cif          text primary key,
    nombre       text,
    contratos    integer not null,
    importe      numeric not null default 0,
    ultima_fecha timestamptz,
    actualizado  timestamptz not null default now()
);

-- RLS activo y SIN POLÍTICAS: nadie llega por la API. Solo lo leen las
-- funciones SECURITY DEFINER.
alter table public.empresas_por_cif enable row level security;
revoke all on table public.empresas_por_cif from public, anon, authenticated;

create or replace function public.refrescar_empresas()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    sello   timestamptz := now();
    metidas int;
begin
    if auth.uid() is not null then
        raise exception 'refrescar_empresas: solo con clave de servicio';
    end if;

    insert into public.empresas_por_cif
        (cif, nombre, contratos, importe, ultima_fecha, actualizado)
    select l.adjudicatario_cif,
           (array_agg(l.adjudicatario order by l.fecha_actualizacion desc))[1],
           count(*)::int,
           coalesce(sum(l.importe_adjudicacion), 0),
           max(l.fecha_actualizacion),
           sello
    from public.licitaciones l
    where l.adjudicatario_cif is not null
    group by l.adjudicatario_cif
    on conflict (cif) do update
        set nombre       = excluded.nombre,
            contratos    = excluded.contratos,
            importe      = excluded.importe,
            ultima_fecha = excluded.ultima_fecha,
            actualizado  = excluded.actualizado;

    get diagnostics metidas = row_count;

    delete from public.empresas_por_cif where actualizado < sello;

    return metidas;
end;
$function$;

revoke execute on function public.refrescar_empresas() from public, anon, authenticated;
grant execute on function public.refrescar_empresas() to service_role;

select public.refrescar_empresas();


-- ------------------------------------------------------------
-- 4 · mi_seguimiento lee del agregado.
--
--     La quinta columna se llama `ultimo`, no `ultima`: el nombre es
--     parte del contrato con la web y no se toca.
--
--     Se conserva el LEFT JOIN: una empresa recién seguida de la que
--     todavía no consta nada tiene que seguir apareciendo con un cero,
--     no desaparecer de la lista.
-- ------------------------------------------------------------
create or replace function public.mi_seguimiento()
returns table(cif text, nombre text, contratos integer,
              importe numeric, ultimo timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $function$
    select s.cif,
           coalesce(s.nombre, e.nombre),
           coalesce(e.contratos, 0),
           coalesce(e.importe, 0),
           e.ultima_fecha
    from public.seguimiento s
    join public.perfiles p on p.id = s.perfil_id and p.usuario_id = auth.uid()
    left join public.empresas_por_cif e on e.cif = s.cif
    order by s.creado desc;
$function$;

grant execute on function public.mi_seguimiento() to authenticated;

commit;


-- ============================================================
-- LO QUE SE MIDIÓ EN LA AUDITORÍA, Y QUEDÓ BIEN
--
--   movimientos_mercado(30), la consultora TIC     493 ms
--     La ventana de 30 días lo acota sola.
--   buscar_organismo, la consultora TIC            344 ms   (antes 11.900)
--   mi_seguimiento, 5 empresas grandes       1 ms   (antes 4.600)
--
-- PENDIENTE, y no lo resuelve esta migración:
--
--   · `anios_de_organismo` y la versión de UN argumento de
--     `buscar_organismo` recorren `licitaciones` sin ningún tope. La
--     segunda parece muerta —la web llama siempre a la de tres— pero
--     sigue expuesta a `authenticated`. Conviene medirlas y, si de
--     verdad no se usa, revocarla.
--
--   · `ficha_empresa` recorre el historial de una empresa. Acotado por
--     empresa (la mayor tiene 2.725 contratos), así que cabe, pero es
--     el siguiente que se quedará corto si crece el histórico.
--
--   · Un perfil con prefijos de DOS dígitos no encuentra nada, porque
--     se comparan contra `prefijo_principal`, que tiene cuatro. Venía
--     de antes; no es una regresión.
-- ============================================================
