-- ============================================================
-- Mi cartera: todo "sí me interesa" entra en la cartera
-- ============================================================
--
-- Arreglo de la Decisión 53. "Sí me interesa" guarda en la cartera
-- llamando a `poner_en_cartera`, pero la web vuelve a `corregir` (el
-- camino de antes) si la cartera todavía no ha cargado, y una pestaña
-- abierta desde antes de publicar la cartera lo hace siempre. El
-- 07/10/2026 un "sí me interesa" se guardó así a las 15:25 UTC, tres
-- horas y media después de publicar, y el contrato salía como
-- "Confirmado como tuyo" sin estar en la cartera.
--
-- En la base y no en la web: así vale para cualquier camino, también
-- para versiones de la página que el navegador tenga guardadas.
--
-- Solo cuando la corrección pasa a "sí" (alta, o de "no" a "sí"). Las
-- demás escrituras de la fila (`aplicada` al ajustar el filtro, el
-- `on conflict` de `corregir` repitiendo "sí") no tocan la cartera: si
-- el cliente quitó el contrato de su cartera, no vuelve solo.
-- ============================================================

create or replace function public.cartera_desde_correccion()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    if new.interesa and (tg_op = 'INSERT' or old.interesa is distinct from true) then
        insert into public.cartera (perfil_id, id_licitacion, estado, plazo_visto)
        select new.perfil_id, new.id_licitacion, 'interesa', l.fecha_limite
        from public.licitaciones l
        where l.id_licitacion = new.id_licitacion
        on conflict (perfil_id, id_licitacion) do nothing;
    end if;
    return null;
end;
$function$;

revoke execute on function public.cartera_desde_correccion() from public, anon, authenticated;

drop trigger if exists cartera_desde_correccion on public.correcciones;
create trigger cartera_desde_correccion
    after insert or update of interesa on public.correcciones
    for each row execute function public.cartera_desde_correccion();

-- Lo que se quedó fuera: "sí me interesa" de contratos abiertos que no
-- están en la cartera (1 el 07/10/2026).
insert into public.cartera (perfil_id, id_licitacion, estado, plazo_visto, creado, cambiado)
select c.perfil_id, c.id_licitacion, 'interesa', l.fecha_limite, c.fecha, c.fecha
from public.correcciones c
join public.licitaciones l on l.id_licitacion = c.id_licitacion
where c.interesa
  and coalesce(l.estado_licitacion, '') = 'PUB'
  and (l.fecha_limite is null or l.fecha_limite >= now())
  and not l.sustituida
on conflict (perfil_id, id_licitacion) do nothing;
