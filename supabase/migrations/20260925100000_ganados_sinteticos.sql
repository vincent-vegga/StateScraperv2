-- ============================================================
-- ALTA SIN NIF: HISTORIAL SINTÉTICO PARA EL MOTOR DE HUELLAS
-- ============================================================
--
-- Aplicada el 25/09/2026.
--
-- Quien entra sin NIF no tiene contratos ganados, que es de lo que parte
-- el motor de huellas (puntuador.py). El alta ya busca los 40 contratos
-- adjudicados más parecidos a su descripción (vecinos.ts); se guardan
-- aquí y el motor los trata como si los hubiera ganado. El rasgo
-- `propio` (cuánto de lo parecido ganó ella) queda a cero solo: sin NIF
-- no hay de quién.
--
-- Medido con las 14 empresas que ya van por huellas, haciendo como si
-- entraran sin NIF (scripts/medir_sintetico.py, rama simulacion-sin-nif):
-- de lo que el motor les enseña con su NIF, lo de antes recuperaba el
-- 32 % y esto el 62 %, mejor en las 14.
--
-- Ocupa ~2 KB por perfil (40 ids). Nulo = sin historial sintético (todos
-- los perfiles anteriores): siguen como estaban.
-- ============================================================

alter table public.perfiles
    add column if not exists ganados_sinteticos text[];
