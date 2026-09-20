-- ============================================================
-- NO GUARDAR UNA CACHÉ VACÍA CUANDO EL PERFIL AÚN NO TIENE PREFIJOS
-- ============================================================
--
-- Aplicada el 20/09/2026.
--
-- EL PROBLEMA
-- El perfil de PIMEC se quedó con las pestañas de Empresas y
-- Organismos en blanco. No faltaban datos: su sector tiene 1.908
-- contratos adjudicados en la ventana de dos años, repartidos entre
-- 608 organismos. Lo que había era una caché envenenada.
--
--   perfiles.fecha_alta           14:09:26   fila del perfil creada
--   organismos_guardados          14:09:44   0 filas   (+18 s)
--   competencia_guardada          14:09:50   0 filas   (+24 s)
--   primer veredicto del cribado  17:40:02             (+3 h 30)
--
-- Las dos cachés se calcularon dieciocho y veinticuatro segundos
-- después de crearse la fila del perfil, cuando `cpv_prefijos`
-- todavía era null. El alta de verdad —CIF, historial, criterio,
-- prefijos— no terminó hasta tres horas y media más tarde.
--
-- Con la lista de prefijos vacía, `prefijo_principal = any(array[])`
-- no devuelve nada. Hasta ahí, correcto. El fallo es que las dos
-- funciones GUARDAN ese vacío como si fuera un resultado legítimo, y
-- la comprobación de frescura solo mira la fecha:
--
--     if guardado is null or cuando <= now() - interval '1 day'
--
-- Un `[]` recién escrito es «fresco». Así que la página se queda en
-- blanco veinticuatro horas, ya con el alta terminada y los datos
-- disponibles.
--
-- No es específico de PIMEC: le pasa a cualquier usuario nuevo que
-- toque las pestañas de mercado mientras se completa su alta. El
-- perfil de adolfopangulo@gmail.com, parado en `describiendo`, tiene
-- la misma caché de competencia a cero por la misma razón.
--
-- EL ARREGLO
-- Salir antes de tocar nada cuando no hay prefijos, que es lo que ya
-- hacen `pendientes_de_perfil` y `mercado_sin_cribar_de` desde la
-- migración de `perfil_ajeno`:
--
--     if mis_pref is null or array_length(mis_pref, 1) is null then
--         return;
--     end if;
--
-- Esto no quita ni acorta la caché de nadie. Para un perfil con
-- prefijos el comportamiento es idéntico al de antes. Para uno sin
-- prefijos es ESTRICTAMENTE MENOS TRABAJO: se ahorra el recorrido
-- sobre `licitaciones` y se ahorra la escritura en la tabla de
-- caché. No puede cargar más la base de lo que ya la carga.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1 · competencia
--     Se antepone la comprobación al `select` de la caché: sin
--     prefijos no hay nada que leer ni que escribir. El resto del
--     cuerpo se conserva tal cual.
-- ------------------------------------------------------------
create or replace function public.competencia(anios integer default 2)
returns table(cif text, nombre text, contratos integer, importe numeric, sigo boolean)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    mi_perfil uuid;
    mi_cif    text;
    prefijos  text[];
    uno       text;
    cola      fila_competencia[] := '{}';
    desde     timestamptz := now() - (anios || ' years')::interval;
    guardado  jsonb;
    cuando    timestamptz;
begin
    select p.id, p.cif,
           array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mi_perfil, mi_cif, prefijos
    from public.perfiles p where p.usuario_id = auth.uid();

    if mi_perfil is null then return; end if;

    -- AÑADIDO. Sin prefijos no se calcula ni se guarda nada: un `[]`
    -- escrito aquí valdría veinticuatro horas y dejaría la pantalla
    -- en blanco al terminar el alta.
    if prefijos is null or array_length(prefijos, 1) is null then
        return;
    end if;

    select cg.datos, cg.calculado into guardado, cuando
    from public.competencia_guardada cg where cg.perfil_id = mi_perfil;

    if guardado is not null and cuando > now() - interval '1 day' then
        return query
        select x->>'cif', x->>'nombre', (x->>'contratos')::int,
               (x->>'importe')::numeric, false
        from jsonb_array_elements(guardado) as x;
        return;
    end if;

    -- Un prefijo cada vez, con `=` simple: cada consulta es un Index
    -- Scan que lee en orden y para a las 1.000.
    --
    -- Mil y no cuatro mil: ya lee solo lo pedido, pero cada fila está
    -- en un bloque de disco distinto y traer 4.000 costaba 2,4 s. Para
    -- un ranking de 25 empresas, las 1.000 últimas dan el mismo
    -- resultado: quien aparece veinte veces sigue apareciendo.
    foreach uno in array prefijos loop
        cola := cola || array(
            select (l.adjudicatario, l.adjudicatario_cif,
                    l.importe_adjudicacion, l.id_licitacion,
                    l.fecha_actualizacion)::fila_competencia
            from public.licitaciones l
            where l.prefijo_principal = uno
              and l.adjudicatario_cif is not null
            order by l.fecha_actualizacion desc
            limit 1000);
    end loop;

    with limpias as (
        select c.* from unnest(cola) c
        left join public.veredictos_mercado v
          on v.id_licitacion = c.id_licitacion and v.perfil_id = mi_perfil
        where coalesce(v.del_sector, true)
          and c.adjudicatario_cif is distinct from mi_cif
          and c.fecha_actualizacion >= desde
    ),
    top as (
        select c.adjudicatario_cif as cif,
               (array_agg(c.adjudicatario))[1] as nombre,
               count(*)::int as contratos,
               coalesce(sum(c.importe_adjudicacion), 0) as importe
        from limpias c
        where not exists (
            select 1 from public.seguimiento sg
            where sg.perfil_id = mi_perfil and sg.cif = c.adjudicatario_cif)
        group by c.adjudicatario_cif
        order by count(*) desc
        limit 25
    )
    select coalesce(jsonb_agg(to_jsonb(t) order by t.contratos desc), '[]'::jsonb)
    into guardado from top t;

    insert into public.competencia_guardada (perfil_id, datos, calculado)
    values (mi_perfil, guardado, now())
    on conflict (perfil_id) do update
        set datos = excluded.datos, calculado = excluded.calculado;

    return query
    select x->>'cif', x->>'nombre', (x->>'contratos')::int,
           (x->>'importe')::numeric, false
    from jsonb_array_elements(guardado) as x;
end;
$function$;


-- ------------------------------------------------------------
-- 2 · buscar_organismo (la de tres argumentos, que es la que llama
--     la web). El resto del cuerpo se conserva tal cual.
-- ------------------------------------------------------------
create or replace function public.buscar_organismo(texto text default ''::text,
                                                   salto integer default 0,
                                                   cuantos integer default 500)
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
    -- AÑADIDO: los prefijos se leen en el mismo viaje que el id, y si
    -- no hay se sale antes de tocar `licitaciones` o la caché.
    select p.id,
           array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mi_perfil, mis_pref
    from public.perfiles p where p.usuario_id = auth.uid();

    if mi_perfil is null then return; end if;
    if mis_pref is null or array_length(mis_pref, 1) is null then
        return;
    end if;

    select og.datos, og.calculado into guardado, cuando
    from public.organismos_guardados og where og.perfil_id = mi_perfil;

    if guardado is null or cuando <= now() - interval '1 day' then
        with suyas as (
            select l.organo, l.provincia, l.importe_adjudicacion
            from public.licitaciones l
            where l.prefijo_principal = any(mis_pref)
              and l.adjudicatario_cif is not null
              and l.organo is not null
              and l.fecha_actualizacion >= now() - interval '2 years'
            limit 40000
        ),
        agrupado as (
            select s.organo as o, (array_agg(s.provincia))[1] as prov,
                   count(*)::int as n,
                   coalesce(sum(s.importe_adjudicacion), 0) as euros
            from suyas s group by s.organo
            order by count(*) desc
            limit 1000
        )
        select coalesce(jsonb_agg(to_jsonb(a) order by a.n desc), '[]'::jsonb)
        into guardado from agrupado a;

        insert into public.organismos_guardados (perfil_id, datos, calculado)
        values (mi_perfil, guardado, now())
        on conflict (perfil_id) do update
            set datos = excluded.datos, calculado = excluded.calculado;
    end if;

    -- El filtro por texto se aplica sobre lo guardado, que ya está en
    -- memoria: buscar no vuelve a tocar la tabla grande.
    return query
    select x->>'o', x->>'prov', (x->>'n')::int, (x->>'euros')::numeric
    from jsonb_array_elements(guardado) as x
    where coalesce(texto, '') = ''
       or (x->>'o') ilike '%' || texto || '%'
    offset salto limit cuantos;
end;
$function$;

-- CREATE OR REPLACE conserva la ACL previa, pero se reafirma por si
-- alguna se recreó alguna vez desde cero.
grant execute on function public.competencia(integer) to authenticated;
grant execute on function public.buscar_organismo(text, integer, integer) to authenticated;


-- ------------------------------------------------------------
-- 3 · Las dos filas envenenadas de PIMEC.
--     Se borran para que se recalculen en la siguiente visita. El
--     recálculo de este perfil está medido: 524 ms el de organismos
--     (608 órganos sobre 1.908 filas, todo por índice y en buffers
--     calientes) y 4 ms por prefijo el de competencia. Muy lejos de
--     los 8 s de `statement_timeout`.
-- ------------------------------------------------------------
delete from public.organismos_guardados
where perfil_id = 'c9988949-f0a0-4098-9f04-8cfa39bb3ad3';

delete from public.competencia_guardada
where perfil_id = 'c9988949-f0a0-4098-9f04-8cfa39bb3ad3';

commit;


-- ============================================================
-- PENDIENTE, y esta migración NO lo resuelve:
--
-- El recálculo de `buscar_organismo` NO CABE en el statement_timeout
-- de 8 s para los sectores grandes. Medido sobre el perfil de
-- Capgemini (12 prefijos, 21.179 filas en la ventana de dos años):
--
--     1ª pasada, buffers fríos    30,5 s   (read=18206)
--     2ª pasada                   11,9 s   (read=8091)
--     3ª pasada, ya caliente       < 8 s
--
-- El plan es correcto —Index Scan sobre idx_licitaciones_prefijo_fecha—
-- pero cada fila vive en un bloque distinto y hay que ir al heap a
-- por `organo`, `provincia` e `importe_adjudicacion` 21.000 veces.
-- El working set no cabe en shared_buffers, así que en cada pasada se
-- vuelven a leer miles de bloques de disco.
--
-- La consecuencia se ve en la tabla: los perfiles más grandes NO
-- TIENEN NINGUNA FILA en `organismos_guardados`.
--
--     SALAN PRODUCCIONES   24.829 filas   sin caché
--     SIENA EDUCACIÓN      22.436 filas   sin caché
--     Capgemini            21.179 filas   sin caché
--     HERREROS Y SOCIOS    14.980 filas   sin caché
--     MARE NOSTRUM         16.134 filas   con caché (1.000)
--     ALTEISA              12.836 filas   con caché (1.000)
--
-- El corte no es limpio porque depende del calor de los buffers en
-- ese instante. Es la misma frontera, vista dos veces.
--
-- Para ellos la pestaña de Organismos está vacía DE FORMA PERMANENTE,
-- y peor que en el caso de PIMEC: sin fila de caché, cada visita
-- vuelve a lanzar la consulta de 12-30 s y vuelve a agotar el tiempo.
-- Eso sí es carga real y repetida sobre la base.
--
-- Arreglos posibles, por orden de coste:
--   a) Índice que cubra la consulta —(prefijo_principal,
--      fecha_actualizacion desc) include (organo, provincia,
--      importe_adjudicacion) where adjudicatario_cif is not null—
--      para que sea Index Only Scan y desaparezcan los 21.000 saltos
--      al heap. Es el candidato obvio, pero añade un índice más a una
--      tabla que ya tiene veinte y que el scraper reescribe entera en
--      cada pasada. Ver la migración `indices_sobrantes`.
--   b) Calcularlo fuera de la petición del usuario, en el cron que ya
--      corre en GitHub Actions, con la clave de servicio y sin
--      timeout de 8 s.
--   c) Recortar la ventana de dos años a una.
--
-- Hace falta medir (a) antes de decidir. No se toca aquí.
-- ============================================================
