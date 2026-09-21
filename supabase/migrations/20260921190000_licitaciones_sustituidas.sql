-- ============================================================
-- UNA LICITACIÓN REPUBLICADA NO SALE DOS VECES
-- ============================================================
--
-- Aplicada el 21/09/2026. El índice idx_licitaciones_organo_expediente
-- se creó aparte, con CONCURRENTLY, para no bloquear escrituras:
--
--   create index concurrently if not exists idx_licitaciones_organo_expediente
--       on public.licitaciones (organo, expediente);
--
-- EL FALLO
-- Las plataformas republican el mismo expediente con otro identificador
-- de sindicación. Se guardaban las dos copias: 73 contratos abiertos
-- salían dos veces en la lista, y en toda la tabla había 657 copias
-- viejas. Y la vieja no es inofensiva: se queda con los datos de su día.
-- El ACPC-2026-1693 aparecía con plazo el 21/09 en la copia vieja y el
-- 28/09 en la nueva; un cliente podía darlo por vencido estando abierto.
--
-- Medido sobre las 73 parejas abiertas: todas son el mismo contrato.
-- Ninguna tiene tres copias, 7 cambian el plazo, y la única con importes
-- distintos es el mismo contrato con y sin IVA (61.000 / 73.200 €).
--
-- LA REGLA
-- Por órgano y expediente vale la copia con la actualización más
-- reciente (y, a igualdad, el identificador mayor, que es el posterior).
-- Las demás quedan `sustituida = true` y no se enseñan, no se criban y
-- no se mandan por correo. No se borran: siguen ahí por si hiciera falta.
--
-- Si la copia nueva ya no está abierta (adjudicada, anulada), la vieja
-- tampoco debe salir como abierta; por eso la regla no mira el estado.
--
-- NO se tocan los agregados de adjudicaciones (Movimientos, Organismos,
-- Empresas): ahí una adjudicación republicada puede contar dos veces.
-- Queda anotado para revisarlo con ellos.
-- ============================================================

set local statement_timeout = '10min';

alter table public.licitaciones
    add column if not exists sustituida boolean not null default false;

comment on column public.licitaciones.sustituida is
  'Hay otra licitación del mismo órgano y expediente más reciente: esta es '
  'una copia vieja de una republicación y no se enseña.';

-- ------------------------------------------------------------
-- El disparador
-- ------------------------------------------------------------
--
-- AFTER y solo sobre las columnas que deciden la regla. Las
-- actualizaciones de dentro tocan únicamente `sustituida`, que no está
-- en la lista, así que no se llama a sí mismo.
create or replace function public.marcar_sustituidas()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    hay_mas_nueva boolean;
begin
    if coalesce(new.expediente, '') = '' or coalesce(new.organo, '') = '' then
        return null;
    end if;

    -- Las copias más viejas que esta quedan sustituidas.
    update public.licitaciones l
       set sustituida = true
     where l.organo = new.organo
       and l.expediente = new.expediente
       and l.id_licitacion <> new.id_licitacion
       and not l.sustituida
       and (coalesce(l.fecha_actualizacion, '-infinity'::timestamptz), l.id_licitacion)
         < (coalesce(new.fecha_actualizacion, '-infinity'::timestamptz), new.id_licitacion);

    -- Y esta, si ya había una más nueva; si no, se asegura de que no lo
    -- esté (por si una actualización la ha convertido en la más reciente).
    -- Solo se escribe si cambia: el scraper refresca miles de filas cada
    -- mañana y reescribirlas todas para dejarlas igual doblaría el coste.
    select exists (
               select 1 from public.licitaciones o
               where o.organo = new.organo
                 and o.expediente = new.expediente
                 and o.id_licitacion <> new.id_licitacion
                 and (coalesce(o.fecha_actualizacion, '-infinity'::timestamptz), o.id_licitacion)
                   > (coalesce(new.fecha_actualizacion, '-infinity'::timestamptz), new.id_licitacion))
      into hay_mas_nueva;

    if hay_mas_nueva is distinct from new.sustituida then
        update public.licitaciones l
           set sustituida = hay_mas_nueva
         where l.id_licitacion = new.id_licitacion;
    end if;

    return null;
end;
$function$;

revoke execute on function public.marcar_sustituidas() from public, anon, authenticated;

drop trigger if exists trg_sustituidas on public.licitaciones;
create trigger trg_sustituidas
    after insert or update of fecha_actualizacion, expediente, organo
    on public.licitaciones
    for each row execute function public.marcar_sustituidas();

-- ------------------------------------------------------------
-- Las que ya estaban
-- ------------------------------------------------------------
update public.licitaciones l
   set sustituida = true
  from (
      select id_licitacion,
             row_number() over (partition by organo, expediente
                                order by coalesce(fecha_actualizacion, '-infinity'::timestamptz) desc,
                                         id_licitacion desc) as rn
      from public.licitaciones
      where coalesce(expediente, '') <> '' and coalesce(organo, '') <> ''
  ) x
 where x.id_licitacion = l.id_licitacion
   and x.rn > 1
   and not l.sustituida;

-- ------------------------------------------------------------
-- Donde se leen los contratos abiertos
-- ------------------------------------------------------------

-- La lista de la web.
create or replace view public.mis_oportunidades as
 SELECT v.perfil_id,
    l.id_licitacion,
    l.titulo,
    l.organo,
    l.origen,
    l.codigo_postal,
    l.provincia,
    l.comunidad,
    l.sector,
    l.presupuesto,
    l.cpvs,
    l.enlace,
    l.fecha_limite,
    l.fecha_publicacion,
    l.fecha_deteccion,
    v.veredicto,
    v.motivo AS veredicto_motivo,
    p.ultima_visita IS NULL OR l.fecha_deteccion > p.ultima_visita AS es_novedad,
    c.interesa AS correccion,
    EXTRACT(day FROM now() - COALESCE(l.ultima_verificacion, l.fecha_actualizacion, l.fecha_deteccion))::integer AS dias_sin_verificar
   FROM licitaciones l
     JOIN veredictos v ON v.id_licitacion = l.id_licitacion
     JOIN perfiles p ON p.id = v.perfil_id
     LEFT JOIN correcciones c ON c.id_licitacion = l.id_licitacion AND c.perfil_id = p.id
  WHERE p.usuario_id = auth.uid() AND (v.veredicto = ANY (ARRAY['si'::text, 'quizas'::text])) AND COALESCE(l.estado_licitacion, ''::text) = 'PUB'::text AND (l.fecha_limite IS NOT NULL AND l.fecha_limite >= now() OR l.fecha_limite IS NULL AND l.fecha_actualizacion >= (now() - '14 days'::interval)) AND (c.interesa IS NULL OR c.interesa)
    AND NOT l.sustituida
  ORDER BY (COALESCE(l.fecha_limite, l.fecha_deteccion));

-- El recuento de "Mi cuenta", que tiene que cuadrar con la lista.
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
              and not l.sustituida
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

-- La pantalla de viabilidad (hoy escondida).
create or replace function public.analizables(texto text default '', organo_filtro text default '')
returns table(id_licitacion text, titulo text, organo text, provincia text, presupuesto numeric, fecha_limite timestamp with time zone, veredicto text)
language sql
stable security definer
set search_path to 'public'
as $function$
    select l.id_licitacion, l.titulo, l.organo, l.provincia,
           coalesce(l.presupuesto_base, l.presupuesto), l.fecha_limite,
           v.veredicto
    from public.veredictos v
    join public.licitaciones l on l.id_licitacion = v.id_licitacion
    join public.perfiles p on p.id = v.perfil_id
    left join public.correcciones c
      on c.id_licitacion = l.id_licitacion and c.perfil_id = p.id
    where p.usuario_id = auth.uid()
      and v.veredicto in ('si', 'quizas')
      and coalesce(l.estado_licitacion, '') = 'PUB'
      -- La misma condición que `mis_oportunidades`, palabra por
      -- palabra: si las dos pantallas no cuentan igual, una miente.
      and ((l.fecha_limite is not null and l.fecha_limite >= now())
           or (l.fecha_limite is null
               and l.fecha_actualizacion >= now() - interval '14 days'))
      -- Y lo que el cliente ha descartado no vuelve a ofrecerse.
      and (c.interesa is null or c.interesa)
      and not l.sustituida
      and (coalesce(texto, '') = '' or l.titulo ilike '%' || texto || '%')
      and (coalesce(organo_filtro, '') = '' or l.organo = organo_filtro)
    order by coalesce(l.fecha_limite, l.fecha_deteccion)
    limit 100;
$function$;

-- El correo diario.
create or replace function public.novedades_de_perfil(perfil uuid, horas integer default 26)
returns table(id_licitacion text, titulo text, organo text, provincia text, codigo_postal text, presupuesto numeric, enlace text, fecha_limite timestamp with time zone, veredicto text, motivo text)
language sql
stable security definer
set search_path to 'public'
as $function$
    select l.id_licitacion, l.titulo, l.organo, l.provincia, l.codigo_postal,
           l.presupuesto, l.enlace, l.fecha_limite, v.veredicto, v.motivo
    from public.licitaciones l
    join public.veredictos v
      on v.id_licitacion = l.id_licitacion and v.perfil_id = perfil
    left join public.correcciones c
      on c.id_licitacion = l.id_licitacion and c.perfil_id = perfil
    where v.veredicto in ('si', 'quizas')
      and coalesce(l.estado_licitacion, '') = 'PUB'
      and (l.fecha_limite is null or l.fecha_limite >= now())
      -- Lo descartado por el cliente no se le vuelve a mandar.
      and (c.interesa is null or c.interesa)
      and not l.sustituida
      -- Novedad: capturado en la última pasada. La ventana es algo mayor
      -- que un día para absorber los retrasos del cron.
      and l.fecha_deteccion >= now() - (horas || ' hours')::interval
    order by l.fecha_limite asc nulls last;
$function$;

-- La cola de cribado: no se gasta modelo en copias viejas.
create or replace function public.pendientes_de_perfil(perfil uuid, tope integer default 300)
returns table(id_licitacion text, titulo text, organo text, presupuesto numeric, cpvs jsonb, enlace text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    -- NO `prefijos`: la tabla tiene una columna con ese nombre y la
    -- referencia resulta ambigua.
    mis_pref text[];
begin
    if not public.perfil_permitido(perfil) then
        return;
    end if;

    select array(select trim(x) from unnest(
               string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
             where trim(x) <> '')
      into mis_pref
    from public.perfiles p
    where p.id = perfil and p.activo and p.criterio is not null;

    if mis_pref is null or array_length(mis_pref, 1) is null then
        return;
    end if;

    -- ORDEN DE FILTRADO: primero las vivas (idx_licitaciones_vivas_pref),
    -- luego los prefijos sobre ese conjunto pequeño. La CTE es
    -- MATERIALIZED a propósito: sin eso el planificador vuelve a colar el
    -- GIN de prefijos dentro y se pierde todo (ver
    -- 20260920140200_pendientes_de_perfil_rapida.sql).
    return query
    with vivas as materialized (
        select l.id_licitacion, l.fecha_limite, l.prefijos, l.sustituida
        from public.licitaciones l
        where coalesce(l.estado_licitacion, '') = 'PUB'
          and coalesce(l.fecha_limite, 'infinity'::timestamptz) >= now()
    ),
    elegidas as (
        select v.id_licitacion, v.fecha_limite
        from vivas v
        where v.prefijos && mis_pref
          and not v.sustituida
          and not exists (
              select 1 from public.veredictos w
              where w.perfil_id = perfil and w.id_licitacion = v.id_licitacion)
        order by v.fecha_limite asc nulls last
        limit tope
    )
    select l.id_licitacion, l.titulo, l.organo, l.presupuesto, l.cpvs, l.enlace
    from elegidas e
    join public.licitaciones l on l.id_licitacion = e.id_licitacion
    order by e.fecha_limite asc nulls last;
end;
$function$;
