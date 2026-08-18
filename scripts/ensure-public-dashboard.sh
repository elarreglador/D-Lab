#!/bin/bash
# Garantiza el public dashboard 'Sistema D-Lab' de Grafana y guarda su URL pública.
#
# El storage de Grafana es emptyDir: los public dashboards se pierden al recrear
# el pod. Este script es idempotente: si el public dashboard ya existe reutiliza
# su accessToken; si no, lo crea. Guarda la URL en info_sensible/public-dashboard.env
# (gitignored), que consume scripts/deploy-landing.sh para inyectarla en la landing.
#
# Requisitos previos:
#   - El dashboard 'Sistema D-Lab' (uid sistema-dlab) debe estar provisionado
#     (ConfigMap files/monitoring/grafana-dashboard-sistema-dlab.yaml con la label
#     grafana_dashboard: "1" y el sidecar kiwigrid activo).
#   - [security] allow_embedding = true en grafana.ini (si se quiere embeber).
#
# Uso (desde la raíz del repo; requiere acceso HTTPS a la URL de Grafana):
#   ./scripts/ensure-public-dashboard.sh
# Las credenciales se cargan de info_sensible/grafana-user.env (gitignored);
# también se pueden pasar por variables de entorno (GRAFANA_ADMIN_PASSWORD, ...).
#
# Variables de entorno:
#   GRAFANA_URL            URL de Grafana (por defecto https://grafana.elarreglador.eu)
#   GRAFANA_ADMIN_USER     admin de Grafana (por defecto admin)
#   GRAFANA_ADMIN_PASSWORD password del admin (obligatoria)
#   DASHBOARD_UID          uid del dashboard a publicar (por defecto sistema-dlab)
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$BASE/info_sensible/grafana-user.env" ]]; then
  source "$BASE/info_sensible/grafana-user.env"
fi

GRAFANA_URL="${GRAFANA_URL:-https://grafana.elarreglador.eu}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:?Falta GRAFANA_ADMIN_PASSWORD (env o info_sensible/grafana-user.env)}"
DASHBOARD_UID="${DASHBOARD_UID:-sistema-dlab}"

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

# Verificación previa: el dashboard debe estar provisionado.
if ! curl -sf -o /dev/null -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" \
     "$GRAFANA_URL/api/dashboards/uid/$DASHBOARD_UID"; then
  echo "ERROR: el dashboard '$DASHBOARD_UID' no existe. Provisiona primero el ConfigMap" >&2
  echo "  files/monitoring/grafana-dashboard-sistema-dlab.yaml y espera al sidecar." >&2
  exit 1
fi

existing="$(api GET "/api/dashboards/uid/$DASHBOARD_UID/public-dashboards" || true)"
if [[ "$existing" == *'"accessToken"'* ]]; then
  access_token="$(echo "$existing" | python3 -c 'import sys,json; print(json.load(sys.stdin)["accessToken"])')"
  echo "El public dashboard ya existe; reutilizando su accessToken."
else
  echo "Creando el public dashboard..."
  created="$(api POST "/api/dashboards/uid/$DASHBOARD_UID/public-dashboards" \
    '{"isEnabled": true, "share": "public", "annotationsEnabled": false, "timeSelectionEnabled": false}')"
  access_token="$(echo "$created" | python3 -c 'import sys,json; print(json.load(sys.stdin)["accessToken"])')"
fi

# En Grafana 13 la ruta pública usa guion (/public-dashboards/...), no barra
# (/public/dashboards/...); esta segunda cae en el handler de assets estáticos.
public_url="$GRAFANA_URL/public-dashboards/$access_token"
cat > "$BASE/info_sensible/public-dashboard.env" <<EOF
# URL pública del dashboard 'Sistema D-Lab' (gitignored). La consume deploy-landing.sh.
PUBLIC_DASHBOARD_URL=$public_url
EOF

echo
echo "OK: public dashboard 'Sistema D-Lab'"
echo "  URL: $public_url"
echo "  Guardado en info_sensible/public-dashboard.env (gitignored)."
echo "  Regenerar si se recrea el pod de Grafana (storage emptyDir): ./scripts/ensure-public-dashboard.sh"
