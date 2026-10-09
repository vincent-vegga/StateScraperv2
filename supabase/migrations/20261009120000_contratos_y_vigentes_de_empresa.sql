-- La ficha de empresa: todos sus contratos, y los que tiene abiertos.
--
-- "Sus últimos contratos" eran los 8 más recientes del periodo, sin forma
-- de ver el resto: de una empresa con 2.000 adjudicaciones no se podía
-- buscar la que interesaba. Dos funciones nuevas, que la web pide aparte
-- de `ficha_empresa` (que no cambia; su `ultimos` deja de leerse).
--
--   contratos_empresa   los del periodo, de 20 en 20, con buscador (título
--                       y organismo), filtro por sector y por organismo, y
--                       orden por fecha o por importe. Los mismos que cuenta
--                       la ficha: sin menores ni homologaciones.
--   vigentes_empresa    los que tiene abiertos hoy, sin mirar el periodo.
--
-- QUÉ ES "VIGENTE"
-- El fin se calcula como en `lo_que_viene` (20261005100000): inicio =
-- formalización, o la estimada, o la adjudicación; fin = inicio +
-- duración. Y las prórrogas con la misma `prorroga_de()`. Dos grupos:
--   en_plazo     el plazo inicial termina hoy o más tarde. Seguro.
--   prorrogados  el plazo inicial ya pasó, pero con las prórrogas que
--                prevé el contrato llegaría a hoy. Solo si se prorrogó:
--                eso no se publica.
-- A diferencia de Lo que viene, aquí SÍ entran las obras, los basados en
-- un acuerdo marco y lo que dura menos de 6 meses: allí se quitan porque
-- no se vuelven a licitar, pero mientras duran son contratos abiertos.
-- Fuera, como en la ficha, los menores (su duración mediana es de un mes)
-- y las homologaciones (no son un contrato con importe). Lo que no
-- publica duración no se puede situar y no sale.
--
-- TIEMPOS MEDIDOS (09/10/2026, la empresa con más contratos, 2.865)
--   el cruce de sus adjudicaciones con `licitaciones`: 1,4 s en frío,
--   el mismo que ya hace `ficha_empresa`. Sin índice nuevo: el buscador
--   filtra las filas de UNA empresa (2.900 como mucho), no la tabla.

create or replace function public.texto_buscable(t text)
returns text
language sql
immutable
as $function$
    select translate(lower(coalesce(t, '')), 'áàâäéèêëíìîïóòôöúùûüçñ·',
                                             'aaaaeeeeiiiioooouuuucn.');
$function$;

revoke execute on function public.texto_buscable(text) from public, anon, authenticated;


create or replace function public.contratos_empresa(
    cif_buscado text,
    desde integer default null,
    hasta integer default null,
    buscar text default null,
    sector_elegido text default null,
    organo_elegido text default null,
    orden text default 'fecha',
    saltar integer default 0,
    cuantos integer default 20)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio   text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
    -- Cada palabra tiene que estar en el título o en el organismo, en
    -- cualquier orden: "limpieza colegios" encuentra "Servicio de limpieza
    -- de los colegios públicos".
    palabras text[] := array_remove(regexp_split_to_array(
                           public.texto_buscable(trim(buscar)), '\s+'), '');
    tope     int := least(greatest(coalesce(cuantos, 20), 1), 100);
    desde_n  int := greatest(coalesce(saltar, 0), 0);
begin
    return (
        with suyas as (
            select s.titulo, s.organo, s.sector, a.fecha, a.importe as suyo,
                   a.lotes, s.duracion_meses, s.enlace,
                   public.en_periodo(a.fecha, desde, hasta) as dentro
            from public.adjudicaciones_empresa a
            join public.licitaciones s on s.id_licitacion = a.id_licitacion
            where a.cif = limpio
              and not a.es_menor and not a.es_homologacion
              and (sector_elegido is null or s.sector = sector_elegido)
              and (organo_elegido is null or s.organo = organo_elegido)
              and (cardinality(palabras) = 0 or not exists (
                    select 1 from unnest(palabras) p
                    where strpos(public.texto_buscable(
                              s.titulo || ' ' || coalesce(s.organo, '')), p) = 0))
        ),
        ordenadas as (
            select t.*, row_number() over (order by
                       case when orden = 'importe' then t.suyo end desc nulls last,
                       t.fecha desc nulls last, t.titulo) as n
            from suyas t
            where t.dentro
        )
        select jsonb_build_object(
            'total', (select count(*) from ordenadas),
            -- Los que cumplen lo pedido pero caen fuera del periodo: para
            -- decir "ninguno en 2025 · 3 en otros años" en vez de "no hay".
            'fuera_del_periodo', (select count(*) from suyas where not dentro),
            'contratos', coalesce((
                select jsonb_agg(jsonb_build_object(
                           'titulo', c.titulo, 'organo', c.organo, 'sector', c.sector,
                           'importe', c.suyo, 'lotes', c.lotes,
                           'duracion_meses', c.duracion_meses,
                           'enlace', c.enlace, 'fecha', c.fecha)
                         order by c.n)
                from ordenadas c
                where c.n > desde_n and c.n <= desde_n + tope), '[]'::jsonb))
    );
end;
$function$;

revoke execute on function public.contratos_empresa(text, integer, integer, text, text, text, text, integer, integer) from public, anon;
grant execute on function public.contratos_empresa(text, integer, integer, text, text, text, text, integer, integer) to authenticated;


-- La primera versión, sin páginas, se aplicó unos minutos antes.
drop function if exists public.vigentes_empresa(text);

-- Los dos grupos llegan con su total y sus 20 primeros. De una empresa
-- grande salen más de mil en plazo (650 KB de golpe); con `grupo` se pide
-- la página siguiente de uno solo.
create or replace function public.vigentes_empresa(
    cif_buscado text,
    grupo text default null,
    saltar integer default 0,
    cuantos integer default 20)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
    limpio text := upper(regexp_replace(cif_buscado, '[^a-zA-Z0-9]', '', 'g'));
    hoy    date := (now() at time zone 'Europe/Madrid')::date;
    tope   int := least(greatest(coalesce(cuantos, 20), 1), 100);
    desde_n int := greatest(coalesce(saltar, 0), 0);
begin
    return (
        with suyas as (
            select s.titulo, s.organo, s.enlace, a.importe as suyo,
                   s.duracion_meses, s.prorrogas_texto,
                   public.clase_sistema(s.sistema) as clase,
                   i.inicio,
                   (i.inicio + s.duracion_meses * interval '1 month')::date as fin
            from public.adjudicaciones_empresa a
            join public.licitaciones s on s.id_licitacion = a.id_licitacion
            cross join lateral (
                select coalesce(s.fecha_formalizacion, s.fecha_formalizacion_estimada,
                                s.fecha_adjudicacion)::date as inicio
            ) i
            where a.cif = limpio
              and not a.es_menor and not a.es_homologacion
              and not s.sustituida
              and s.duracion_meses > 0 and s.duracion_meses <= 300
              and i.inicio between date '2000-01-01' and hoy + 400
        ),
        -- Las prórrogas solo se leen de lo que terminó hace menos de 5
        -- años (LCSP, art. 29.4), como en `vencimientos_calculados`.
        con_prorroga as (
            select c.*, p.prorroga, p.fin_maximo
            from suyas c
            cross join lateral public.prorroga_de(c.prorrogas_texto, c.duracion_meses, c.fin) p
            where c.fin >= hoy - interval '5 years'
        ),
        vivos as (
            select c.*, c.fin >= hoy as en_plazo,
                   row_number() over (partition by c.fin >= hoy order by
                       case when c.fin >= hoy then c.fin else c.fin_maximo end,
                       c.titulo) as n
            from con_prorroga c
            where c.fin >= hoy or c.fin_maximo >= hoy
        )
        select jsonb_build_object(
            'hoy', hoy,
            'n_en_plazo', (select count(*) from vivos where en_plazo),
            'n_prorrogados', (select count(*) from vivos where not en_plazo),
            'en_plazo', case when grupo is distinct from 'prorrogados' then coalesce((
                select jsonb_agg(jsonb_build_object(
                           'titulo', v.titulo, 'organo', v.organo, 'enlace', v.enlace,
                           'importe', v.suyo, 'duracion_meses', v.duracion_meses,
                           'clase', v.clase, 'inicio', v.inicio, 'fin', v.fin,
                           'prorroga', v.prorroga, 'fin_maximo', v.fin_maximo)
                         order by v.n)
                from vivos v
                where v.en_plazo and v.n > desde_n and v.n <= desde_n + tope),
                '[]'::jsonb) end,
            'prorrogados', case when grupo is distinct from 'en_plazo' then coalesce((
                select jsonb_agg(jsonb_build_object(
                           'titulo', v.titulo, 'organo', v.organo, 'enlace', v.enlace,
                           'importe', v.suyo, 'duracion_meses', v.duracion_meses,
                           'clase', v.clase, 'inicio', v.inicio, 'fin', v.fin,
                           'prorroga', v.prorroga, 'fin_maximo', v.fin_maximo)
                         order by v.n)
                from vivos v
                where not v.en_plazo and v.n > desde_n and v.n <= desde_n + tope),
                '[]'::jsonb) end
        )
    );
end;
$function$;

revoke execute on function public.vigentes_empresa(text, text, integer, integer) from public, anon;
grant execute on function public.vigentes_empresa(text, text, integer, integer) to authenticated;
