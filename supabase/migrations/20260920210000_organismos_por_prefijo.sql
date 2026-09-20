-- ============================================================
-- ORGANISMOS: DE RECORRER `licitaciones` A LEER UN AGREGADO
-- ============================================================
--
-- Aplicada el 20/09/2026, en dos tandas:
--   organismos_por_prefijo_tabla
--   organismos_desde_agregado_y_competencia_acotada
--
-- EL PROBLEMA
-- El recálculo de `buscar_organismo` no cabía en el statement_timeout
-- de 8 s del rol `authenticated`. Medido sobre el perfil de Capgemini
-- (12 prefijos, 21.179 filas en la ventana de dos años):
--
--     1ª pasada, buffers fríos    30,5 s   (read=18206)
--     2ª pasada                   11,9 s   (read=8091)
--     3ª pasada, ya caliente       < 8 s
--
-- El plan era correcto —Index Scan sobre idx_licitaciones_prefijo_fecha—
-- pero cada fila vive en un bloque distinto y hay que ir al heap a por
-- `organo`, `provincia` e `importe_adjudicacion` 21.000 veces. El
-- working set no cabe en shared_buffers.
--
-- La consecuencia: los perfiles grandes NO TENÍAN NINGUNA FILA en
-- `organismos_guardados`. Su pestaña de Organismos estaba vacía de
-- forma permanente y, peor, cada visita relanzaba la consulta y volvía
-- a agotar el tiempo — 8 s de conexión y miles de lecturas que además
-- desalojaban páginas de shared_buffers y perjudicaban al resto.
--
--     SALAN PRODUCCIONES   24.829 filas   sin caché
--     SIENA EDUCACIÓN      22.436 filas   sin caché
--     Capgemini            21.179 filas   sin caché
--     HERREROS Y SOCIOS    14.980 filas   sin caché
--     MARE NOSTRUM         16.134 filas   con caché (1.000)
--     ALTEISA              12.836 filas   con caché (1.000)
--
-- El corte no es limpio porque dependía del calor de los buffers en
-- ese instante. Es la misma frontera, vista dos veces.
--
-- POR QUÉ ESTE ARREGLO Y NO OTRO
--
--   a) Índice de cobertura con INCLUDE (organo, provincia,
--      importe_adjudicacion). Habría funcionado —el mapa de
--      visibilidad está al 100%, así que sería Index Only Scan— pero
--      son unos 100 MB sobre los 570 MB de índices que ya tiene
--      `licitaciones`, en una tabla con veinte índices que el scraper
--      reescribe entera en cada pasada y donde solo el 2% de los
--      updates son HOT. Se paga en cada escritura para acelerar una
--      lectura que se hace una vez al día.
--
--   b) pg_cron. Está disponible pero sin instalar, y el README es
--      explícito: «Todo corre en GitHub Actions. No requiere
--      instalación local ni servidor propio». No se mete un
--      planificador nuevo dentro de la base.
--
--   c) ESTE. Un agregado POR PREFIJO, no por perfil. Dos clientes del
--      mismo sector hacían dos veces el mismo trabajo y uno nuevo lo
--      hacía desde cero; ahora se calcula una vez y sirve a todos,
--      incluido el que se dio de alta hace un minuto. 227.655 filas,
--      45 MB, y la lectura de Capgemini baja de 11.900 ms a 344 ms
--      sin una sola lectura de disco.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1 · La tabla del agregado.
-- ------------------------------------------------------------
create table if not exists public.organismos_por_prefijo (
    prefijo_principal text not null,
    organo            text not null,
    provincia         text,
    contratos         integer not null,
    importe           numeric not null default 0,
    actualizado       timestamptz not null default now(),
    primary key (prefijo_principal, organo)
);

-- RLS activo y SIN POLÍTICAS: nadie llega por la API. Solo lo leen las
-- funciones SECURITY DEFINER, igual que `palabras_titulo`.
alter table public.organismos_por_prefijo enable row level security;

revoke all on table public.organismos_por_prefijo from public, anon, authenticated;

-- Relleno inicial, la pasada completa: 28,7 s de Seq Scan más un merge
-- externo. Aquí se puede; en una petición de usuario, no.
insert into public.organismos_por_prefijo
    (prefijo_principal, organo, provincia, contratos, importe, actualizado)
select l.prefijo_principal,
       l.organo,
       (array_agg(l.provincia order by l.fecha_actualizacion desc))[1],
       count(*)::int,
       coalesce(sum(l.importe_adjudicacion), 0),
       now()
from public.licitaciones l
where l.adjudicatario_cif is not null
  and l.organo is not null
  and l.prefijo_principal is not null
  and l.fecha_actualizacion >= now() - interval '2 years'
group by l.prefijo_principal, l.organo
on conflict (prefijo_principal, organo) do update
    set provincia   = excluded.provincia,
        contratos   = excluded.contratos,
        importe     = excluded.importe,
        actualizado = excluded.actualizado;

analyze public.organismos_por_prefijo;


-- ------------------------------------------------------------
-- 2 · El refresco necesita más de 8 s, y solo lo llama el robot.
--
--     `service_role` no tiene statement_timeout propio, así que
--     heredaba los 8 s del `authenticator`. El prefijo más grande en
--     uso (9231) tiene 24.829 contratos en la ventana y tarda unos
--     12 s él solo.
--
--     Se sube SOLO para service_role, que es la clave del robot de
--     GitHub Actions y que nunca sale del servidor. `anon` (3 s) y
--     `authenticated` (8 s) NO se tocan: ahí es donde el límite
--     protege de verdad.
-- ------------------------------------------------------------
alter role service_role set statement_timeout = '120s';


-- ------------------------------------------------------------
-- 3 · El refresco, prefijo a prefijo.
--
--     Recibe una lista para que el robot pueda llamarlo UNA VEZ POR
--     PREFIJO. Cada llamada es su propia transacción y confirma por su
--     cuenta: si la cuarenta falla, las treinta y nueve anteriores
--     siguen hechas. Una sola llamada para los 54 prefijos en uso
--     sería una transacción de varios minutos que se pierde entera si
--     algo va mal.
-- ------------------------------------------------------------
create or replace function public.refrescar_organismos_por_prefijo(
    prefijos text[] default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    objetivo text[];
    uno      text;
    metidas  int := 0;
    n        int;
begin
    -- Solo con clave de servicio. Con sesión de usuario, auth.uid()
    -- devuelve algo y aquí se para. Mismo criterio que
    -- `perfil_permitido`.
    if auth.uid() is not null then
        raise exception 'refrescar_organismos_por_prefijo: solo con clave de servicio';
    end if;

    objetivo := coalesce(prefijos, array(
        select distinct trim(x)
        from public.perfiles p,
             unnest(string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
        where p.activo and trim(x) <> ''));

    foreach uno in array objetivo loop
        -- Se borra y se rehace el prefijo entero. Un organismo que dejó
        -- de aparecer en la ventana de dos años tiene que desaparecer,
        -- y con un upsert se quedaría ahí para siempre.
        delete from public.organismos_por_prefijo
        where prefijo_principal = uno;

        insert into public.organismos_por_prefijo
            (prefijo_principal, organo, provincia, contratos, importe, actualizado)
        select l.prefijo_principal,
               l.organo,
               (array_agg(l.provincia order by l.fecha_actualizacion desc))[1],
               count(*)::int,
               coalesce(sum(l.importe_adjudicacion), 0),
               now()
        from public.licitaciones l
        where l.prefijo_principal = uno
          and l.adjudicatario_cif is not null
          and l.organo is not null
          and l.fecha_actualizacion >= now() - interval '2 years'
        group by l.prefijo_principal, l.organo;

        get diagnostics n = row_count;
        metidas := metidas + n;
    end loop;

    return metidas;
end;
$function$;

revoke execute on function public.refrescar_organismos_por_prefijo(text[])
    from public, anon, authenticated;
grant execute on function public.refrescar_organismos_por_prefijo(text[])
    to service_role;


-- ------------------------------------------------------------
-- 4 · buscar_organismo lee del agregado.
--
--     El tope sube de 1.000 a 5.000 organismos. Con 1.000, a Capgemini
--     se le tiraban 2.767 de sus 3.767: justo los ayuntamientos
--     pequeños que el comentario de la versión de un argumento avisaba
--     de no perder. Con el agregado ya no cuesta nada traerlos, y la
--     web pagina de 400 en 400 hasta 5.000.
--
--     `organismos_guardados` se conserva como caché de paginación: la
--     web pide trece tandas seguidas y no tiene sentido reagrupar
--     trece veces.
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
    select p.id,
           array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mi_perfil, mis_pref
    from public.perfiles p where p.usuario_id = auth.uid();

    if mi_perfil is null then return; end if;

    -- Sin prefijos no se calcula ni se guarda nada: un `[]` escrito
    -- aquí valdría veinticuatro horas y dejaría la pantalla en blanco
    -- al terminar el alta. Ver la migración `no_guardar_cache_vacia`.
    if mis_pref is null or array_length(mis_pref, 1) is null then
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
    where coalesce(texto, '') = ''
       or (x->>'o') ilike '%' || texto || '%'
    offset salto limit cuantos;
end;
$function$;

grant execute on function public.buscar_organismo(text, integer, integer) to authenticated;


-- ------------------------------------------------------------
-- 5 · competencia: el presupuesto se reparte entre los prefijos.
--
--     Aquí NO sirve un agregado por prefijo: `veredictos_mercado`
--     guarda 1.315 licitaciones marcadas como «fuera de mi sector» por
--     14 perfiles, y agregando por (prefijo, CIF) resucitarían
--     empresas que el usuario ya descartó a mano.
--
--     El problema es el de siempre: 1.000 filas por prefijo son 543 ms
--     en uno grande, y Capgemini tiene doce. Seis segundos y medio en
--     caliente, contra 8 s de límite; por eso su caché de competencia
--     también estaba sin calcular.
--
--     El arreglo respeta el razonamiento que ya estaba escrito en esta
--     función: «para un ranking de 25 empresas, las 1.000 últimas dan
--     el mismo resultado». Lo que se acota es el TOTAL y no el trozo.
--
--     El presupuesto salió de medir EN FRÍO, no a ojo: 3.710 filas
--     costaron 5,57 s con read=3081, o sea ~1,5 ms por fila cuando hay
--     que ir a disco. Un primer intento con 4.000 dejaba solo un 30%
--     de margen sobre los 8 s, y además estrechaba a los perfiles de
--     cuatro prefijos, que hoy calculan sin problema.
--
--     Así que el reparto solo entra a partir de CINCO prefijos:
--
--         n <= 4   1.000 por prefijo, exactamente como antes
--         n = 5      500        n = 12     208
--
--     Ningún perfil que hoy calcula cambia. Los que hoy no calculan
--     nada pasan a calcular algo, que es todo lo que se pide.
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
    cuantos   int;
    n_pref    int;
begin
    select p.id, p.cif,
           array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mi_perfil, mi_cif, prefijos
    from public.perfiles p where p.usuario_id = auth.uid();

    if mi_perfil is null then return; end if;

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

    -- Hasta cuatro prefijos, 1.000 cada uno: es lo que ya había y
    -- cabe de sobra. A partir de ahí se reparte un total de 2.500,
    -- con un suelo de 150 para que un perfil con treinta prefijos
    -- siga viendo algo de cada uno.
    n_pref  := array_length(prefijos, 1);
    cuantos := case when n_pref <= 4 then 1000
                    else greatest(150, (2500 / n_pref)::int) end;

    foreach uno in array prefijos loop
        cola := cola || array(
            select (l.adjudicatario, l.adjudicatario_cif,
                    l.importe_adjudicacion, l.id_licitacion,
                    l.fecha_actualizacion)::fila_competencia
            from public.licitaciones l
            where l.prefijo_principal = uno
              and l.adjudicatario_cif is not null
            order by l.fecha_actualizacion desc
            limit cuantos);
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

grant execute on function public.competencia(integer) to authenticated;

commit;


-- ============================================================
-- QUIÉN LO REFRESCA
-- `lector_atom.py`, al final de cada pasada diaria, en
-- `refrescar_agregado_organismos()`. Una llamada por prefijo. Si falla,
-- avisa en el registro y sigue: la pestaña enseña los datos de ayer,
-- que es mejor que un robot en rojo.
--
-- PENDIENTE, y no lo resuelve esta migración:
-- Un perfil con prefijos de DOS dígitos (p. ej. "72") no encuentra
-- nada, porque se comparan contra `prefijo_principal`, que tiene
-- cuatro. Ya pasaba antes de este cambio —la comparación es la misma—
-- así que no es una regresión, pero sigue ahí. Hoy solo afecta a
-- info@sertoria.com, que está parado en el alta.
-- ============================================================
