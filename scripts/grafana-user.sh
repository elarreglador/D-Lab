#!/bin/bash
# Garantiza la existencia de un usuario en Grafana con rol Admin en la org principal.
#
# El storage de Grafana es emptyDir: los usuarios se pierden al recrear el pod.
# Este script es idempotente y se re-ejecuta tras una recreación para volver a
# crear el usuario sin duplicados.
#
# Uso (desde la raíz del repo; requiere acceso HTTPS a la URL de Grafana):
#   ./scripts/grafana-user.sh
# Las credenciales se cargan de info_sensible/grafana-user.env (gitignored) si
# existe; también se pueden pasar por variables de entorno (GRAFANA_ADMIN_PASSWORD,
# USER_PASSWORD, ...), que tienen prioridad sobre el fichero.
#
# Variables de entorno:
#   GRAFANA_URL          URL de Grafana (por defecto https://grafana.elarreglador.eu)
#   GRAFANA_ADMIN_USER   admin de Grafana (por defecto admin)
#   GRAFANA_ADMIN_PASSWORD  password del admin (obligatoria)
#   USER                 login del usuario a garantizar (por defecto elarreglador)
#   USER_PASSWORD        password del usuario (obligatoria)
#   USER_NAME            nombre visible (por defecto elarreglador)
#   USER_EMAIL           email del usuario (por defecto elarreglador@protonmail.com)
#   USER_ROLE            rol en la org principal (por defecto Admin)
#   SERVER_ADMIN         otorgar también Grafana Admin global (true/false; por defecto true)
#   ORG_ID               org principal (por defecto 1)
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$BASE/info_sensible/grafana-user.env" ]]; then
  source "$BASE/info_sensible/grafana-user.env"
fi

GRAFANA_URL="${GRAFANA_URL:-https://grafana.elarreglador.eu}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:?Falta GRAFANA_ADMIN_PASSWORD (env o info_sensible/grafana-user.env)}"
USER="${USER:-elarreglador}"
USER_PASSWORD="${USER_PASSWORD:?Falta USER_PASSWORD (env o info_sensible/grafana-user.env)}"
USER_NAME="${USER_NAME:-elarreglador}"
USER_EMAIL="${USER_EMAIL:-elarreglador@protonmail.com}"
USER_ROLE="${USER_ROLE:-Admin}"
SERVER_ADMIN="${SERVER_ADMIN:-true}"
ORG_ID="${ORG_ID:-1}"

api() { # api <method> <path> [json] -> imprime el body HTTP
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sf -X "$method" -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
      -H 'Content-Type: application/json' -d "$body" \
      "$GRAFANA_URL$path"
  else
    curl -sf -X "$method" -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
      "$GRAFANA_URL$path"
  fi
}

if ! curl -sf -o /dev/null -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" "$GRAFANA_URL/api/user"; then
  echo "ERROR: no se pudo autenticar como '$GRAFANA_ADMIN_USER' en $GRAFANA_URL" >&2
  exit 1
fi

user_json="$(api GET "/api/users/lookup?loginOrEmail=$USER" || true)"
if [[ "$user_json" == *'"id"'* ]]; then
  user_id="$(echo "$user_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"
  echo "El usuario '$USER' ya existe (id=$user_id)."
else
  echo "El usuario '$USER' no existe. Creándolo..."
  user_id="$(api POST /api/admin/users \
    "{\"login\":\"$USER\",\"email\":\"$USER_EMAIL\",\"name\":\"$USER_NAME\",\"password\":\"$USER_PASSWORD\"}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"
  echo "Usuario '$USER' creado (id=$user_id)."
fi

members="$(api GET "/api/orgs/$ORG_ID/users")"
current_role="$(echo "$members" | python3 -c \
  "import sys,json; print(next((u['role'] for u in json.load(sys.stdin) if u['userId']==$user_id), ''))")"

if [[ -z "$current_role" ]]; then
  echo "Añadiendo '$USER' a la org $ORG_ID con rol '$USER_ROLE'..."
  api POST "/api/orgs/$ORG_ID/users" "{\"loginOrEmail\":\"$USER\",\"role\":\"$USER_ROLE\"}" >/dev/null
elif [[ "$current_role" != "$USER_ROLE" ]]; then
  # En esta versión de Grafana el PUT de org-user devuelve 404; se re-añade el
  # miembro con el rol deseado (DELETE + POST).
  echo "Cambiando rol de '$USER' en la org $ORG_ID: $current_role -> $USER_ROLE"
  api DELETE "/api/orgs/$ORG_ID/users/$user_id" >/dev/null
  api POST "/api/orgs/$ORG_ID/users" "{\"loginOrEmail\":\"$USER\",\"role\":\"$USER_ROLE\"}" >/dev/null
else
  echo "El usuario '$USER' ya tiene el rol '$USER_ROLE' en la org $ORG_ID."
fi

echo
echo "OK: usuario '$USER' con rol '$USER_ROLE' en la org $ORG_ID ($GRAFANA_URL)"
echo "Verificación:"
curl -sf -u "$USER:$USER_PASSWORD" "$GRAFANA_URL/api/user" \
  | python3 -c '
import sys, json
d = json.load(sys.stdin)
print("  login=%s orgId=%s isGrafanaAdmin=%s" % (d["login"], d["orgId"], d["isGrafanaAdmin"]))
'

if [[ "$SERVER_ADMIN" == "true" ]]; then
  echo "Otorgando Grafana Admin global a '$USER'..."
  api PUT "/api/admin/users/$user_id/permissions" '{"isGrafanaAdmin": true}' >/dev/null
fi