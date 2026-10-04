-- ============================================================
-- Empresas: la competencia de tu tamaño
-- ============================================================
--
-- Aplicada el 03/10/2026.
--
-- Un betatester con una pyme entraba en Empresas y lo primero que veía
-- era al líder del sector: una empresa que gana cientos de millones al
-- año y contra la que no puede hacer nada. Lo que quiere ver es a quien
-- le quita los contratos a su escala.
--
-- Medido con los 21 perfiles con NIF (desde 2024):
--   - Filtrar por tamaño de CONTRATO no sirve: los grandes también ganan
--     muchos contratos pequeños, y en 6 de 7 perfiles pequeños las tres
--     primeras seguían siendo las mismas, o mayores.
--   - Un tope a lo que gana la EMPRESA al año en contratos públicos sí:
--     en los perfiles de menos de 1 M€/año, las tres primeras pasan de
--     empresas de 3-800 M€/año a otras de 10.000 € a 4 M€/año, con 8-140
--     contratos en su sector. Por encima de 1 M€/año apenas cambia.
--
-- La facturación no está en los datos. Lo que gana al año en contratos
-- públicos sí, y es lo que importa aquí: quien gana 276 M€ al año con la
-- administración no es una pyme.
--
-- Qué cambia:
--   - `empresas_por_cif.anual`: media de lo que ganó en los dos últimos
--     años, en todos sus sectores, sin menores ni homologaciones. La
--     rellena `refrescar_empresas` cada día.
--   - `perfiles.tamano_competencia`: el tope que eligió el cliente, en
--     euros al año. 0 = todas; null = no ha elegido.
--   - `mi_tamano_competencia()`: el tope que vale y si lo eligió él. Sin
--     elegir: con NIF, el primero de 500.000 €, 2 M€ y 10 M€ que llega a
--     diez veces lo que gana él (todas, si gana más de 1 M€ al año); sin
--     NIF, todas. Los topes son los mismos que ofrece la web.
--   - `cambiar_tamano_competencia(tope)`.
--   - `competencia_periodo` gana el parámetro `tope` (null o 0 = todas,
--     como antes) y la columna `anual`; `seguimiento_periodo`, la
--     columna. La web antigua sigue funcionando: no pasa `tope` e ignora
--     la columna.
--
-- Paso aparte, después de aplicarla: select public.refrescar_empresas();
-- ============================================================

create table if not exists public.respaldo_funciones_tamano_20261003 as
select p.proname as nombre, pg_get_functiondef(p.oid) as definicion,
       now() as guardado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('refrescar_empresas', 'competencia_periodo',
                    'seguimiento_periodo');

alter table public.respaldo_funciones_tamano_20261003 enable row level security;
revoke all on public.respaldo_funciones_tamano_20261003 from anon, authenticated;


alter table public.empresas_por_cif add column if not exists anual numeric;
comment on column public.empresas_por_cif.anual is
    'Media anual de lo ganado en los dos últimos años, todos los sectores, '
    'sin menores ni homologaciones. La rellena refrescar_empresas.';

alter table public.perfiles add column if not exists tamano_competencia bigint;
comment on column public.perfiles.tamano_competencia is
    'Tope de lo que ganan al año las empresas de la lista de competencia, '
    'en euros. 0 = todas; null = no ha elegido (ver mi_tamano_competencia).';


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
        (cif, nombre, contratos, importe, anual, ultima_fecha, actualizado)
    select a.cif,
           (array_agg(a.nombre order by l.fecha_actualizacion desc))[1],
           count(*)::int,
           coalesce(sum(a.importe), 0),
           coalesce(sum(a.importe) filter (
               where not a.es_menor and not a.es_homologacion
                 and a.fecha >= sello - interval '2 years'), 0) / 2,
           max(l.fecha_actualizacion),
           sello
    from public.adjudicaciones_empresa a
    join public.licitaciones l on l.id_licitacion = a.id_licitacion
    group by a.cif
    on conflict (cif) do update
        set nombre       = excluded.nombre,
            contratos    = excluded.contratos,
            importe      = excluded.importe,
            anual        = excluded.anual,
            ultima_fecha = excluded.ultima_fecha,
            actualizado  = excluded.actualizado;

    get diagnostics metidas = row_count;

    delete from public.empresas_por_cif where actualizado < sello;

    return metidas;
end;
$function$;


-- Cambia lo que devuelve, así que hay que borrarla y crearla otra vez.
drop function if exists public.competencia_periodo(integer, integer);

create function public.competencia_periodo(
    desde integer default null, hasta integer default null,
    tope bigint default null)
returns table(cif text, nombre text, contratos integer, importe numeric,
              sigo boolean, anual numeric)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif from public.perfiles p
        where p.id = public.mi_perfil_id()
    ),
    movidas as materialized (
        select m.id_licitacion, m.fecha
        from public.mercado_del_periodo(desde, hasta, null) m
    ),
    repartos as materialized (
        select * from public.repartos_del_periodo(desde, hasta)
    ),
    por_empresa as (
        select r.cif,
               (array_agg(r.nombre order by m.fecha desc))[1] as nombre,
               count(*)::int as contratos,
               coalesce(sum(r.importe), 0) as importe
        from movidas m
        join repartos r on r.id_licitacion = m.id_licitacion
        cross join yo
        where r.cif is distinct from yo.cif
          and not exists (select 1 from public.seguimiento sg
                          where sg.perfil_id = yo.id and sg.cif = r.cif)
        group by r.cif
    )
    select e.cif, e.nombre, e.contratos, e.importe, false, c.anual
    from por_empresa e
    left join public.empresas_por_cif c on c.cif = e.cif
    -- Sin cifra todavía (nueva desde el último refresco) cuenta como
    -- pequeña: mejor enseñarla que esconderla.
    where coalesce(tope, 0) = 0 or coalesce(c.anual, 0) <= tope
    order by e.contratos desc, e.importe desc
    limit 25;
$function$;

revoke execute on function public.competencia_periodo(integer, integer, bigint)
    from public, anon;
grant execute on function public.competencia_periodo(integer, integer, bigint)
    to authenticated, service_role;


drop function if exists public.seguimiento_periodo(integer, integer);

create function public.seguimiento_periodo(
    desde integer default null, hasta integer default null)
returns table(cif text, nombre text, contratos integer, importe numeric,
              ultimo timestamptz, anual numeric)
language sql
stable security definer
set search_path to 'public'
as $function$
    select s.cif,
           coalesce(s.nombre, (array_agg(a.nombre order by a.fecha desc))[1]),
           count(l.id_licitacion)::int,
           coalesce(sum(a.importe) filter (where l.id_licitacion is not null), 0),
           max(a.fecha) filter (where l.id_licitacion is not null),
           (select c.anual from public.empresas_por_cif c where c.cif = s.cif)
    from public.seguimiento s
    left join public.adjudicaciones_empresa a on a.cif = s.cif
    left join public.licitaciones l
      on l.id_licitacion = a.id_licitacion
     and not a.es_menor and not a.es_homologacion
     and public.en_periodo(a.fecha, desde, hasta)
    where s.perfil_id = public.mi_perfil_id()
    group by s.cif, s.nombre, s.creado
    order by s.creado desc;
$function$;

revoke execute on function public.seguimiento_periodo(integer, integer)
    from public, anon;
grant execute on function public.seguimiento_periodo(integer, integer)
    to authenticated, service_role;


create or replace function public.mi_tamano_competencia()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
    select jsonb_build_object(
        'tope', coalesce(p.tamano_competencia,
                    case when p.cif is null then 0
                         else coalesce((select min(t)
                                        from unnest(array[500000, 2000000,
                                                          10000000]::bigint[]) t
                                        where t >= 10 * coalesce(c.anual, 0)), 0)
                    end),
        'elegido', p.tamano_competencia is not null)
    from public.perfiles p
    left join public.empresas_por_cif c on c.cif = p.cif
    where p.id = public.mi_perfil_id();
$function$;

revoke execute on function public.mi_tamano_competencia() from public, anon;
grant execute on function public.mi_tamano_competencia()
    to authenticated, service_role;


create or replace function public.cambiar_tamano_competencia(tope bigint)
returns bigint
language sql
security definer
set search_path to 'public'
as $function$
    update public.perfiles set tamano_competencia = greatest(coalesce(tope, 0), 0)
    where id = public.mi_perfil_id()
    returning tamano_competencia;
$function$;

revoke execute on function public.cambiar_tamano_competencia(bigint) from public, anon;
grant execute on function public.cambiar_tamano_competencia(bigint)
    to authenticated, service_role;
