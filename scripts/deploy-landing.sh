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

MAX_BYTES=$((1024 * 1024))
total_bytes=0
while IFS= read -r -d '' f; do
  total_bytes=$((total_bytes + $(stat -c%s "$f")))
done < <(find "$LANDING" -maxdepth 1 -type f ! -name '*.yaml' -print0)

if (( total_bytes * 4 / 3 > MAX_BYTES )); then
  echo "ERROR: el contenido de la web pesa $((total_bytes / 1024)) KB y superaría 1 MiB en base64 (límite de ConfigMap)." >&2
  echo "Consejo: migrar a imagen nginx custom (ver README, sección 'Web pública (landing)')." >&2
  exit 1
fi
echo "Contenido de la web: $((total_bytes / 1024)) KB (límite 1 MiB) — OK"

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
