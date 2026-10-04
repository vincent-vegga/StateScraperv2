-- ============================================================
-- Viabilidad: el rango de precio y los contratos con su enlace
-- ============================================================
--
-- Dos cosas, las dos en la pantalla de Viabilidad:
--
-- 1. El rango y no solo la media. "Se cierra al 85 % de media" no dice
--    si todos rondan el 85 o si hay de 60 y de 100. `viabilidad()` añade
--    al bloque `organismo` el cuartil inferior y el superior de la baja
--    (`baja_p25`, `baja_p75`): la mitad central de las adjudicaciones.
--    Mismo conjunto y misma `baja_real` que la media. La web solo enseña
--    el rango con 5 o más contratos medidos; con menos, la media sola.
--
-- 2. Los contratos exactos, con enlace al expediente en la plataforma.
--    - `incumbencia()`: cada empresa del `reparto` lleva `contratos`, sus
--      cinco más recientes de los que cuentan (titulo, fecha, importe,
--      enlace). El resto de claves, igual.
--    - `ediciones_anteriores()`: devuelve también `enlace`. Cambia la
--      firma, así que se borra y se crea de nuevo, con sus permisos.
--
-- Las tres funciones parten de la definición de producción del
-- 04/10/2026 (20261004120000_viabilidad_por_series.sql), sin más cambios
-- que los descritos.
-- ============================================================


-- ------------------------------------------------------------
-- Las convocatorias anteriores, con enlace
-- ------------------------------------------------------------
drop function if exists public.ediciones_anteriores(text);

create function public.ediciones_anteriores(ficha text)
returns table(id_licitacion text, titulo text, fecha timestamptz,
              empresa text, cif text, importe numeric, presupuesto numeric,
              licitadores integer, semejanza real, desierta text, enlace text)
language sql
stable
security definer
set search_path to 'public'
as $function$
    select s.id_licitacion, s.titulo, s.fecha, s.empresa, s.cif, s.importe,
           s.presupuesto, s.licitadores, s.semejanza, s.desierta, l.enlace
    from public.serie_de(ficha) s
    left join public.licitaciones l on l.id_licitacion = s.id_licitacion
    where not s.paralelos
    order by s.fecha desc;
$function$;

revoke execute on function public.ediciones_anteriores(text) from public, anon;
grant execute on function public.ediciones_anteriores(text) to authenticated, service_role;


-- ------------------------------------------------------------
-- Quién gana, con los contratos de cada uno
-- ------------------------------------------------------------
create or replace function public.incumbencia(ficha text, anios integer default 4)
 returns jsonb
 language sql
 stable security definer
 set search_path to 'public'
as $function$
    with s as materialized (select * from public.serie_de(ficha)),
    par as (select coalesce(bool_or(paralelos), false) as p from s),
    serie as (select * from s where not (select p from par)),
    ganadas as (
        select empresa as adjudicatario, cif as adjudicatario_cif,
               fecha as fecha_actualizacion,
               id_licitacion, titulo, importe
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
        select o.adjudicatario, o.adjudicatario_cif, o.fecha_actualizacion,
               o.id_licitacion, o.titulo, o.importe_sin_iva as importe
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
    ),
    -- Los contratos que cuentan para cada empresa, los cinco más
    -- recientes: lo que hay detrás de "ha ganado N veces".
    contratos as (
        select b.adjudicatario_cif as cif,
               jsonb_agg(jsonb_build_object(
                   'titulo', b.titulo, 'fecha', b.fecha_actualizacion,
                   'importe', b.importe, 'enlace', l.enlace)
                 order by b.fecha_actualizacion desc) as lista
        from (select *, row_number() over (partition by adjudicatario_cif
                                           order by fecha_actualizacion desc) as n
              from base) b
        left join public.licitaciones l on l.id_licitacion = b.id_licitacion
        where b.n <= 5
        group by b.adjudicatario_cif
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
                       'nombre', r.nombre, 'cif', r.cif, 'veces', r.veces,
                       'contratos', coalesce(c.lista, '[]'::jsonb))
                     order by r.veces desc)
            from (select * from reparto order by veces desc limit 6) r
            left join contratos c on c.cif = r.cif
        )
    );
$function$;


-- ------------------------------------------------------------
-- Viabilidad, con el rango de la baja
-- ------------------------------------------------------------
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
    baja_p25     int;
    baja_p75     int;
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
    --
    -- Los cuartiles, sobre las mismas bajas que la media: entre los dos
    -- queda la mitad central. `percentile_cont` salta los nulos.
    select round(avg(public.baja_real(o.presupuesto_base, o.importe_sin_iva,
                                      o.lotes, o.sistema)))::int,
           round(percentile_cont(0.25) within group (order by
                 public.baja_real(o.presupuesto_base, o.importe_sin_iva,
                                  o.lotes, o.sistema)))::int,
           round(percentile_cont(0.75) within group (order by
                 public.baja_real(o.presupuesto_base, o.importe_sin_iva,
                                  o.lotes, o.sistema)))::int,
           count(*) filter (where public.baja_real(o.presupuesto_base,
                    o.importe_sin_iva, o.lotes, o.sistema) is not null),
           round(avg(o.licitadores), 1),
           count(o.licitadores),
           count(*) filter (where o.licitadores = 1)
      into baja_org, baja_p25, baja_p75, n_baja, licit, n_licit, solos
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
            'baja_p25', baja_p25,
            'baja_p75', baja_p75,
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
