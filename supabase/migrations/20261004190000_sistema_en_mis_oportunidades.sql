-- ============================================================
-- Contratos: decir cuándo lo abierto es un sistema dinámico o un marco
-- ============================================================
--
-- El problema: en la lista de Contratos un sistema dinámico de
-- adquisición, un acuerdo marco o un contrato basado en un acuerdo marco
-- salían igual que un contrato normal. No lo son:
--   - Sistema dinámico: es inscribirse en un catálogo abierto; entrar no
--     es ganar nada, los encargos llegan después.
--   - Acuerdo marco: se homologa a varias empresas; el dinero llega con
--     los contratos basados en él.
--   - Contrato basado en acuerdo marco: SOLO pueden presentarse las
--     empresas ya homologadas en ese marco. Para el resto no es una
--     oportunidad.
-- El dato ya estaba (`licitaciones.sistema`, lo rellena el scraper),
-- pero la vista no lo daba. En la inteligencia de mercado ya se tratan
-- aparte (20260923140000_marcos_aparte.sql); aquí solo se etiquetan.
--
-- Medido el 04/10/2026 en lo que ven los clientes: 184 sistemas
-- dinámicos (536 filas), 63 acuerdos marco (108) y 15 contratos basados
-- en marco (30), frente a 2.608 contratos (4.750).
--
-- `create or replace view` solo permite añadir columnas AL FINAL: la
-- definición es la de producción del 04/10/2026 (ya con `parecido`, de
-- 20261004180000_parecido_en_veredictos.sql), igual, más `sistema`.
-- Conserva permisos y propietario.
-- ============================================================

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
    l.sistema
   FROM licitaciones l
     JOIN veredictos v ON v.id_licitacion = l.id_licitacion
     JOIN perfiles p ON p.id = v.perfil_id
     LEFT JOIN correcciones c ON c.id_licitacion = l.id_licitacion AND c.perfil_id = p.id
  WHERE p.usuario_id = auth.uid() AND (v.veredicto = ANY (ARRAY['si'::text, 'quizas'::text])) AND COALESCE(l.estado_licitacion, ''::text) = 'PUB'::text AND (l.fecha_limite IS NOT NULL AND l.fecha_limite >= now() OR l.fecha_limite IS NULL AND l.fecha_actualizacion >= (now() - '14 days'::interval)) AND (c.interesa IS NULL OR c.interesa) AND NOT l.sustituida
  ORDER BY (COALESCE(l.fecha_limite, l.fecha_deteccion));
