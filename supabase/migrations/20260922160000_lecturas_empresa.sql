-- ============================================================
-- MISMA EMPRESA, MISMA LECTURA
-- ============================================================
--
-- El criterio de una empresa lo escribe el modelo leyendo sus contratos
-- ganados, y no es determinista: dos altas de Soltec (22/09/2026) dieron
-- 38 y 17 contratos en la lista, y cinco más, entre 23 y 35.
--
-- Aquí se guarda la lectura del modelo por NIF (criterio, prefijos
-- válidos, actividad, lo que se le enseña al cliente). Un perfil NUEVO
-- con un NIF ya leído la reutiliza: mismo resultado, sin esperar al
-- modelo y sin pagarlo. Quien rehace su filtro (criterio_version > 0)
-- obtiene una lectura nueva, que pasa a ser la guardada.
--
-- Caduca a los 30 días: la empresa gana contratos nuevos y conviene
-- releerla. Solo la toca la función de alta con la clave de servicio.
-- ============================================================

create table if not exists public.lecturas_empresa (
    cif    text primary key,
    datos  jsonb not null,
    creado timestamptz not null default now()
);

alter table public.lecturas_empresa enable row level security;
revoke all on public.lecturas_empresa from anon, authenticated;
