-- ============================================================
-- Ganadores fantasma: expedientes desiertos con el ganador de una
-- versión anterior
-- ============================================================
--
-- Encontrado el 04/10/2026 al revisar `sin_contrato` (decisión 44): 638
-- expedientes tenían todos los lotes sin ganador pero conservaban
-- `adjudicatario`, `adjudicatario_cif` e importe en la columna principal.
-- Comprobados cinco en la Plataforma: tres desiertos (uno "se niega a
-- firmar el contrato", otro con "Rectificación de Adjudicación"), una
-- renuncia y una anulación de lotes. Contaban en todas las pantallas de
-- mercado: 391 M€ que nunca se contrataron (Viajes El Corte Inglés,
-- 1,2 M€, en un contrato desierto).
--
-- La causa: el histórico se procesa por meses y `completar_explicacion`
-- aplica la versión más nueva, pero con `coalesce(nuevo, viejo)`. Si la
-- versión nueva dice "desierto", no trae ganador (null) y se quedaba el
-- de la versión adjudicada anterior, mientras `adjudicaciones` sí pasaba
-- a la nueva. Todos venían del histórico; el feed escribe todos los
-- campos y no tiene el fallo.
--
-- Arreglo: si la versión nueva trae lotes y ninguno acaba en contrato
-- (`sin_contrato`), el ganador, el NIF, los importes y el número de
-- adjudicatarios se vacían. En los demás casos, nada cambia.
-- ============================================================

set local statement_timeout = '300s';

create or replace function public.completar_explicacion(datos jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    tocadas int;
begin
    update public.licitaciones l
    set procedimiento = coalesce(l.procedimiento, d.procedimiento),
        urgencia = coalesce(l.urgencia, d.urgencia),
        licitadores = case when d.nueva then coalesce(d.licitadores, l.licitadores)
                           else coalesce(l.licitadores, d.licitadores) end,
        lotes = greatest(coalesce(l.lotes, 0), coalesce(d.lotes, 0)),
        adjudicaciones = case
            when jsonb_array_length(d.adjudicaciones) > 0
                 and (d.nueva or jsonb_array_length(coalesce(l.adjudicaciones, '[]'::jsonb)) = 0)
            then d.adjudicaciones
            else l.adjudicaciones end,
        adjudicatarios = case when d.vacia then 0
                              when d.nueva then coalesce(d.adjudicatarios, l.adjudicatarios)
                              else greatest(coalesce(l.adjudicatarios, 0),
                                            coalesce(d.adjudicatarios, 0)) end,
        -- El importe es la SUMA de los lotes (o nada, en un acuerdo marco
        -- con varios): lo decide el lector. Manda la versión más nueva.
        importe_adjudicacion = case when d.vacia then null
                                    when d.nueva then coalesce(d.importe, l.importe_adjudicacion)
                                    else coalesce(l.importe_adjudicacion, d.importe) end,
        adjudicatario = case when d.vacia then null
                             when d.nueva then coalesce(d.adjudicatario, l.adjudicatario)
                             else coalesce(l.adjudicatario, d.adjudicatario) end,
        adjudicatario_cif = case when d.vacia then null
                                 when d.nueva then coalesce(d.cif, l.adjudicatario_cif)
                                 else coalesce(l.adjudicatario_cif, d.cif) end,
        presupuesto_base = coalesce(d.presupuesto_base, l.presupuesto_base),
        valor_estimado = coalesce(d.valor_estimado, l.valor_estimado),
        importe_sin_iva = case when d.vacia then null
                               when d.nueva then coalesce(d.importe_sin_iva, l.importe_sin_iva)
                               else coalesce(l.importe_sin_iva, d.importe_sin_iva) end,
        oferta_baja = coalesce(d.oferta_baja, l.oferta_baja),
        oferta_alta = coalesce(d.oferta_alta, l.oferta_alta),
        motivo_adjudicacion = coalesce(l.motivo_adjudicacion, d.motivo),
        fecha_adjudicacion = case when d.nueva then coalesce(d.fecha, l.fecha_adjudicacion)
                                  else coalesce(l.fecha_adjudicacion, d.fecha) end,
        fecha_formalizacion = case when d.nueva then coalesce(d.formalizacion, l.fecha_formalizacion)
                                   else coalesce(l.fecha_formalizacion, d.formalizacion) end,
        gano_pyme = coalesce(l.gano_pyme, d.pyme),
        sistema = coalesce(l.sistema, d.sistema),
        -- El territorio del agregado autonómico, que no publica código
        -- postal. Se asigna aquí y el disparador lo traduce a provincia
        -- y comunidad.
        nuts = coalesce(l.nuts, d.nuts),
        -- El reparto de puntuación entre fórmula y juicio de valor.
        peso_objetivo = coalesce(l.peso_objetivo, d.peso_objetivo),
        peso_subjetivo = coalesce(l.peso_subjetivo, d.peso_subjetivo),
        criterios = coalesce(l.criterios, d.criterios),
        fecha_actualizacion = case when d.nueva then d.actualizada
                                   else l.fecha_actualizacion end,
        estado_licitacion = case when d.nueva then coalesce(d.estado, l.estado_licitacion)
                                 else l.estado_licitacion end,
        -- Una versión formalizada anterior a lo que ya sabíamos adelanta
        -- la fecha estimada (el disparador la calcula solo con la versión
        -- que queda guardada).
        fecha_formalizacion_estimada = case
            when d.estado = 'RES' and d.actualizada is not null
            then least(l.fecha_formalizacion_estimada,
                       (d.actualizada at time zone 'Europe/Madrid')::date)
            else l.fecha_formalizacion_estimada end
    from (
        select z.*,
               -- La versión nueva dice que no hubo contrato: manda sobre
               -- el ganador de una versión anterior (desierta tras
               -- adjudicarse, renuncia, anulación).
               z.nueva and jsonb_array_length(z.adjudicaciones) > 0
               and public.sin_contrato(z.adjudicaciones) is not null as vacia
        from (
        select x.*,
               x.actualizada is not null
               and x.actualizada >= coalesce(l2.fecha_actualizacion, '-infinity') as nueva
        from (
            select y->>'id' as id,
                   nullif(y->>'procedimiento', '') as procedimiento,
                   nullif(y->>'urgencia', '') as urgencia,
                   (nullif(y->>'licitadores', ''))::int as licitadores,
                   (nullif(y->>'lotes', ''))::int as lotes,
                   coalesce(y->'adjudicaciones', '[]'::jsonb) as adjudicaciones,
                   (nullif(y->>'adjudicatarios', ''))::int as adjudicatarios,
                   (nullif(y->>'importe', ''))::numeric as importe,
                   nullif(y->>'adjudicatario', '') as adjudicatario,
                   nullif(y->>'cif', '') as cif,
                   (nullif(y->>'presupuesto_base', ''))::numeric as presupuesto_base,
                   (nullif(y->>'valor_estimado', ''))::numeric as valor_estimado,
                   (nullif(y->>'importe_sin_iva', ''))::numeric as importe_sin_iva,
                   (nullif(y->>'oferta_baja', ''))::numeric as oferta_baja,
                   (nullif(y->>'oferta_alta', ''))::numeric as oferta_alta,
                   nullif(y->>'motivo_adjudicacion', '') as motivo,
                   (nullif(y->>'fecha_adjudicacion', ''))::date as fecha,
                   (nullif(y->>'fecha_formalizacion', ''))::date as formalizacion,
                   (nullif(y->>'gano_pyme', ''))::boolean as pyme,
                   nullif(y->>'sistema', '') as sistema,
                   nullif(y->>'nuts', '') as nuts,
                   (nullif(y->>'peso_objetivo', ''))::int as peso_objetivo,
                   (nullif(y->>'peso_subjetivo', ''))::int as peso_subjetivo,
                   case when coalesce(y->>'criterios', '') <> ''
                        then (y->>'criterios')::jsonb else null end as criterios,
                   (nullif(y->>'fecha_actualizacion', ''))::timestamptz as actualizada,
                   nullif(y->>'estado', '') as estado
            from jsonb_array_elements(datos) as y
        ) x
        join public.licitaciones l2 on l2.id_licitacion = x.id
        ) z
    ) d
    where l.id_licitacion = d.id;

    get diagnostics tocadas = row_count;
    return tocadas;
end;
$function$;


-- ------------------------------------------------------------
-- Limpieza de los que ya están guardados
-- ------------------------------------------------------------
-- Los lotes son de la versión más nueva (`completar_explicacion` solo los
-- reemplaza con una versión igual o más reciente), así que si ninguno
-- acaba en contrato, el ganador de la columna principal es de antes. El
-- disparador `sincronizar_adjudicaciones_empresa` borra sus filas.
update public.licitaciones
set adjudicatario = null,
    adjudicatario_cif = null,
    importe_adjudicacion = null,
    importe_sin_iva = null,
    adjudicatarios = 0
where adjudicatario_cif is not null
  and jsonb_typeof(adjudicaciones) = 'array'
  and jsonb_array_length(adjudicaciones) > 0
  and public.sin_contrato(adjudicaciones) is not null;
