-- ============================================================
-- `incumbencia`: 11,2 s -> 5,1 s, con resultado idéntico
-- ============================================================
--
-- Aplicada el 20/09/2026.
--
-- EL FALLO
-- La pestaña de viabilidad falla con "No hemos podido analizar este
-- contrato" cuando el contrato pertenece a un grupo grande de
-- órgano + familia CPV. Medido:
--
--   incumbencia, grupo de 5.365 contratos .... 17.963 ms
--   viabilidad (que la llama) ................ 10.830 ms
--
-- Contra un statement_timeout de 8 s, eso es fallo seguro.
--
-- ALCANCE: de las 4.517 licitaciones vivas, 17 (0,4%) caen en grupos
-- de 1.000 o más y fallaban siempre; otras 84 (1,9%) iban al límite.
-- Estrecho, pero con 30 personas trasteando alguien lo pincha.
--
-- LA CAUSA
-- El predicado era:
--
--     public.parecido_util(o.titulo, este.titulo) >= 0.4
--
-- y parecido_util calcula palabras_utiles() de SUS DOS argumentos en
-- cada llamada. Como `este.titulo` es el mismo para todas las filas
-- del grupo, en un grupo de 5.365 contratos se hacían 5.365 cálculos
-- idénticos del mismo título, tirados.
--
-- Dato revelador que salió midiendo: en esos grupos grandes el 90% de
-- los contratos (4.845 de 5.365) pasan el filtro de parecido. La
-- comparación cara no estaba descartando casi nada; era coste sin
-- beneficio.
--
-- EL ARREGLO
-- Se añade parecido_con(titulo, palabras[]), que recibe las palabras
-- del título de referencia ya calculadas, y se le pasan mediante una
-- subconsulta NO correlacionada, que Postgres resuelve una sola vez
-- como InitPlan.
--
-- El criterio no cambia: misma fórmula, mismo umbral 0.4. Verificado
-- antes de sustituir nada, comparando la versión vieja y la nueva
-- sobre 120 licitaciones vivas reales: 120 resultados idénticos, más
-- el caso peor también idéntico.
--
-- QUEDA MARGEN si hiciera falta: la CTE `familia` vuelve a recorrer el
-- mismo grupo que `mismas`, y solo se usa cuando `mismas` tiene menos
-- de 2 filas. Unificarlas ahorraría otro tanto. No se toca ahora
-- porque 5,1 s ya cabe bajo el límite y el cambio es más invasivo.
-- ============================================================

create or replace function public.parecido_con(a text, pb text[])
returns real
language sql
immutable
set search_path to 'public'
as $$
    with pa as (select public.palabras_utiles(a) as v)
    select case
        when array_length(pa.v, 1) is null or array_length(pb, 1) is null then 0
        else (select count(*) from (
                select unnest(pa.v) intersect select unnest(pb)) c)::real
             / least(array_length(pa.v, 1), array_length(pb, 1))
    end
    from pa;
$$;

revoke execute on function public.parecido_con(text, text[]) from public, anon;
grant  execute on function public.parecido_con(text, text[]) to authenticated;

-- El cuerpo de incumbencia queda igual salvo el predicado de `mismas`.
-- Ver la definición aplicada en la migración `incumbencia_rapida`.
