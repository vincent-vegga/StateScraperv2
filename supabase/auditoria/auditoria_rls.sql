-- ============================================================
-- AUDITORÍA DE PERMISOS · solo lectura
-- ============================================================
-- Ninguna de estas consultas modifica nada. Copiar y pegar en el
-- SQL Editor de Supabase. Sirven para confirmar desde dentro lo que
-- solo pudo comprobarse desde fuera, a ciegas.
-- ============================================================

-- 1 · Tablas del esquema público SIN RLS activado.
--     Lo esperado es que no devuelva ninguna fila.
select tablename
from pg_tables
where schemaname = 'public' and not rowsecurity
order by tablename;


-- 2 · Políticas que no filtran nada: dejan pasar cualquier fila.
--     `qual` nulo o 'true' significa "sin condición".
select tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and (qual is null or qual::text in ('true', '(true)'))
order by tablename, policyname;


-- 3 · Tablas con RLS activado pero SIN ninguna política.
--     No es un fallo: es el cierre total. Conviene saber cuáles son
--     para distinguirlas de las que sí deberían tener política.
select t.tablename
from pg_tables t
where t.schemaname = 'public' and t.rowsecurity
  and not exists (
    select 1 from pg_policies p
    where p.schemaname = 'public' and p.tablename = t.tablename)
order by t.tablename;


-- 4 · LA CONSULTA CLAVE: qué funciones puede ejecutar un visitante
--     sin cuenta, y cuáles de ellas se saltan RLS por ser DEFINER.
--     Una función SECURITY DEFINER ejecutable por `anon` es una
--     puerta abierta aunque todas las tablas estén cerradas.
select
    p.proname                                        as funcion,
    pg_get_function_identity_arguments(p.oid)        as argumentos,
    case p.prosecdef when true then 'DEFINER (ignora RLS)'
                     else 'invoker' end              as modo,
    has_function_privilege('anon',          p.oid, 'EXECUTE') as ejecuta_anon,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') as ejecuta_usuario
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
order by ejecuta_anon desc, p.prosecdef desc, p.proname;


-- 5 · Permisos de tabla concedidos directamente a anon.
--     RLS filtra filas, pero si además falta el GRANT no se llega
--     ni a evaluar. Útil para ver la segunda capa.
select table_name, grantee, string_agg(privilege_type, ', ' order by privilege_type) as permisos
from information_schema.role_table_grants
where table_schema = 'public' and grantee in ('anon', 'authenticated', 'public')
group by table_name, grantee
order by table_name, grantee;


-- 6 · Vistas: una vista sin `security_invoker` se ejecuta con los
--     permisos de quien la creó y puede saltarse el RLS de sus tablas.
select c.relname as vista,
       coalesce((select option_value
                 from pg_options_to_table(c.reloptions)
                 where option_name = 'security_invoker'), 'false') as security_invoker
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('v', 'm')
order by c.relname;
