-- ============================================================
-- Solvencia y requisitos: lo que piden para presentarse, y si llegas
-- ============================================================
--
-- Prioridad 4 de `docs/competencia/LEEME.md` y Decisión 54.
--
-- QUÉ GUARDA
-- `condiciones`: una fila por licitación con lo que el feed trae y la
-- tabla `licitaciones` no guardaba (Decisiones 18 y 19): la solvencia
-- económica y técnica, la clasificación exigida, las garantías, el
-- contacto del órgano y los documentos (pliegos y anexos). Va aparte y no
-- en `licitaciones` (4,7 GB): solo interesa mientras la licitación está
-- abierta, y así ni se ensancha la tabla grande ni se toca su escritura.
--
-- Y la LECTURA: lo que pide de verdad, normalizado por el modelo a partir
-- del texto del feed o, cuando el feed remite al pliego o no trae nada,
-- del propio pliego (`leer_pliegos.py`). Ver la Decisión 54.
--
-- LO MEDIDO (06/10/2026, 7.859 licitaciones abiertas de septiembre y
-- octubre, 643 y 1044):
--   - Solvencia económica o técnica con contenido propio en el feed: 26 %.
--     Solo remisiones al pliego: 29 %. Nada: 45 % (todo el 1044, que no
--     publica esos campos, y el 22 % del 643, sobre todo por debajo de
--     60.000 €). La Decisión 19 contaba como "contenido real" las
--     declaraciones de trámite ("Capacidad de obrar", "No prohibición para
--     contratar"), que son casi todo `SpecificTendererRequirement`.
--   - Clasificación exigida: 5 %. Garantía definitiva: 41 %. Correo del
--     órgano: 71 %. Algún documento: 94 %.
--
-- LA COMPARACIÓN (`requisitos`)
-- Con NIF, lo que la empresa gana en contratos públicos (sin
-- homologaciones), repartido por los meses que dura cada contrato: es una
-- COTA INFERIOR de su facturación. Si ya llega a lo que piden, se puede
-- decir "cumples"; si no, solo "compruébalo con tu facturación total",
-- nunca "no llegas". La experiencia en trabajos parecidos usa los mismos
-- contratos con las tres primeras cifras del CPV (art. 90.1.a LCSP).
-- Sin NIF, el historial es sintético (Decisión 40): solo se enseña lo que
-- piden, sin comparar.
-- ============================================================

create table if not exists public.condiciones (
    id_licitacion   text primary key,
    version         text,                   -- <updated> de la entrada leída
    -- [{clase: economica|tecnica|declaracion, codigo, descripcion,
    --   umbral, es_remision}]
    solvencia       jsonb not null default '[]'::jsonb,
    clasificacion   text[],                 -- {'G6-1','E1-3'}
    -- {provisional, definitiva, complementaria}: porcentaje
    garantias       jsonb,
    email           text,
    telefono        text,
    -- [{tipo, nombre, extension, url, hash}]
    documentos      jsonb not null default '[]'::jsonb,
    leido           timestamptz not null default now(),
    -- La lectura normalizada (ver `leer_pliegos.py`)
    lectura         jsonb,
    lectura_origen  text,                   -- feed | pliego
    lectura_estado  text,                   -- leido | sin_pliego | sin_texto | error
    lectura_fecha   timestamptz,
    lectura_coste   numeric,                -- dólares de esa llamada
    lectura_documento text                  -- nombre del documento leído
);

create index if not exists idx_condiciones_pendientes
    on public.condiciones (leido) where lectura_estado is null;

alter table public.condiciones enable row level security;
revoke all on public.condiciones from anon, authenticated;


-- ---------- Escritura desde el scraper y el relleno ----------
--
-- Por lotes, como `refrescar_licitaciones`. Una versión más antigua no
-- pisa a una más nueva (el relleno lee meses enteros en cualquier orden).
-- Si cambian los documentos, el pliego puede haber cambiado: la lectura
-- hecha a partir del pliego se repite. La hecha a partir del feed también
-- si cambia la solvencia del feed.
create or replace function public.guardar_condiciones(filas jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    n int;
begin
    with entrada as (
        select f->>'id_licitacion'                      as id_licitacion,
               f->>'version'                            as version,
               coalesce(f->'solvencia', '[]'::jsonb)    as solvencia,
               case when jsonb_typeof(f->'clasificacion') = 'array'
                         and jsonb_array_length(f->'clasificacion') > 0
                    then array(select jsonb_array_elements_text(f->'clasificacion'))
               end                                      as clasificacion,
               nullif(f->'garantias', '{}'::jsonb)      as garantias,
               nullif(f->>'email', '')                  as email,
               nullif(f->>'telefono', '')               as telefono,
               coalesce(f->'documentos', '[]'::jsonb)   as documentos
        from jsonb_array_elements(filas) f
        where coalesce(f->>'id_licitacion', '') <> ''
          -- Solo lo que se sigue: el relleno lee meses enteros, con
          -- obras y sectores que no tiene ningún cliente.
          and exists (select 1 from public.licitaciones l
                      where l.id_licitacion = f->>'id_licitacion')
    ), unicas as (
        select distinct on (id_licitacion) *
        from entrada order by id_licitacion, version desc nulls last
    )
    insert into public.condiciones as c
        (id_licitacion, version, solvencia, clasificacion, garantias, email,
         telefono, documentos, leido)
    select id_licitacion, version, solvencia, clasificacion, garantias,
           email, telefono, documentos, now()
    from unicas
    on conflict (id_licitacion) do update set
        version       = excluded.version,
        solvencia     = excluded.solvencia,
        clasificacion = excluded.clasificacion,
        garantias     = excluded.garantias,
        email         = coalesce(excluded.email, c.email),
        telefono      = coalesce(excluded.telefono, c.telefono),
        documentos    = case when excluded.documentos = '[]'::jsonb
                             then c.documentos else excluded.documentos end,
        leido         = now(),
        lectura_estado = case
            when c.lectura_origen = 'pliego'
                 and excluded.documentos <> '[]'::jsonb
                 and public.huella_documentos(excluded.documentos)
                     is distinct from public.huella_documentos(c.documentos)
                then null
            when c.lectura_origen = 'feed'
                 and excluded.solvencia is distinct from c.solvencia
                then null
            when c.lectura_estado in ('sin_pliego', 'sin_texto', 'error')
                 and public.huella_documentos(excluded.documentos)
                     is distinct from public.huella_documentos(c.documentos)
                then null
            else c.lectura_estado end
    where c.version is null or excluded.version is null
       or excluded.version >= c.version;
    get diagnostics n = row_count;
    return n;
end
$function$;

-- Lo que identifica a un conjunto de documentos: sus direcciones y sus
-- huellas, ordenadas. El feed repite las mismas en cada versión.
create or replace function public.huella_documentos(docs jsonb)
returns text
language sql
immutable
as $function$
    select string_agg(coalesce(d->>'url', '') || '#' || coalesce(d->>'hash', ''),
                      '|' order by d->>'url')
    from jsonb_array_elements(coalesce(docs, '[]'::jsonb)) d
$function$;

revoke execute on function public.guardar_condiciones(jsonb) from public, anon, authenticated;
grant execute on function public.guardar_condiciones(jsonb) to service_role;
revoke execute on function public.huella_documentos(jsonb) from public, anon, authenticated;


-- ---------- La cola de lectura ----------
--
-- Lo abierto (PUB, plazo vigente) sin lectura, o con una lectura fallida
-- de hace casi un día. Primero lo que está en la
-- lista de algún cliente y vence antes; luego el resto. Trae lo que el
-- lector necesita para decidir si basta con el feed.
create or replace function public.condiciones_por_leer(tope integer default 200,
                                                       solo_en_listas boolean default false)
returns table (
    id_licitacion  text,
    titulo         text,
    presupuesto_base numeric,
    valor_estimado numeric,
    duracion_meses numeric,
    solvencia      jsonb,
    clasificacion  text[],
    documentos     jsonb,
    en_listas      boolean
)
language sql
stable
security definer
set search_path to 'public'
as $function$
    select c.id_licitacion, l.titulo, l.presupuesto_base, l.valor_estimado,
           l.duracion_meses, c.solvencia, c.clasificacion, c.documentos,
           exists (select 1 from public.veredictos v
                   where v.id_licitacion = c.id_licitacion
                     and v.veredicto in ('si', 'quizas')) as en_listas
    from public.condiciones c
    join public.licitaciones l on l.id_licitacion = c.id_licitacion
    where (c.lectura_estado is null
           -- Un fallo (red, modelo) se reintenta al día siguiente.
           or (c.lectura_estado = 'error' and c.lectura_fecha < now() - interval '20 hours'))
      and coalesce(l.estado_licitacion, '') = 'PUB'
      and l.fecha_limite >= now()
      and not coalesce(l.sustituida, false)
      and (not solo_en_listas or exists (
              select 1 from public.veredictos v
              where v.id_licitacion = c.id_licitacion
                and v.veredicto in ('si', 'quizas')))
    order by 9 desc, l.fecha_limite
    limit tope
$function$;

create or replace function public.guardar_lectura(ficha text, datos jsonb,
                                                  origen text, estado text,
                                                  coste numeric,
                                                  documento text default null)
returns void
language sql
security definer
set search_path to 'public'
as $function$
    update public.condiciones set
        lectura = datos, lectura_origen = origen, lectura_estado = estado,
        lectura_fecha = now(), lectura_coste = coste,
        lectura_documento = documento
    where id_licitacion = ficha
$function$;

-- Lo gastado en lecturas, para que el lector respete su tope.
create or replace function public.gasto_lecturas(desde timestamptz default '-infinity')
returns numeric
language sql
stable
security definer
set search_path to 'public'
as $function$
    select coalesce(sum(lectura_coste), 0) from public.condiciones
    where lectura_fecha >= desde
$function$;

revoke execute on function public.condiciones_por_leer(integer, boolean) from public, anon, authenticated;
revoke execute on function public.guardar_lectura(text, jsonb, text, text, numeric, text) from public, anon, authenticated;
revoke execute on function public.gasto_lecturas(timestamptz) from public, anon, authenticated;
grant execute on function public.condiciones_por_leer(integer, boolean) to service_role;
grant execute on function public.guardar_lectura(text, jsonb, text, text, numeric, text) to service_role;
grant execute on function public.gasto_lecturas(timestamptz) to service_role;


-- ---------- La clasificación, en palabras ----------
--
-- Grupos del Real Decreto 773/2015 (obras A-K, servicios L-V) y las
-- categorías por anualidad media. El subgrupo se deja en número: son
-- más de cien y el cliente que tiene clasificación ya sabe el suyo.
create or replace function public.clasificacion_legible(codigo text)
returns jsonb
language sql
immutable
as $function$
    with p as (
        select upper(left(codigo, 1)) as grupo,
               substring(codigo from '^[A-Za-z](\d+)') as subgrupo,
               substring(codigo from '-\s*(\w+)$') as categoria
    )
    select jsonb_build_object(
        'codigo', codigo,
        'grupo', p.grupo,
        'subgrupo', p.subgrupo,
        'categoria', p.categoria,
        'obras', p.grupo between 'A' and 'K',
        'nombre', case p.grupo
            when 'A' then 'Movimiento de tierras y perforaciones'
            when 'B' then 'Puentes, viaductos y grandes estructuras'
            when 'C' then 'Edificaciones'
            when 'D' then 'Ferrocarriles'
            when 'E' then 'Hidráulicas'
            when 'F' then 'Marítimas'
            when 'G' then 'Viales y pistas'
            when 'H' then 'Transportes de productos petrolíferos y gaseosos'
            when 'I' then 'Instalaciones eléctricas'
            when 'J' then 'Instalaciones mecánicas'
            when 'K' then 'Obras especiales'
            when 'L' then 'Servicios administrativos'
            when 'M' then 'Servicios especializados'
            when 'N' then 'Servicios cualificados'
            when 'O' then 'Conservación y mantenimiento de bienes inmuebles'
            when 'P' then 'Mantenimiento y reparación de equipos e instalaciones'
            when 'Q' then 'Mantenimiento y reparación de maquinaria'
            when 'R' then 'Servicios de transporte'
            when 'S' then 'Tratamiento de residuos'
            when 'T' then 'Servicios de contenido'
            when 'U' then 'Servicios generales'
            when 'V' then 'Tecnologías de la información y las comunicaciones'
        end,
        -- Anualidad media que cubre la categoría (RD 773/2015, art. 26)
        'tramo', case
            when p.grupo between 'A' and 'K' then case p.categoria
                when '1' then 'hasta 150.000 € al año'
                when '2' then 'hasta 360.000 € al año'
                when '3' then 'hasta 840.000 € al año'
                when '4' then 'hasta 2,4 M€ al año'
                when '5' then 'hasta 5 M€ al año'
                when '6' then 'más de 5 M€ al año'
            end
            else case p.categoria
                when '1' then 'hasta 150.000 € al año'
                when '2' then 'hasta 300.000 € al año'
                when '3' then 'hasta 600.000 € al año'
                when '4' then 'hasta 1,2 M€ al año'
                when '5' then 'más de 1,2 M€ al año'
            end
        end)
    from p
$function$;


-- ---------- Lo que ganas al año en contratos públicos ----------
--
-- Cada contrato reparte su importe por los meses que dura (12 si no se
-- publicó; entre 1 y 60), desde su fecha de formalización o
-- adjudicación (Decisión 36). Así un contrato de cuatro años no cuenta
-- entero en el año en que se firmó. Por años naturales, y aparte lo que
-- comparte las tres primeras cifras del CPV con `cpv_parecido`.
create or replace function public.facturacion_publica(cif_empresa text,
                                                      cpv_parecido text default null,
                                                      desde integer default null)
returns table (anio integer, total numeric, parecido numeric, contratos integer,
               contratos_parecidos integer)
language sql
stable
security definer
set search_path to 'public'
as $function$
    with a as (
        select e.importe, e.fecha,
               left(e.prefijo_principal, 3) = left(cpv_parecido, 3) as es_parecido,
               coalesce(least(greatest(round(l.duracion_meses), 1), 60), 12)::int as meses
        from public.adjudicaciones_empresa e
        join public.licitaciones l on l.id_licitacion = e.id_licitacion
        where e.cif = cif_empresa
          and not e.es_homologacion
          and e.importe > 0
          and e.fecha is not null
    ), anios as (
        select generate_series(coalesce(desde, extract(year from now())::int - 3),
                               extract(year from now())::int) as anio
    ), reparto as (
        select y.anio, a.importe, a.es_parecido,
               a.importe * greatest(0, extract(epoch from (
                   least(a.fecha + make_interval(months => a.meses),
                         make_date(y.anio + 1, 1, 1)::timestamptz)
                   - greatest(a.fecha, make_date(y.anio, 1, 1)::timestamptz))))
               / extract(epoch from make_interval(months => a.meses)) as parte
        from a cross join anios y
    )
    select anio,
           round(sum(parte))::numeric,
           round(coalesce(sum(parte) filter (where es_parecido), 0))::numeric,
           count(*) filter (where parte > 0)::int,
           count(*) filter (where parte > 0 and es_parecido)::int
    from reparto
    group by anio
    order by anio
$function$;

revoke execute on function public.facturacion_publica(text, text, integer) from public, anon, authenticated;


-- ---------- Lo que se exige, en euros ----------
--
-- La lectura da el importe tal cual o una regla ("1,5 veces el valor
-- anual medio"). La regla se resuelve aquí con los importes de la
-- licitación: el valor anual medio es el presupuesto base (o, sin él, el
-- valor estimado) dividido entre los años que dura, si dura más de uno.
create or replace function public.importe_exigido(req jsonb, base numeric,
                                                  estimado numeric, meses numeric)
returns numeric
language sql
immutable
as $function$
    select case
        when req is null or jsonb_typeof(req) <> 'object' then null
        when (req->>'importe') ~ '^\d+(\.\d+)?$' and (req->>'importe')::numeric > 0
            then round((req->>'importe')::numeric)
        when (req->>'multiplo') ~ '^\d+(\.\d+)?$' then round(
            (req->>'multiplo')::numeric * case req->>'base'
                when 'valor_estimado' then coalesce(estimado, base)
                when 'presupuesto' then coalesce(base, estimado)
                when 'valor_anual' then coalesce(base, estimado)
                     / case when meses > 12 then meses / 12.0 else 1 end
            end)
    end
$function$;


-- ---------- Lo que ve el cliente ----------
--
-- Todo lo que hace falta para el bloque "Qué piden" de la ficha: lo que
-- se exige, con su origen (feed o pliego) y una frase literal, y la
-- comparación con lo que la empresa ya gana. Cada comprobación dice en
-- cuántos contratos se apoya.
create or replace function public.requisitos_de(ficha text, perfil uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
    l          record;
    c          record;
    yo         record;
    lec        jsonb;
    pide_eco   numeric;
    pide_tec   numeric;
    eco        jsonb;
    tec        jsonb;
    clas       jsonb;
    fact       jsonb;
    mejor      record;
    mejor_par  record;
    comprobar  jsonb := '[]'::jsonb;
    rolece     boolean;
    medio_eco  text;
    medio_tec  text;
    anio_hoy   int := extract(year from now())::int;
begin
    select p.id, p.cif into yo
    from public.perfiles p where p.id = perfil;
    if not found then
        return jsonb_build_object('error', 'sin perfil');
    end if;

    select li.id_licitacion, li.titulo, li.presupuesto_base, li.valor_estimado,
           li.duracion_meses, li.prefijo_principal, li.enlace, li.procedimiento
      into l
    from public.licitaciones li where li.id_licitacion = ficha;
    if not found then
        return jsonb_build_object('error', 'no encontrado');
    end if;

    select * into c from public.condiciones co where co.id_licitacion = ficha;
    if not found then
        return jsonb_build_object('estado', 'sin_datos');
    end if;

    lec := case when c.lectura_estado = 'leido' then c.lectura end;
    eco := lec->'economica';
    tec := lec->'tecnica';
    medio_eco := eco->>'medio';
    medio_tec := tec->>'medio';
    pide_eco := public.importe_exigido(eco, l.presupuesto_base, l.valor_estimado, l.duracion_meses);
    pide_tec := public.importe_exigido(tec, l.presupuesto_base, l.valor_estimado, l.duracion_meses);

    -- Clasificación: la del feed manda; si no hay, la que leyó el modelo.
    select jsonb_agg(public.clasificacion_legible(x) order by x) into clas
    from unnest(coalesce(
        c.clasificacion,
        array(select jsonb_array_elements_text(coalesce(lec->'clasificacion'->'codigos', '[]'::jsonb)))
    )) x
    where x ~ '^[A-Za-z]\d+\s*-\s*\w+$';

    rolece := exists (
        select 1 from jsonb_array_elements(c.solvencia) s
        where s->>'clase' = 'declaracion'
          and (s->>'codigo' = '8' or s->>'descripcion' ~* 'ROLECE|Registro Oficial de Licitadores'))
        or coalesce((lec->>'rolece')::boolean, false);

    -- ---------- La comparación, solo con NIF ----------
    if yo.cif is not null and lec is not null then
        select coalesce(jsonb_agg(jsonb_build_object(
                   'anio', f.anio, 'total', f.total, 'parecido', f.parecido,
                   'contratos', f.contratos, 'contratos_parecidos', f.contratos_parecidos)
                   order by f.anio), '[]'::jsonb)
          into fact
        from public.facturacion_publica(yo.cif, l.prefijo_principal) f;

        -- Mejor de los tres últimos años cerrados (art. 87.3.a LCSP).
        select (x->>'anio')::int as anio, (x->>'total')::numeric as total,
               (x->>'contratos')::int as contratos
          into mejor
        from jsonb_array_elements(fact) x
        where (x->>'anio')::int between anio_hoy - 3 and anio_hoy - 1
        order by (x->>'total')::numeric desc nulls last limit 1;

        -- Trabajos parecidos: el año de más ejecución entre los últimos
        -- tres y el que corre (art. 90.1.a: "en el curso de" los tres
        -- últimos años).
        select (x->>'anio')::int as anio, (x->>'parecido')::numeric as total,
               (x->>'contratos_parecidos')::int as contratos
          into mejor_par
        from jsonb_array_elements(fact) x
        order by (x->>'parecido')::numeric desc nulls last limit 1;

        if pide_eco is not null and coalesce(medio_eco, 'volumen_negocios') = 'volumen_negocios' then
            comprobar := comprobar || jsonb_build_object(
                'que', 'economica',
                'pide', pide_eco,
                'tienes', mejor.total,
                'anio', mejor.anio,
                'contratos', coalesce(mejor.contratos, 0),
                'estado', case when coalesce(mejor.total, 0) >= pide_eco
                               then 'cumple' else 'revisar' end);
        end if;

        if pide_tec is not null and coalesce(medio_tec, 'trabajos_similares') = 'trabajos_similares' then
            comprobar := comprobar || jsonb_build_object(
                'que', 'tecnica',
                'pide', pide_tec,
                'tienes', mejor_par.total,
                'anio', mejor_par.anio,
                'contratos', coalesce(mejor_par.contratos, 0),
                'estado', case when coalesce(mejor_par.total, 0) >= pide_tec
                               then 'cumple' else 'revisar' end);
        end if;
    end if;

    return jsonb_build_object(
        'estado', coalesce(c.lectura_estado, 'pendiente'),
        'origen', c.lectura_origen,
        'documento_leido', c.lectura_documento,
        'exento', coalesce((lec->>'exento')::boolean, false),
        'economica', case when eco is not null and eco <> 'null'::jsonb
            then eco || jsonb_build_object('pide', pide_eco) end,
        'tecnica', case when tec is not null and tec <> 'null'::jsonb
            then tec || jsonb_build_object('pide', pide_tec) end,
        'seguro', nullif(lec->'seguro', 'null'::jsonb),
        'otros', coalesce(lec->'otros', '[]'::jsonb),
        'cita', lec->>'cita',
        'clasificacion', clas,
        'clasificacion_obligatoria', coalesce((lec->'clasificacion'->>'obligatoria')::boolean,
                                              c.clasificacion is not null),
        'rolece', rolece,
        'garantias', c.garantias,
        'email', c.email,
        'telefono', c.telefono,
        'documentos', c.documentos,
        -- Lo del feed tal cual, por si la lectura falta o falla
        'feed', (select coalesce(jsonb_agg(s), '[]'::jsonb)
                 from jsonb_array_elements(c.solvencia) s
                 where s->>'clase' in ('economica', 'tecnica')),
        'con_nif', yo.cif is not null,
        'facturacion', fact,
        'comprobar', comprobar
    );
end
$function$;

revoke execute on function public.requisitos_de(text, uuid) from public, anon, authenticated;
grant execute on function public.requisitos_de(text, uuid) to service_role;

-- La que llama la web: con la empresa activa (`x-perfil`). Solo quien
-- tiene una empresa dada de alta.
create or replace function public.requisitos(ficha text)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    select public.requisitos_de(ficha, public.mi_perfil_id())
$function$;

revoke execute on function public.requisitos(text) from public, anon;
grant execute on function public.requisitos(text) to authenticated, service_role;
