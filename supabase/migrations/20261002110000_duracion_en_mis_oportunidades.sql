-- ============================================================
-- Contratos abiertos: duración, prórrogas y base de licitación
-- ============================================================
--
-- La duración es de lo más útil para decidir si presentarse: no es lo
-- mismo un servicio a 1 año que a 12. Se añaden tres columnas AL FINAL
-- de la vista (CREATE OR REPLACE VIEW solo admite añadir al final);
-- las existentes y sus filtros quedan idénticos.
--
--   duracion_meses     null si el organismo no la publicó
--   prorrogas_texto    texto libre del organismo, sin interpretar
--   presupuesto_base   base de licitación sin IVA; `presupuesto` es el
--                      valor estimado, que ya incluye las prórrogas
--
-- Respaldo de la definición anterior en
-- `respaldo_vistas_duracion_20261002`.
-- ============================================================

create table if not exists public.respaldo_vistas_duracion_20261002 as
select 'mis_oportunidades'::text as nombre,
       pg_get_viewdef('public.mis_oportunidades'::regclass, true) as definicion,
       now() as guardado;

alter table public.respaldo_vistas_duracion_20261002 enable row level security;
revoke all on public.respaldo_vistas_duracion_20261002 from anon, authenticated;

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
    l.presupuesto_base
   FROM licitaciones l
     JOIN veredictos v ON v.id_licitacion = l.id_licitacion
     JOIN perfiles p ON p.id = v.perfil_id
     LEFT JOIN correcciones c ON c.id_licitacion = l.id_licitacion AND c.perfil_id = p.id
  WHERE p.usuario_id = auth.uid() AND (v.veredicto = ANY (ARRAY['si'::text, 'quizas'::text])) AND COALESCE(l.estado_licitacion, ''::text) = 'PUB'::text AND (l.fecha_limite IS NOT NULL AND l.fecha_limite >= now() OR l.fecha_limite IS NULL AND l.fecha_actualizacion >= (now() - '14 days'::interval)) AND (c.interesa IS NULL OR c.interesa) AND NOT l.sustituida
  ORDER BY (COALESCE(l.fecha_limite, l.fecha_deteccion));
