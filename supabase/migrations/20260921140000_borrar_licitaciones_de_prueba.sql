-- ============================================================
-- BORRAR LAS LICITACIONES DE PRUEBA DE LA GENERALITAT
-- ============================================================
--
-- Aplicada el 21/09/2026.
--
-- El canal agregado del Estado replica anuncios del entorno de pruebas
-- de contractaciopublica.cat: 54 licitaciones con el enlace apuntando a
-- http://localhost:4204/..., títulos como "test", "dd", "wdqwdwdqqwd" o
-- "20250610 lots" e importes de 1 a 3 €. Una de ellas —"test", en
-- estado PUB y con 100.000.000 € de presupuesto— salía en la lista de
-- contratos abiertos de un perfil de construcción como "para mí".
--
-- Se borran con todo lo que cuelga de ellas. No hay claves foráneas
-- hacia `licitaciones`, así que se limpia a mano cada tabla que guarda
-- `id_licitacion`. Antes se copia todo a `respaldo_licitaciones_prueba`
-- por si hubiera que recuperar algo.
--
-- Lo que NO se borra: tres licitaciones del Estado tituladas "Prueba" o
-- "Pruebas" (10.000 €, 180.000 € y 3.255 €). Pueden ser contratos reales
-- de pruebas médicas o de exámenes; el criterio aquí es el enlace a
-- localhost, que no deja dudas.
--
-- Para que no vuelvan a entrar, lector_atom.py descarta desde hoy las
-- entradas cuyo enlace apunta a localhost.
-- ============================================================

create table if not exists public.respaldo_licitaciones_prueba (
    tabla      text not null,
    fila       jsonb not null,
    borrada    timestamptz not null default now()
);
alter table public.respaldo_licitaciones_prueba enable row level security;
revoke all on public.respaldo_licitaciones_prueba from anon, authenticated;

create temp table _prueba on commit drop as
    select id_licitacion from public.licitaciones
    where enlace ilike 'http://localhost%' or enlace ilike 'https://localhost%'
       or enlace ilike 'http://127.0.0.1%';

insert into public.respaldo_licitaciones_prueba (tabla, fila)
          select 'licitaciones', to_jsonb(t) from public.licitaciones t join _prueba using (id_licitacion)
union all select 'veredictos', to_jsonb(t) from public.veredictos t join _prueba using (id_licitacion)
union all select 'veredictos_mercado', to_jsonb(t) from public.veredictos_mercado t join _prueba using (id_licitacion)
union all select 'correcciones', to_jsonb(t) from public.correcciones t join _prueba using (id_licitacion)
union all select 'ejemplos_entrenamiento', to_jsonb(t) from public.ejemplos_entrenamiento t join _prueba using (id_licitacion)
union all select 'palabras_titulo', to_jsonb(t) from public.palabras_titulo t join _prueba using (id_licitacion);

delete from public.veredictos             where id_licitacion in (select id_licitacion from _prueba);
delete from public.veredictos_mercado     where id_licitacion in (select id_licitacion from _prueba);
delete from public.correcciones           where id_licitacion in (select id_licitacion from _prueba);
delete from public.ejemplos_entrenamiento where id_licitacion in (select id_licitacion from _prueba);
delete from public.palabras_titulo        where id_licitacion in (select id_licitacion from _prueba);
delete from public.licitaciones           where id_licitacion in (select id_licitacion from _prueba);
