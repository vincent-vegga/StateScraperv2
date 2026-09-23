-- ============================================================
-- Año de formalización (1 de 3): columnas, fecha de mercado y escritura
-- ============================================================
--
-- Orden: 1 → código (lector_atom.py, procesar_historico.py) → 2 (relleno,
-- fuera de transacción) → 3 → reprocesar 643 y 1044.
-- Este paso no cambia nada de lo que ve la web: prepara los datos.
--
-- El problema (medido el 23/09/2026):
--
--   Movimientos, Empresas y Organismos repartían los contratos por años
--   según `fecha_actualizacion`, que es la fecha de la PRIMERA versión
--   del expediente que entró en la base. Al importar el histórico, las
--   versiones posteriores solo pasaban por `completar_explicacion`, que
--   rellenaba huecos pero no tocaba ni la fecha ni el estado. En el 643,
--   152.500 adjudicaciones tenían la fecha de adjudicación posterior a la
--   que usábamos; en el 1044, 64.127 adjudicadas seguían "publicadas" o
--   "en evaluación".
--
--   Caso que lo destapó: uniformidad de la Guardia Urbana de Badalona
--   (2024/48275K). En la base: estado EV, 10/04/2025. En la Plataforma:
--   adjudicado el 30/05/2025, recurrido, formalizado el 17/02/2026.
--
-- Decidido el 23/09/2026: el dinero cuenta en el AÑO EN QUE SE RESUELVE,
-- es decir, en el de la FORMALIZACIÓN del contrato (estado RES), y cada
-- empresa en el de la formalización de SUS lotes.
--
-- La fecha está en el XML y no se leía: <cac:TenderResult><cac:Contract>
-- <cbc:IssueDate>, una por lote. Comprobado en febrero de 2026: la trae
-- el 99 % de los formalizados del 643 y el 91 % del 1044 (que en cambio
-- no publica nunca la de adjudicación). De adjudicación a formalización
-- van 8 días de mediana y 39 en el percentil 90.
--
-- Qué fecha cuenta, por orden (`fecha_mercado`):
--   1. `fecha_formalizacion` (IssueDate), si es creíble.
--   2. `fecha_adjudicacion` (AwardDate), si es creíble: lo adjudicado y
--      aún no formalizado cuenta de momento en su adjudicación, y se
--      mueve cuando se formalice.
--   3. `fecha_formalizacion_estimada`: la de la versión más antigua vista
--      en estado RES. Para los formalizados sin ninguna de las dos fechas
--      (casi todos del 1044). Va detrás de la adjudicación porque la
--      primera versión RES vista puede ser una modificación años después.
--   4. `fecha_actualizacion`, como hasta ahora.
-- "Creíble": desde el año 2000 y no más de 400 días después de la versión
-- guardada. Hay fechas basura publicadas (años 1, 24, 202, 1925, 2029).
-- ============================================================


-- ------------------------------------------------------------
-- Respaldo de lo que se toca en los pasos 1 y 3
-- ------------------------------------------------------------
create table if not exists public.respaldo_funciones_formalizacion_20260923 as
select p.proname as nombre, pg_get_function_identity_arguments(p.oid) as argumentos,
       pg_get_functiondef(p.oid) as definicion, now() as guardado
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('sincronizar_adjudicaciones_empresa', 'reparto_adjudicacion',
                    'completar_explicacion', 'refrescar_licitaciones',
                    'mercado_del_periodo', 'repartos_del_periodo',
                    'resumen_periodo', 'movimientos_periodo', 'ficha_empresa',
                    'ficha_organismo', 'seguimiento_periodo',
                    'anios_de_mi_sector', 'anios_de_organismo',
                    'refrescar_organismos_por_prefijo');
alter table public.respaldo_funciones_formalizacion_20260923 enable row level security;
revoke all on public.respaldo_funciones_formalizacion_20260923 from anon, authenticated;


-- ------------------------------------------------------------
-- Columnas nuevas
-- ------------------------------------------------------------
-- Todas sin reescribir la tabla: nulas, o con un valor por defecto
-- constante.
alter table public.licitaciones
    add column if not exists fecha_formalizacion date,
    add column if not exists fecha_formalizacion_estimada date;

comment on column public.licitaciones.fecha_formalizacion is
    'Formalización del lote principal (Contract/IssueDate). La de cada lote '
    'va en adjudicaciones[].formalizacion.';
comment on column public.licitaciones.fecha_formalizacion_estimada is
    'Fecha de la versión más antigua vista en estado RES. Solo se usa si '
    'no hay fecha de formalización ni de adjudicación.';

-- Los contratos menores se guardan pero no cuentan en las métricas de
-- mercado (decidido el 23/09/2026: solo hay menores de 2025 y deforman
-- el reparto por años y las medianas). Siguen sirviendo para el alta:
-- `prefijos_de_empresa`, `historial_empresa`, etc. no se tocan.
alter table public.adjudicaciones_empresa
    add column if not exists es_menor boolean not null default false;


-- ------------------------------------------------------------
-- La fecha con la que un contrato cuenta en el mercado
-- ------------------------------------------------------------
-- IMMUTABLE y sin `set search_path` para que se expanda en línea: así la
-- misma expresión sirve para los índices del paso 2 y las consultas del
-- paso 3 la encuentran. Comprobado con una tabla temporal el 23/09/2026:
-- el plan usa el índice por expresión.
create or replace function public.fecha_mercado(
    formalizada date, adjudicada date, estimada date, actualizada timestamptz)
returns timestamptz
language sql
immutable
as $function$
    select case
        when formalizada between date '2000-01-01'
                             and (actualizada at time zone 'Europe/Madrid')::date + 400
            then formalizada::timestamp at time zone 'Europe/Madrid'
        when adjudicada between date '2000-01-01'
                            and (actualizada at time zone 'Europe/Madrid')::date + 400
            then adjudicada::timestamp at time zone 'Europe/Madrid'
        when estimada is not null
            then estimada::timestamp at time zone 'Europe/Madrid'
        else actualizada
    end
$function$;

revoke execute on function public.fecha_mercado(date, date, date, timestamptz)
    from public, anon;
grant execute on function public.fecha_mercado(date, date, date, timestamptz)
    to authenticated, service_role;


-- ------------------------------------------------------------
-- Disparador: no perder fechas y estimar la de formalización
-- ------------------------------------------------------------
--   - Una versión que no trae fecha de adjudicación o de formalización
--     no borra la que ya teníamos.
--   - Cada vez que una fila está formalizada (RES), la fecha de esa
--     versión es candidata a fecha estimada, y se queda la más antigua.
create or replace function public.rellenar_fechas_contrato()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
    if tg_op = 'UPDATE' then
        if new.fecha_adjudicacion is null then
            new.fecha_adjudicacion := old.fecha_adjudicacion;
        end if;
        if new.fecha_formalizacion is null then
            new.fecha_formalizacion := old.fecha_formalizacion;
        end if;
    end if;

    if new.estado_licitacion = 'RES'
       and new.adjudicatario_cif is not null
       and new.fecha_actualizacion is not null then
        -- `least` ignora los nulos: la primera vez queda la de esta versión.
        new.fecha_formalizacion_estimada := least(
            new.fecha_formalizacion_estimada,
            (new.fecha_actualizacion at time zone 'Europe/Madrid')::date);
    end if;

    return new;
end;
$function$;

revoke execute on function public.rellenar_fechas_contrato()
    from public, anon, authenticated;

drop trigger if exists trg_fechas_contrato on public.licitaciones;
create trigger trg_fechas_contrato
    before insert or update of fecha_adjudicacion, fecha_formalizacion,
                               fecha_formalizacion_estimada, estado_licitacion,
                               fecha_actualizacion, adjudicatario_cif
    on public.licitaciones
    for each row execute function public.rellenar_fechas_contrato();


-- ------------------------------------------------------------
-- El reparto por empresa lleva la formalización de sus lotes
-- ------------------------------------------------------------
-- Igual que antes, con una columna más: la formalización más temprana
-- de los lotes de esa empresa. Cambia el tipo de lo que devuelve, así que
-- hay que borrarla y crearla; solo la usa el disparador de abajo.
drop function if exists public.reparto_adjudicacion(jsonb, text, text, numeric);

create function public.reparto_adjudicacion(
    adjudicaciones jsonb, nombre_principal text, cif_principal text, total numeric)
returns table(cif text, nombre text, importe numeric, lotes integer,
              principal boolean, formalizacion date)
language sql
immutable
as $function$
    with lote as (
        select a.value->>'cif' as cif,
               nullif(a.value->>'adjudicatario', '') as nombre,
               case when jsonb_typeof(a.value->'importe') = 'number'
                    then (a.value->>'importe')::numeric end as importe,
               case when coalesce(a.value->>'formalizacion', '')
                             ~ '^\d{4}-\d{2}-\d{2}'
                    then left(a.value->>'formalizacion', 10)::date end as formalizacion
        from jsonb_array_elements(
                 case when jsonb_typeof(adjudicaciones) = 'array'
                      then adjudicaciones else '[]'::jsonb end) a
        where coalesce(a.value->>'cif', '') <> ''
    ),
    por_cif as (
        select lote.cif,
               (array_agg(lote.nombre) filter (where lote.nombre is not null))[1] as nombre,
               count(*)::int as n,
               sum(lote.importe) as suma,
               min(lote.formalizacion) as formalizacion
        from lote group by lote.cif
        union all
        select cif_principal, nombre_principal, 1, null, null
        where coalesce(cif_principal, '') <> ''
          and not exists (select 1 from lote where lote.cif = cif_principal)
    ),
    cuadre as (
        select (select count(*) from por_cif) as ganadores,
               (select coalesce(sum(lote.importe), 0) from lote)
                   <= total * 1.01 as cuadra
    )
    select p.cif,
           case when p.cif = cif_principal
                then coalesce(nombre_principal, p.nombre) else p.nombre end,
           case when total is null then null
                when c.ganadores = 1 then total
                when c.cuadra and p.suma > 0 then least(p.suma, total)
                else null end,
           p.n,
           p.cif is not distinct from cif_principal,
           p.formalizacion
    from por_cif p cross join cuadre c
$function$;

revoke execute on function public.reparto_adjudicacion(jsonb, text, text, numeric)
    from public, anon, authenticated;
grant execute on function public.reparto_adjudicacion(jsonb, text, text, numeric)
    to service_role;


-- ------------------------------------------------------------
-- `adjudicaciones_empresa`: fecha de mercado de cada empresa y si es menor
-- ------------------------------------------------------------
-- Cambios:
--   - `fecha` es la fecha de mercado con la formalización de los lotes
--     de ESA empresa. En Badalona, la empresa de los lotes 1 y 2 cuenta
--     en 2026 y la del lote de calzado en 2025.
--   - `es_menor` se copia de `procedimiento`.
--   - Se rehace el reparto siempre que cambie algo de lo que depende. El
--     atajo que solo copiaba sector y fecha ya no sirve: ahora la fecha
--     es distinta en cada fila.
create or replace function public.sincronizar_adjudicaciones_empresa()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    if tg_op = 'UPDATE'
       and new.adjudicaciones is not distinct from old.adjudicaciones
       and new.adjudicatario is not distinct from old.adjudicatario
       and new.adjudicatario_cif is not distinct from old.adjudicatario_cif
       and new.importe_adjudicacion is not distinct from old.importe_adjudicacion
       and new.prefijo_principal is not distinct from old.prefijo_principal
       and new.procedimiento is not distinct from old.procedimiento
       and new.fecha_formalizacion is not distinct from old.fecha_formalizacion
       and new.fecha_adjudicacion is not distinct from old.fecha_adjudicacion
       and new.fecha_formalizacion_estimada is not distinct from old.fecha_formalizacion_estimada
       and new.fecha_actualizacion is not distinct from old.fecha_actualizacion
    then
        return null;
    end if;

    delete from public.adjudicaciones_empresa
    where id_licitacion = new.id_licitacion;

    insert into public.adjudicaciones_empresa
        (id_licitacion, cif, nombre, importe, lotes, principal,
         prefijo_principal, fecha, es_menor)
    select new.id_licitacion, r.cif, r.nombre, r.importe, r.lotes, r.principal,
           new.prefijo_principal,
           public.fecha_mercado(coalesce(r.formalizacion, new.fecha_formalizacion),
                                new.fecha_adjudicacion,
                                new.fecha_formalizacion_estimada,
                                new.fecha_actualizacion),
           coalesce(new.procedimiento = 'Contrato menor', false)
    from public.reparto_adjudicacion(new.adjudicaciones, new.adjudicatario,
                                     new.adjudicatario_cif,
                                     new.importe_adjudicacion) r;
    return null;
end;
$function$;

drop trigger if exists trg_adjudicaciones_empresa on public.licitaciones;
create trigger trg_adjudicaciones_empresa
    after insert or update of adjudicaciones, adjudicatario, adjudicatario_cif,
                              importe_adjudicacion, prefijo_principal,
                              fecha_actualizacion, fecha_adjudicacion,
                              fecha_formalizacion, fecha_formalizacion_estimada,
                              procedimiento
    on public.licitaciones
    for each row execute function public.sincronizar_adjudicaciones_empresa();


-- ------------------------------------------------------------
-- El histórico deja de congelar la primera versión
-- ------------------------------------------------------------
-- Antes, una versión posterior del mismo expediente solo rellenaba
-- huecos. Ahora, si la versión que llega es IGUAL DE RECIENTE O MÁS que
-- la guardada, manda en fecha, estado, lotes, ganador, importe y fechas
-- de adjudicación y formalización. Si es más antigua (los meses pueden
-- importarse en cualquier orden, y el scraper puede haber traído ya algo
-- más nuevo), solo rellena huecos, como antes.
--
-- "Igual de reciente" cuenta como más nueva a propósito: reprocesar un
-- mes ya cargado tiene que poder refrescar los lotes (así entran las
-- fechas de formalización en lo que ya estaba).
--
-- Necesita que `procesar_historico.py` mande `fecha_actualizacion`,
-- `estado` y `fecha_formalizacion`. Con un importador viejo, sin fecha,
-- ninguna versión cuenta como más nueva y solo se rellenan huecos.
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
        adjudicatarios = case when d.nueva then coalesce(d.adjudicatarios, l.adjudicatarios)
                              else greatest(coalesce(l.adjudicatarios, 0),
                                            coalesce(d.adjudicatarios, 0)) end,
        -- El importe es la SUMA de los lotes (o nada, en un acuerdo marco
        -- con varios): lo decide el lector. Manda la versión más nueva.
        importe_adjudicacion = case when d.nueva then coalesce(d.importe, l.importe_adjudicacion)
                                    else coalesce(l.importe_adjudicacion, d.importe) end,
        adjudicatario = case when d.nueva then coalesce(d.adjudicatario, l.adjudicatario)
                             else coalesce(l.adjudicatario, d.adjudicatario) end,
        adjudicatario_cif = case when d.nueva then coalesce(d.cif, l.adjudicatario_cif)
                                 else coalesce(l.adjudicatario_cif, d.cif) end,
        presupuesto_base = coalesce(d.presupuesto_base, l.presupuesto_base),
        valor_estimado = coalesce(d.valor_estimado, l.valor_estimado),
        importe_sin_iva = case when d.nueva then coalesce(d.importe_sin_iva, l.importe_sin_iva)
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
    ) d
    where l.id_licitacion = d.id;

    get diagnostics tocadas = row_count;
    return tocadas;
end;
$function$;


-- ------------------------------------------------------------
-- El refresco del scraper también guarda la formalización
-- ------------------------------------------------------------
-- Igual que antes, con `fecha_formalizacion`. Si la versión del feed no
-- la trae, el disparador conserva la que había.
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
           fecha_formalizacion  = r.fecha_formalizacion,
           gano_pyme            = r.gano_pyme,
           ultima_verificacion  = r.ultima_verificacion,
           fecha_actualizacion  = r.fecha_actualizacion
      from jsonb_populate_recordset(null::public.licitaciones, filas) r
     where l.id_licitacion = r.id_licitacion;

    get diagnostics n = row_count;
    return n;
end;
$function$;
