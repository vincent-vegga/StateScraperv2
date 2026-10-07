-- ============================================================
-- Viabilidad: el porqué del veredicto, también en la ficha de Contratos
-- ============================================================
--
-- Un contrato salía "Difícil" en la fila y, al abrirlo, todo era "Llegas"
-- (07/10/2026). Son dos preguntas distintas: la solvencia dice si puedes
-- presentarte; Viabilidad, si es fácil ganarlo (en ese caso, el 50 % de
-- la puntuación era juicio de valor). La fila no decía de qué era el
-- "Difícil" ni por qué, y la ficha no lo explicaba.
--
-- `viabilidad_guardada` guarda ahora los motivos que ya calcula
-- `viabilidad()`, y `requisitos()` los devuelve con el veredicto, para que
-- la ficha diga "Para ganarlo: difícil, porque…" junto a "Qué piden para
-- presentarte". El veredicto "mio" se resuelve igual que en
-- `mis_oportunidades`: misma serie y el último adjudicatario es la empresa.
--
-- Los veredictos ya guardados no tienen motivos: se marcan como
-- caducados para que `refrescar_viabilidad_guardada` (pg_cron, cada 10
-- minutos) los recalcule en las pasadas siguientes. El veredicto no se
-- borra mientras tanto.
-- ============================================================

alter table public.viabilidad_guardada add column if not exists motivos jsonb;

create or replace function public.refrescar_viabilidad_guardada(segundos integer default 100)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    fin    timestamptz := clock_timestamp() + make_interval(secs => segundos);
    r      record;
    v      jsonb;
    ver    text;
    hechos integer := 0;
begin
    delete from public.viabilidad_guardada
     where calculada < now() - interval '30 days';

    for r in
        select l.id_licitacion
        from public.licitaciones l
        left join public.viabilidad_guardada g on g.id_licitacion = l.id_licitacion
        where coalesce(l.estado_licitacion, '') = 'PUB'
          and not coalesce(l.sustituida, false)
          and (l.fecha_limite >= now()
               or (l.fecha_limite is null
                   and l.fecha_actualizacion >= now() - interval '14 days'))
          and exists (select 1 from public.veredictos v
                      where v.id_licitacion = l.id_licitacion
                        and v.veredicto in ('si', 'quizas'))
          and (g.id_licitacion is null
               or g.calculada < now() - interval '7 days')
        order by g.calculada nulls first, l.fecha_limite nulls last
        limit 3000
    loop
        exit when clock_timestamp() > fin;
        begin
            v := public.viabilidad(r.id_licitacion);
            ver := case v->>'veredicto'
                       when 'difícil' then 'dificil'
                       else v->>'veredicto' end;
            if ver = 'abierto'
               and coalesce((v->'contrato'->>'peso_objetivo')::int, 0) = 0
               and coalesce((v->'incumbencia'->>'ediciones')::int, 0) = 0 then
                ver := 'sin_datos';
            end if;
            insert into public.viabilidad_guardada as g
                   (id_licitacion, veredicto, serie, ultimo_cif, calculada, motivos)
            values (r.id_licitacion, coalesce(ver, 'error'),
                    coalesce((v->'incumbencia'->>'por_convocatoria')::boolean, false),
                    v->'incumbencia'->'ultimo'->>'cif', now(),
                    case when jsonb_typeof(v->'motivos') = 'array' then v->'motivos' end)
            on conflict (id_licitacion) do update
               set veredicto = excluded.veredicto, serie = excluded.serie,
                   ultimo_cif = excluded.ultimo_cif, calculada = excluded.calculada,
                   motivos = excluded.motivos;
        exception when others then
            insert into public.viabilidad_guardada (id_licitacion, veredicto, calculada)
            values (r.id_licitacion, 'error', now())
            on conflict (id_licitacion) do update
               set veredicto = 'error', calculada = now();
        end;
        hechos := hechos + 1;
    end loop;
    return hechos;
end;
$function$;

-- Lo guardado sin motivos, a recalcular en las próximas pasadas.
update public.viabilidad_guardada
   set calculada = least(calculada, now() - interval '8 days')
 where motivos is null and veredicto not in ('error');

-- La ficha: requisitos y, si hay veredicto, el de Viabilidad con su porqué.
create or replace function public.requisitos(ficha text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    select public.requisitos_de(ficha, public.mi_perfil_id())
        || coalesce((
            select jsonb_build_object('viabilidad', jsonb_build_object(
                       'veredicto', case
                           when g.serie and p.cif is not null and g.ultimo_cif = p.cif then 'mio'
                           else g.veredicto end,
                       'motivos', coalesce(g.motivos, '[]'::jsonb)))
            from public.viabilidad_guardada g
            left join public.perfiles p on p.id = public.mi_perfil_id()
            where g.id_licitacion = ficha
              and g.veredicto not in ('sin_datos', 'error')), '{}'::jsonb)
$function$;

revoke execute on function public.requisitos(text) from public, anon;
grant execute on function public.requisitos(text) to authenticated, service_role;
