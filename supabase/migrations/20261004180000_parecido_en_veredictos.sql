-- ============================================================
-- «Te lo enseñamos porque se parece a…»
-- ============================================================
--
-- Al pulsar «no me interesa», la web dice por qué salió ese contrato:
-- el contrato de su historial que más se le parece. Con NIF, uno que
-- ganó; sin NIF, uno de su historial sintético (adjudicado a otra
-- empresa, parecido a lo que contó). Así el descarte deja de parecer
-- arbitrario y se ve qué corregir.
--
-- No se usa `motivo`, que ya está en la vista: lo escribe el juez y,
-- sin NIF, habla de «contratos ganados» que la empresa no ha ganado.
-- `parecido` lo escribe puntuador.py con los mismos vectores que los
-- ejemplos del juez, sin llamar al modelo, en cada pasada y para todo
-- el grupo (también lo ya juzgado): se rellena en la siguiente pasada.
-- Null con el criterio en prosa, que no tiene historial que comparar.
--
-- ORDEN AL DESPLEGAR: esta migración antes que puntuador.py. Si el
-- puntuador escribe `parecido` sin la columna, falla la escritura.
--
-- La vista: una columna AL FINAL (CREATE OR REPLACE VIEW solo admite
-- añadir al final); las demás y sus filtros, idénticos.
-- ============================================================

alter table public.veredictos add column if not exists parecido text;

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
    v.parecido
   FROM licitaciones l
     JOIN veredictos v ON v.id_licitacion = l.id_licitacion
     JOIN perfiles p ON p.id = v.perfil_id
     LEFT JOIN correcciones c ON c.id_licitacion = l.id_licitacion AND c.perfil_id = p.id
  WHERE p.usuario_id = auth.uid() AND (v.veredicto = ANY (ARRAY['si'::text, 'quizas'::text])) AND COALESCE(l.estado_licitacion, ''::text) = 'PUB'::text AND (l.fecha_limite IS NOT NULL AND l.fecha_limite >= now() OR l.fecha_limite IS NULL AND l.fecha_actualizacion >= (now() - '14 days'::interval)) AND (c.interesa IS NULL OR c.interesa) AND NOT l.sustituida
  ORDER BY (COALESCE(l.fecha_limite, l.fecha_deteccion));
