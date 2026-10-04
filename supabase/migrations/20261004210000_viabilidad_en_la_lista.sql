-- ============================================================
-- El veredicto de Viabilidad en la lista de Contratos
-- ============================================================
--
-- La lista decía qué encaja; ahora dice también dónde se puede ganar:
-- "Tienes opciones", "Difícil", "Parece cerrado" o "Es tuyo", y se puede
-- filtrar por eso.
--
-- Calcularlo al pedir la lista no cabe: `viabilidad()` tarda de 0,2 a 5 s
-- por contrato y una lista tiene cientos. Pero el veredicto NO depende de
-- quién mira, solo del contrato. La única excepción es "Es tuyo" (hay
-- serie y la última convocatoria la ganó tu NIF), que se resuelve en la
-- vista comparando `ultimo_cif` con el NIF del perfil. Así que se calcula
-- una vez por contrato y sirve a todos.
--
-- Qué se guarda:
--   - Los contratos abiertos que están en la lista de alguien (sí o
--     quizás). Medido el 04/10/2026: unos 2.600.
--   - `veredicto`: abierto | dificil | cerrado | sin_datos | error.
--     `sin_datos` es lo que la pantalla de Viabilidad ya avisa como "no
--     hay datos suficientes" (sin reparto de la puntuación ni
--     adjudicaciones anteriores): en la lista no se pinta, porque
--     "Tienes opciones" ahí no estaría respaldado. `error` tampoco.
--   - Se recalcula a los 7 días: las adjudicaciones nuevas cambian el
--     veredicto despacio. Lo que deja de estar abierto se borra a los 30.
--
-- Quién lo rellena: `refrescar_viabilidad_guardada()` por `pg_cron`, cada
-- 10 minutos y con un tope de 100 s por pasada, primero lo que no tiene
-- veredicto. La primera vez tarda unas horas en completar; después, cada
-- pasada solo ve lo que ha entrado nuevo.
-- ============================================================


-- ------------------------------------------------------------
-- (1) La tabla
-- ------------------------------------------------------------
create table if not exists public.viabilidad_guardada (
    id_licitacion text primary key,
    veredicto     text not null,
    serie         boolean not null default false,
    ultimo_cif    text,
    calculada     timestamptz not null default now()
);

-- Solo la leen la vista y la función, que corren como propietario.
alter table public.viabilidad_guardada enable row level security;
revoke all on public.viabilidad_guardada from anon, authenticated;


-- ------------------------------------------------------------
-- (2) Quién la rellena
-- ------------------------------------------------------------
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
    -- Lo que ya no está abierto deja de recalcularse; a los 30 días, fuera.
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
        -- Primero lo que no tiene veredicto, y de eso lo que cierra antes.
        order by g.calculada nulls first, l.fecha_limite nulls last
        limit 3000
    loop
        exit when clock_timestamp() > fin;
        begin
            v := public.viabilidad(r.id_licitacion);
            ver := case v->>'veredicto'
                       when 'difícil' then 'dificil'
                       else v->>'veredicto' end;
            -- Lo mismo que la pantalla avisa como "no hay datos
            -- suficientes": sin reparto de la puntuación y sin
            -- adjudicaciones anteriores.
            if ver = 'abierto'
               and coalesce((v->'contrato'->>'peso_objetivo')::int, 0) = 0
               and coalesce((v->'incumbencia'->>'ediciones')::int, 0) = 0 then
                ver := 'sin_datos';
            end if;
            insert into public.viabilidad_guardada as g
                   (id_licitacion, veredicto, serie, ultimo_cif, calculada)
            values (r.id_licitacion, coalesce(ver, 'error'),
                    coalesce((v->'incumbencia'->>'por_convocatoria')::boolean, false),
                    v->'incumbencia'->'ultimo'->>'cif', now())
            on conflict (id_licitacion) do update
               set veredicto = excluded.veredicto, serie = excluded.serie,
                   ultimo_cif = excluded.ultimo_cif, calculada = excluded.calculada;
        exception when others then
            -- Uno que falla no para la pasada, y no se reintenta en cada
            -- una: queda como error hasta dentro de 7 días.
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

revoke execute on function public.refrescar_viabilidad_guardada(integer) from public, anon, authenticated;


-- ------------------------------------------------------------
-- (3) Cada 10 minutos
-- ------------------------------------------------------------
select cron.schedule('refrescar-viabilidad-guardada', '*/10 * * * *',
                     'select public.refrescar_viabilidad_guardada(100)');


-- ------------------------------------------------------------
-- (4) La vista de la lista, con `viabilidad` al final
-- ------------------------------------------------------------
-- La definición de producción del 04/10/2026
-- (20261004190000_sistema_en_mis_oportunidades.sql), igual, más la
-- columna. Sin veredicto calculado todavía, o sin datos, sale null y la
-- web no pinta nada.
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
    EXTRACT(day FROM now() - COALESCE(l.ultima_verificacion, l.fecha_actualizacion, l.fecha_deteccion))::integer AS dias_sin_verificar,
    l.duracion_meses,
    l.prorrogas_texto,
    l.presupuesto_base,
    v.parecido,
    l.sistema,
    CASE
        WHEN g.veredicto IS NULL OR g.veredicto = ANY (ARRAY['sin_datos'::text, 'error'::text]) THEN NULL::text
        WHEN g.serie AND p.cif IS NOT NULL AND g.ultimo_cif = p.cif THEN 'mio'::text
        ELSE g.veredicto
    END AS viabilidad
   FROM licitaciones l
     JOIN veredictos v ON v.id_licitacion = l.id_licitacion
     JOIN perfiles p ON p.id = v.perfil_id
     LEFT JOIN correcciones c ON c.id_licitacion = l.id_licitacion AND c.perfil_id = p.id
     LEFT JOIN viabilidad_guardada g ON g.id_licitacion = l.id_licitacion
  WHERE p.usuario_id = auth.uid() AND (v.veredicto = ANY (ARRAY['si'::text, 'quizas'::text])) AND COALESCE(l.estado_licitacion, ''::text) = 'PUB'::text AND (l.fecha_limite IS NOT NULL AND l.fecha_limite >= now() OR l.fecha_limite IS NULL AND l.fecha_actualizacion >= (now() - '14 days'::interval)) AND (c.interesa IS NULL OR c.interesa) AND NOT l.sustituida
  ORDER BY (COALESCE(l.fecha_limite, l.fecha_deteccion));
