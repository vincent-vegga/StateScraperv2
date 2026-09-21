-- ============================================================
-- "UTE UTE AMSASJA25" -> "UTE AMSASJA25"
-- ============================================================
--
-- Aplicada el 21/09/2026.
--
-- El órgano publicó el adjudicatario con la forma jurídica repetida en
-- 29 licitaciones, y salía así en el ranking de competidores. Desde hoy
-- lo limpia el scraper al extraerlo (limpiar_nombre_adjudicatario en
-- lector_atom.py); esto arregla lo que ya estaba guardado.
--
-- Solo "UTE" repetido: otras repeticiones al principio del nombre son
-- legítimas ("GARCIA GARCIA ALICIA", "FRIO FRIO INSTALACIONES").
-- En las expresiones regulares de Postgres el límite de palabra es \y,
-- no \b (que ahí es el carácter de retroceso).
-- ============================================================

-- Primero las adjudicaciones, filtrando por el adjudicatario principal:
-- buscar en el JSON convertido a texto recorrería el millón de filas.
update public.licitaciones l
   set adjudicaciones = (
       select jsonb_agg(
                case when a->>'adjudicatario' ~* '^\s*UTE\s+UTE\y'
                     then jsonb_set(a, '{adjudicatario}', to_jsonb(
                            regexp_replace(a->>'adjudicatario',
                                           '^\s*(UTE\s+)+(?=UTE\y)', '', 'i')))
                     else a end
                order by ord)
       from jsonb_array_elements(l.adjudicaciones) with ordinality as e(a, ord))
 where l.adjudicatario ~* '^\s*UTE\s+UTE\y'
   and jsonb_typeof(l.adjudicaciones) = 'array'
   and jsonb_array_length(l.adjudicaciones) > 0;

update public.licitaciones
   set adjudicatario = regexp_replace(adjudicatario, '^\s*(UTE\s+)+(?=UTE\y)', '', 'i')
 where adjudicatario ~* '^\s*UTE\s+UTE\y';

update public.empresas
   set nombre = regexp_replace(nombre, '^\s*(UTE\s+)+(?=UTE\y)', '', 'i'),
       nombre_norm = regexp_replace(nombre_norm, '^\s*(UTE\s+)+(?=UTE\y)', '', 'i')
 where nombre ~* '^\s*UTE\s+UTE\y';
