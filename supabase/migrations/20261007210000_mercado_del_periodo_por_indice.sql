-- ============================================================
-- Mercado del periodo: que el índice filtre también por fecha
-- ============================================================
--
-- `mercado_del_periodo` alimenta las tres pantallas más lentas de la web
-- (medido en pg_stat_statements del 01/10 al 07/10/2026, rol
-- authenticated):
--
--   resumen_periodo ......... 1.989 ms de media, 5.440 ms de máximo
--   competencia_periodo ..... 1.426 ms de media, 6.583 ms de máximo
--   movimientos_periodo .....   921 ms de media, 2.750 ms de máximo
--
-- El límite es de 8 s, y el máximo ya se acerca.
--
-- EL FALLO
-- `idx_licitaciones_cuentan` está hecho para esta consulta: (prefijo,
-- fecha_mercado(...)) con el mismo filtro parcial. Pero la fecha se pide a
-- través de `en_periodo(fecha_mercado(...), desde, hasta)`, y Postgres no
-- puede meter `en_periodo` dentro de la consulta: usa su argumento dos
-- veces y ese argumento es caro (el CASE de `fecha_mercado`), así que la
-- deja como función opaca. Resultado: el índice solo filtra por prefijo,
-- lee TODOS los años del sector y descarta después los que no son.
--
-- Medido el 07/10/2026 con el perfil de sector más grande (72.861
-- adjudicaciones, año 2026, caché caliente):
--
--   antes: Index Cond solo por prefijo, 42.979 filas leídas,
--          33.576 descartadas ......................... 500 ms
--   ahora: Index Cond por prefijo Y fecha, 9.403 filas  84 ms
--
-- Mismas 9.403 filas en los dos casos.
--
-- APLICADO el 07/10/2026. Antes de aplicar se compararon las dos
-- condiciones fila a fila en seis periodos (2023, 2024, 2025, 2026,
-- 2023-2026 y sin años): 0 diferencias. Después, como el usuario real de
-- ese perfil y con la caché caliente (incluye la reconstrucción de
-- índices de 20261007211000):
--
--   movimientos_periodo   1.000 -> 356 ms
--   resumen_periodo         810 -> 298 ms
--   competencia_periodo     871 -> 298 ms
--
-- EL CAMBIO
-- Solo la condición de fecha, escrita como rango sobre la misma
-- expresión del índice. Lo demás queda igual, letra por letra.
--
-- Equivalencia con `en_periodo`: `desde`/`hasta` nulos pasan a ser
-- -infinity/infinity, que es lo que significaban. La única diferencia
-- sería una fila con `fecha_mercado` nula, que antes entraba cuando
-- desde y hasta eran los dos nulos; no puede darse, porque cae en
-- `fecha_actualizacion` y esa columna no tiene ni una nula (0 de
-- 1.365.272 el 07/10/2026). La web, además, nunca llama sin años.
--
-- `ficha_organismo` tiene el mismo patrón pero no se toca: va por
-- órgano, lee unas decenas de filas y tarda 29 ms de media.
--
-- `create or replace` conserva los permisos (postgres y service_role: la
-- web no la llama directamente, sino a través de resumen_periodo,
-- competencia_periodo y movimientos_periodo, que son security definer).
--
-- Para volver atrás: la definición anterior está en
-- `20260923140000_marcos_aparte.sql`.
-- ============================================================

create or replace function public.mercado_del_periodo(
    desde integer default null::integer, hasta integer default null::integer,
    provincia_elegida text default null::text)
returns table(id_licitacion text, fecha timestamptz, importe numeric,
              organo text, provincia text)
language sql
stable security definer
set search_path to 'public'
as $function$
    with yo as (
        select p.id,
               array(select trim(x) from unnest(
                   string_to_array(coalesce(p.cpv_prefijos, ''), ',')) as x
                 where trim(x) <> '') as prefijos
        from public.perfiles p where p.id = public.mi_perfil_id()
    )
    select l.id_licitacion,
           public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                                l.fecha_formalizacion_estimada, l.fecha_actualizacion),
           l.importe_adjudicacion, l.organo, l.provincia
    from yo
    join public.licitaciones l
      on l.prefijo_principal = any(yo.prefijos)
     and l.adjudicatario_cif is not null
     and l.procedimiento is distinct from 'Contrato menor'
     and not public.es_homologacion(l.sistema, l.importe_adjudicacion)
    -- Lo mismo que en_periodo(), pero en forma de rango para que entre
    -- en idx_licitaciones_cuentan (ver cabecera).
    where public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                               l.fecha_formalizacion_estimada, l.fecha_actualizacion)
            >= coalesce(make_timestamptz(desde, 1, 1, 0, 0, 0, 'Europe/Madrid'),
                        '-infinity'::timestamptz)
      and public.fecha_mercado(l.fecha_formalizacion, l.fecha_adjudicacion,
                               l.fecha_formalizacion_estimada, l.fecha_actualizacion)
            < coalesce(make_timestamptz(hasta + 1, 1, 1, 0, 0, 0, 'Europe/Madrid'),
                       'infinity'::timestamptz)
      and (provincia_elegida is null or l.provincia = provincia_elegida)
      and coalesce((select v.del_sector from public.veredictos_mercado v
                    where v.perfil_id = yo.id
                      and v.id_licitacion = l.id_licitacion), true);
$function$;


-- ------------------------------------------------------------
-- Comprobación después de aplicar (no escribe nada)
-- ------------------------------------------------------------
-- Con el uuid de usuario (auth) de un perfil de sector grande. Tiene que
-- dar el mismo número de filas que antes y bajar de ~500 ms a ~100 ms:
--
--   begin;
--   select set_config('request.jwt.claims',
--          '{"sub":"<usuario_id>","role":"authenticated"}', true);
--   set local role authenticated;
--   explain (analyze, buffers, timing off)
--     select * from public.movimientos_periodo(2026, 2026, null, 300);
--   rollback;
