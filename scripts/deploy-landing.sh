#!/bin/bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
LANDING="$BASE/files/landing"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
CONFIGMAP=landing-html

if [[ ! -f "$LANDING/index.html" ]]; then
  echo "ERROR: no existe $LANDING/index.html" >&2
  exit 1
fi

ETCD_LIMIT=$((1572864))    # default etcd max-request-bytes (1,5 MiB); el cluster no lo sobreescribe
ABORT_B64=$((ETCD_LIMIT * 23 / 25))   # ~1,35 MiB: margen por overhead YAML + base64
WARN_B64=$((921600))                 # ~0,9 MiB: aviso generoso antes del techo

total_bytes=0
while IFS= read -r -d '' f; do
  total_bytes=$((total_bytes + $(stat -c%s "$f")))
done < <(find "$LANDING" -maxdepth 1 -type f ! -name '*.yaml' -print0)
total_b64=$((total_bytes * 4 / 3))

echo "Contenido de la web: $((total_bytes / 1024)) KB (≈$((total_b64 / 1024)) KB en base64; techo efectivo ≈$((ETCD_LIMIT / 1024)) KB)"

if (( total_b64 >= ABORT_B64 )); then
  echo "ERROR: el contenido supera ~$((ABORT_B64 / 1024)) KB en base64 y rozaría el límite de etcd (~$((ETCD_LIMIT / 1024)) KB por objeto)." >&2
  echo "Consejo: migrar a imagen nginx custom (ver README, sección 'Web pública (landing)')." >&2
  exit 1
elif (( total_b64 >= WARN_B64 )); then
  echo "AVISO: cerca de $((WARN_B64 / 1024)) KB en base64; el ConfigMap empieza a ser grande para etcd." >&2
fi

{
  echo "apiVersion: v1"
  echo "kind: ConfigMap"
  echo "metadata:"
  echo "  name: $CONFIGMAP"
  echo "  namespace: default"
  echo "binaryData:"
  while IFS= read -r -d '' f; do
    key="$(basename "$f")"
    printf '  %s: %s\n' "$key" "$(base64 -w0 < "$f")"
  done < <(find "$LANDING" -maxdepth 1 -type f ! -name '*.yaml' -print0 | sort -z)
  echo "---"
  cat "$LANDING/landing.yaml"
  echo "---"
  cat "$LANDING/landing-ingress.yaml"
} | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "OK: ConfigMap '$CONFIGMAP' + Deployment/Service 'landing' + Ingress 'elarreglador-landing' aplicados"
echo "Reiniciando pods para forzar la carga del contenido..."
ssh "$KUBECTL_HOST" "kubectl -n default rollout restart deployment/landing"
