-- ============================================================
-- Lo que viene: "ya hay una nueva licitación abierta"
-- ============================================================
--
-- Un contrato que vence puede tener ya su nueva licitación abierta. Si es
-- así, "Lo que vence" lo dice y enlaza a ella: es el dato más accionable
-- de la pantalla ("presenta oferta ya").
--
-- COMO SE EMPAREJA
-- Con `serie_de` de Viabilidad (Decisión 45: mismo órgano y CPV principal,
-- palabras raras del título dentro de ese grupo, semejanza de 0,6 o más,
-- series paralelas fuera), buscando entre las licitaciones abiertas (PUB,
-- con plazo vigente) las que tienen entre sus ediciones anteriores un
-- contrato de `vencimientos`.
--
-- LA REGLA DE SEGURIDAD: solo se afirma si el emparejamiento es único.
--   - Una licitación abierta que emparejaría con DOS o más contratos que
--     vencen no se enlaza con ninguno: son contratos paralelos, o una
--     edición anterior con otro objeto parecido.
--   - Un contrato que vence que emparejaría con DOS o más abiertas
--     tampoco: son lotes licitados por separado o una republicación.
-- Medido el 06/10/2026 con 49 parejas revisadas a mano: 40 eran el mismo
-- contrato, 3 probables y 6 dudosas o falsas (hermanos del mismo año,
-- otro objeto con palabras parecidas). La regla de unicidad quita 2 de las
-- 6 y pierde algún acierto. Lo que sale se dice como "ya hay una nueva
-- licitación abierta", y cuando no sale no se dice nada: nunca "no se va a
-- licitar".
--
-- Cobertura: alrededor del 6 % de las abiertas se emparejan, unos 300
-- contratos de 84.000, menos del 1 % de lo que vence en 3 meses.
-- ============================================================

create table if not exists public.vencimientos_nueva (
    anterior    text primary key,       -- el contrato que vence (`vencimientos`)
    nueva       text not null,          -- la licitación abierta que lo sustituye
    semejanza   real not null,
    actualizado timestamptz not null default now()
);

create index if not exists idx_vencimientos_nueva_nueva
    on public.vencimientos_nueva (nueva);

alter table public.vencimientos_nueva enable row level security;
revoke all on public.vencimientos_nueva from anon, authenticated;


-- Marcar y barrer, como `refrescar_vencimientos`. Solo se miran las
-- abiertas cuyo órgano y CPV principal coinciden con algo que vence: es
-- lo que `serie_de` exigiría de todos modos, y deja el trabajo en una
-- fracción de los ~3 minutos de recorrerlas todas.
create or replace function public.refrescar_vencimientos_nueva()
returns integer
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '600s'
as $function$
declare
    sello    timestamptz := clock_timestamp();
    metidas  int;
    barridas int;
begin
    if auth.uid() is not null then
        raise exception 'refrescar_vencimientos_nueva: solo con clave de servicio';
    end if;

    with abiertas as (
        select l.id_licitacion
        from public.licitaciones l
        where l.estado_licitacion = 'PUB'
          and l.fecha_limite >= now()
          and l.prefijo_principal is not null
          and l.prefijo_principal not like '45%'
          and l.procedimiento is distinct from 'Contrato menor'
          and not coalesce(l.sustituida, false)
          and exists (select 1 from public.vencimientos v
                      where v.organo = l.organo
                        and v.prefijo_principal = l.prefijo_principal)
    ),
    pares as (
        select a.id_licitacion as nueva, s.id_licitacion as anterior, s.semejanza
        from abiertas a
        cross join lateral public.serie_de(a.id_licitacion) s
        where not s.paralelos
    ),
    vence as (
        select p.* from pares p
        join public.vencimientos v on v.id_licitacion = p.anterior
    ),
    unica_por_nueva as (
        select nueva from vence group by nueva having count(*) = 1),
    unica_por_anterior as (
        select anterior from vence group by anterior having count(*) = 1)
    insert into public.vencimientos_nueva as vn (anterior, nueva, semejanza, actualizado)
    select c.anterior, c.nueva, c.semejanza, sello
    from vence c
    where c.nueva in (select nueva from unica_por_nueva)
      and c.anterior in (select anterior from unica_por_anterior)
    on conflict (anterior) do update
        set nueva = excluded.nueva, semejanza = excluded.semejanza,
            actualizado = excluded.actualizado;
    get diagnostics metidas = row_count;

    delete from public.vencimientos_nueva where actualizado < sello;
    get diagnostics barridas = row_count;

    raise notice 'vencimientos_nueva: % al día, % barridas', metidas, barridas;
    return metidas;
end;
$function$;

revoke execute on function public.refrescar_vencimientos_nueva() from public, anon, authenticated;
grant execute on function public.refrescar_vencimientos_nueva() to service_role;


-- Lo que lee la web: lo mismo que antes, y cada fila con su `nueva` (o
-- null). Se comprueba al leer que la nueva siga abierta, para no enseñar
-- una cuyo plazo terminó entre dos refrescos.
create or replace function public.lo_que_viene(
    meses integer default 12,
    provincia_elegida text default null,
    tope integer default 300)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif,
               array(select trim(x)
                     from unnest(string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                     where trim(x) <> '') as prefijos,
               (now() at time zone 'Europe/Madrid')::date as hoy,
               least(greatest(coalesce(meses, 12), 1), 12) as plazo
        from public.perfiles p
        where p.id = public.mi_perfil_id()
    ),
    -- Todo lo de su sector en los 12 meses, sin la provincia: de aquí
    -- salen las provincias del filtro.
    sector as materialized (
        select v.*,
               v.vence < yo.hoy + interval '3 months' as en_3,
               v.vence < yo.hoy + interval '6 months' as en_6,
               v.vence < yo.hoy + make_interval(months => yo.plazo) as en_plazo
        from yo
        join public.vencimientos v
          on (v.prefijo_principal = any(yo.prefijos)
              or left(v.prefijo_principal, 2) = any(yo.prefijos))
         and v.vence >= yo.hoy
         and v.vence < yo.hoy + interval '12 months'
        where coalesce((select m.del_sector from public.veredictos_mercado m
                        where m.perfil_id = yo.id
                          and m.id_licitacion = v.id_licitacion), true)
    ),
    zona as (
        select s.* from sector s
        where provincia_elegida is null or s.provincia = provincia_elegida
    ),
    elegidos as (
        -- Es tuyo si lo ganaste tú, o uno de sus lotes. El reparto por
        -- empresa solo se mira si lo ganaron varias: con 2.024 filas,
        -- mirarlo en todas llevaba la lectura en frío a 1,2 s.
        select z.*,
               yo.cif is not null and (z.cif = yo.cif or (
                   coalesce(z.adjudicatarios, 1) > 1 and exists (
                       select 1 from public.adjudicaciones_empresa a
                       where a.id_licitacion = z.id_licitacion and a.cif = yo.cif))) as es_mia,
               exists (select 1 from public.seguimiento s
                       where s.perfil_id = yo.id and s.cif = z.cif) as la_sigo
        from zona z cross join yo
        where z.en_plazo
    )
    select jsonb_build_object(
        'cuantos', (select jsonb_build_object(
                        '3', count(*) filter (where en_3),
                        '6', count(*) filter (where en_6),
                        '12', count(*))
                    from zona),
        'provincias', (select coalesce(jsonb_agg(distinct provincia order by provincia), '[]')
                       from sector where provincia is not null),
        'importe', (select coalesce(sum(importe), 0) from elegidos),
        'mios', (select count(*) from elegidos where es_mia),
        'actualizado', (select max(actualizado) from public.vencimientos),
        'filas', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'id_licitacion', e.id_licitacion, 'titulo', e.titulo,
                       'organo', e.organo, 'provincia', e.provincia,
                       'enlace', e.enlace, 'clase', e.clase, 'cif', e.cif,
                       'empresa', e.empresa, 'adjudicatarios', e.adjudicatarios,
                       'importe', e.importe, 'inicio', e.inicio,
                       'duracion_meses', e.duracion_meses, 'fin', e.fin,
                       'prorroga', e.prorroga, 'fin_maximo', e.fin_maximo,
                       'vence', e.vence, 'es_mia', e.es_mia, 'la_sigo', e.la_sigo,
                       'nueva', (select jsonb_build_object(
                                     'id_licitacion', n.id_licitacion,
                                     'titulo', n.titulo, 'enlace', n.enlace,
                                     'fecha_limite', n.fecha_limite,
                                     'presupuesto', n.presupuesto_base,
                                     'semejanza', vn.semejanza)
                                 from public.vencimientos_nueva vn
                                 join public.licitaciones n on n.id_licitacion = vn.nueva
                                 where vn.anterior = e.id_licitacion
                                   and n.estado_licitacion = 'PUB'
                                   and n.fecha_limite >= now()))
                   order by e.vence, e.importe desc nulls last)
            from (select * from elegidos
                  order by vence, importe desc nulls last
                  limit least(greatest(coalesce(tope, 300), 1), 2000)) e
        ), '[]'))
    from yo;
$function$;

revoke execute on function public.lo_que_viene(integer, text, integer) from public, anon;
grant execute on function public.lo_que_viene(integer, text, integer) to authenticated, service_role;


-- Cada día, 10 minutos después del refresco de `vencimientos` (14:45).
select cron.schedule('refrescar-vencimientos-nueva', '55 14 * * *',
                     'select public.refrescar_vencimientos_nueva()');
