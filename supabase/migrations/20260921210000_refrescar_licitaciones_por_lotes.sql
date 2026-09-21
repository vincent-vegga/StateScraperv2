-- ============================================================
-- REFRESCAR LAS LICITACIONES CONOCIDAS POR LOTES
-- ============================================================
--
-- Aplicada el 21/09/2026.
--
-- EL PROBLEMA, medido en la pasada del 20/09/2026
-- El scraper refresca las licitaciones que ya conoce con un PATCH por
-- fila: 5.914 peticiones, 229 ms de media, 22,6 minutos de tiempo en la
-- base y unos 28 de reloj. De los 38,5 minutos del paso, la mayor parte.
-- Casi todo ese tiempo es coste fijo de cada petición: dentro de
-- Postgres, 200 filas en un solo UPDATE tardan 3,1 s (15 ms por fila).
--
-- LA SOLUCIÓN
-- Esta función recibe un lote de filas en JSON y las actualiza de una
-- vez. Actualiza EXACTAMENTE las mismas columnas que el PATCH de
-- refrescar_conocidas (lector_atom.py), y convierte los tipos igual:
-- PostgREST usa por dentro jsonb_populate_recordset, que es lo que se
-- usa aquí. Una clave que llega con null deja la columna a null, igual
-- que el PATCH.
--
-- Es UPDATE y no upsert por la misma razón que el PATCH: PostgreSQL
-- comprueba los NOT NULL de la fila propuesta antes de ver el
-- conflicto, y estas filas no traen `fuente` ni `titulo`.
--
-- Solo para el rol de servicio, que es el del scraper. Si falta o falla,
-- el scraper vuelve solo al PATCH fila a fila.
-- ============================================================

create or replace function public.refrescar_licitaciones(filas jsonb)
returns integer
language plpgsql
set search_path to 'public'
as $function$
declare
    n integer;
begin
    if filas is null or jsonb_typeof(filas) <> 'array'
       or jsonb_array_length(filas) = 0 then
        return 0;
    end if;

    update public.licitaciones l
       set estado_licitacion    = r.estado_licitacion,
           estado_nombre        = r.estado_nombre,
           fecha_limite         = r.fecha_limite,
           presupuesto          = r.presupuesto,
           procedimiento        = r.procedimiento,
           urgencia             = r.urgencia,
           licitadores          = r.licitadores,
           lotes                = r.lotes,
           adjudicaciones       = r.adjudicaciones,
           adjudicatarios       = r.adjudicatarios,
           presupuesto_base     = r.presupuesto_base,
           valor_estimado       = r.valor_estimado,
           sistema              = r.sistema,
           peso_objetivo        = r.peso_objetivo,
           peso_subjetivo       = r.peso_subjetivo,
           criterios            = r.criterios,
           adjudicatario        = r.adjudicatario,
           adjudicatario_cif    = r.adjudicatario_cif,
           importe_sin_iva      = r.importe_sin_iva,
           importe_adjudicacion = r.importe_adjudicacion,
           oferta_baja          = r.oferta_baja,
           oferta_alta          = r.oferta_alta,
           motivo_adjudicacion  = r.motivo_adjudicacion,
           fecha_adjudicacion   = r.fecha_adjudicacion,
           gano_pyme            = r.gano_pyme,
           ultima_verificacion  = r.ultima_verificacion,
           fecha_actualizacion  = r.fecha_actualizacion
      from jsonb_populate_recordset(null::public.licitaciones, filas) r
     where l.id_licitacion = r.id_licitacion;

    get diagnostics n = row_count;
    return n;
end;
$function$;

revoke execute on function public.refrescar_licitaciones(jsonb) from public, anon, authenticated;
grant execute on function public.refrescar_licitaciones(jsonb) to service_role;
