-- ============================================================
-- Viabilidad: convocatorias anteriores por series, no por parecido
-- ============================================================
--
-- Viabilidad se escondió el 20/09/2026 porque el emparejamiento no
-- discriminaba: "convocatoria anterior" era cualquier contrato del mismo
-- órgano y CPV principal con el título parecido al 40 %, y en grupos
-- grandes pasaba el 90 %. Decía "X ha ganado 8 de las últimas 10
-- convocatorias de este contrato" de diez contratos distintos.
--
-- Medido el 04/10/2026 sobre 300 licitaciones abiertas al azar:
--
--   · Las palabras que cuentan son las raras DENTRO del organismo: en
--     las vigilancias de Málaga, "servicio de vigilancia y seguridad"
--     sale en todas y "sede, servicios operativos, régimen interior"
--     solo en la buena. Cada palabra pesa su rareza en el grupo órgano +
--     CPV principal (log del total entre los contratos que la llevan), y
--     la semejanza es el peso compartido entre el peso del título nuevo.
--     Con 0,6 o más, el anterior es el bueno en la práctica totalidad de
--     los revisados a mano; entre 0,4 y 0,6, la mitad. Se elige 0,6:
--     mejor callar que afirmar algo falso.
--   · Las obras (CPV 45) no se repiten: una acera, un pabellón. No
--     tienen convocatoria anterior.
--   · Un acuerdo marco no se empareja con sus contratos derivados, ni al
--     revés: cada uno con los de su clase (`clase_sistema`).
--   · Contratos PARALELOS no son una serie: una mutua con 11 contratos de
--     diagnóstico por imagen en dos años, uno por localidad, cada uno con
--     otro ganador. Un contrato se repite como mucho una vez al año: con
--     más de 4 ediciones, o 3 en doce meses, no se afirma nada.
--   · Las desiertas cuentan como edición (sin ganador): que la anterior
--     quedara desierta es justo lo que conviene saber.
--
-- Resultado en la muestra: 22 % de las abiertas con convocatorias
-- anteriores identificadas (antes un 39 %, con muchos falsos), en series
-- de 1 a 4 ediciones.
-- ============================================================

set local statement_timeout = '300s';


-- ------------------------------------------------------------
-- Clase de sistema: contrato, marco (AM o SDA) o basado en un marco
-- ------------------------------------------------------------
create or replace function public.clase_sistema(sistema text)
returns text
language sql
immutable
as $function$
    select case
        when sistema in ('Acuerdo marco', 'Sistema dinámico de adquisición') then 'marco'
        when sistema = 'Contrato basado en acuerdo marco' then 'basado'
        else 'contrato' end
$function$;

revoke execute on function public.clase_sistema(text) from public, anon;
grant execute on function public.clase_sistema(text) to authenticated, service_role;


-- ------------------------------------------------------------
-- La serie de un contrato: sus convocatorias anteriores
-- ------------------------------------------------------------
-- Una fila por edición, de la más reciente a la más antigua. `paralelos`
-- (igual en todas las filas) dice que lo encontrado son contratos
-- paralelos y no una serie: quien la use no debe afirmar nada con ella.
create or replace function public.serie_de(ficha text)
returns table(id_licitacion text, titulo text, fecha timestamptz,
              empresa text, cif text, importe numeric, presupuesto numeric,
              licitadores integer, semejanza real, desierta text,
              paralelos boolean)
language sql
stable
security definer
set search_path to 'public'
as $function$
    with este as (
        select l.id_licitacion, l.organo, l.prefijo_principal,
               coalesce(l.fecha_publicacion, l.fecha_deteccion,
                        l.fecha_actualizacion) as pub,
               public.clase_sistema(l.sistema) as clase,
               (select array_agg(distinct w)
                from public.palabras_titulo p, unnest(p.palabras) w
                where p.id_licitacion = l.id_licitacion) as pal
        from public.licitaciones l
        where l.id_licitacion = ficha
          and l.prefijo_principal is not null
          and l.prefijo_principal not like '45%'
    ),
    grupo as materialized (
        select o.id_licitacion, o.titulo, o.adjudicatario, o.adjudicatario_cif,
               o.importe_sin_iva, o.presupuesto_base, o.licitadores,
               o.adjudicaciones, o.estado_licitacion, o.sistema,
               o.sustituida, o.procedimiento,
               coalesce(o.fecha_adjudicacion::timestamptz,
                        o.fecha_formalizacion::timestamptz,
                        o.fecha_actualizacion) as fecha,
               (select array_agg(distinct w) from unnest(po.palabras) w) as pal
        from este e
        join public.licitaciones o
          on o.organo = e.organo
         and o.prefijo_principal = e.prefijo_principal
         and o.id_licitacion <> e.id_licitacion
         and o.fecha_actualizacion >= now() - interval '6 years'
        join public.palabras_titulo po on po.id_licitacion = o.id_licitacion
    ),
    tam as (select count(*) + 1 as n from grupo),
    peso as (
        select x.w, ln((select n from tam)::numeric / count(*)) as idf
        from grupo g, unnest(g.pal) x(w)
        group by x.w
    ),
    -- Una palabra del título nuevo que no sale en el grupo es de las más
    -- raras posibles: pesa como si saliera en un solo contrato.
    den as (
        select sum(coalesce(p.idf, ln((select n from tam)::numeric))) as d
        from este e, unnest(e.pal) x(w)
        left join peso p on p.w = x.w
    ),
    serie as materialized (
        select g.*, public.sin_contrato(g.adjudicaciones) as sc,
               ((select coalesce(sum(p.idf), 0)
                 from unnest(g.pal) x(w) join peso p on p.w = x.w
                 where x.w = any(e.pal))
                / nullif((select d from den), 0))::real as s
        from grupo g, este e
        where g.fecha < e.pub
          and g.estado_licitacion in ('ADJ', 'RES')
          and not coalesce(g.sustituida, false)
          and coalesce(g.procedimiento, '') <> 'Contrato menor'
          and public.clase_sistema(g.sistema) = e.clase
    ),
    buena as (
        select * from serie
        where s >= 0.6
          and (adjudicatario_cif is not null or sc is not null)
    ),
    paralela as (
        select (select count(*) from buena) > 4
            or exists (
                select 1 from buena a
                where (select count(*) from buena b
                       where b.fecha >= a.fecha
                         and b.fecha < a.fecha + interval '365 days') >= 3
            ) as p
    )
    select b.id_licitacion, b.titulo, b.fecha, b.adjudicatario,
           b.adjudicatario_cif, b.importe_sin_iva, b.presupuesto_base,
           b.licitadores, b.s, b.sc, (select p from paralela)
    from buena b
    order by b.fecha desc;
$function$;

revoke execute on function public.serie_de(text) from public, anon, authenticated;
grant execute on function public.serie_de(text) to service_role;


-- ------------------------------------------------------------
-- Las convocatorias anteriores que enseña la pantalla
-- ------------------------------------------------------------
-- Cambia la firma (ya no recibe el umbral de parecido y devuelve si
-- quedó desierta), así que se borra y se crea de nuevo.
drop function if exists public.ediciones_anteriores(text, real);

create function public.ediciones_anteriores(ficha text)
returns table(id_licitacion text, titulo text, fecha timestamptz,
              empresa text, cif text, importe numeric, presupuesto numeric,
              licitadores integer, semejanza real, desierta text)
language sql
stable
security definer
set search_path to 'public'
as $function$
    select s.id_licitacion, s.titulo, s.fecha, s.empresa, s.cif, s.importe,
           s.presupuesto, s.licitadores, s.semejanza, s.desierta
    from public.serie_de(ficha) s
    where not s.paralelos
    order by s.fecha desc;
$function$;

revoke execute on function public.ediciones_anteriores(text) from public, anon;
grant execute on function public.ediciones_anteriores(text) to authenticated, service_role;


-- ------------------------------------------------------------
-- Quién gana: la serie si la hay; si no, el organismo
-- ------------------------------------------------------------
-- Las mismas claves de antes, más `paralelos`, `desiertas`,
-- `ultima_desierta` y `ultimo` (quién ganó la más reciente). `por_convocatoria` dice de dónde sale el reparto:
-- de las convocatorias anteriores de ESTE contrato, o (si no se
-- encuentran) de todas las adjudicaciones del organismo en su CPV
-- principal. Quien lo enseñe tiene que decir cuál de las dos es.
create or replace function public.incumbencia(ficha text, anios integer default 4)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    with s as materialized (select * from public.serie_de(ficha)),
    par as (select coalesce(bool_or(paralelos), false) as p from s),
    serie as (select * from s where not (select p from par)),
    ganadas as (
        select empresa as adjudicatario, cif as adjudicatario_cif,
               fecha as fecha_actualizacion
        from serie where cif is not null
    ),
    por_conv as (select count(*) > 0 as si from ganadas),
    este as (
        select l.organo, l.prefijo_principal,
               public.clase_sistema(l.sistema) as clase
        from public.licitaciones l where l.id_licitacion = ficha
    ),
    -- Solo los de su misma clase: en un acuerdo marco, sus cientos de
    -- contratos derivados (un licitador cada uno, por definición) no
    -- dicen nada de quién gana el marco.
    organismo as (
        select o.adjudicatario, o.adjudicatario_cif, o.fecha_actualizacion
        from public.licitaciones o, este
        where o.organo = este.organo
          and o.prefijo_principal = este.prefijo_principal
          and public.clase_sistema(o.sistema) = este.clase
          and o.adjudicatario_cif is not null
          and not coalesce(o.sustituida, false)
          and coalesce(o.procedimiento, '') <> 'Contrato menor'
          and o.fecha_actualizacion >= now() - (anios || ' years')::interval
          and not (select si from por_conv)
    ),
    base as (
        select * from ganadas
        union all
        select * from organismo
    ),
    reparto as (
        select adjudicatario_cif as cif,
               (array_agg(adjudicatario order by fecha_actualizacion desc))[1] as nombre,
               count(*)::int as veces,
               max(fecha_actualizacion) as ultima
        from base group by adjudicatario_cif
    )
    select jsonb_build_object(
        'ediciones', (select count(*) from base),
        'empresas', (select count(*) from reparto),
        'por_convocatoria', (select si from por_conv),
        'paralelos', (select p from par),
        'desiertas', (select count(*) from serie where desierta is not null),
        'ultima_desierta', coalesce(
            (select desierta is not null from serie order by fecha desc limit 1), false),
        -- Quién ganó la convocatoria más reciente: si no es el líder, el
        -- contrato ha cambiado de manos y no está cerrado.
        'ultimo', (
            select jsonb_build_object('nombre', adjudicatario, 'cif', adjudicatario_cif)
            from ganadas order by fecha_actualizacion desc limit 1
        ),
        -- Si NADIE destaca, decirlo.
        'reparto_equitativo', (
            select coalesce(max(veces), 0) <= 1
                   or count(*) filter (where veces = (select max(veces) from reparto)) > 1
            from reparto
        ),
        'lider', (
            select jsonb_build_object(
                'nombre', r.nombre, 'cif', r.cif, 'veces', r.veces,
                'ultima', r.ultima,
                'cuota', round(100.0 * r.veces /
                               nullif((select count(*) from base), 0)))
            from reparto r order by r.veces desc, r.ultima desc limit 1
        ),
        'reparto', (
            select jsonb_agg(jsonb_build_object(
                       'nombre', r.nombre, 'cif', r.cif, 'veces', r.veces)
                     order by r.veces desc)
            from (select * from reparto order by veces desc limit 6) r
        )
    );
$function$;


-- ------------------------------------------------------------
-- El veredicto: "este contrato" solo cuando hay serie
-- ------------------------------------------------------------
-- Cambia solo el bloque del proveedor de referencia:
--   · Con serie, se habla de las convocatorias de este contrato.
--   · Sin serie, del organismo ("de este tipo en este organismo"), y un
--     proveedor dominante da como mucho "difícil": no es el mismo
--     contrato, así que no se puede decir que esté cerrado.
--   · Si la convocatoria anterior quedó desierta, se dice.
--   · Si son contratos paralelos, se explica por qué no hay serie.
create or replace function public.viabilidad(ficha text)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
-- El parámetro NO puede llamarse `expediente`: la tabla tiene una
-- columna con ese nombre y PostgreSQL no sabe a cuál se refiere.
declare
    c            record;
    yo           record;
    inc          jsonb;
    serie        boolean;
    baja_org     int;
    n_baja       int;
    licit        numeric;
    n_licit      int;
    solos        int;
    veredicto    text;
    motivos      text[] := '{}';
begin
    select l.*, l.titulo_normal as tn into c
    from public.licitaciones l where l.id_licitacion = ficha;
    if not found then
        return jsonb_build_object('error', 'no encontrado');
    end if;

    select p.id, p.cif, p.empresa into yo
    from public.perfiles p where p.id = public.mi_perfil_id();

    inc := public.incumbencia(ficha, 4);
    serie := coalesce((inc->>'por_convocatoria')::boolean, false);

    -- Cómo adjudica ese organismo en esta familia de contratos. Solo
    -- adjudicaciones de verdad y de su misma clase, como el resto de
    -- pantallas: los menores (un licitador casi siempre), los duplicados
    -- republicados y los derivados de un marco inflaban el "solo se
    -- presentó una empresa" (2.212 de 2.337 en un acuerdo marco).
    select round(avg(public.baja_real(o.presupuesto_base, o.importe_sin_iva,
                                      o.lotes, o.sistema)))::int,
           count(*) filter (where public.baja_real(o.presupuesto_base,
                    o.importe_sin_iva, o.lotes, o.sistema) is not null),
           round(avg(o.licitadores), 1),
           count(o.licitadores),
           count(*) filter (where o.licitadores = 1)
      into baja_org, n_baja, licit, n_licit, solos
    from public.licitaciones o
    where o.organo = c.organo
      and o.prefijo_principal = c.prefijo_principal
      and public.clase_sistema(o.sistema) = public.clase_sistema(c.sistema)
      and o.adjudicatario_cif is not null
      and not coalesce(o.sustituida, false)
      and coalesce(o.procedimiento, '') <> 'Contrato menor'
      and o.fecha_actualizacion >= now() - interval '4 years';

    -- ---------- El veredicto ----------
    --
    -- Tres niveles, no cien. Y cada uno con su motivo escrito, para que
    -- el cliente pueda discutirlo en vez de creérselo.
    veredicto := 'abierto';

    -- Un líder que empata con otros no es un líder. Solo se habla de
    -- proveedor dominante cuando de verdad destaca sobre el resto.
    if coalesce((inc->>'ediciones')::int, 0) = 0 then
        null;
    elsif serie and (inc->>'ediciones')::int = 1 then
        motivos := motivos || format(
            'la convocatoria anterior de este contrato la ganó %s',
            inc->'lider'->>'nombre');
    elsif (inc->>'ediciones')::int = 1 then
        motivos := motivos || format(
            'la única adjudicación de este tipo en este organismo la ganó %s',
            inc->'lider'->>'nombre');
    elsif (inc->>'reparto_equitativo')::boolean then
        if serie then
            motivos := motivos || format(
                '%s empresas distintas se han repartido las %s convocatorias anteriores de este contrato',
                inc->>'empresas', inc->>'ediciones');
        else
            motivos := motivos || format(
                '%s empresas distintas se reparten las %s adjudicaciones de este '
                'tipo en este organismo, sin que ninguna repita más que las demás',
                inc->>'empresas', inc->>'ediciones');
        end if;
    elsif serie and (inc->'lider'->>'cuota')::int >= 50
          and (inc->>'ediciones')::int >= 2
          and (inc->'ultimo'->>'cif') is distinct from (inc->'lider'->>'cif') then
        -- El líder ya no es quien lo tiene: la última convocatoria se la
        -- llevó otra empresa. Ha cambiado de manos, así que está abierto.
        motivos := motivos || format(
            '%s ganó %s de las últimas %s convocatorias de este contrato, pero la más reciente se la llevó %s',
            inc->'lider'->>'nombre', inc->'lider'->>'veces', inc->>'ediciones',
            inc->'ultimo'->>'nombre');
    elsif serie and (inc->'lider'->>'cuota')::int >= 50
          and (inc->>'ediciones')::int >= 2 then
        -- Tres de tres es una costumbre; dos de dos, todavía no.
        veredicto := case when (inc->'lider'->>'cuota')::int >= 60
                               and (inc->>'ediciones')::int >= 3
                          then 'cerrado' else 'difícil' end;
        -- Con competencia de por medio se dice, porque cambia el
        -- sentido: ganar ocho de ocho frente a nadie es una cosa, y
        -- ganarlas compitiendo con tres empresas cada vez es otra,
        -- bastante peor para quien quiera entrar.
        motivos := motivos || format(
            '%s ha ganado %s de las últimas %s convocatorias de este contrato%s',
            inc->'lider'->>'nombre', inc->'lider'->>'veces', inc->>'ediciones',
            case when licit >= 2 then
                format(', y no por falta de competencia: se presentan %s empresas de media',
                       replace(licit::text, '.', ','))
            else '' end);
    elsif not serie and (inc->'lider'->>'cuota')::int >= 50
          and (inc->>'ediciones')::int >= 3 then
        veredicto := 'difícil';
        motivos := motivos || format(
            '%s gana mucho en este organismo: %s de %s adjudicaciones de este tipo',
            inc->'lider'->>'nombre', inc->'lider'->>'veces', inc->>'ediciones');
    end if;

    -- Una convocatoria anterior desierta es una puerta abierta: nadie se
    -- la llevó, y el organismo vuelve a necesitarlo.
    if coalesce((inc->>'ultima_desierta')::boolean, false) then
        motivos := motivos || 'la convocatoria anterior de este contrato quedó desierta'::text;
    end if;

    if coalesce((inc->>'paralelos')::boolean, false) then
        motivos := motivos || ('este organismo saca muchos contratos casi '
            || 'iguales a la vez (por centros, zonas o especialidades), así que '
            || 'no podemos saber cuál fue la convocatoria anterior de este')::text;
    end if;

    if c.peso_subjetivo is not null and c.peso_subjetivo >= 40 then
        if veredicto = 'abierto' then veredicto := 'difícil'; end if;
        motivos := motivos || format(
            'el %s %% de la puntuación depende de juicio de valor, no de fórmula',
            c.peso_subjetivo);
    elsif c.peso_objetivo is not null and c.peso_objetivo >= 85 then
        motivos := motivos || format(
            'el %s %% de la puntuación se calcula con fórmula', c.peso_objetivo);
    end if;

    if licit is not null and licit >= 8 then
        motivos := motivos || format('se presentan %s empresas de media aquí',
                                     replace(licit::text, '.', ','));
    end if;

    -- Que la mitad de las adjudicaciones vayan con un solo licitador
    -- dice bastante: puede haber barreras que no se ven en el pliego, o
    -- que nadie más se entera. En los dos casos, conviene saberlo.
    if n_licit >= 5 and solos::numeric / n_licit >= 0.5 then
        motivos := motivos || format(
            'en %s de las últimas %s adjudicaciones solo se presentó una empresa',
            solos, n_licit);
    end if;

    if baja_org is not null and baja_org <= 80 then
        motivos := motivos || format(
            'este organismo adjudica de media al %s %% del presupuesto', baja_org);
    end if;

    return jsonb_build_object(
        'contrato', jsonb_build_object(
            'titulo', c.titulo, 'organo', c.organo, 'provincia', c.provincia,
            'presupuesto', coalesce(c.presupuesto_base, c.presupuesto),
            'fecha_limite', c.fecha_limite,
            'peso_objetivo', c.peso_objetivo,
            'peso_subjetivo', c.peso_subjetivo,
            'criterios', c.criterios,
            'procedimiento', c.procedimiento,
            'lotes', c.lotes,
            'enlace', c.enlace),
        'veredicto', veredicto,
        'motivos', to_jsonb(motivos),
        'incumbencia', inc,
        'organismo', jsonb_build_object(
            'baja_media', baja_org,
            'baja_muestra', n_baja,
            'licitadores_medio', licit,
            'licitadores_muestra', n_licit,
            'sin_competencia', solos),
        -- "Este contrato es tuyo" solo si de verdad lo es: hay serie y
        -- ganaste la convocatoria más reciente. Ser quien más gana en el
        -- organismo no hace tuyo ESTE contrato, y haber ganado dos de
        -- tres tampoco si la última se la llevó otro.
        'soy_el_lider', serie and yo.cif is not null
                        and (inc->'ultimo'->>'cif') = yo.cif
    );
end;
$function$;
