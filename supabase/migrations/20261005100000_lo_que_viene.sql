-- ============================================================
-- Lo que viene: los contratos de tu sector que van a vencer
-- ============================================================
--
-- SIN APLICAR. Escrita la noche del 04 al 05/10/2026; pasos para
-- aplicarla al final de `docs/competencia/LEEME.md`.
--
-- Prioridad 2 de la hoja de ruta. Movimientos decía quién ganó qué el
-- último mes, que es interesante pero no lleva a ninguna acción. Lo que
-- sí lleva a una acción es saber qué contratos de tu sector terminan en
-- los próximos meses: el organismo tendrá que volver a licitarlos, y
-- quien lo sabe antes prepara la oferta, visita al organismo y mira las
-- condiciones del contrato que vence. Es lo que más valoran los
-- clientes de Tussell y Stotles, y el argumento del plan Pro.
--
-- LA FECHA DE FIN
--   inicio = coalesce(fecha_formalizacion, fecha_formalizacion_estimada,
--                     fecha_adjudicacion)
--   fin    = inicio + duracion_meses
-- Medido el 04/10/2026 sobre una muestra del 2 % de las adjudicaciones
-- (23.028 filas): el 99 % tiene inicio y el 85 % duración. Sin contar
-- los menores, la duración la tiene el 99,5 % (en los perfiles de
-- ascensores y de uniformidad, 3.181 de 3.196 y 4.801 de 4.825).
--
-- QUÉ ENTRA Y QUÉ NO
--   - Fuera los contratos MENORES. Son el 47 % de las adjudicaciones,
--     pero su duración mediana es de un mes y solo hay histórico de
--     2025: de 7.384 de la muestra con duración, 7.373 ya han vencido y
--     6 vencen entre 3 y 12 meses. Además, no se vuelven a licitar en
--     abierto. Mismo criterio que las métricas de mercado (Decisión 36).
--   - Fuera los contratos BASADOS en un acuerdo marco (el 10 % de los no
--     menores, duración mediana de 4 meses): cuando vencen, el siguiente
--     solo pueden pedirlo las empresas homologadas en el marco. Lo que se
--     vuelve a licitar en abierto es el acuerdo marco, y ese sí entra.
--   - Fuera las HOMOLOGACIONES (`es_homologacion`: marco sin importe
--     atribuible). Su "adjudicatario" es una de muchas empresas
--     homologadas y no tiene importe; "quién lo tiene ahora" sería falso.
--   - Fuera las OBRAS (CPV 45): una obra terminada no se vuelve a licitar
--     (ver Decisión 45, donde ya se excluyen de las series).
--   - Fuera lo que dura MENOS DE 6 MESES. Son compras y actos sueltos
--     ("Suministro e instalación de plataforma elevadora", "Contratación
--     de los artistas X"), no contratos que se renueven. Es el 14 % de lo
--     que vence en un año en ascensores, el 17 % en uniformidad y el 29 %
--     en espectáculos.
--   - Fuera las duraciones de MÁS DE 25 AÑOS: concesiones demaniales,
--     enajenaciones (996 meses = 83 años) y algún error de unidades
--     ("Suministro de electrocardiógrafos", 720 meses). No hay
--     duraciones de cero o negativas. Con el histórico que hay (desde
--     2014 como mucho), ninguna de más de 25 años vencería ahora.
--   - Fuera las copias republicadas (`sustituida`).
--
-- LAS PRÓRROGAS
-- Solo llegan como texto libre (`prorrogas_texto`, en el 22 % de los
-- contratos no menores). `meses_de_prorroga()` lo lee con reglas
-- sencillas y `prorrogable_hasta()` saca una fecha si la hay ("hasta el
-- 31 de diciembre de 2029"). Sobre 2.069 textos de la muestra, sin
-- basados:
--     48 %  da los meses ("2 prórrogas de 12 meses", "hasta un máximo de
--           24 meses", "duración total, incluidas las prórrogas, de 4
--           años" menos la duración)
--     14 %  dice que no hay prórroga
--      2 %  da una fecha
--     37 %  no se puede leer: remite al pliego o no da cifra
-- Probado además con 55 textos reales etiquetados a mano: los 55 bien.
-- Lo que no se lee se enseña como "puede tener prórrogas (ver el
-- pliego)", no se inventa.
--
-- CUÁNDO VENCE
--   - Si el plazo inicial termina en el futuro, vence entonces. Si se
--     sabe hasta cuándo se puede prorrogar, se dice al lado.
--   - Si ya terminó pero las prórrogas lo llevan al futuro, vence cuando
--     terminen, y la web dice "como tarde": no sabemos si se prorrogó.
--
-- CUÁNTOS SALEN (medido el 04/10/2026 con la función entera, en un
-- bloque que se deshace; en los 12 meses siguientes, ya sin lo que dura
-- menos de 6 meses y sin lo que el clasificador del mercado dijo que no
-- es de su sector):
--                                         3 meses  6 meses  12 meses
--     ascensores (2 prefijos)                    170      314       586
--     uniformidad (9 prefijos)                   178      402       735
--     espectáculos (9231)                        122      256       459
--     consultoría (6 prefijos)                   533    1.183     2.024
-- De lo que vence en esos prefijos (2.800 contratos), el 25 % tiene
-- prórrogas leídas, el 2 % dice que no las tiene, el 10 % remite al
-- pliego y el 63 % no trae texto. El 8 % ya pasó el plazo inicial y
-- vence al acabar las prórrogas.
-- Por eso la pantalla filtra por plazo (3, 6 y 12 meses) y provincia.
--
-- POR QUÉ UNA TABLA PRECALCULADA
-- Calcularlo al pedirlo no cabe en los 8 s de la API: solo leer las
-- 3.478 adjudicaciones de ascensores costó 1,4 s en frío (2.621 bloques
-- del disco), y un sector como el 9231 tiene más de 12.000. Además, leer
-- las prórrogas con expresiones regulares en cada petición sería tirar
-- el trabajo. Igual que `organismos_por_prefijo`: un agregado por
-- prefijo, que sirve a todos los clientes y también al que se dio de
-- alta hace un minuto.
--
--   vencimientos_calculados  vista: los candidatos, ya filtrados, con su
--                            fin y sus prórrogas. Solo la lee el
--                            refresco.
--   vencimientos             tabla: lo que vence en los próximos 13
--                            meses (uno de margen sobre los 12 que se
--                            enseñan, por si el refresco falla un día).
--   refrescar_vencimientos() la rehace entera cada día (pg_cron,
--                            14:45 UTC, después de los demás agregados),
--                            marcando y barriendo como
--                            `refrescar_organismos`. Con una lista de
--                            prefijos, solo esos (sirve para probar y
--                            para rehacer un sector suelto).
--   lo_que_viene(meses, provincia_elegida, tope)
--                            lo que lee la web, para la empresa activa.
--
-- TIEMPOS MEDIDOS
--   refrescar_vencimientos(8 prefijos)   7,2 s, 2.800 filas (por índice)
--   lo_que_viene(), 300 filas            40-660 ms; 1,2 s en frío con
--                                        2.024 filas antes de mirar el
--                                        reparto solo en los de varias
--                                        empresas (ver la función)
--   el cálculo sobre una muestra del 2 % copiada aparte: 1,2 s
--
-- La primera vez hay que rellenarla a mano (ver el traspaso): recorre
-- `licitaciones` entera, como `refrescar_organismos` (68 s medidos el
-- 20/09/2026). Estimado: 1,5-2,5 minutos (unos 60 s de cálculo, por la
-- muestra, más leer la tabla) y unas 80.000 filas.
-- ============================================================


-- ------------------------------------------------------------
-- (1) Las prórrogas, leídas del texto
-- ------------------------------------------------------------
create or replace function public.texto_prorroga_normal(texto text)
returns text
language sql
immutable
as $function$
    -- Minúsculas, sin acentos, números escritos en cifra y sin el "(2)"
    -- que repite la cifra ("DOS (2) PRÓRROGAS").
    select regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           regexp_replace(regexp_replace(regexp_replace(regexp_replace(
           regexp_replace(regexp_replace(
               translate(lower(texto), 'áàâäéèêëíìîïóòôöúùûüçñ·',
                                       'aaaaeeeeiiiioooouuuucn.'),
               '\s+', ' ', 'g'),
               '\mcuarenta y ocho\M', '48', 'g'),
               '\mtreinta y seis\M', '36', 'g'),
               '\m(veinticuatro|vint-i-quatre)\M', '24', 'g'),
               '\m(dieciocho|divuit)\M', '18', 'g'),
               '\m(doce|dotze)\M', '12', 'g'),
               '\m(seis|sis)\M', '6', 'g'),
               '\m(cinco|cinc)\M', '5', 'g'),
               '\m(cuatro|quatre|catro)\M', '4', 'g'),
               '\mtres\M', '3', 'g'),
               '\m(dos|dues|dous)\M', '2', 'g'),
               '\m(un|una|uno|unha)\M', '1', 'g'),
               '(\d+) ?\( ?\1 ?\)', '\1', 'g'),
               '\m(\d+) ?\( ?\d+ ?\)', '\1', 'g')
$function$;


create or replace function public.meses_de_unidad(unidad text)
returns numeric
language sql
immutable
as $function$
    select case
        when unidad ~ '^(ano|any|anual)' then 12
        when unidad ~ '^mes'             then 1
        when unidad ~ '^semana'          then 7 / 30.44
        when unidad ~ '^di'              then 1 / 30.44
    end
$function$;


-- Cuántos meses de prórroga prevé el texto, sumadas todas.
--   0     el texto dice que no hay prórroga
--   > 0   los meses que se pueden añadir, como mucho
--   null  no se sabe: remite al pliego, no da cifra o no se entiende
create or replace function public.meses_de_prorroga(texto text, duracion numeric default null)
returns numeric
language plpgsql
immutable
as $function$
declare
    t      text := public.texto_prorroga_normal(texto);
    -- Una cifra con su unidad: "12 meses", "1,5 años", "189 días".
    cifra  constant text := '(\d+(?:[.,]\d+)?)\.? ?(anos|ano|anys|any|meses|mesos|mes|semanas|dias|dies)\M';
    m      text[];
    x      text[];
    tras   text;
    v      numeric;
begin
    if t is null or btrim(t) = '' then
        return null;
    end if;

    -- 1. No hay prórroga.
    if t ~ '^\W*no\W*$'
       or t ~ '\mno (se |es |s'')?(establec|preve|prev|admit|contempl|procede|cabe|esta previst|esta sujet|existe|hay|incluye|permite|aplica|preveu|admet|estableix|es prorrogable|sera (susceptible|prorrogable|objeto de prorroga)|podra(n)? (ser )?(prorrog|objeto)|son prorrogables)'
       or t ~ '\m(sin|sense) (posibilidad de |possibilitat de )?(prorroga|prorrogues)'
       or t ~ '\m(ninguna|cap) prorroga'
       or t ~ '\m0 prorrogas'
       or t ~ '\m(improrrogable|no prorrogable)'
       or t ~ 'prorroga[a-z ]{0,25}: ?no\M'
    then
        return 0;
    end if;

    -- "sin perjuicio de las prórrogas que pudieran pactarse" no dice
    -- nada, y la cifra que lleva delante es la duración del contrato.
    t := regexp_replace(t, 'sin perjuicio de (la |las )?(posibles |eventuales )?prorrog[a-z]*', 'sin perjuicio', 'g');

    -- Lo demás solo vale si el texto habla de prórrogas: "La vigencia
    -- será de 6 meses" describe la duración, no la prórroga. Algunos
    -- textos van directos a la cifra ("Hasta un máximo de 36 meses",
    -- "Anuales hasta una duración máxima de 4 años"): están en la
    -- casilla de las prórrogas, así que también valen.
    if t !~ 'prorrog' and t !~ '^\W*(hasta|maximo|prevista|previstas|anual|anuales|si)\M' then
        return null;
    end if;

    -- 2. Duración total, prórrogas incluidas: la prórroga es lo que pasa
    --    de la duración ("la duración total del contrato, incluidas las
    --    prórrogas, será de 2 años"). No "duración total de la prórroga".
    if duracion > 0 then
        tras := substring(t from '(?:duracion (?:total|maxima)(?! de (?:la|las|cada) prorroga)|incluid[ao]s? (?:las |sus |el )?(?:posibles |eventuales )?(?:prorrogas|inicial)|incloses|hasta completar|total durada|durada (?:total|maxima)|plazo total)(.*)$');
        x := regexp_match(left(tras, 80), cifra);
        if x is not null then
            v := replace(x[1], ',', '.')::numeric * public.meses_de_unidad(x[2]) - duracion;
            if v > 0 then
                return case when v <= 120 then round(v, 1) end;
            end if;
        end if;
    end if;

    -- 3. Cuántas por cuánto: "2 prórrogas de 12 meses", "3 prórrogas
    --    anuales", "2 anualidades más", "1 periodo anual más". La cifra
    --    de cada una tiene que ir justo detrás: en "3 prórrogas hasta un
    --    máximo de 4 años", los 4 años son el total, no cada una.
    v := null;
    m := regexp_match(t,
        '\m(\d+) (?:[a-z]+ )?(prorrogas|prorroga|prorrogues|periodos|periodo|anualidades|anualidad|anualitats|anualitat)\M(.*)$');
    if m is not null then
        tras := left(m[3], 50);
        x := regexp_match(tras, cifra);
        if m[2] ~ '^anuali' then
            v := 12;
        elsif x is not null
              and substring(tras from 1 for position(x[1] in tras)) !~ '(maximo|total|hasta)' then
            v := replace(x[1], ',', '.')::numeric * public.meses_de_unidad(x[2]);
        elsif tras ~ '^[^0-9]{0,30}\manual' then
            v := 12;
        elsif tras ~ '^[^0-9]{0,30}\mmensual' then
            v := 1;
        elsif x is not null and duracion > 0 and m[1]::int > 1
              and m[2] ~ '^prorrog' then
            -- "3 prórrogas hasta un máximo de 4 años": el total.
            v := replace(x[1], ',', '.')::numeric * public.meses_de_unidad(x[2]) - duracion;
            return case when v > 0 and v <= 120 then round(v, 1) end;
        end if;
        if v is not null then
            v := m[1]::numeric * v;
            return case when v > 0 and v <= 120 then round(v, 1) end;
        end if;
    end if;

    -- 4. "hasta un máximo de 24 meses", "por un máximo de 48 meses".
    --    Si el texto habla de la duración inicial o del contrato, el
    --    máximo es del contrato entero ("1 año inicial... hasta un máximo
    --    de 5 años", "hasta un máximo de 5 años de contrato").
    x := regexp_match(t, '\mmaximo:? (?:total )?(?:de )?' || cifra || '(.{0,20})');
    if x is not null then
        v := replace(x[1], ',', '.')::numeric * public.meses_de_unidad(x[2]);
        if (t ~ '\minicial' or x[3] ~ '\md(e|el) (contrato|duracion)') and duracion > 0 then
            v := v - duracion;
        end if;
        return case when v > 0 and v <= 120 then round(v, 1) end;
    end if;

    -- 5. La primera cifra después de "prorrog..." ("prorrogable otros 2
    --    años", "la prórroga será por 1 año"), justo antes ("1 año de
    --    prórroga") o al empezar ("Hasta 24 meses").
    x := regexp_match(left(substring(t from 'prorrog(.*)$'), 70), cifra);
    if x is null then
        x := regexp_match(right(substring(t from '^(.*?)prorrog'), 30), cifra || '[^0-9]*$');
    end if;
    if x is null and t !~ 'prorrog' then
        -- Ha llegado aquí por empezar por "Hasta", "Sí"...: la cifra
        -- del principio es la de la prórroga ("Sí se prevé, por un
        -- plazo de 4 meses").
        x := regexp_match(left(t, 60), cifra);
    end if;
    if x is not null then
        v := replace(x[1], ',', '.')::numeric * public.meses_de_unidad(x[2]);
        return case when v > 0 and v <= 120 then round(v, 1) end;
    end if;

    return null;
end;
$function$;


-- "Se podrá prorrogar hasta el 30 de septiembre de 2025": una fecha.
create or replace function public.prorrogable_hasta(texto text)
returns date
language plpgsql
immutable
as $function$
declare
    t text := public.texto_prorroga_normal(texto);
    m text[];
    mes int;
begin
    if t is null then
        return null;
    end if;
    m := regexp_match(t,
        '\m(?:hasta|fins)(?: el| al| a)? (\d{1,2}) (?:de |d'')?(enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre|gener|febrer|marc|maig|juny|juliol|agost|setembre|novembre|desembre)(?: de| del)? (\d{4})');
    if m is not null then
        mes := case m[2]
            when 'enero' then 1 when 'gener' then 1
            when 'febrero' then 2 when 'febrer' then 2
            when 'marzo' then 3 when 'marc' then 3
            when 'abril' then 4
            when 'mayo' then 5 when 'maig' then 5
            when 'junio' then 6 when 'juny' then 6
            when 'julio' then 7 when 'juliol' then 7
            when 'agosto' then 8 when 'agost' then 8
            when 'septiembre' then 9 when 'setiembre' then 9 when 'setembre' then 9
            when 'octubre' then 10
            when 'noviembre' then 11 when 'novembre' then 11
            else 12 end;
    else
        m := regexp_match(t, '\m(?:hasta|fins)(?: el| al| a)? (\d{1,2})[/.-](\d{1,2})[/.-](\d{4})');
        if m is null then
            return null;
        end if;
        mes := m[2]::int;
    end if;
    if m[3]::int not between 2000 and 2060 or mes not between 1 and 12 then
        return null;
    end if;
    return least(make_date(m[3]::int, mes, 1) + (m[1]::int - 1),
                 (make_date(m[3]::int, mes, 1) + interval '1 month - 1 day')::date);
exception when others then
    return null;
end;
$function$;

-- Las dos lecturas juntas, y lo que se deduce de ellas para un contrato
-- que termina en `fin`. Una sola función, llamada en el FROM, para que
-- cada texto se lea una vez por fila: con las dos funciones sueltas en
-- la vista, el planificador las copiaba en cada columna y en el filtro
-- que las usan, y el texto se leía hasta cinco veces.
--   prorroga    'no' | 'si' | 'pliego' (hay texto pero no se entiende);
--               null si no hay texto
--   fin_maximo  el fin con todas las prórrogas, si se sabe
create or replace function public.prorroga_de(
    texto text, duracion numeric, fin date,
    out meses numeric, out hasta date, out fin_maximo date, out prorroga text)
language plpgsql
immutable
as $function$
begin
    if texto is null then
        return;
    end if;
    meses := public.meses_de_prorroga(texto, duracion);
    if texto ~* '(hasta|fins)' then
        hasta := public.prorrogable_hasta(texto);
    end if;
    -- Una fecha anterior al fin no es una prórroga (a veces el texto
    -- repite el fin del plazo inicial).
    fin_maximo := case
        when hasta > fin
            then greatest(hasta, (fin + coalesce(meses, 0) * interval '1 month')::date)
        when meses > 0
            then (fin + meses * interval '1 month')::date
    end;
    prorroga := case
        when meses = 0 and hasta is null then 'no'
        when fin_maximo is not null then 'si'
        else 'pliego'
    end;
end;
$function$;

-- Son funciones de cálculo, sin datos de nadie; no hace falta que se
-- puedan llamar desde la API.
revoke execute on function public.texto_prorroga_normal(text) from public, anon, authenticated;
revoke execute on function public.meses_de_unidad(text) from public, anon, authenticated;
revoke execute on function public.meses_de_prorroga(text, numeric) from public, anon, authenticated;
revoke execute on function public.prorrogable_hasta(text) from public, anon, authenticated;
revoke execute on function public.prorroga_de(text, numeric, date) from public, anon, authenticated;


-- ------------------------------------------------------------
-- (2) Los candidatos: qué contratos vencen y cuándo
-- ------------------------------------------------------------
-- Una vista y no la consulta dentro del refresco para que el refresco
-- de todo y el de unos prefijos usen exactamente lo mismo. Al filtrar
-- por `prefijo_principal`, la condición baja hasta `licitaciones` y usa
-- `idx_licitaciones_cuentan`.
--
-- Las prórrogas solo se leen de lo que vence o venció hace menos de 5
-- años: la LCSP (art. 29.4) limita los servicios y suministros a cinco
-- años contando las prórrogas, así que lo que terminó antes no puede
-- seguir prorrogado. Las condiciones sobre `licitaciones` se aplican al
-- leer la tabla, antes de llamar a `prorroga_de`.
create or replace view public.vencimientos_calculados as
select c.id_licitacion, c.prefijo_principal, c.titulo, c.organo,
       c.provincia, c.enlace, c.clase, c.cif, c.empresa,
       c.adjudicatarios, c.importe, c.inicio, c.duracion_meses, c.fin,
       p.prorroga, p.fin_maximo,
       case when c.fin >= c.hoy then c.fin else p.fin_maximo end as vence
from (
    select l.id_licitacion, l.prefijo_principal, l.titulo, l.organo,
           l.provincia, l.enlace,
           public.clase_sistema(l.sistema) as clase,
           l.adjudicatario_cif as cif, l.adjudicatario as empresa,
           l.adjudicatarios, l.importe_adjudicacion as importe,
           i.inicio, l.duracion_meses,
           (i.inicio + l.duracion_meses * interval '1 month')::date as fin,
           l.prorrogas_texto,
           (now() at time zone 'Europe/Madrid')::date as hoy
    from public.licitaciones l
    cross join lateral (
        select coalesce(l.fecha_formalizacion, l.fecha_formalizacion_estimada,
                        l.fecha_adjudicacion) as inicio
    ) i
    where l.adjudicatario_cif is not null
      and not l.sustituida
      and l.procedimiento is distinct from 'Contrato menor'
      and not public.es_homologacion(l.sistema, l.importe_adjudicacion)
      and public.clase_sistema(l.sistema) <> 'basado'
      and l.prefijo_principal is not null
      and l.prefijo_principal not like '45%'
      and l.duracion_meses between 6 and 300
      -- Fechas imposibles fuera, con el mismo margen que `fecha_mercado`.
      and i.inicio between date '2000-01-01' and current_date + 400
) c
cross join lateral public.prorroga_de(c.prorrogas_texto, c.duracion_meses, c.fin) p
where c.fin >= c.hoy - interval '5 years'
  and c.fin < c.hoy + interval '13 months'
  and ((c.fin >= c.hoy)
       or (p.fin_maximo >= c.hoy and p.fin_maximo < c.hoy + interval '13 months'));

-- Solo la lee el refresco, que corre como propietario.
revoke all on public.vencimientos_calculados from public, anon, authenticated;


-- ------------------------------------------------------------
-- (3) La tabla
-- ------------------------------------------------------------
create table if not exists public.vencimientos (
    id_licitacion     text primary key,
    prefijo_principal text not null,
    titulo            text,
    organo            text,
    provincia         text,
    enlace            text,
    clase             text not null,      -- contrato | marco
    cif               text,               -- quien lo ganó (el principal)
    empresa           text,
    adjudicatarios    integer,            -- empresas distintas, si son varias
    importe           numeric,
    inicio            date not null,
    duracion_meses    numeric not null,
    fin               date not null,      -- inicio + duración, sin prórrogas
    prorroga          text,               -- no | si | pliego | null (sin texto)
    fin_maximo        date,               -- con todas las prórrogas, si se sabe
    vence             date not null,      -- fin, o fin_maximo si fin ya pasó
    actualizado       timestamptz not null default now(),
    constraint vencimientos_prorroga_check
        check (prorroga is null or prorroga in ('no', 'si', 'pliego'))
);

-- Por prefijo de cuatro cifras, que es como lo guardan casi todos los
-- perfiles, y por familia de dos, que es como lo guardan algunos
-- antiguos ("72,48,79"): sin esto, a esos no les saldría nada.
create index if not exists idx_vencimientos_prefijo
    on public.vencimientos (prefijo_principal, vence);
create index if not exists idx_vencimientos_familia
    on public.vencimientos (left(prefijo_principal, 2), vence);

-- RLS activo y sin políticas: nadie llega por la API. Solo la leen la
-- función de la web y el refresco, como propietario.
alter table public.vencimientos enable row level security;
revoke all on public.vencimientos from anon, authenticated;


-- ------------------------------------------------------------
-- (4) El refresco
-- ------------------------------------------------------------
-- Marcar y barrer, como `refrescar_organismos`: primero se escribe todo
-- con la hora de la pasada y después se borra lo que no se tocó. La
-- tabla nunca se queda vacía a medias.
create or replace function public.refrescar_vencimientos(prefijos text[] default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    sello    timestamptz := clock_timestamp();
    metidas  int;
    barridas int;
begin
    if auth.uid() is not null then
        raise exception 'refrescar_vencimientos: solo con clave de servicio';
    end if;

    -- Dos consultas y no una con "prefijos is null or ...": así cada una
    -- tiene su plan (la de unos prefijos va por índice; la de todo,
    -- recorriendo la tabla una vez).
    if prefijos is null then
        insert into public.vencimientos as v
            (id_licitacion, prefijo_principal, titulo, organo, provincia,
             enlace, clase, cif, empresa, adjudicatarios, importe, inicio,
             duracion_meses, fin, prorroga, fin_maximo, vence, actualizado)
        select c.id_licitacion, c.prefijo_principal, c.titulo, c.organo,
               c.provincia, c.enlace, c.clase, c.cif, c.empresa,
               c.adjudicatarios, c.importe, c.inicio, c.duracion_meses,
               c.fin, c.prorroga, c.fin_maximo, c.vence, sello
        from public.vencimientos_calculados c
        on conflict (id_licitacion) do update
            set prefijo_principal = excluded.prefijo_principal,
                titulo = excluded.titulo, organo = excluded.organo,
                provincia = excluded.provincia, enlace = excluded.enlace,
                clase = excluded.clase, cif = excluded.cif,
                empresa = excluded.empresa,
                adjudicatarios = excluded.adjudicatarios,
                importe = excluded.importe, inicio = excluded.inicio,
                duracion_meses = excluded.duracion_meses,
                fin = excluded.fin, prorroga = excluded.prorroga,
                fin_maximo = excluded.fin_maximo, vence = excluded.vence,
                actualizado = excluded.actualizado;
        get diagnostics metidas = row_count;

        delete from public.vencimientos where actualizado < sello;
        get diagnostics barridas = row_count;
    else
        insert into public.vencimientos as v
            (id_licitacion, prefijo_principal, titulo, organo, provincia,
             enlace, clase, cif, empresa, adjudicatarios, importe, inicio,
             duracion_meses, fin, prorroga, fin_maximo, vence, actualizado)
        select c.id_licitacion, c.prefijo_principal, c.titulo, c.organo,
               c.provincia, c.enlace, c.clase, c.cif, c.empresa,
               c.adjudicatarios, c.importe, c.inicio, c.duracion_meses,
               c.fin, c.prorroga, c.fin_maximo, c.vence, sello
        from public.vencimientos_calculados c
        where c.prefijo_principal = any(prefijos)
        on conflict (id_licitacion) do update
            set prefijo_principal = excluded.prefijo_principal,
                titulo = excluded.titulo, organo = excluded.organo,
                provincia = excluded.provincia, enlace = excluded.enlace,
                clase = excluded.clase, cif = excluded.cif,
                empresa = excluded.empresa,
                adjudicatarios = excluded.adjudicatarios,
                importe = excluded.importe, inicio = excluded.inicio,
                duracion_meses = excluded.duracion_meses,
                fin = excluded.fin, prorroga = excluded.prorroga,
                fin_maximo = excluded.fin_maximo, vence = excluded.vence,
                actualizado = excluded.actualizado;
        get diagnostics metidas = row_count;

        delete from public.vencimientos
        where prefijo_principal = any(prefijos) and actualizado < sello;
        get diagnostics barridas = row_count;
    end if;

    raise notice 'vencimientos: % al día, % barridos', metidas, barridas;
    return metidas;
end;
$function$;

revoke execute on function public.refrescar_vencimientos(text[]) from public, anon, authenticated;
grant execute on function public.refrescar_vencimientos(text[]) to service_role;


-- ------------------------------------------------------------
-- (5) Lo que lee la web
-- ------------------------------------------------------------
-- Para la empresa activa (`mi_perfil_id()`), en sus prefijos, sin lo que
-- el clasificador del mercado ya dijo que no es de su sector (lo mismo
-- que Movimientos). Devuelve:
--   cuantos     {"3": n, "6": n, "12": n}, con la provincia elegida
--   provincias  las que tienen algo en 12 meses, sin filtrar
--   importe     la suma de lo que vence en el plazo elegido
--   mios        cuántos de esos son de la empresa
--   actualizado cuándo se rehízo la tabla (null: aún no se ha rellenado)
--   filas       los `tope` primeros por fecha de vencimiento
create or replace function public.lo_que_viene(
    meses integer default 12,
    provincia_elegida text default null,
    tope integer default 300)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id, p.cif,
               array(select trim(x)
                     from unnest(string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                     where trim(x) <> '') as prefijos,
               (now() at time zone 'Europe/Madrid')::date as hoy,
               least(greatest(coalesce(meses, 12), 1), 12) as plazo
        from public.perfiles p
        where p.id = public.mi_perfil_id()
    ),
    -- Todo lo de su sector en los 12 meses, sin la provincia: de aquí
    -- salen las provincias del filtro.
    sector as materialized (
        select v.*,
               v.vence < yo.hoy + interval '3 months' as en_3,
               v.vence < yo.hoy + interval '6 months' as en_6,
               v.vence < yo.hoy + make_interval(months => yo.plazo) as en_plazo
        from yo
        join public.vencimientos v
          on (v.prefijo_principal = any(yo.prefijos)
              or left(v.prefijo_principal, 2) = any(yo.prefijos))
         and v.vence >= yo.hoy
         and v.vence < yo.hoy + interval '12 months'
        where coalesce((select m.del_sector from public.veredictos_mercado m
                        where m.perfil_id = yo.id
                          and m.id_licitacion = v.id_licitacion), true)
    ),
    zona as (
        select s.* from sector s
        where provincia_elegida is null or s.provincia = provincia_elegida
    ),
    elegidos as (
        -- Es tuyo si lo ganaste tú, o uno de sus lotes. El reparto por
        -- empresa solo se mira si lo ganaron varias: con 2.024 filas,
        -- mirarlo en todas llevaba la lectura en frío a 1,2 s.
        select z.*,
               yo.cif is not null and (z.cif = yo.cif or (
                   coalesce(z.adjudicatarios, 1) > 1 and exists (
                       select 1 from public.adjudicaciones_empresa a
                       where a.id_licitacion = z.id_licitacion and a.cif = yo.cif))) as es_mia,
               exists (select 1 from public.seguimiento s
                       where s.perfil_id = yo.id and s.cif = z.cif) as la_sigo
        from zona z cross join yo
        where z.en_plazo
    )
    select jsonb_build_object(
        'cuantos', (select jsonb_build_object(
                        '3', count(*) filter (where en_3),
                        '6', count(*) filter (where en_6),
                        '12', count(*))
                    from zona),
        'provincias', (select coalesce(jsonb_agg(distinct provincia order by provincia), '[]')
                       from sector where provincia is not null),
        'importe', (select coalesce(sum(importe), 0) from elegidos),
        'mios', (select count(*) from elegidos where es_mia),
        'actualizado', (select max(actualizado) from public.vencimientos),
        'filas', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'id_licitacion', e.id_licitacion, 'titulo', e.titulo,
                       'organo', e.organo, 'provincia', e.provincia,
                       'enlace', e.enlace, 'clase', e.clase, 'cif', e.cif,
                       'empresa', e.empresa, 'adjudicatarios', e.adjudicatarios,
                       'importe', e.importe, 'inicio', e.inicio,
                       'duracion_meses', e.duracion_meses, 'fin', e.fin,
                       'prorroga', e.prorroga, 'fin_maximo', e.fin_maximo,
                       'vence', e.vence, 'es_mia', e.es_mia, 'la_sigo', e.la_sigo)
                   order by e.vence, e.importe desc nulls last)
            from (select * from elegidos
                  order by vence, importe desc nulls last
                  limit least(greatest(coalesce(tope, 300), 1), 2000)) e
        ), '[]'))
    from yo;
$function$;

revoke execute on function public.lo_que_viene(integer, text, integer) from public, anon;
grant execute on function public.lo_que_viene(integer, text, integer) to authenticated, service_role;


-- ------------------------------------------------------------
-- (6) Cada día, después de los demás agregados (14:00-14:30 UTC)
-- ------------------------------------------------------------
select cron.schedule('refrescar-vencimientos', '45 14 * * *',
                     'select public.refrescar_vencimientos()');
