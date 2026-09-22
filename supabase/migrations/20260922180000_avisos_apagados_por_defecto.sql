-- ============================================================
-- EL AVISO POR CORREO SE ENCIENDE, NO SE APAGA
-- ============================================================
--
-- Al activar el envío diario (22/09/2026), nadie debía recibir un correo
-- que no hubiera pedido: los betatesters entraron cuando el correo estaba
-- apagado y no lo esperan.
--
-- Se apaga en todos los perfiles y el valor por defecto pasa a `false`:
-- quien quiera el aviso lo enciende con la campana de la cabecera, y ahí
-- elige qué le llega (sectores y zona) en Mi cuenta -> Mis avisos.
--
-- `nueva_empresa` copia el valor del primer perfil del usuario, así que
-- una empresa añadida hereda lo que esa persona ya decidió.
-- ============================================================

alter table public.perfiles alter column avisos set default false;
update public.perfiles set avisos = false where avisos;
