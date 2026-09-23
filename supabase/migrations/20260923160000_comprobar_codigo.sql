-- El código de acceso se pide ANTES del correo.
--
-- El orden era: correo → código del correo → código de acceso. Después
-- de escribir el código que llega al correo, aparecía otra pantalla
-- pidiendo otro código, y se leía como un error: "¿no acabo de poner
-- el código?". Ahora el código de acceso va primero, que es además lo
-- que se espera de una invitación: primero enseñas la entrada, luego
-- dices quién eres.
--
-- canjear_codigo necesita sesión (crea el perfil del usuario), así que
-- no sirve para comprobar el código antes de tenerla. Esta lo comprueba
-- sin gastarlo; el canje sigue haciéndose después, con sesión, por
-- canjear_codigo, que vuelve a comprobarlo todo.
--
-- Abrirla a anon no expone nada nuevo: cualquiera podía ya darse de
-- alta con un correo y probar códigos en canjear_codigo. Solo devuelve
-- si vale o por qué no; nada del código en sí.

create or replace function public.comprobar_codigo(codigo_entrada text)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
    fila public.codigos_acceso%rowtype;
begin
    select * into fila from public.codigos_acceso
    where lower(codigo) = lower(trim(codigo_entrada));

    if not found then
        return jsonb_build_object('ok', false, 'error', 'codigo_no_valido');
    end if;
    if fila.caduca is not null and fila.caduca < now() then
        return jsonb_build_object('ok', false, 'error', 'codigo_caducado');
    end if;
    if fila.usos >= fila.usos_maximos then
        return jsonb_build_object('ok', false, 'error', 'codigo_agotado');
    end if;
    return jsonb_build_object('ok', true);
end;
$function$;
revoke all on function public.comprobar_codigo(text) from public;
grant execute on function public.comprobar_codigo(text) to anon, authenticated;
