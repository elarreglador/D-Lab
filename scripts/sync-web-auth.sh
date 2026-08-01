#!/bin/bash
set -euo pipefail

HTPASSWD_FILE="${1:-info_sensible/htpasswd-web}"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NAMESPACES="${WEB_AUTH_NAMESPACES:-monitoring}"
SECRET=web-basic-auth

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
