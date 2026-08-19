#!/bin/bash
# Bootstrap completo del stack multimedia de D-Lab vía API (sin navegador).
#
# Cadena: qBittorrent ← Sonarr/Radarr/Prowlarr(sync) — rastreo con Prowlarr +
# FlareSolverr — Jellyfin/Jellyseerr (front + request). Cada paso es idempotente:
# se comprueba el estado antes de alterar. Ejecutar desde la raíz del repo.
#
# Uso:
#   ./scripts/multimedia-wizard.sh                    # full apply
#   TEST_INDEXERS=1 ./scripts/multimedia-wizard.sh    # + test de indexadores
#
# Variables de entorno (KUBECTL_HOST, SI se quiere override):
#   KUBECTL_HOST  (server)  host con kubectl y acceso a los Services del ns multimedia
#
# Credenciales: se cargan solas desde info_sensible/multimedia.env (gitignored).
# NOTA: la inyección de trackers se aplica en tiempo de grab (un torrent ya con
# trackers no se modifica); el puerto 6881 externo depende de IONOS (manual).

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="multimedia"
HELPER="multimedia-tools"   # pod con curl en el ns multimedia
TEST_INDEXERS="${TEST_INDEXERS:-0}"

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

# URL-encoded password (los '=' se codifican %3D para los form posts).
PW_ENC="$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$MM_ADMIN_PASS")"

# Ejecuta kubectl en el host remoto preservando las comillas de los argumentos.
# Uso: KC <args...> [< fichero]
KC() {
  local quoted=()
  local x
  for x in "$@"; do quoted+=("$(printf '%q' "$x")"); done
  ssh "$KUBECTL_HOST" "kubectl ${quoted[*]}"
}
die() { echo "ERROR: $*" >&2; exit 1; }
have_jq() { python3 -c "import json,sys" 2>/dev/null; }

echo "== Stack multimedia: bootstrap vía API (kubectl host: $KUBECTL_HOST) =="
KC -n "$NS" rollout status deploy --timeout=60s >/dev/null 2>&1 || true

echo
echo "[1] qBittorrent — login y preferencias"
KC -n "$NS" exec "$HELPER" -- curl -s -c /tmp/qb -o /dev/null -X POST \
  "http://qbittorrent:8080/api/v2/auth/login" \
  -d "username=$QB_USER&password=$PW_ENC" || die "login qbittorrent falló"
KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/qb -o /dev/null -X POST \
  "http://qbittorrent:8080/api/v2/app/setPreferences" \
  -d "save_path=$QB_SAVE_PATH&temp_path=$QB_TEMP_PATH"
QVER="$(KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/qb "http://qbittorrent:8080/api/v2/app/version" 2>/dev/null)"
echo "  -> qBittorrent version: $QVER"

echo
echo "[2] Sonarr / Radarr — config de host autenticada (auth=forms)"
for app in sonarr radarr; do
  port=$([ "$app" = sonarr ] && echo 8989 || echo 7878)
  key=$([ "$app" = sonarr ] && echo "$SONARR_APIKEY" || echo "$RADARR_APIKEY")
  current="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://$app:$port/api/v3/config/host" -H "X-Api-Key: $key" 2>/dev/null)"
  echo "$current" | python3 -c "
import sys,json
d=json.load(sys.stdin)
if d.get('authenticationMethod')!='forms' or d.get('username')!='${MM_ADMIN_USER}':
    d['authenticationMethod']='forms'; d['username']='${MM_ADMIN_USER}'
    d['password']='${MM_ADMIN_PASS}'; d['passwordConfirmation']='${MM_ADMIN_PASS}'
print(json.dumps(d))
" > "/tmp/host_$app.json"
  KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X PUT \
    "http://$app:$port/api/v3/config/host" \
    -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    --data-binary @- < "/tmp/host_$app.json" && echo "  -> $app auth=forms ($MM_ADMIN_USER)"
done

echo
echo "[3] Sonarr/Radarr — rootfolder y download client qBittorrent"
for app in sonarr radarr; do
  port=$([ "$app" = sonarr ] && echo 8989 || echo 7878)
  key=$([ "$app" = sonarr ] && echo "$SONARR_APIKEY" || echo "$RADARR_APIKEY")
  media=$([ "$app" = sonarr ] && echo "$MEDIA_TV" || echo "$MEDIA_MOVIES")
  cat_=$([ "$app" = sonarr ] && echo "$SONARR_CATEGORY" || echo "$RADARR_CATEGORY")
  # rootfolder idempotente
  KC -n "$NS" exec "$HELPER" -- curl -s "http://$app:$port/api/v3/rootfolder" -H "X-Api-Key: $key" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin); print('' if any(r.get('path')=='$media' for r in d) else 'missing')" > "/tmp/rf_$app"
  if [ "$(cat "/tmp/rf_$app")" = "missing" ]; then
    KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
      "http://$app:$port/api/v3/rootfolder" -H "X-Api-Key: $key" -H "Content-Type: application/json" \
      -d "{\"path\":\"$media\"}" && echo "  -> $app rootfolder $media creado"
  else
    echo "  -> $app rootfolder $media ya existe"
  fi
  # download client idempotente
  KC -n "$NS" exec "$HELPER" -- curl -s "http://$app:$port/api/v3/downloadclient" -H "X-Api-Key: $key" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin); print(next((str(x['id']) for x in d if x.get('implementation')=='QBittorrent'), ''))" > "/tmp/dc_$app"
  if [ -n "$(cat "/tmp/dc_$app")" ]; then
    echo "  -> $app downloadclient qBittorrent ya existe (id $(cat "/tmp/dc_$app"))"
  else
    KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
      "http://$app:$port/api/v3/downloadclient" -H "X-Api-Key: $key" -H "Content-Type: application/json" \
      -d "{\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"name\":\"qBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"fields\":[{\"name\":\"host\",\"value\":\"qbittorrent\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"username\",\"value\":\"$QB_USER\"},{\"name\":\"password\",\"value\":\"$QB_PASS\"},{\"name\":\"category\",\"value\":\"$cat_\"}]}" \
      && echo "  -> $app downloadclient qBittorrent creado (cat $cat_)"
  fi
done

echo
echo "[4] Prowlarr — qBittorrent como DownloadClient + apps sync (Sonarr/Radarr)"
# DownloadClient en Prowlarr (necesario para los indexadores)
KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/downloadclient" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin); print('' if any(x.get('implementation')=='QBittorrent' for x in d) else 'missing')" > /tmp/qbd
if [ "$(cat /tmp/qbd)" != "missing" ]; then
  echo "  -> Prowlarr DownloadClient qBittorrent ya existe"
else
  KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
    "http://prowlarr:9696/api/v1/downloadclient" -H "Content-Type: application/json" -H "X-Api-Key: $PROWLARR_APIKEY" \
    -d "{\"enable\":true,\"protocol\":\"torrent\",\"priority\":1,\"name\":\"QBittorrent\",\"implementation\":\"QBittorrent\",\"configContract\":\"QBittorrentSettings\",\"categories\":[],\"tags\":[],\"fields\":[{\"name\":\"host\",\"value\":\"qbittorrent\"},{\"name\":\"port\",\"value\":8080},{\"name\":\"useSsl\",\"value\":false},{\"name\":\"username\",\"value\":\"$QB_USER\"},{\"name\":\"password\",\"value\":\"$QB_PASS\"},{\"name\":\"category\",\"value\":\"prowlarr\"}]}" \
    && echo "  -> Prowlarr DownloadClient qBittorrent creado (cat prowlarr)"
fi

# Apps (Sonarr/Radarr) — idempotente por nombre
for app in Sonarr Radarr; do
  exists="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/applications" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin); print('' if any(x.get('name')=='$app' for x in d) else 'missing')")"
  if [ -n "$exists" ]; then
    : # no-op: faltaba crear
  else
    echo "  -> Prowlarr application $app ya existe (skip)"
    continue
  fi
  base=$([ "$app" = Sonarr ] && echo sonarr || echo radarr)
  port=$([ "$app" = Sonarr ] && echo 8989 || echo 7878)
  key=$([ "$app" = Sonarr ] && echo "$SONARR_APIKEY" || echo "$RADARR_APIKEY")
  cats=$([ "$app" = Sonarr ] && echo "[5000,5010,5020,5030,5040,5045,5050,5090]" || echo "[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]")
  concrete=$app
  KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
    "http://prowlarr:9696/api/v1/applications" -H "Content-Type: application/json" -H "X-Api-Key: $PROWLARR_APIKEY" \
    -d "{\"name\":\"$app\",\"implementation\":\"$concrete\",\"configContract\":\"${concrete}Settings\",\"syncLevel\":\"fullSync\",\"fields\":[{\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},{\"name\":\"baseUrl\",\"value\":\"http://$base:$port\"},{\"name\":\"apiKey\",\"value\":\"$key\"},{\"name\":\"syncCategories\",\"value\":$cats}]}" \
    && echo "  -> Prowlarr application $app sync creada"
done

echo
echo "[5] Prowlarr — indexadores públicos en castellano (DivxTotal, Torrent9, LimeTorrents) + FlareSolverr"
echo "    (se purgan los anglófonos 1337x y Torrent Downloads)"
# Tag cloudflare (idempotente)
TAG_ID="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/tag" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin); print(next((str(x['id']) for x in d if x.get('label')=='cloudflare'), ''))")"
if [ -z "$TAG_ID" ]; then
  TAG_ID="$(KC -n "$NS" exec "$HELPER" -- curl -s -X POST "http://prowlarr:9696/api/v1/tag" -H "Content-Type: application/json" -H "X-Api-Key: $PROWLARR_APIKEY" -d '{"label":"cloudflare"}' 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")"
fi
# Proxy FlareSolverr (idempotente)
KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/indexerproxy" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin); print('' if any(x.get('implementation')=='FlareSolverr' for x in d) else 'missing')" > /tmp/fs
if [ "$(cat /tmp/fs)" != "missing" ]; then
  echo "  -> FlareSolverr proxy ya existe"
else
  KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
    "http://prowlarr:9696/api/v1/indexerproxy" -H "Content-Type: application/json" -H "X-Api-Key: $PROWLARR_APIKEY" \
    -d "{\"name\":\"FlareSolverr\",\"implementation\":\"FlareSolverr\",\"configContract\":\"FlareSolverrSettings\",\"enable\":true,\"tags\":[$TAG_ID],\"fields\":[{\"name\":\"host\",\"value\":\"http://flaresolverr:8191\"},{\"name\":\"requestTimeout\",\"value\":120}]}" \
    && echo "  -> FlareSolverr proxy creado (tag cloudflare)"
fi

# Baja de indexadores idempotente (por nombre); los anglófonos se purgan.
idx_remove() {
  local name="$1" id
  id="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/indexer" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin); print(next((str(x['id']) for x in d if x.get('name')=='$name'), ''))")"
  if [ -z "$id" ]; then
    echo "  -> $name no existe (skip)"
  else
    KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X DELETE \
      "http://prowlarr:9696/api/v1/indexer/$id" -H "X-Api-Key: $PROWLARR_APIKEY" \
      && echo "  -> $name (id $id) eliminado"
  fi
}
idx_remove "1337x"
idx_remove "Torrent Downloads"

# Alta de indexadores idempotente; las rutas que requieren FlareSolverr llevan el tag.
idx_add() {
  local name="$1" def="$2" url="$3" cf="$4" tags body result
  tags="$([ "$cf" = cloudflare ] && echo "[$TAG_ID]" || echo "[]")"
  local exist
  exist="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/indexer" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null \
    | python3 -c "
import sys,json;d=json.load(sys.stdin);print('' if any(x.get('name')=='$name' for x in d) else 'missing')")"
  [ -z "$exist" ] && echo "  -> $name ya existe" && return 0
  body="{\"name\":\"$name\",\"implementation\":\"Cardigann\",\"configContract\":\"CardigannSettings\",\"protocol\":\"torrent\",\"privacy\":\"public\",\"enable\":true,\"redirect\":false,\"priority\":25,\"appProfileId\":1,\"downloadClientId\":1,\"tags\":$tags,\"categories\":[],\"fields\":[{\"name\":\"definitionFile\",\"value\":\"$def\"},{\"name\":\"baseUrl\",\"value\":\"$url\"}]}"
  result="$(KC -n "$NS" exec "$HELPER" -- curl -s -X POST "http://prowlarr:9696/api/v1/indexer" -H "Content-Type: application/json" -H "X-Api-Key: $PROWLARR_APIKEY" -d "$body" 2>&1)"
  if echo "$result" | grep -qE '"id"'; then
    echo "  -> $name alta OK"
  else
    echo "  -> $name alta FALLIDA: $(echo "$result" | head -c 120)"
  fi
}
idx_add "Torrent9"          "torrent9"          "https://www6.torrent9.to/"   ""
idx_add "LimeTorrents"      "limetorrents"      "https://www.limetorrents.fun/" ""
idx_add "DivxTotal"         "divxtotal"         "https://divxtotal.foo/"     ""

if [ "$TEST_INDEXERS" = "1" ]; then
  echo
  echo "[6] Test de conexión de cada indexador"
  for idxid in $(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/indexer" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null \
    | python3 -c "
import sys,json;d=json.load(sys.stdin);print(' '.join(str(x['id']) for x in d))"); do
    obj="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://prowlarr:9696/api/v1/indexer/$idxid" -H "X-Api-Key: $PROWLARR_APIKEY" 2>/dev/null)"
    name="$(echo "$obj" | python3 -c "import sys,json;print(json.load(sys.stdin)['name'])")"
    res="$(KC -n "$NS" exec "$HELPER" -- curl -s -X POST "http://prowlarr:9696/api/v1/indexer/test" -H "Content-Type: application/json" -H "X-Api-Key: $PROWLARR_APIKEY" -d "$obj" 2>&1)"
    status="$(echo "$res" | python3 -c "
import sys,json
try:
    r=json.load(sys.stdin)
    print('OK' if not isinstance(r,list) or not any(x.get('isWarning') for x in r) else 'FAIL')
except Exception:
    print('??')")"
    echo "  -> $name: $status"
  done
fi

echo
echo "[7] Jellyfin — completar wizard de primer arranque si falta el admin"
JF_STATE="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://jellyfin:8096/System/Info/Public" 2>/dev/null || true)"
JF_COMPLETE="$(echo "$JF_STATE" | python3 -c "import sys,json
try: print(str(json.load(sys.stdin).get('StartupWizardCompleted')))
except Exception: print('')")"
if [ "$JF_COMPLETE" = "False" ]; then
  echo "  -> wizard Jellyfin incompleto; completando..."
  KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
    "http://jellyfin:8096/Startup/Configuration" -H "Content-Type: application/json" \
    -d '{"UICulture":"es-ES","MetadataCountryCode":"ES","PreferredMetadataLanguage":"es","ServerName":"D-Lab Jellyfin","BaseUrl":""}'
  KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
    "http://jellyfin:8096/Startup/User" -H "Content-Type: application/json" \
    -d "{\"Name\":\"$MM_ADMIN_USER\",\"Password\":\"$MM_ADMIN_PASS\"}"
  KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
    "http://jellyfin:8096/Startup/RemoteAccess" -H "Content-Type: application/json" \
    -d '{"EnableRemoteAccess":true}'
  KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST "http://jellyfin:8096/Startup/Complete"
  echo "  -> wizard Jellyfin completado (user: $MM_ADMIN_USER)"
else
  echo "  -> wizard Jellyfin ya completado (saltar; verificar libraries si cambió)"
fi

echo
echo "[8] Jellyfin — crear librerías Movies/TV Shows si faltan (query.. en VirtualFolders)"
JF_TOKEN="$(KC -n "$NS" exec "$HELPER" -- curl -s -X POST "http://jellyfin:8096/Users/AuthenticateByName" \
  -H "Content-Type: application/json" \
  -H 'X-Emby-Authorization: MediaBrowser Client="Jellyfin Web", Device="wizard", DeviceId="mm-wizard-00", Version="10.11.11"' \
  -d "{\"Username\":\"$MM_ADMIN_USER\",\"Pw\":\"$MM_ADMIN_PASS\"}" 2>/dev/null \
  | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('AccessToken',''))
except Exception: print('')")"
if [ -n "$JF_TOKEN" ]; then
  for lib in "Movies:/data/media/movies:movies" "TV Shows:/data/media/tv:tvshows"; do
    name="${lib%%:*}"; rest="${lib#*:}"; path="${rest%%:*}"; ctype="${rest##*:}"
    if ! KC -n "$NS" exec "$HELPER" -- curl -s "http://jellyfin:8096/Library/VirtualFolders" -H "X-Emby-Token: $JF_TOKEN" 2>/dev/null \
      | python3 -c "import sys,json;d=json.load(sys.stdin);import sys as s; s.exit(0 if any(x.get('Name')=='$name' for x in d) else 1)"; then
      KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
        "http://jellyfin:8096/Library/VirtualFolders" -H "Content-Type: application/json" -H "X-Emby-Token: $JF_TOKEN" \
        -d "{}" --get --data-urlencode "name=$name" --data-urlencode "collectionType=$ctype" --data-urlencode "paths=$path" 2>/dev/null \
        || KC -n "$NS" exec "$HELPER" -- curl -s -o /dev/null -X POST \
        -H "Content-Type: application/json" -H "X-Emby-Token: $JF_TOKEN" \
        -d "{\"name\":\"$name\",\"collectionType\":\"$ctype\",\"paths\":[\"$path\"]}" \
        "http://jellyfin:8096/Library/VirtualFolders?name=$name&collectionType=$ctype&paths=$path"
      echo "  -> librería $name creada"
    else
      echo "  -> librería $name ya existe"
    fi
  done
else
  echo "  -> (aviso) no se obtuvo token Jellyfin; revisar login"
fi

echo
echo "[9] Jellyseerr — login Jellyfin (idempotente) y activación de librerías"
JS_PUB="$(KC -n "$NS" exec "$HELPER" -- curl -s "http://jellyseerr:5055/api/v1/settings/public" 2>/dev/null || true)"
JS_INIT="$(echo "$JS_PUB" | python3 -c "import sys,json
try: print('true' if json.load(sys.stdin).get('initialized') else 'false')
except Exception: print('unsure')")"
echo "  -> estado Seerr: initialized=$JS_INIT"
# Jellyseerr: si ya está inicializado, el login se hace SIN hostname (usa la config
# guardada); enviarlo provoca 500 "Jellyfin hostname already configured".
JS_BODY="{\"username\":\"$MM_ADMIN_USER\",\"password\":\"$MM_ADMIN_PASS\"}"
if [ "$JS_INIT" != "true" ]; then
  echo "  -> Seerr sin inicializar; primer arranque con hostname Jellyfin"
  JS_BODY="{\"username\":\"$MM_ADMIN_USER\",\"password\":\"$MM_ADMIN_PASS\",\"hostname\":\"jellyfin\",\"port\":8096,\"urlBase\":\"\",\"useSsl\":false,\"email\":\"$MM_ADMIN_USER@d-lab.local\",\"serverType\":2}"
fi
JS_LOGIN="$(KC -n "$NS" exec "$HELPER" -- curl -s -c /tmp/js -o /dev/null -w '%{http_code}' -X POST \
  "http://jellyseerr:5055/api/v1/auth/jellyfin" -H "Content-Type: application/json" \
  -d "$JS_BODY" 2>/dev/null || true)"
if [ "$JS_LOGIN" = "200" ] || [ "$JS_LOGIN" = "201" ]; then
  echo "  -> login Jellyfin OK (HTTP $JS_LOGIN)"
  KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/js -o /dev/null -X POST \
    "http://jellyseerr:5055/api/v1/settings/initialize"
  KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/js -o /dev/null \
    "http://jellyseerr:5055/api/v1/settings/jellyfin/library?sync=1"
  JFLIBS="$(KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/js "http://jellyseerr:5055/api/v1/settings/jellyfin/library" 2>/dev/null)"
  JFLIBS_ENABLE="$(echo "$JFLIBS" | python3 -c "import sys,json
try: print(','.join(x['id'] for x in json.load(sys.stdin)))
except Exception: print('')")"
  if [ -n "$JFLIBS_ENABLE" ]; then
    KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/js -o /dev/null \
      "http://jellyseerr:5055/api/v1/settings/jellyfin/library?enable=$JFLIBS_ENABLE"
    echo "  -> librerías Jellyfin activadas: $JFLIBS_ENABLE"
  else
    echo "  -> (aviso) no se listaron librerías Jellyfin desde Seerr"
  fi
else
  echo "  -> (aviso) login Seerr devolvió $JS_LOGIN; revisar credenciales"
fi

echo
echo "[10] Jellyseerr — alta Sonarr/Radarr como servidores de descarga si faltan"
for app in sonarr radarr; do
  port=$([ "$app" = sonarr ] && echo 8989 || echo 7878)
  key=$([ "$app" = sonarr ] && echo "$SONARR_APIKEY" || echo "$RADARR_APIKEY")
  media=$([ "$app" = sonarr ] && echo "$MEDIA_TV" || echo "$MEDIA_MOVIES")
  cat_=$([ "$app" = sonarr ] && echo "$SONARR_CATEGORY" || echo "$RADARR_CATEGORY")
  cur="$(KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/js "http://jellyseerr:5055/api/v1/settings/$app" 2>/dev/null || true)"
  n="$(echo "$cur" | python3 -c "import sys,json
try: print(len(json.load(sys.stdin)))
except Exception: print(-1)")"
  if [ "$n" -gt 0 ] 2>/dev/null; then
    echo "  -> $app ya configurado en Jellyseerr (servidores: $n); skip"
    continue
  fi
  KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/js -o /dev/null \
    "http://jellyseerr:5055/api/v1/settings/$app/test" -X POST -H "Content-Type: application/json" \
    -d "{\"name\":\"$app\",\"hostname\":\"$app\",\"port\":$port,\"apiKey\":\"$key\",\"useSsl\":false,\"baseUrl\":\"\",\"is4k\":false,\"isDefault\":true,\"tags\":[],\"minimumAvailability\":\"released\"}"
  KC -n "$NS" exec "$HELPER" -- curl -s -b /tmp/js -o /dev/null \
    "http://jellyseerr:5055/api/v1/settings/$app" -X POST -H "Content-Type: application/json" \
    -d "{\"name\":\"$app\",\"hostname\":\"$app\",\"port\":$port,\"apiKey\":\"$key\",\"useSsl\":false,\"baseUrl\":\"\",\"activeProfileId\":1,\"activeProfileName\":\"Any\",\"activeDirectory\":\"$media\",\"is4k\":false,\"isDefault\":true,\"tags\":[],\"minimumAvailability\":\"released\"}"
  echo "  -> $app configurado en Jellyseerr (root $media)"
done

echo
echo "== Bootstrap OK. Verificación web =="
echo "  qBittorrent/arrs/prowlarr+indexers/jellyfin/jellyseerr cableados."
echo "  Ha de abrirse en IONOS TCP+UDP 6881 para la cadena torrent externa."