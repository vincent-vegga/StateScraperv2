-- ============================================================
-- ALTA SIN NIF: CONTRATOS PARECIDOS A LA DESCRIPCIÓN
-- ============================================================
--
-- Aplicada el 24/09/2026. Poblada ese mismo día con una pasada suelta
-- de pg_cron (08:26 UTC, 47 s): 71.073 filas de 1.196 códigos, 41 MB.
-- muestra_de_familias('{72,48}') devuelve 4.118 filas en 0,1 s.
--
-- La entrada por NIF construye el filtro con EJEMPLOS: los contratos que
-- la empresa ha ganado. Sin NIF solo había la descripción, y una frase
-- como "material eléctrico e instrumentación" deja pasar demasiado. Ahora
-- el alta busca los contratos adjudicados que más se parecen a lo que ha
-- escrito (embeddings, en la función `alta`) y los usa como ejemplos.
-- Simulado con los perfiles que tienen NIF (rama simulacion-sin-nif,
-- decisión 38): F1 media 0,52 frente a 0,43 con la descripción sola y
-- 0,33 con lo que había.
--
-- Esos ejemplos salen de lo adjudicado en sus familias. Leerlo de
-- `licitaciones` en el momento no cabe: unos 4.000 títulos dispersos por
-- la tabla pasan de 7 s con la base ocupada (medido el 24/09/2026 con
-- la división 79). Se guarda una muestra pequeña, pegada por código:
--
--   muestra_adjudicada      los 100 últimos adjudicados de cada prefijo
--                           de 4 dígitos, sin menores ni homologaciones.
--                           Como mucho unas 128.000 filas.
--   refrescar_muestra_adjudicada()
--                           la rehace. Por pg_cron, dentro de la base:
--                           ~47 s, y PostgREST corta a los 8 s.
--   muestra_de_familias(familias, por_prefijo)
--                           lo que lee el alta.
--
-- Si la tabla estuviera vacía, el alta sigue como antes: criterio de la
-- descripción y captura por familias.
--
-- Y en `perfiles`, `franjas`: los tamaños de contrato que marca el
-- cliente al describir su negocio. De momento eligen qué ejemplos se
-- toman; más adelante ordenarán la lista.
-- ============================================================

alter table public.perfiles
    add column if not exists franjas text[];


create table if not exists public.muestra_adjudicada (
    id_licitacion     text primary key,
    prefijo_principal text not null,
    titulo            text not null,
    organo            text,
    presupuesto       numeric,
    importe           numeric,
    adjudicatario     text,
    adjudicatario_cif text,
    cpvs              jsonb,
    fecha             timestamptz
);

create index if not exists idx_muestra_adjudicada_prefijo
    on public.muestra_adjudicada (prefijo_principal, fecha desc);

-- Solo se lee a través de la función de alta, con la clave de servicio.
alter table public.muestra_adjudicada enable row level security;
revoke all on public.muestra_adjudicada from anon, authenticated;


-- Prefijo a prefijo, con el índice idx_licitaciones_cuentan: su
-- predicado es exactamente "adjudicado, no menor, no homologación" y su
-- orden, la fecha de mercado.
--
-- Se borra e inserta en la misma transacción: quien lea mientras tanto
-- ve la muestra anterior entera (TRUNCATE bloquearía la lectura).
create or replace function public.refrescar_muestra_adjudicada()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    n integer;
begin
    delete from public.muestra_adjudicada;

    insert into public.muestra_adjudicada
    select x.id_licitacion, p.prefijo, x.titulo, x.organo,
           coalesce(x.presupuesto_base, x.presupuesto), x.importe_adjudicacion,
           x.adjudicatario, x.adjudicatario_cif, x.cpvs, x.fecha
    from (select distinct r.prefijo from public.resumen_cpv_total r
          where length(r.prefijo) = 4) p
    cross join lateral (
        select l.id_licitacion, l.titulo, l.organo, l.presupuesto,
               l.presupuesto_base, l.importe_adjudicacion, l.adjudicatario,
               l.adjudicatario_cif, l.cpvs,
               public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                   l.fecha_formalizacion_estimada, l.fecha_actualizacion) as fecha
        from public.licitaciones l
        where l.prefijo_principal = p.prefijo
          and l.adjudicatario_cif is not null
          and l.procedimiento is distinct from 'Contrato menor'
          and not public.es_homologacion(l.sistema, l.importe_adjudicacion)
          and coalesce(l.titulo, '') <> ''
        order by public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                     l.fecha_formalizacion_estimada, l.fecha_actualizacion) desc
        limit 100
    ) x
    on conflict (id_licitacion) do nothing;

    get diagnostics n = row_count;
    return n;
end;
$function$;

revoke all on function public.refrescar_muestra_adjudicada() from public, anon, authenticated;


-- Lo de sus familias, repartido: con muchas familias o una división
-- enorme, menos por prefijo, para que el alta no reciba más de ~6.000
-- filas (se comparan una a una con la descripción).
create or replace function public.muestra_de_familias(familias text[], tope integer default 6000)
returns setof public.muestra_adjudicada
language sql
stable
security definer
set search_path to 'public'
as $function$
    with suyas as (
        select m.*
        from public.muestra_adjudicada m
        where exists (select 1 from unnest(familias) f
                      where m.prefijo_principal like f || '%'
                         or f like m.prefijo_principal || '%')
    ),
    reparto as (
        select greatest(10, tope / greatest(1, count(distinct prefijo_principal)))::int as por_prefijo
        from suyas
    )
    select s.id_licitacion, s.prefijo_principal, s.titulo, s.organo, s.presupuesto,
           s.importe, s.adjudicatario, s.adjudicatario_cif, s.cpvs, s.fecha
    from (select suyas.*, row_number() over (partition by prefijo_principal
                                              order by fecha desc nulls last) as n
          from suyas) s, reparto
    where s.n <= reparto.por_prefijo;
$function$;

revoke all on function public.muestra_de_familias(text[], integer) from public, anon, authenticated;
grant execute on function public.muestra_de_familias(text[], integer) to service_role;


-- De noche, fuera de las horas del scraper y de los demás agregados
-- (14:00-14:30 UTC).
select cron.schedule('refrescar-muestra-adjudicada', '30 3 * * *',
                     $$select public.refrescar_muestra_adjudicada()$$);
