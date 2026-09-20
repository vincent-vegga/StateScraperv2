#!/usr/bin/env bash
# ============================================================
# Plantillas de correo de Auth, por API
# ============================================================
#
# Para qué: el editor del panel guardó el asunto pero no el cuerpo
# (20/09/2026). Esta vía no depende de ese editor.
#
# Deja IDÉNTICAS las dos plantillas que usa signInWithOtp:
#   · confirmation -> "Confirm signup", la que reciben los usuarios NUEVOS
#   · magic_link   -> la que reciben los usuarios QUE YA EXISTEN
#
# Que las dos lleven {{ .Token }} y NINGUNA lleve {{ .ConfirmationURL }}
# es lo que garantiza que a todo el mundo le llegue un código. Mientras
# quede un ConfirmationURL, Supabase manda enlace mágico.
#
# ------------------------------------------------------------
# ANTES DE EJECUTAR: necesitas un token personal de Supabase.
#   https://supabase.com/dashboard/account/tokens  -> Generate new token
#
# Exporta el token en tu terminal (NO lo escribas dentro de este
# fichero, que está en un repositorio público):
#
#   export SUPABASE_ACCESS_TOKEN='sbp_...'
#
# Luego:  bash supabase/plantillas_correo.sh ver
#         bash supabase/plantillas_correo.sh aplicar
# ============================================================

set -euo pipefail

PROYECTO="swgrbzqxagrqdyddmvfy"
API="https://api.supabase.com/v1/projects/$PROYECTO/config/auth"

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "Falta SUPABASE_ACCESS_TOKEN. Créalo en:"
  echo "  https://supabase.com/dashboard/account/tokens"
  echo "y expórtalo:  export SUPABASE_ACCESS_TOKEN='sbp_...'"
  exit 1
fi

CUERPO='<h2>Tu código de acceso</h2><p>Escribe este código en la página para entrar:</p><p style="font-size:28px;font-weight:bold;letter-spacing:4px">{{ .Token }}</p><p>Caduca en unos minutos. Si no has sido tú, ignora este correo.</p>'
ASUNTO='{{ .Token }} es tu código de acceso'

case "${1:-ver}" in

  ver)
    # Qué hay guardado AHORA MISMO. Esto zanja la duda de si el panel
    # guardó o no: si el cuerpo sale en inglés con ConfirmationURL, no
    # guardó.
    respuesta=$(curl -sS -w '\n%{http_code}' -X GET "$API" \
      -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN")
    estado=$(printf '%s' "$respuesta" | tail -1)
    cuerpo=$(printf '%s' "$respuesta" | sed '$d')
    if [ "$estado" != "200" ]; then
      echo "La API respondió $estado, no 200. NO te fíes de lo que siga."
      echo "Casi siempre es un token revocado, caducado o sin permisos."
      printf '%s\n' "$cuerpo"
      exit 1
    fi
    printf '%s' "$cuerpo" | python3 -c '
import json, sys
c = json.load(sys.stdin)
for k in ["mailer_subjects_confirmation", "mailer_templates_confirmation_content",
          "mailer_subjects_magic_link", "mailer_templates_magic_link_content"]:
    v = c.get(k) or "(vacío: usa la plantilla por defecto de Supabase)"
    print(f"\n=== {k} ===\n{v}")
print()
for k in ["mailer_templates_confirmation_content", "mailer_templates_magic_link_content"]:
    v = c.get(k) or ""
    tiene_codigo = "{{ .Token }}" in v
    tiene_enlace = "{{ .ConfirmationURL }}" in v
    if not v:                 estado = "POR DEFECTO -> manda ENLACE"
    elif tiene_enlace:        estado = "tiene ConfirmationURL -> manda ENLACE"
    elif tiene_codigo:        estado = "solo Token -> manda CÓDIGO  ✓"
    else:                     estado = "no tiene ninguna de las dos variables (revisar)"
    print(f"{k}: {estado}")
'
    ;;

  crudo)
    # Vuelca TODOS los campos mailer_* tal como los devuelve la API,
    # distinguiendo "no viene en la respuesta" de "viene vacío". Son
    # cosas distintas: lo primero apunta a un token sin permisos o a que
    # la API no expone el campo; lo segundo, a que de verdad no hay
    # plantilla personalizada.
    respuesta=$(curl -sS -w '\n%{http_code}' -X GET "$API" \
      -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN")
    estado=$(printf '%s' "$respuesta" | tail -1)
    if [ "$estado" != "200" ]; then
      echo "La API respondió $estado, no 200. Token revocado o sin permisos."
      printf '%s' "$respuesta" | sed '$d'
      exit 1
    fi
    printf '%s' "$respuesta" | sed '$d' | python3 -c '
import json, sys
c = json.load(sys.stdin)
claves = sorted(k for k in c if k.startswith("mailer"))
print(f"Campos mailer_* devueltos por la API: {len(claves)}")
if not claves:
    print("  NINGUNO. La respuesta no trae plantillas: token sin permisos")
    print("  para leer configuracion de Auth, o la API no las expone.")
for k in claves:
    v = c[k]
    if v == "":       est = "CADENA VACIA (sin personalizar)"
    elif v is None:   est = "null"
    else:             est = repr(v)[:300]
    print(f"\n  {k}\n    {est}")
print()
print("Otros campos relevantes:")
for k in ["external_email_enabled", "mailer_otp_length", "mailer_otp_exp",
          "smtp_host", "smtp_sender_name", "smtp_admin_email",
          "hook_send_email_enabled", "hook_send_email_uri"]:
    if k in c:
        print(f"  {k} = {c[k]!r}")
    else:
        print(f"  {k} = (no viene)")
'
    ;;

  aplicar)
    python3 - "$CUERPO" "$ASUNTO" > /tmp/plantillas.json <<'PY'
import json, sys
cuerpo, asunto = sys.argv[1], sys.argv[2]
json.dump({
    "mailer_subjects_confirmation":        asunto,
    "mailer_templates_confirmation_content": cuerpo,
    "mailer_subjects_magic_link":          asunto,
    # OJO: NO se toca mailer_templates_magic_link_content. La plantilla
    # que hay escrita a mano en el panel es mejor que esta y lleva
    # documentado por qué no puede llevar enlace (Safe Links de
    # Microsoft 365 consume el token antes que el destinatario).
}, sys.stdout)
PY
    curl -sS -X PATCH "$API" \
      -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      --data @/tmp/plantillas.json > /dev/null
    rm -f /tmp/plantillas.json
    echo "Aplicado. Comprobando lo que ha quedado guardado:"
    echo
    "$0" ver
    ;;

  *)
    echo "Uso: bash supabase/plantillas_correo.sh [ver|crudo|aplicar]"
    exit 1
    ;;
esac
