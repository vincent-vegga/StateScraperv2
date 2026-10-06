-- ============================================================
-- Qué piden, también en la lista de Contratos (Decisión 54)
-- ============================================================
--
-- La ficha dice todo lo que piden (`requisitos`). En la fila solo se marca
-- lo que cambia la decisión de un vistazo, como hace Viabilidad con
-- "Difícil" y "Parece cerrado":
--
--   clasificacion  exigen clasificación (obligatoria). Para todos.
--   facturacion    con NIF: piden un volumen de negocios por encima de lo
--                  que la empresa gana en contratos públicos. La fila dice
--                  la cifra ("Piden facturar 2,3 M€ al año"), no un
--                  veredicto: lo privado no lo vemos.
--
-- No se marca lo que se cumple: con NIF, 79 de 94 contratos con importe
-- exigido lo cumplen solo con contratos públicos (medido el 06/10/2026), y
-- una marca en el 85 % de las filas no avisaría de nada. La solvencia
-- técnica tampoco: "trabajos parecidos" por las tres primeras cifras del
-- CPV es estricto y saldría "compruébalo" en 3 de cada 5.
--
-- Como `viabilidad_guardada`: una tabla que rellena `pg_cron` cada 10
-- minutos con un tope de tiempo. Calcular `requisitos_de` (20-40 ms) por
-- fila en la vista no cabe en el corte de 8 s con listas de 800.
-- ============================================================

create table if not exists public.requisitos_guardados (
    perfil_id     uuid not null,
    id_licitacion text not null,
    marca         text,                     -- clasificacion | facturacion | null
    pide          numeric,                  -- el volumen exigido, si marca = facturacion
    actualizado   timestamptz not null default now(),
    primary key (perfil_id, id_licitacion)
);

alter table public.requisitos_guardados enable row level security;
revoke all on public.requisitos_guardados from anon, authenticated;


-- La marca a partir de lo que devuelve `requisitos_de`.
create or replace function public.marca_requisitos(r jsonb)
returns table (marca text, pide numeric)
language sql
immutable
as $function$
    select case
               when jsonb_typeof(r->'clasificacion') = 'array'
                    and coalesce((r->>'clasificacion_obligatoria')::boolean, false)
                   then 'clasificacion'
               when exists (select 1 from jsonb_array_elements(coalesce(r->'comprobar', '[]'::jsonb)) c
                            where c->>'que' = 'economica' and c->>'estado' = 'revisar')
                   then 'facturacion'
           end,
           (select (c->>'pide')::numeric
            from jsonb_array_elements(coalesce(r->'comprobar', '[]'::jsonb)) c
            where c->>'que' = 'economica' and c->>'estado' = 'revisar' limit 1)
$function$;


-- Rellena lo que falta o ha cambiado desde la última vez (lectura nueva,
-- condiciones releídas), primero lo que vence antes, hasta `segundos`.
-- Borra lo que ya no está abierto o ya no está en la lista.
create or replace function public.refrescar_requisitos_guardados(segundos integer default 100)
returns integer
language plpgsql
security definer
set search_path to 'public'
set statement_timeout to '300s'
as $function$
declare
    fin   timestamptz := clock_timestamp() + make_interval(secs => segundos);
    par   record;
    m     record;
    n     int := 0;
begin
    delete from public.requisitos_guardados g
    where not exists (
        select 1 from public.veredictos v
        join public.licitaciones l on l.id_licitacion = v.id_licitacion
        where v.perfil_id = g.perfil_id and v.id_licitacion = g.id_licitacion
          and v.veredicto in ('si', 'quizas')
          and coalesce(l.estado_licitacion, '') = 'PUB'
          and l.fecha_limite >= now());

    for par in
        select v.perfil_id, v.id_licitacion
        from public.veredictos v
        join public.licitaciones l on l.id_licitacion = v.id_licitacion
        join public.condiciones c on c.id_licitacion = v.id_licitacion
        left join public.requisitos_guardados g
               on g.perfil_id = v.perfil_id and g.id_licitacion = v.id_licitacion
        where v.veredicto in ('si', 'quizas')
          and coalesce(l.estado_licitacion, '') = 'PUB'
          and l.fecha_limite >= now()
          and not coalesce(l.sustituida, false)
          and (g.actualizado is null
               or g.actualizado < greatest(c.leido, coalesce(c.lectura_fecha, c.leido))
               -- lo que gana la empresa cambia despacio: una vez por semana
               or g.actualizado < now() - interval '7 days')
        order by g.actualizado nulls first, l.fecha_limite
    loop
        exit when clock_timestamp() > fin;
        select * into m from public.marca_requisitos(
            public.requisitos_de(par.id_licitacion, par.perfil_id));
        insert into public.requisitos_guardados as g
            (perfil_id, id_licitacion, marca, pide, actualizado)
        values (par.perfil_id, par.id_licitacion, m.marca, m.pide, now())
        on conflict (perfil_id, id_licitacion) do update
            set marca = excluded.marca, pide = excluded.pide,
                actualizado = excluded.actualizado;
        n := n + 1;
    end loop;
    return n;
end
$function$;

revoke execute on function public.refrescar_requisitos_guardados(integer) from public, anon, authenticated;
grant execute on function public.refrescar_requisitos_guardados(integer) to service_role;

select cron.schedule('refrescar-requisitos-guardados', '5-59/10 * * * *',
                     $$select public.refrescar_requisitos_guardados(100)$$);


-- ---------- La vista de la lista: una columna más, al final ----------
--
-- Definición tomada de producción con `pg_get_viewdef` el 06/10/2026
-- (la han redefinido varias sesiones; ver el traspaso de
-- `docs/competencia/LEEME.md`). Solo se añade `requisitos` al final.
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
            WHEN g.veredicto IS NULL OR (g.veredicto = ANY (ARRAY['sin_datos'::text, 'error'::text])) THEN NULL::text
            WHEN g.serie AND p.cif IS NOT NULL AND g.ultimo_cif = p.cif THEN 'mio'::text
            ELSE g.veredicto
        END AS viabilidad,
        CASE
            WHEN rg.marca IS NOT NULL THEN jsonb_build_object('marca', rg.marca, 'pide', rg.pide)
        END AS requisitos
   FROM licitaciones l
     JOIN veredictos v ON v.id_licitacion = l.id_licitacion
     JOIN perfiles p ON p.id = v.perfil_id
     LEFT JOIN correcciones c ON c.id_licitacion = l.id_licitacion AND c.perfil_id = p.id
     LEFT JOIN viabilidad_guardada g ON g.id_licitacion = l.id_licitacion
     LEFT JOIN requisitos_guardados rg ON rg.perfil_id = p.id AND rg.id_licitacion = l.id_licitacion
  WHERE p.usuario_id = auth.uid() AND (v.veredicto = ANY (ARRAY['si'::text, 'quizas'::text])) AND COALESCE(l.estado_licitacion, ''::text) = 'PUB'::text AND (l.fecha_limite IS NOT NULL AND l.fecha_limite >= now() OR l.fecha_limite IS NULL AND l.fecha_actualizacion >= (now() - '14 days'::interval)) AND (c.interesa IS NULL OR c.interesa) AND NOT l.sustituida
  ORDER BY (COALESCE(l.fecha_limite, l.fecha_deteccion));
