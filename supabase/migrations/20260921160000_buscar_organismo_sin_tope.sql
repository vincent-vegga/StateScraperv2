-- ============================================================
-- buscar_organismo: que se pueda encontrar cualquier organismo
-- ============================================================
--
-- Aplicada el 21/09/2026.
--
-- EL FALLO
-- La lista se calcula una vez al día y se guarda con `limit 5000`, y la
-- búsqueda por texto filtraba sobre esa lista guardada. Para un perfil de
-- construcción hay 8.583 organismos: los 3.583 con menos contratos no
-- salían nunca, por mucho que se escribiera su nombre exacto. La web
-- además decía "Busca entre 5000 organismos", que no era un recuento
-- sino el tope.
--
-- LA SOLUCIÓN
-- Sin texto, igual que antes: la lista guardada, que es la que la web
-- carga al entrar. Con texto, se busca sobre la tabla de organismos
-- entera. Medido con el perfil de construcción: 550 ms.
-- ============================================================

create or replace function public.buscar_organismo(texto text default '', salto integer default 0, cuantos integer default 500)
returns table(organo text, provincia text, contratos integer, importe numeric)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    mi_perfil uuid;
    mis_pref  text[];
    guardado  jsonb;
    cuando    timestamptz;
begin
    select p.id,
           array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mi_perfil, mis_pref
    from public.perfiles p where p.usuario_id = auth.uid();

    if mi_perfil is null then return; end if;

    -- Sin prefijos no se calcula ni se guarda nada: un `[]` escrito
    -- aquí valdría veinticuatro horas y dejaría la pantalla en blanco
    -- al terminar el alta.
    if mis_pref is null or array_length(mis_pref, 1) is null then
        return;
    end if;

    -- Con texto, sobre todos los organismos y no sobre la lista guardada,
    -- que se corta en 5.000.
    if coalesce(texto, '') <> '' then
        return query
        select o.organo,
               (array_agg(o.provincia order by o.contratos desc))[1],
               sum(o.contratos)::int,
               sum(o.importe)
        from public.organismos_por_prefijo o
        where o.prefijo_principal = any(mis_pref)
          and o.organo ilike '%' || texto || '%'
        group by o.organo
        order by sum(o.contratos) desc, o.organo
        offset salto limit cuantos;
        return;
    end if;

    select og.datos, og.calculado into guardado, cuando
    from public.organismos_guardados og where og.perfil_id = mi_perfil;

    if guardado is null or cuando <= now() - interval '1 day' then
        with agrupado as (
            select o.organo as o,
                   (array_agg(o.provincia order by o.contratos desc))[1] as prov,
                   sum(o.contratos)::int as n,
                   sum(o.importe) as euros
            from public.organismos_por_prefijo o
            where o.prefijo_principal = any(mis_pref)
            group by o.organo
            -- El desempate por nombre no es cosmético: la web pagina
            -- con OFFSET y sin un orden total estricto una misma fila
            -- puede salir en dos tandas o en ninguna.
            order by sum(o.contratos) desc, o.organo
            limit 5000
        )
        select coalesce(jsonb_agg(to_jsonb(a) order by a.n desc, a.o), '[]'::jsonb)
        into guardado from agrupado a;

        insert into public.organismos_guardados (perfil_id, datos, calculado)
        values (mi_perfil, guardado, now())
        on conflict (perfil_id) do update
            set datos = excluded.datos, calculado = excluded.calculado;
    end if;

    return query
    select x->>'o', x->>'prov', (x->>'n')::int, (x->>'euros')::numeric
    from jsonb_array_elements(guardado) as x
    offset salto limit cuantos;
end;
$function$;
