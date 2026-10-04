-- ============================================================
-- La ficha de empresa devuelve la duración de sus últimos contratos
-- ============================================================
--
-- Cambio ADITIVO: cada elemento de `ultimos` gana la clave
-- `duracion_meses` (null si el organismo no la publicó). Todo lo demás
-- de la función queda igual. La web antigua ignora la clave nueva.
--
-- Respaldo de la definición anterior en
-- `respaldo_funciones_duracion_20261002`, por si hay que volver atrás.
-- ============================================================

create table if not exists public.respaldo_funciones_duracion_20261002 as
select p.proname as nombre, pg_get_functiondef(p.oid) as definicion,
       now() as guardado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'ficha_empresa';

alter table public.respaldo_funciones_duracion_20261002 enable row level security;
revoke all on public.respaldo_funciones_duracion_20261002 from anon, authenticated;

create or replace function public.ficha_empresa(cif_buscado text, desde integer default null::integer, hasta integer default null::integer)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
begin
    return (
        with suyas as (
            select s.titulo, s.organo, s.sector, a.fecha,
                   a.nombre, a.importe as suyo, a.lotes,
                   s.duracion_meses
            from public.adjudicaciones_empresa a
            join public.licitaciones s on s.id_licitacion = a.id_licitacion
            where a.cif = limpio
              and not a.es_menor and not a.es_homologacion
              and public.en_periodo(a.fecha, desde, hasta)
        )
        select jsonb_build_object(
            'cif', limpio,
            'desde', desde,
            'hasta', hasta,
            'nombre', (select a.nombre
                       from public.adjudicaciones_empresa a
                       where a.cif = limpio
                       order by a.fecha desc nulls last limit 1),
            'contratos', count(*),
            'lotes', coalesce(sum(l.lotes), 0),
            'importe', coalesce(sum(l.suyo), 0),
            'primero', min(l.fecha),
            'ultimo', max(l.fecha),
            'sectores', (
                select jsonb_agg(jsonb_build_object(
                           'sector', t.sector, 'contratos', t.n, 'importe', t.euros)
                         order by t.euros desc nulls last)
                from (select s.sector, count(*)::int as n,
                             coalesce(sum(s.suyo), 0) as euros
                      from suyas s
                      where s.sector is not null
                      group by s.sector order by euros desc nulls last limit 10) t
            ),
            'organos', (
                select jsonb_agg(jsonb_build_object(
                           'organo', o.organo, 'contratos', o.n, 'importe', o.euros)
                         order by o.n desc)
                from (select s.organo, count(*)::int as n,
                             coalesce(sum(s.suyo), 0) as euros
                      from suyas s
                      where s.organo is not null
                      group by s.organo order by count(*) desc limit 8) o
            ),
            'ultimos', (
                select jsonb_agg(jsonb_build_object(
                           'titulo', u.titulo, 'organo', u.organo,
                           'importe', u.suyo,
                           'duracion_meses', u.duracion_meses,
                           'fecha', u.fecha)
                         order by u.fecha desc)
                from (select s.titulo, s.organo, s.suyo, s.fecha, s.duracion_meses
                      from suyas s
                      order by s.fecha desc limit 8) u
            ),
            'marcos', (
                select jsonb_agg(jsonb_build_object(
                           'organo', m.organo, 'titulo', m.titulo,
                           'lotes', m.lotes, 'fecha', m.fecha,
                           'valor_marco', m.valor_marco)
                         order by m.fecha desc)
                from (select s.organo, s.titulo, a.lotes, a.fecha,
                             coalesce(s.valor_estimado, s.presupuesto) as valor_marco
                      from public.adjudicaciones_empresa a
                      join public.licitaciones s on s.id_licitacion = a.id_licitacion
                      where a.cif = limpio
                        and a.es_homologacion
                        and public.en_periodo(a.fecha, desde, hasta)
                      order by a.fecha desc limit 20) m
            ),
            'sigo', exists (
                select 1 from public.seguimiento sg
                join public.perfiles p on p.id = sg.perfil_id
                where p.id = public.mi_perfil_id() and sg.cif = limpio)
        )
        from suyas l
    );
end;
$function$;
