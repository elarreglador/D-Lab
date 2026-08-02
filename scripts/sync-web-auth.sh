#!/bin/bash
set -euo pipefail

HTPASSWD_FILE="${1:-info_sensible/htpasswd-web}"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NAMESPACES="${WEB_AUTH_NAMESPACES:-}"
SECRET=web-basic-auth

if [[ -z "$NAMESPACES" ]]; then
  echo "AVISO: WEB_AUTH_NAMESPACES vacío o sin argumentos — ningún namespace indicado."
  echo "Ningún servicio usa actualmente la clave web (Grafana usa su propio login)."
  echo "Uso: WEB_AUTH_NAMESPACES=\"ns1 ns2\" ./scripts/sync-web-auth.sh"
  exit 0
fi

if [[ ! -f "$HTPASSWD_FILE" ]]; then
  echo "ERROR: no existe $HTPASSWD_FILE" >&2
  exit 1
fi

for ns in $NAMESPACES; do
  echo "--- Secret '$SECRET' en namespace '$ns' ---"
  AUTH_B64=$(base64 -w0 < "$HTPASSWD_FILE")
  {
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  auth: %s\n' \
      "$SECRET" "$ns" "$AUTH_B64"
  } | ssh "$KUBECTL_HOST" "kubectl apply -f -"
done

echo
echo "OK: clave web sincronizada en: $NAMESPACES"
