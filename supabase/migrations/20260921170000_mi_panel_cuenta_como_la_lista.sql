-- ============================================================
-- mi_panel: "contratos abiertos que te mostramos" cuenta como la lista
-- ============================================================
--
-- Aplicada el 21/09/2026.
--
-- "Mi cuenta" decía 661 y la lista de contratos enseñaba 621. El panel
-- contaba todos los veredictos "si"/"quizas" del perfil, también los de
-- contratos ya cerrados, vencidos o descartados por el cliente. Ahora
-- aplica las mismas condiciones que la vista `mis_oportunidades`, que es
-- de donde sale la lista. Medido: 270 ms.
--
-- Si cambian las condiciones de esa vista, hay que cambiar esto con ella.
-- ============================================================

create or replace function public.mi_panel()
returns jsonb
language sql
stable security definer
set search_path to 'public'
as $function$
    select jsonb_build_object(
        'empresa', p.empresa,
        'cif', p.cif,
        'email', p.email,
        'actividad', p.descripcion,
        'que_buscamos', p.que_buscamos,
        'contratos_ganados', p.contratos_ganados,
        'criterio_version', p.criterio_version,
        'criterio_fecha', p.criterio_fecha,
        'alta', p.fecha_alta,
        'avisos', p.avisos,
        'correcciones', (
            select jsonb_build_object(
                'total', count(*),
                'sin_aplicar', count(*) filter (where not aplicada)
            )
            from public.correcciones c where c.perfil_id = p.id
        ),
        -- Las mismas condiciones que `mis_oportunidades`.
        'oportunidades', (
            select count(*)
            from public.veredictos v
            join public.licitaciones l on l.id_licitacion = v.id_licitacion
            left join public.correcciones c
                   on c.id_licitacion = v.id_licitacion and c.perfil_id = v.perfil_id
            where v.perfil_id = p.id
              and v.veredicto in ('si', 'quizas')
              and coalesce(l.estado_licitacion, '') = 'PUB'
              and (l.fecha_limite is not null and l.fecha_limite >= now()
                   or l.fecha_limite is null
                      and l.fecha_actualizacion >= now() - interval '14 days')
              and (c.interesa is null or c.interesa)
        ),
        'sectores', (
            select jsonb_agg(jsonb_build_object(
                       'sector', t.sector, 'contratos', t.n, 'importe', t.euros)
                     order by t.euros desc nulls last, t.n desc)
            from (
                select l.sector, count(*)::int as n,
                       coalesce(sum(l.importe_adjudicacion), 0) as euros
                from public.licitaciones l
                where l.adjudicatario_cif = p.cif and l.sector is not null
                group by l.sector order by euros desc nulls last limit 10
            ) t
        ),
        'importe_ganado', (
            select sum(l.importe_adjudicacion) from public.licitaciones l
            where l.adjudicatario_cif = p.cif
        ),
        'organos', (
            select jsonb_agg(jsonb_build_object(
                       'organo', o.organo, 'contratos', o.n, 'importe', o.euros)
                     order by o.n desc)
            from (
                select l.organo, count(*)::int as n,
                       coalesce(sum(l.importe_adjudicacion), 0) as euros
                from public.licitaciones l
                where l.adjudicatario_cif = p.cif and l.organo is not null
                group by l.organo order by count(*) desc limit 8
            ) o
        )
    )
    from public.perfiles p
    where p.usuario_id = auth.uid();
$function$;
