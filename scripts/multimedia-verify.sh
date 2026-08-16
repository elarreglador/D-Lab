#!/bin/bash
# Verificación integral del stack multimedia de D-Lab (solo lectura, no altera estado).
#
# Comprueba, capa a capa: cluster → qBittorrent → Sonarr/Radarr → Prowlarr
# (indexadores/sync) → Jellyfin → Jellyseerr → cadena externa 6881. Cada check
# imprime [OK]/[FAIL]; al final se resume y se sale con código distinto de cero
# si algún check crítico falló. Ejecutar desde la raíz del repo.
#
# Uso:
#   ./scripts/multimedia-verify.sh              # verificación integral
#   ./scripts/multimedia-verify.sh -t sonarr    # verificar solo una capa
#   ./scripts/multimedia-verify.sh -q           # salida compacta (solo final)
#
# Variables de entorno (KUBECTL_HOST, shortcut: -t <capa>):
#   KUBECTL_HOST  (server)  host con kubectl y acceso a los Services del ns multimedia
#   VERBOSE       (1)       0 = solo resumen final
#
# Credenciales: se cargan solas desde info_sensible/multimedia.env (gitignored).

set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="multimedia"
HELPER="multimedia-tools"   # pod con curl en el ns multimedia
VERBOSE="${VERBOSE:-1}"

# Carga automática de credenciales (info_sensible/multimedia.env, gitignored).
if [ -f "$BASE/info_sensible/multimedia.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$BASE/info_sensible/multimedia.env"
  set +a
fi

# --- Credenciales obligatorias ---
: "${MM_ADMIN_USER:?define en info_sensible/multimedia.env}"
: "${MM_ADMIN_PASS:?define en info_sensible/multimedia.env}"
: "${SONARR_APIKEY:?define en info_sensible/multimedia.env}"
: "${RADARR_APIKEY:?define en info_sensible/multimedia.env}"
: "${PROWLARR_APIKEY:?define en info_sensible/multimedia.env}"
: "${QB_USER:?define en info_sensible/multimedia.env}"
: "${QB_PASS:?define en info_sensible/multimedia.env}"

PW_ENC="$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$MM_ADMIN_PASS")"

# Ejecuta kubectl en el host remoto preservando las comillas de los argumentos.
KC() {
  local quoted=() x
  for x in "$@"; do quoted+=("$(printf '%q' "$x")"); done
  ssh "$KUBECTL_HOST" "kubectl ${quoted[*]}"
}

# Contadores y resumen
PASS=0; FAIL=0; TOTAL=0
FAILED_WHAT=()
check() {
  local ok=$1 label=$2
  TOTAL=$((TOTAL+1))
  if [ "$ok" = OK ]; then
    PASS=$((PASS+1)); [ "$VERBOSE" = 1 ] && echo "  [OK]   $label"
  else
    FAIL=$((FAIL+1)); [ "$VERBOSE" = 1 ] && echo "  [FAIL] $label   $3"
    FAILED_WHAT+=("$label")
  fi
}
final_report() {
  echo
  echo "== Resumen: $PASS/$TOTAL OK, $FAIL fallos =="
  if [ "$FAIL" -gt 0 ]; then
    printf '  - %s\n' "${FAILED_WHAT[@]}"
    exit 1
  fi
  exit 0
}

# Parsea -t <capa> (solo verifica una capa)
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -t) ONLY="$2"; shift 2 ;;
    -q) VERBOSE=0; shift ;;
    *) echo "Uso: $0 [-t <capa>] [-q]  (capas: cluster qb sonarr radarr prowlarr jellyfin jellyseerr external)" >&2; exit 1 ;;
  esac
done

run() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

echo "== Verificación multimedia (kubectl host: $KUBECTL_HOST) =="

if run cluster; then
  echo "[1] Cluster — pods del namespace multimedia"
  PODS="$(KC -n "$NS" get pods --no-headers 2>/dev/null)"
  RESTARTS="$(echo "$PODS" | awk '$4>0{c++} END{print c+0}')"
  NOTRUN="$(echo "$PODS" | awk '$3!="Running" && $3!="Completed"{c++} END{print c+0}')"
  check "$( [ "$NOTRUN" -eq 0 ] && echo OK || echo FAIL )" "pods sin estados anómalos (bad=$NOTRUN)" ""
  check "$( [ "$RESTARTS" -eq 0 ] && echo OK || echo FAIL )" "sin reinicios (restarts=$RESTARTS)" ""
  for app in qbittorrent sonarr radarr prowlarr flaresolverr jellyfin jellyseerr; do
    n=$(echo "$PODS" | grep -c "^$app-" || true)
    check "$( [ "$n" -ge 1 ] && echo OK || echo FAIL )" "pod $app presente" ""
  done
fi

if run qb; then
  echo "[2] qBittorrent"
  KC -n "$NS" exec "$HELPER" -- curl -s -c /tmp/qb -o /dev/null -X POST \
    "http://qbittorrent:8080/api/v2/auth/login" \
    -d "username=$QB_USER&password=$PW_ENC" >/dev/null 2>&1
  QVER="$(KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/qb "http://qbittorrent:8080/api/v2/app/version" 2>/dev/null)"
  check "$( [ -n "$QVER" ] && echo OK || echo FAIL )" "login y versión qBittorrent ($QVER)" ""
  QPREFS="$(KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/qb "http://qbittorrent:8080/api/v2/app/preferences" 2>/dev/null)"
  QPORT="$(echo "$QPREFS" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('listen_port',''))
except Exception: print('')")"
  check "$( [ "$QPORT" = 6881 ] && echo OK || echo FAIL )" "listen_port=6881" "(actual: $QPORT)"
  QINFO="$(KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/qb "http://qbittorrent:8080/api/v2/transfer/info" 2>/dev/null)"
  QC="$(echo "$QINFO" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print(d.get('connection_status'), d.get('dht_nodes',0), sep=':')
except Exception: print(':')")"
  check "$( echo "$QC" | grep -q "^connected:" && echo OK || echo FAIL )" "connection_status=connected · DHT>$(( $(echo "$QC"|cut -d: -f2) ))" ""
fi

if run sonarr || run radarr; then
  for app in sonarr radarr; do
    [ -n "$ONLY" ] && [ "$ONLY" != "$app" ] && continue
    echo "[3] $app"
    port=$([ "$app" = sonarr ] && echo 8989 || echo 7878)
    key=$([ "$app" = sonarr ] && echo "$SONARR_APIKEY" || echo "$RADARR_APIKEY")
    media=$([ "$app" = sonarr ] && echo "$MEDIA_TV" || echo "$MEDIA_MOVIES")
    K="$(KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -w '%{http_code}' "http://$app:$port/api/v3/system/status" -H "X-Api-Key: $key" 2>/dev/null)"
    check "$( [ "$K" = 200 ] && echo OK || echo FAIL )" "$app API status HTTP $K" ""
    ROOTS="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://$app:$port/api/v3/rootfolder" -H "X-Api-Key: $key" 2>/dev/null)"
    ADIR="$(echo "$ROOTS" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print('yes' if any(r.get('path')=='$media' and r.get('accessible') for r in d) else 'no')
except Exception: print('no')")"
    check "$( [ "$ADIR" = yes ] && echo OK || echo FAIL )" "$app rootfolder $media accesible" ""
    DC="$(echo "$ROOTS" >/dev/null; KC -n "$NS" exec "$HELPER" -- curl -s "http://$app:$port/api/v3/downloadclient" -H "X-Api-Key: $key" 2>/dev/null)"
    nDC="$(echo "$DC" | python3 -c "import sys,json
try: print(sum(1 for x in json.load(sys.stdin) if x.get('implementation')=='QBittorrent'))
except Exception: print(0)")"
    check "$( [ "$nDC" -ge 1 ] && echo OK || echo FAIL )" "$app downloadclient qBittorrent (n=$nDC)" ""
  done
fi

if run prowlarr; then
  echo "[4] Prowlarr — health, indexadores, sync"
  K="$(KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -w '%{http_code}' "http://prowlarr:9696/api/v1/health" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null)"
  check "$( [ "$K" = 200 ] && echo OK || echo FAIL )" "Prowlarr health HTTP $K" ""
  IDX="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/indexer" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null)"
  nIdx="$(echo "$IDX" | python3 -c "import sys,json
try: print(sum(1 for x in json.load(sys.stdin) if x.get('enable')))
except Exception: print(0)")"
  check "$( [ "$nIdx" -ge 1 ] && echo OK || echo FAIL )" "indexadores activos (n=$nIdx)" ""
  APPS="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/applications" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null)"
  nApps="$(echo "$APPS" | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(0)")"
  check "$( [ "$nApps" -ge 2 ] && echo OK || echo FAIL )" "apps Sonarr/Radarr sync (n=$nApps)" ""
  FS="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/indexerproxy" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null)"
  nFS="$(echo "$FS" | python3 -c "import sys,json
try: print(sum(1 for x in json.load(sys.stdin) if x.get('implementation')=='FlareSolverr'))
except Exception: print(0)")"
  check "$( [ "$nFS" -ge 1 ] && echo OK || echo FAIL )" "proxy FlareSolverr (n=$nFS)" ""
fi

if run jellyfin; then
  echo "[5] Jellyfin — wizard, admin, librerías"
  JPUB="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://jellyfin:8096/System/Info/Public" 2>/dev/null)"
  JW="$(echo "$JPUB" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('StartupWizardCompleted'))
except Exception: print('')")"
  check "$( [ "$JW" = True ] && echo OK || echo FAIL )" "StartupWizardCompleted" "(actual: $JW)"
  JF_TOKEN="$(KC -n "$NS" exec "$HELPER" -- curl -s -X POST "http://jellyfin:8096/Users/AuthenticateByName" \
    -H "Content-Type: application/json" \
    -H 'X-Emby-Authorization: MediaBrowser Client="jellyfin", Device="verify", DeviceId="mm-verify-00", Version="10.11.11"' \
    -d "{\"Username\":\"$MM_ADMIN_USER\",\"Pw\":\"$MM_ADMIN_PASS\"}" 2>/dev/null \
    | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('AccessToken',''))
except Exception: print('')")"
  check "$( [ -n "$JF_TOKEN" ] && echo OK || echo FAIL )" "login admin" ""
  VF="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://jellyfin:8096/Library/VirtualFolders" -H "X-Emby-Token: $JF_TOKEN" 2>/dev/null)"
  nLib="$(echo "$VF" | python3 -c "import sys,json
try: print(len([x for x in json.load(sys.stdin) if x.get('CollectionType') in ('movies','tvshows')]))
except Exception: print(0)")"
  check "$( [ "$nLib" -ge 2 ] && echo OK || echo FAIL )" "librerías Movies+TV (n=$nLib)" ""
fi

if run jellyseerr; then
  echo "[6] Jellyseerr — initialized, login, librerías, servidores"
  JS_PUB="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://jellyseerr:5055/api/v1/settings/public" 2>/dev/null)"
  JS_INIT="$(echo "$JS_PUB" | python3 -c "import sys,json
try: print('true' if json.load(sys.stdin).get('initialized') else 'false')
except Exception: print('unsure')")"
  check "$( [ "$JS_INIT" = true ] && echo OK || echo FAIL )" "initialized" "(actual: $JS_INIT)"
  JS_BODY="{\"username\":\"$MM_ADMIN_USER\",\"password\":\"$MM_ADMIN_PASS\"}"
  JS_LOGIN="$(KC -n "$NS" exec "$HELPER" -- curl -s -c /tmp/js -o /dev/null -w '%{http_code}' -X POST \
    "http://jellyseerr:5055/api/v1/auth/jellyfin" -H "Content-Type: application/json" -d "$JS_BODY" 2>/dev/null)"
  check "$( [ "$JS_LOGIN" = 200 ] && echo OK || echo FAIL )" "login admin (HTTP $JS_LOGIN)" ""
  # NOTA: el endpoint GET /jellyfin/library de Jellyseerr es MUTADOR sin ?enable=
  # (vuelca enabled a false), por lo que no sirve para verificar. Se lee el estado
  # real desde settings.json en el pod de Seerr (fuente de verdad).
  nOn="$(KC -n "$NS" exec deploy/jellyseerr -- sh -c "grep -o '\"enabled\": *true' /app/config/settings.json 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')"
  check "$( [ "${nOn:-0}" -ge 2 ] && echo OK || echo FAIL )" "librerías Jellyfin activas en settings.json (n=${nOn:-0})" ""
  for app in sonarr radarr; do
    cur="$(KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/js "http://jellyseerr:5055/api/v1/settings/$app" 2>/dev/null)"
    nSrv="$(echo "$cur" | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(0)")"
    check "$( [ "$nSrv" -ge 1 ] && echo OK || echo FAIL )" "Seerr→$app server (n=$nSrv)" ""
  done
fi

if run external; then
  echo "[7] Cadena externa 6881"
  DV0_SS="$(ssh -o ConnectTimeout=8 server "ss -tulpn 2>/dev/null | grep -c ':6881 ' " 2>/dev/null || echo 0)"
  check "$( [ "${DV0_SS// /}" -ge 1 ] && echo OK || echo FAIL )" "DV0 escucha 6881 (n=${DV0_SS// /})" ""
  NC_DV0="$(ssh -o ConnectTimeout=8 server "timeout 6 nc -zv -w 4 10.8.0.11 6881 2>&1 | grep -c succeeded" 2>/dev/null || echo 0)"
  check "$( [ "${NC_DV0// /}" -ge 1 ] && echo OK || echo FAIL )" "DV0→D1:6881(proxy LXC) tcp" ""
fi

final_report