-- ============================================================
-- Año de formalización (2 de 3): relleno e índices
-- ============================================================
--
-- SIN APLICAR. Después del paso 1 y antes del 3.
--
-- FUERA DE TRANSACCIÓN, sentencia a sentencia (el relleno va por tandas
-- con commit y los índices son `concurrently`). El relleno toca ~1,1
-- millones de filas de `adjudicaciones_empresa`.
--
-- Aquí todavía no hay fechas de formalización (llegan al reprocesar):
-- de momento cada contrato queda en su fecha de adjudicación o, si no la
-- tiene, en la de siempre. Sin menores desde ya.
--
-- La web sigue igual durante todo el paso: todavía lee con las funciones
-- viejas, que no usan nada de esto.
-- ============================================================


-- ------------------------------------------------------------
-- a) Fecha de mercado y marca de menor en `adjudicaciones_empresa`
-- ------------------------------------------------------------
-- Por tandas de licitaciones, con commit en cada una, para no tener un
-- millón de filas bloqueadas en una sola transacción. Se puede cortar y
-- relanzar: solo escribe las filas que no cuadran.
create or replace procedure public.rellenar_fecha_mercado(tanda int default 20000)
language plpgsql
set search_path to 'public'
as $procedure$
declare
    ultimo text := '';
    hasta  text;
    n      int;
    total  int := 0;
begin
    loop
        select max(t.id_licitacion) into hasta
        from (select l.id_licitacion from public.licitaciones l
              where l.id_licitacion > ultimo
              order by l.id_licitacion limit tanda) t;
        exit when hasta is null;

        update public.adjudicaciones_empresa a
           set fecha = x.fecha, es_menor = x.menor
          from (select l.id_licitacion,
                       public.fecha_mercado(l.fecha_formalizacion,
                                            l.fecha_adjudicacion,
                                            l.fecha_formalizacion_estimada,
                                            l.fecha_actualizacion) as fecha,
                       coalesce(l.procedimiento = 'Contrato menor', false) as menor
                from public.licitaciones l
                where l.id_licitacion > ultimo and l.id_licitacion <= hasta) x
         where a.id_licitacion = x.id_licitacion
           and (a.fecha is distinct from x.fecha or a.es_menor is distinct from x.menor);

        get diagnostics n = row_count;
        total := total + n;
        commit;
        raise notice 'hasta % · % filas (% en total)', right(hasta, 12), n, total;
        ultimo := hasta;
    end loop;
end;
$procedure$;

revoke all on procedure public.rellenar_fecha_mercado(int) from public, anon, authenticated;

call public.rellenar_fecha_mercado();

drop procedure public.rellenar_fecha_mercado(int);


-- ------------------------------------------------------------
-- b) Índices
-- ------------------------------------------------------------
-- Los mismos que usaban las funciones de periodo, pero por fecha de
-- mercado y sin menores (entran unas 560.000 filas, no 1,1 millones).
-- Llevan dentro las tres fechas de las que sale la de mercado: sin
-- ellas no hay lectura solo del índice y cada consulta iría a la tabla.
-- Los viejos (`idx_licitaciones_periodo`, `idx_licitaciones_organo_periodo`)
-- se quedan: los usan `pulso_mercado`, `movimientos_mercado` y otras
-- consultas por días. Se pueden revisar cuando la web vieja desaparezca.
create index concurrently if not exists idx_licitaciones_mercado
on public.licitaciones (
    prefijo_principal,
    public.fecha_mercado(fecha_formalizacion, fecha_adjudicacion,
                         fecha_formalizacion_estimada, fecha_actualizacion))
include (id_licitacion, importe_adjudicacion, organo, provincia,
         fecha_formalizacion, fecha_adjudicacion, fecha_formalizacion_estimada,
         fecha_actualizacion)
where adjudicatario_cif is not null
  and procedimiento is distinct from 'Contrato menor';

create index concurrently if not exists idx_licitaciones_organo_mercado
on public.licitaciones (
    organo, prefijo_principal,
    public.fecha_mercado(fecha_formalizacion, fecha_adjudicacion,
                         fecha_formalizacion_estimada, fecha_actualizacion))
include (id_licitacion, importe_adjudicacion, presupuesto_base, importe_sin_iva,
         lotes, sistema, licitadores, procedimiento, provincia,
         fecha_formalizacion, fecha_adjudicacion, fecha_formalizacion_estimada,
         fecha_actualizacion)
where adjudicatario_cif is not null
  and procedimiento is distinct from 'Contrato menor';

-- Sustituye a `idx_adjudicaciones_empresa_periodo`: el mismo, sin menores.
create index concurrently if not exists idx_adjudicaciones_empresa_mercado
on public.adjudicaciones_empresa (prefijo_principal, fecha)
include (id_licitacion, cif, nombre, importe)
where not es_menor;

-- Solo después del paso 3, cuando ya nada lo use:
--   drop index concurrently public.idx_adjudicaciones_empresa_periodo;

vacuum (analyze) public.adjudicaciones_empresa;
analyze public.licitaciones;


-- ------------------------------------------------------------
-- c) Comprobaciones antes de pasar al 3
-- ------------------------------------------------------------
-- Ninguna fila descuadrada (debe dar 0):
--   select count(*) from public.adjudicaciones_empresa a
--   join public.licitaciones l using (id_licitacion)
--   where a.fecha is distinct from public.fecha_mercado(
--             l.fecha_formalizacion, l.fecha_adjudicacion,
--             l.fecha_formalizacion_estimada, l.fecha_actualizacion)
--      or a.es_menor is distinct from coalesce(l.procedimiento = 'Contrato menor', false);


-- ------------------------------------------------------------
-- Después del paso 3: reprocesar el 643 y el 1044
-- ------------------------------------------------------------
-- Con `procesar_historico.py` ya actualizado, relanzar los meses de
-- 2024-01 a 2026-09 EN ORDEN y de uno en uno (PENDIENTES §6):
--
--   gh workflow run scraper.yml -f modo=catalogar_historico \
--      -f conjunto_xml=643 -f catalogo_anio=2024 -f catalogo_meses=1
--
-- En orden porque, a igual expediente, manda la versión más reciente:
-- empezar por los meses viejos deja al final la foto buena. Cada mes
-- rellena la formalización de lo que ya estaba y rehace sus repartos.
