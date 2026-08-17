#!/bin/bash
# Fija la política de idioma de las descargas de Sonarr/Radarr: castellano.
#
# Jerarquía (minFormatScore=100; score por release, se elige el mayor):
#   1º  Doblado castellano + audio dual en inglés + subtítulos   110+110+100
#   2º  Doblado castellano + audio dual en inglés                110+110
#   3º  Doblado castellano (solo)                                110
#   4º  VOSE (subtítulos), fallback si no hay doblaje           100
#   —   Inglés sin subtítulos                                    0 -> rechazado
#
# 3 Custom Formats por app (Sonarr/Radarr):
#   "Español (Audio)"      LanguageSpecification = Spanish (castellano, NO Latino)
#   "Audio dual"           ReleaseTitleSpecification (regex dual/multi/es-en)
#   "VOSE"                 ReleaseTitleSpecification (regex subtítulos)
# El CF "VOSE" no exige idioma a propósito: los releases `...-VOSE`/`SUBBED`/`VOS`
# se parsean a menudo como idioma "Unknown" (no inglés) y exigirlo los dejaría sin
# puntuar. Al ser solo regex de título, puntúa cualquier release con etiqueta de
# subtítulos y suma bonus al doblaje (doblado + subs).
#
# Se configura el perfil de calidad "Any" (id 1), el único que usa Jellyseerr.
# Idempotente: reutiliza CFs existentes y no altera el perfil si ya está puntuado.
# Ejecutar desde la raíz del repo.
#
# Uso:
#   ./scripts/multimedia-language.sh               # política estándar
#   VERBOSE=0 ./scripts/multimedia-language.sh     # solo resumen final
#
# Variables de entorno (override):
#   KUBECTL_HOST  (server)  host con kubectl y acceso a los Services del ns multimedia
#   S_DUB   (110)  score del CF "Español (Audio)"
#   S_DUAL  (110)  score del CF "Audio dual"
#   S_VOSE  (100)  score del CF "VOSE"
#   MIN     (100)  minFormatScore del perfil
#
# Credenciales: se cargan solas desde info_sensible/multimedia.env (gitignored).

set -uo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="multimedia"
HELPER="multimedia-tools"   # pod con curl en el ns multimedia
VERBOSE="${VERBOSE:-1}"
S_DUB="${S_DUB:-110}"
S_DUAL="${S_DUAL:-110}"
S_VOSE="${S_VOSE:-100}"
MIN="${MIN:-100}"

# Carga automática de credenciales (info_sensible/multimedia.env, gitignored).
if [ -f "$BASE/info_sensible/multimedia.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$BASE/info_sensible/multimedia.env"
  set +a
fi

# --- Credenciales obligatorias ---
: "${SONARR_APIKEY:?define en info_sensible/multimedia.env}"
: "${RADARR_APIKEY:?define en info_sensible/multimedia.env}"

# Ejecuta kubectl en el host remoto preservando las comillas de los argumentos.
KC() {
  local quoted=() x
  for x in "$@"; do quoted+=("$(printf '%q' "$x")"); done
  ssh "$KUBECTL_HOST" "kubectl ${quoted[*]}"
}
# GET: exec sin -i (no necesita stdin).
KCURL() {
  KC -n "$NS" exec "$HELPER" -- curl -s "$@"
}
# POST/PUT con cuerpo: exec -i para que el stdin (--data-binary @-) llegue a curl.
KCURLI() {
  KC -n "$NS" exec -i "$HELPER" -- curl -s "$@"
}
die() { echo "ERROR: $*" >&2; exit 1; }

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

# Devuelve el id de un Custom Format por nombre (vacío si no existe).
# Uso: cf_id_by_name <app> <port> <key> <nombre>
cf_id_by_name() {
  KCURL "http://$1:$2/api/v3/customformat" -H "X-Api-Key: $3" 2>/dev/null | python3 -c '
import sys,json
try:
    for cf in json.load(sys.stdin):
        if cf.get("name")==sys.argv[1]:
            print(cf.get("id")); break
except Exception:
    pass
' "$4"
}

# Crea (o reutiliza) un Custom Format y devuelve su id por stdout.
# Uso: ensure_cf <app> <port> <key> <nombre> <specifications_json>
ensure_cf() {
  local app=$1 port=$2 key=$3 name=$4 specs=$5
  local id
  id="$(cf_id_by_name "$app" "$port" "$key" "$name")"
  if [ -n "$id" ]; then
    echo "$id"
    return 0
  fi
  python3 -c '
import sys,json
print(json.dumps({
  "name": sys.argv[1],
  "includeCustomFormatWhenRenaming": False,
  "specifications": json.loads(sys.argv[2])
}))
' "$name" "$specs" > "/tmp/cf_$app.json"
  local hcode
  hcode="$(KCURLI -o /dev/null -w '%{http_code}' -X POST \
    "http://$app:$port/api/v3/customformat" -H "X-Api-Key: $key" -H "Content-Type: application/json" \
    --data-binary @- < "/tmp/cf_$app.json")"
  [ "$hcode" = "201" ] || [ "$hcode" = "200" ] || die "$app: POST customformat '$name' devolvió HTTP $hcode"
  cf_id_by_name "$app" "$port" "$key" "$name"
}

echo "== Política de idioma en Sonarr/Radarr (scores: dub=$S_DUB dual=$S_DUAL vose=$S_VOSE min=$MIN) =="

for app in sonarr radarr; do
  port=$([ "$app" = sonarr ] && echo 8989 || echo 7878)
  key=$([ "$app" = sonarr ] && echo "$SONARR_APIKEY" || echo "$RADARR_APIKEY")
  info_link="https://wiki.servarr.com/$app/settings#custom-formats-2"
  echo
  echo "[$app]"

  # 1) Ids de idioma desde el schema del CF (el valor que admite el campo).
  LANGS="$(KCURL "http://$app:$port/api/v3/customformat/schema" -H "X-Api-Key: $key" 2>/dev/null | python3 -c '
import sys,json
langs={}
try:
    for s in json.load(sys.stdin):
        if s.get("implementation")=="LanguageSpecification":
            for f in s.get("fields",[]):
                if f.get("name")=="value":
                    for o in f.get("selectOptions",[]):
                        langs[o.get("name")]=o.get("value")
except Exception:
    pass
print(langs.get("Spanish",""),langs.get("English",""))
')"
  ES_ID="$(printf '%s' "$LANGS" | cut -d' ' -f1)"
  EN_ID="$(printf '%s' "$LANGS" | cut -d' ' -f2)"
  [ -n "$ES_ID" ] && [ -n "$EN_ID" ] || die "$app: no se pudieron resolver los idiomas Spanish/English del schema"
  echo "  -> ids idioma: Spanish=$ES_ID English=$EN_ID"

  # 2) Custom Formats
  SPEC_DUB="[{\"name\":\"Idioma: Español\",\"implementation\":\"LanguageSpecification\",\"implementationName\":\"Language\",\"infoLink\":\"$info_link\",\"negate\":false,\"required\":false,\"fields\":[{\"name\":\"value\",\"value\":$ES_ID},{\"name\":\"exceptLanguage\",\"value\":false}]}]"
  SPEC_DUAL="[{\"name\":\"Release dual\",\"implementation\":\"ReleaseTitleSpecification\",\"implementationName\":\"Release Title\",\"infoLink\":\"$info_link\",\"negate\":false,\"required\":false,\"fields\":[{\"name\":\"value\",\"value\":\"\\\\b(dual|multi)\\\\b|\\\\b(?:es|esp)[-_.](?:en|eng)\\\\b|\\\\bcastellano\\\\b.*\\\\bingl[ée]s\\\\b\"}]}]"
  SPEC_VOSE="[{\"name\":\"Subtítulos\",\"implementation\":\"ReleaseTitleSpecification\",\"implementationName\":\"Release Title\",\"infoLink\":\"$info_link\",\"negate\":false,\"required\":false,\"fields\":[{\"name\":\"value\",\"value\":\"\\\\b(?:vose|voe|subs?|subbed|subtitled|subtitulad[oa]s?)\\\\b\"}]}]"

  CF_DUB="$(ensure_cf "$app" "$port" "$key" "Español (Audio)" "$SPEC_DUB")"
  echo "  -> CF 'Español (Audio)' id $CF_DUB (score $S_DUB)"
  CF_DUAL="$(ensure_cf "$app" "$port" "$key" "Audio dual" "$SPEC_DUAL")"
  echo "  -> CF 'Audio dual' id $CF_DUAL (score $S_DUAL)"
  CF_VOSE="$(ensure_cf "$app" "$port" "$key" "VOSE" "$SPEC_VOSE")"
  echo "  -> CF 'VOSE' id $CF_VOSE (score $S_VOSE)"

  # 3) Perfil "Any": puntuar los CFs y fijar minFormatScore (idempotente)
  PROF="$(KCURL "http://$app:$port/api/v3/qualityprofile" -H "X-Api-Key: $key" 2>/dev/null | python3 -c '
import sys,json
try:
    d=json.load(sys.stdin)
    p=next((x for x in d if x.get("name")=="Any"), d[0] if d else {})
    print(json.dumps(p))
except Exception:
    print("{}")
')"
  [ "$PROF" != "{}" ] || die "$app: no se pudo leer el perfil de calidad"
  P_ID="$(printf '%s' "$PROF" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")"
  T_DUB="Español (Audio):$CF_DUB:$S_DUB"; T_DUAL="Audio dual:$CF_DUAL:$S_DUAL"; T_VOSE="VOSE:$CF_VOSE:$S_VOSE"

  NEEDS="$(printf '%s' "$PROF" | python3 -c '
import sys,json
p=json.load(sys.stdin)
triples=[a.split(":") for a in sys.argv[1:-1]]
want_min=int(sys.argv[-1])
items={i.get("name"):i.get("score") for i in (p.get("formatItems") or [])}
ok = p.get("minFormatScore")==want_min and all(items.get(n)==int(s) for n,i,s in triples)
print("no" if ok else "yes")
' "$T_DUB" "$T_DUAL" "$T_VOSE" "$MIN")"
  if [ "$NEEDS" = "no" ]; then
    echo "  -> perfil 'Any' (id $P_ID) ya configurado (min=$MIN)"
  else
    printf '%s' "$PROF" | python3 -c '
import sys,json
p=json.load(sys.stdin)
triples=[a.split(":") for a in sys.argv[1:-1]]
want_min=int(sys.argv[-1])
names={n for n,i,s in triples}
items=[i for i in (p.get("formatItems") or []) if i.get("name") not in names]
for n,i,s in triples:
    items.append({"format":int(i),"name":n,"score":int(s)})
p["formatItems"]=items
p["minFormatScore"]=want_min
print(json.dumps(p))
' "$T_DUB" "$T_DUAL" "$T_VOSE" "$MIN" > "/tmp/profile_$app.json"
    hcode="$(KCURLI -o /dev/null -w '%{http_code}' -X PUT \
      "http://$app:$port/api/v3/qualityprofile/$P_ID" -H "X-Api-Key: $key" -H "Content-Type: application/json" \
      --data-binary @- < "/tmp/profile_$app.json")"
    [ "$hcode" = "200" ] || [ "$hcode" = "202" ] || [ "$hcode" = "204" ] || die "$app: PUT qualityprofile devolvió HTTP $hcode"
    echo "  -> perfil 'Any' (id $P_ID) puntuado (min=$MIN)"
  fi

  # 4) Verificación
  VRES="$(KCURL "http://$app:$port/api/v3/qualityprofile" -H "X-Api-Key: $key" 2>/dev/null | python3 -c '
import sys,json
d=json.load(sys.stdin)
p=next((x for x in d if x.get("name")=="Any"), d[0] if d else {})
triples=[a.split(":") for a in sys.argv[1:-1]]
want_min=int(sys.argv[-1])
items={i.get("name"):i.get("score") for i in (p.get("formatItems") or [])}
res=["OK" if p.get("minFormatScore")==want_min else "FAIL"]
res += ["OK" if items.get(n)==int(s) else "FAIL" for n,i,s in triples]
res.append(str(p.get("minFormatScore","?")))
print(" ".join(res))
' "$T_DUB" "$T_DUAL" "$T_VOSE" "$MIN")"
  VMIN="$(printf '%s\n' "$VRES" | cut -d' ' -f1)"
  VDUB="$(printf '%s\n' "$VRES" | cut -d' ' -f2)"
  VDUAL="$(printf '%s\n' "$VRES" | cut -d' ' -f3)"
  VVOSE="$(printf '%s\n' "$VRES" | cut -d' ' -f4)"
  VMINACT="$(printf '%s\n' "$VRES" | cut -d' ' -f5)"
  check "$VMIN" "minFormatScore=$MIN" "(actual: $VMINACT)"
  check "$VDUB" "CF 'Español (Audio)' score=$S_DUB" ""
  check "$VDUAL" "CF 'Audio dual' score=$S_DUAL" ""
  check "$VVOSE" "CF 'VOSE' score=$S_VOSE" ""
  for cfname in "Español (Audio)" "Audio dual" "VOSE"; do
    v="$(cf_id_by_name "$app" "$port" "$key" "$cfname" | python3 -c 'import sys;print("OK" if sys.stdin.read().strip() else "FAIL")')"
    check "$v" "CF '$cfname' presente en $app" ""
  done
done

final_report
