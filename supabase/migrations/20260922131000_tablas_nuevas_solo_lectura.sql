-- ============================================================
-- TABLAS NUEVAS DEL 22/09/2026: SOLO LECTURA PARA LOS USUARIOS
-- ============================================================
--
-- Supabase da por defecto a `authenticated` TRUNCATE, REFERENCES y
-- TRIGGER sobre cada tabla nueva. TRUNCATE se salta RLS; la API
-- (PostgREST) no lo expone por HTTP, así que no era explotable, pero
-- sobra. Estas tablas se escriben solo a través de funciones
-- (guardar_sectores, guardar_avisos): el usuario solo necesita leerlas.
-- ============================================================

revoke truncate, references, trigger
    on public.sectores_perfil, public.avisos_perfil, public.avisos_sectores
    from authenticated;
