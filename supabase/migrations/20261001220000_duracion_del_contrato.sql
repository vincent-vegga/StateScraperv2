-- ============================================================
-- Duración del contrato (solo base de datos; la web no la muestra aún)
-- ============================================================
--
-- Un contrato de 448 M€ puede ser 12 años a 37 M€ al año. Sin la
-- duración, el importe adjudicado se lee como si fuera de un año.
--
-- El feed de la Plataforma la trae en `PlannedPeriod/DurationMeasure`
-- (mayo de 2026, sindicación 643: 90 % de las entradas; otro 10 % trae
-- solo StartDate/EndDate). Las prórrogas llegan como texto libre.
--
-- Esta migración solo AÑADE: tres columnas nulas y una función de
-- relleno para el rol de servicio. Nada existente las lee todavía.
--
--   duracion_meses   duración del contrato en meses (unidades CODICE
--                    ya convertidas: años x12, días / 30,44)
--   duracion_origen  'publicada' (DurationMeasure) o 'fechas' (deducida
--                    de inicio y fin). Null = no se sabe.
--   prorrogas_texto  texto libre de las prórrogas previstas, sin
--                    interpretar
-- ============================================================

alter table public.licitaciones
    add column if not exists duracion_meses  numeric(8,2),
    add column if not exists duracion_origen text,
    add column if not exists prorrogas_texto text;

alter table public.licitaciones
    add constraint licitaciones_duracion_origen_check
    check (duracion_origen is null or duracion_origen in ('publicada', 'fechas'))
    not valid;

-- Relleno por lotes, solo de estas tres columnas. Nunca borra: un valor
-- que llega vacío deja el que había (una versión posterior del mismo
-- expediente puede venir sin el periodo). Solo escribe donde el valor
-- cambia, para no generar versiones de fila inútiles en un reproceso.
create or replace function public.rellenar_duracion(filas jsonb)
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
       set duracion_meses  = coalesce(r.duracion_meses,  l.duracion_meses),
           duracion_origen = coalesce(r.duracion_origen, l.duracion_origen),
           prorrogas_texto = coalesce(r.prorrogas_texto, l.prorrogas_texto)
      from jsonb_to_recordset(filas) as r(
               id text, duracion_meses numeric,
               duracion_origen text, prorrogas_texto text)
     where l.id_licitacion = r.id
       and (l.duracion_meses  is distinct from coalesce(r.duracion_meses,  l.duracion_meses)
         or l.duracion_origen is distinct from coalesce(r.duracion_origen, l.duracion_origen)
         or l.prorrogas_texto is distinct from coalesce(r.prorrogas_texto, l.prorrogas_texto));

    get diagnostics n = row_count;
    return n;
end;
$function$;

revoke execute on function public.rellenar_duracion(jsonb) from public, anon, authenticated;
grant execute on function public.rellenar_duracion(jsonb) to service_role;
