#!/bin/bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
NODERED="$BASE/files/nodered"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="pods"
SECRET="nodered-settings"
PASSWORD="${NODERED_PASSWORD:?Defina NODERED_PASSWORD con la clave del usuario de Node-RED}"

if [[ ! -f "$NODERED/settings.js.tpl" ]]; then
  echo "ERROR: no existe $NODERED/settings.js.tpl" >&2
  exit 1
fi

if ! command -v python3 >/dev/null; then
  echo "ERROR: se necesita python3 con bcrypt" >&2
  exit 1
fi
if ! python3 -c "import bcrypt" 2>/dev/null; then
  echo "ERROR: falta el módulo bcrypt de python3" >&2
  exit 1
fi

echo "Generando hash bcrypt de la clave (sin escribirla en disco)..."
ADMIN_HASH=$(python3 -c 'import bcrypt,sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=12)).decode())' "$PASSWORD")

echo "Generando credentialSecret aleatorio..."
CREDENTIAL_SECRET=$(head -c 32 /dev/urandom | base64 -w0 | tr -d '=/+' | head -c 32)

echo "Construyendo Secret '$SECRET' en namespace '$NS' y aplicándolo por stdin..."
sed -e "s|__ADMIN_HASH__|$ADMIN_HASH|g" \
    -e "s|__CREDENTIAL_SECRET__|$CREDENTIAL_SECRET|g" \
    "$NODERED/settings.js.tpl" | {
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n' "$SECRET" "$NS"
  printf '  settings.js: '
  base64 -w0
  printf '\n'
} | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "Aplicando manifests (namespace, pvc, deployment, service, ingress, networkpolicy, certificate)..."
cat "$NODERED/nodered.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$NODERED/ingress.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$NODERED/networkpolicy.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$NODERED/certificate.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "Esperando a que el pod esté listo..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deployment/nodered --timeout=300s"

echo
echo "OK: Node-RED desplegado en https://nodered.elarreglador.eu"
echo "Verificación sugerida:"
echo "  kubectl -n $NS get pods"
echo "  curl -s -o /dev/null -w '%{http_code}' https://nodered.elarreglador.eu/"
