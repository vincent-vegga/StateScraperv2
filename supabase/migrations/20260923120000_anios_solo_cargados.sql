-- ============================================================
-- El selector de años solo ofrece años cargados de verdad
-- ============================================================
--
-- Aplicada el 23/09/2026.
--
-- Al pasar a contar cada contrato en su año de formalización o
-- adjudicación (20260923100000), aparecieron 2021, 2022 y 2023 en el
-- selector: en uniformidad, 45, 132 y 302 contratos frente a ~1.700 de
-- 2024. Son contratos viejos republicados en los ficheros de 2024-2026
-- (modificaciones, prórrogas, acuerdos marco, publicaciones tardías):
-- una muestra sesgada de esos años, no su mercado. El histórico solo
-- está cargado desde 2024.
--
-- Regla: se ofrecen los años con al menos el 2 % del más lleno (como
-- antes) y que no sean anteriores al PRIMER AÑO CARGADO, que es el
-- primero que llega a ese mismo 2 % contando por fecha de publicación
-- (`fecha_actualizacion`). Cuando se importe 2021-2023, entrarán solos.
--
-- Los contratos viejos no se borran ni se esconden en las fichas: solo
-- dejan de ofrecerse sus años.
-- ============================================================

create or replace function public.anios_de_mi_sector()
returns table(anio integer, contratos integer)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    ),
    suyas as materialized (
        select public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                    l.fecha_formalizacion_estimada,
                                    l.fecha_actualizacion) as fecha,
               l.fecha_actualizacion
        from yo
        join public.licitaciones l
          on l.prefijo_principal = any(yo.prefijos)
         and l.adjudicatario_cif is not null
         and l.procedimiento is distinct from 'Contrato menor'
    ),
    por_anio as (
        select extract(year from fecha at time zone 'Europe/Madrid')::int as anio,
               count(*)::int as n
        from suyas group by 1
    ),
    -- Por fecha de publicación: qué años del histórico hay cargados.
    cargados as (
        select extract(year from fecha_actualizacion at time zone 'Europe/Madrid')::int as anio,
               count(*)::int as n
        from suyas group by 1
    ),
    primero as (
        select min(anio) as anio from cargados
        where n >= 0.02 * (select max(n) from cargados)
    ),
    validos as (
        select anio from por_anio
        where n >= 0.02 * (select max(n) from por_anio)
          and anio >= (select anio from primero)
    )
    select s.anio::int, coalesce(pa.n, 0)
    from generate_series((select min(anio) from validos),
                         (select max(anio) from validos)) as s(anio)
    left join por_anio pa on pa.anio = s.anio
    order by 1;
$function$;
