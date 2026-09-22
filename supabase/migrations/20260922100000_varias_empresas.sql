-- ============================================================
-- VARIAS EMPRESAS POR CUENTA (hasta 3)
-- ============================================================
--
-- Un betatester lleva varias empresas y pidió poder vigilarlas desde
-- una sola cuenta. El modelo ya lo permitía casi entero: todo cuelga de
-- `perfil_id` (veredictos, seguimiento, correcciones, fichas...), no del
-- usuario. Lo que lo impedía:
--
--   1. Un índice ÚNICO sobre perfiles.usuario_id.
--   2. Veinte funciones que encuentran "mi perfil" con
--      `usuario_id = auth.uid()`. Con dos perfiles, las que hacen
--      `select ... into` o una subconsulta escalar fallan o cogen uno al
--      azar, y las que cruzan con `perfiles p` mezclan las empresas.
--
-- CÓMO SE SABE QUÉ EMPRESA ESTÁ MIRANDO
--
-- La web manda en cada petición la cabecera `x-perfil` con el perfil
-- activo, y `mi_perfil_id()` la lee de `request.headers` (PostgREST la
-- expone ahí). Se descartó guardar "la empresa activa" en la base: la
-- cuenta se usa desde varios dispositivos a la vez, y cambiar de empresa
-- en el móvil le cambiaría la pantalla al ordenador.
--
-- La cabecera NO da acceso a nada: `mi_perfil_id()` solo devuelve
-- perfiles del propio usuario. Un id ajeno, uno inventado o ninguno caen
-- en su perfil más antiguo, que es exactamente lo que devolvía todo
-- antes de este cambio. Quien no mande la cabecera (versiones viejas de
-- la web en caché) sigue funcionando igual que hoy.
--
-- Las definiciones anteriores quedan en `respaldo_funciones_20260922`
-- para poder volver atrás sin reconstruirlas.
-- ============================================================

-- ---------- 1. Respaldo ----------
create table if not exists public.respaldo_funciones_20260922 (
    oid        oid primary key,
    nombre     text not null,
    definicion text not null,
    guardado   timestamptz not null default now()
);
alter table public.respaldo_funciones_20260922 enable row level security;
revoke all on public.respaldo_funciones_20260922 from anon, authenticated;

insert into public.respaldo_funciones_20260922 (oid, nombre, definicion)
select p.oid, p.proname, pg_get_functiondef(p.oid)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.prokind = 'f'
  and (pg_get_functiondef(p.oid) ~* 'usuario_id\s*=\s*auth\.uid\(\)'
       or p.proname = 'canjear_codigo')
on conflict (oid) do nothing;

-- ---------- 2. La empresa activa ----------
create or replace function public.mi_perfil_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
    select p.id
    from public.perfiles p
    where p.usuario_id = (select auth.uid())
    order by (p.id::text = coalesce(
                 nullif(current_setting('request.headers', true), '')::json
                   ->> 'x-perfil', '')) desc,
             p.fecha_alta, p.id
    limit 1
$$;
revoke all on function public.mi_perfil_id() from public, anon;
grant execute on function public.mi_perfil_id() to authenticated, service_role;

-- ---------- 3. Las veinte funciones pasan a la empresa activa ----------
--
-- Se reescriben dentro de la base en vez de copiarlas aquí: son 46.000
-- caracteres y el único cambio es una condición por función. Se dejan
-- fuera a propósito:
--   · perfil_permitido: comprueba que un perfil DADO es del usuario; debe
--     aceptar cualquiera de sus empresas, no solo la activa.
--   · marcar_bienvenida: la bienvenida es de la persona, no de la
--     empresa. Se marca en todas.
do $$
declare
    f record;
    nueva text;
begin
    for f in
        select p.oid, p.proname, pg_get_functiondef(p.oid) as d
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.prokind = 'f'
          and pg_get_functiondef(p.oid) ~* 'usuario_id\s*=\s*auth\.uid\(\)'
          and p.proname not in ('perfil_permitido', 'marcar_bienvenida')
    loop
        nueva := regexp_replace(f.d,
            '(\m[a-z_]+\.)?usuario_id\s*=\s*auth\.uid\(\)',
            '\1id = public.mi_perfil_id()', 'gi');
        execute nueva;
        raise notice 'Reescrita: %', f.proname;
    end loop;
end $$;

-- ---------- 4. Más de un perfil por usuario, hasta 3 ----------
drop index if exists public.idx_perfiles_usuario;
create index if not exists idx_perfiles_usuario
    on public.perfiles (usuario_id, fecha_alta);

-- El tope vive en la base: en la web se lo saltaría cualquiera con la
-- consola abierta. El bloqueo por usuario evita que dos altas simultáneas
-- (dos pestañas) cuenten a la vez 2 y metan la cuarta.
create or replace function public.tope_empresas()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.usuario_id is null then return new; end if;
    perform pg_advisory_xact_lock(hashtext('perfiles:' || new.usuario_id::text));
    if (select count(*) from public.perfiles where usuario_id = new.usuario_id) >= 3 then
        raise exception 'tope_empresas' using errcode = 'P0001';
    end if;
    return new;
end;
$$;
revoke all on function public.tope_empresas() from public, anon, authenticated;

drop trigger if exists tope_empresas on public.perfiles;
create trigger tope_empresas before insert on public.perfiles
    for each row execute function public.tope_empresas();

-- Nadie crea perfiles por la API directamente. Con el índice único esto
-- no importaba (solo cabía uno), pero sin él dejaría abrir perfiles sin
-- código de acceso. Se entra por canjear_codigo (el primero) o por
-- nueva_empresa (los demás).
drop policy if exists "perfil propio: crear" on public.perfiles;

-- ---------- 5. Añadir y quitar empresas ----------
create or replace function public.nueva_empresa()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    quien uuid := auth.uid();
    base  public.perfiles%rowtype;
    nuevo uuid;
begin
    if quien is null then
        return jsonb_build_object('ok', false, 'error', 'sin_sesion');
    end if;
    perform pg_advisory_xact_lock(hashtext('perfiles:' || quien::text));

    -- Hace falta tener ya una empresa: el código de acceso se canjeó con
    -- ella, y las demás lo heredan.
    select * into base from public.perfiles
    where usuario_id = quien order by fecha_alta, id limit 1;
    if not found then
        return jsonb_build_object('ok', false, 'error', 'sin_perfil');
    end if;

    -- Una empresa empezada y abandonada antes de poner el NIF se reutiliza
    -- en vez de gastar otro hueco.
    select id into nuevo from public.perfiles
    where usuario_id = quien and paso_alta <> 'listo'
      and cif is null and descripcion is null
    order by fecha_alta desc limit 1;
    if found then
        return jsonb_build_object('ok', true, 'perfil_id', nuevo);
    end if;

    if (select count(*) from public.perfiles where usuario_id = quien) >= 3 then
        return jsonb_build_object('ok', false, 'error', 'tope_empresas');
    end if;

    insert into public.perfiles (nombre, email, usuario_id, codigo_usado,
                                 paso_alta, vio_bienvenida, avisos)
    values (base.nombre, base.email, quien, base.codigo_usado,
            'describiendo', true, base.avisos)
    returning id into nuevo;

    return jsonb_build_object('ok', true, 'perfil_id', nuevo);
end;
$$;
revoke all on function public.nueva_empresa() from public, anon;
grant execute on function public.nueva_empresa() to authenticated;

create or replace function public.quitar_empresa(perfil uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    quien uuid := auth.uid();
begin
    if quien is null then
        return jsonb_build_object('ok', false, 'error', 'sin_sesion');
    end if;
    perform pg_advisory_xact_lock(hashtext('perfiles:' || quien::text));

    if not exists (select 1 from public.perfiles
                   where id = perfil and usuario_id = quien) then
        return jsonb_build_object('ok', false, 'error', 'no_es_tuya');
    end if;
    -- La última no se quita: la cuenta se quedaría sin perfil y volvería
    -- a pedir el código de acceso.
    if (select count(*) from public.perfiles where usuario_id = quien) <= 1 then
        return jsonb_build_object('ok', false, 'error', 'ultima_empresa');
    end if;

    -- ON DELETE CASCADE se lleva sus veredictos, seguimiento, etc.
    delete from public.perfiles where id = perfil and usuario_id = quien;
    return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.quitar_empresa(uuid) from public, anon;
grant execute on function public.quitar_empresa(uuid) to authenticated;

-- ---------- 6. canjear_codigo con varios perfiles ----------
-- `select into` sin orden cogía uno cualquiera. Da igual cuál para decir
-- "ya estaba", pero el paso devuelto debe ser estable.
create or replace function public.canjear_codigo(codigo_entrada text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
    fila   public.codigos_acceso%rowtype;
    quien  uuid := auth.uid();
    perfil public.perfiles%rowtype;
begin
    if quien is null then
        return jsonb_build_object('ok', false, 'error', 'sin_sesion');
    end if;

    -- Si ya tiene perfil, no hace falta código: es alguien que
    -- vuelve, no alguien que entra.
    select * into perfil from public.perfiles where usuario_id = quien
    order by fecha_alta, id limit 1;
    if found then
        return jsonb_build_object('ok', true, 'perfil_id', perfil.id,
                                  'paso', perfil.paso_alta, 'ya_estaba', true);
    end if;

    select * into fila from public.codigos_acceso
    -- Sin distinguir mayúsculas: nadie recuerda si un código las
    -- llevaba, y menos si se lo han pasado por WhatsApp.
    where lower(codigo) = lower(trim(codigo_entrada)) for update;

    if not found then
        return jsonb_build_object('ok', false, 'error', 'codigo_no_valido');
    end if;
    if fila.caduca is not null and fila.caduca < now() then
        return jsonb_build_object('ok', false, 'error', 'codigo_caducado');
    end if;
    if fila.usos >= fila.usos_maximos then
        return jsonb_build_object('ok', false, 'error', 'codigo_agotado');
    end if;

    update public.codigos_acceso set usos = usos + 1 where codigo = fila.codigo;

    insert into public.perfiles (nombre, email, usuario_id, codigo_usado, paso_alta)
    values (coalesce((select email from auth.users where id = quien), 'Sin nombre'),
            (select email from auth.users where id = quien),
            quien, fila.codigo, 'describiendo')
    returning * into perfil;

    return jsonb_build_object('ok', true, 'perfil_id', perfil.id,
                              'paso', perfil.paso_alta, 'ya_estaba', false);
end;
$function$;
