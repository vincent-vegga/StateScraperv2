-- ============================================================
-- Ganadores sin NIF y contratos que no llegaron a firmarse
-- ============================================================
--
-- Revisión de huecos del 04/10/2026 sobre los contratos no menores.
--
-- (1) GANADORES SIN NIF. Algunos lotes llegan con el nombre del
-- adjudicatario y ningún identificador: UTEs, sobre todo gallegas ("UTE
-- OREGA-XAC JUZGADOS VIGO", "UTE TELEMARK COREMAIN"), y empresas
-- extranjeras. `reparto_adjudicacion` descarta los lotes sin NIF, así que
-- no entraban en ninguna ficha, ranking ni Movimientos: 214 contratos sin
-- una sola fila en `adjudicaciones_empresa`, 927 M€, más otros 72 con
-- algún lote perdido. Ahora llevan un código sacado del nombre,
-- `codigo_sin_nif`: "SN" + diez cifras hexadecimales del MD5 del nombre
-- (solo letras y números ASCII, en mayúsculas). Doce caracteres: no puede
-- coincidir con un NIF. El lector (`lector_atom.codigo_sin_nif`) usa la
-- misma fórmula para lo que entre a partir de hoy: si se cambia una, hay
-- que cambiar la otra.
--
-- No se convierten en empresa los nombres que no lo son ("SEGUN
-- RESOLUCION", "DESERT", "Ver Resolución Adjunta", "VARIOS
-- ADJUDICATARIOS", "18 empresas adjudicatarias"…). Y se repara un "&"
-- roto en origen: "EQUIPO MULTIDISCIPLINAR X &' || ' OUTROS".
--
-- (2) SIN CONTRATO. La Plataforma llama "Resuelta" igual a lo formalizado
-- y a lo desierto: ~39.000 expedientes en RES (el 8 %) no tienen ganador
-- porque quedaron desiertos, se desistió o se renunció. No inflaban
-- ninguna cifra de mercado (todas parten del ganador), pero viabilidad
-- necesita saberlo: una convocatoria desierta que se vuelve a licitar es
-- una serie. Desde hoy el lector guarda el código de resultado de cada
-- lote (`resultado` en `adjudicaciones`); para lo anterior, no tener
-- ganador basta: en los feeds van siempre juntos (425 lotes comprobados,
-- sin excepción).
--
-- Aplicada el 04/10/2026. Resultado: 368 contratos y 1.212 M€ (sin
-- menores ni homologaciones) con código SN; quedan 8 lotes con nombre y
-- sin código, todos nombres que no son empresa. `sin_contrato` da 47.287
-- en ADJ/RES sin menores: 47.112 desiertos, 92 renuncias y 83
-- desistimientos. 625 de ellos conservaban el ganador de una versión
-- anterior en la columna principal: lo arregla
-- 20261004110000_ganadores_fantasma.sql.
-- ============================================================

set local statement_timeout = '300s';


-- ------------------------------------------------------------
-- (1) Código para quien gana sin NIF
-- ------------------------------------------------------------
create or replace function public.codigo_sin_nif(nombre text)
returns text
language sql
immutable
as $function$
    select case
        when coalesce(nombre, '') ~* ('^\W*$|^DESIERT|^DESERT|SEG[UÚ]N RESOLUCI|VER RESOLUCI|'
                                       || 'VARIOS ADJUDICATARIOS|^\d+ EMPRESAS ADJUDICATARIAS')
            then ''
        when regexp_replace(nombre, '[^A-Za-z0-9]', '', 'g') = '' then ''
        else 'SN' || upper(left(md5(upper(regexp_replace(nombre, '[^A-Za-z0-9]', '', 'g'))), 10))
    end
$function$;

revoke execute on function public.codigo_sin_nif(text) from public, anon;
grant execute on function public.codigo_sin_nif(text) to authenticated, service_role;


-- ------------------------------------------------------------
-- (2) Por qué un expediente no acabó en contrato
-- ------------------------------------------------------------
-- 'desierto', 'desistimiento' o 'renuncia'; null si hubo contrato o si
-- todavía no hay resultado. Solo tiene sentido con estado ADJ o RES.
create or replace function public.sin_contrato(adjudicaciones jsonb)
returns text
language sql
immutable
as $function$
    with lote as (
        select coalesce(e->>'cif', '') as cif,
               coalesce(e->>'resultado', '') as resultado,
               coalesce(e->>'motivo', '') as motivo
        from jsonb_array_elements(
                 case when jsonb_typeof(adjudicaciones) = 'array'
                      then adjudicaciones else '[]'::jsonb end) e
    )
    select case
        when not exists (select 1 from lote) then null
        when exists (select 1 from lote
                     where cif <> ''
                        or resultado in ('adjudicado', 'formalizado', 'mejor_valorado'))
            then null
        else coalesce(
            (select resultado from lote where resultado <> ''
             group by resultado order by count(*) desc, resultado limit 1),
            -- Sin código (cargado antes del 04/10/2026): el motivo lo dice
            -- a veces; si no, lo más frecuente con diferencia es desierto.
            case when exists (select 1 from lote where motivo ~* 'renunci') then 'renuncia'
                 when exists (select 1 from lote where motivo ~* 'desist') then 'desistimiento'
                 else 'desierto' end)
    end
$function$;

revoke execute on function public.sin_contrato(jsonb) from public, anon;
grant execute on function public.sin_contrato(jsonb) to authenticated, service_role;


-- ------------------------------------------------------------
-- (3) Relleno de los lotes con nombre y sin NIF
-- ------------------------------------------------------------
-- El nombre se limpia igual que `limpiar_nombre_adjudicatario` antes de
-- sacar el código, para que lo que llegue después por el feed caiga en
-- la misma empresa. El disparador `sincronizar_adjudicaciones_empresa`
-- rehace sus filas al cambiar `adjudicaciones`.
with afectadas as (
    select l.id_licitacion,
           (select jsonb_agg(
                       case when coalesce(x.e->>'cif', '') = ''
                                 and coalesce(x.e->>'adjudicatario', '') <> ''
                            then x.e || jsonb_build_object(
                                     'adjudicatario', n.limpio,
                                     'cif', public.codigo_sin_nif(n.limpio))
                            else x.e end
                       order by x.o)
            from jsonb_array_elements(l.adjudicaciones) with ordinality x(e, o)
            cross join lateral (
                select btrim(regexp_replace(
                           replace(coalesce(x.e->>'adjudicatario', ''), '&'' || ''', '& '),
                           '\s{2,}', ' ', 'g')) as limpio) n
           ) as nuevas,
           btrim(regexp_replace(replace(coalesce(l.adjudicatario, ''), '&'' || ''', '& '),
                                '\s{2,}', ' ', 'g')) as principal
    from public.licitaciones l
    where jsonb_typeof(l.adjudicaciones) = 'array'
      and jsonb_path_exists(l.adjudicaciones,
                            '$[*] ? (@.adjudicatario != "" && @.cif == "")')
)
update public.licitaciones l
set adjudicaciones = a.nuevas,
    adjudicatario = coalesce(nullif(a.principal, ''), l.adjudicatario),
    adjudicatario_cif = coalesce(nullif(l.adjudicatario_cif, ''),
                                 nullif(public.codigo_sin_nif(a.principal), '')),
    adjudicatarios = (select count(distinct e->>'cif')
                      from jsonb_array_elements(a.nuevas) e
                      where coalesce(e->>'cif', '') <> '')
from afectadas a
where l.id_licitacion = a.id_licitacion;
