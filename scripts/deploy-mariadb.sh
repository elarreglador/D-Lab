#!/bin/bash
set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
MARIADB="$BASE/files/mariadb"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="pods"
SECRET="mariadb-secret"
ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:?Defina MARIADB_ROOT_PASSWORD con la clave de root de MariaDB}"
DATABASE="${MARIADB_DATABASE:-dlab}"
USER="${MARIADB_USER:-dlab}"
PASSWORD="${MARIADB_PASSWORD:?Defina MARIADB_PASSWORD con la clave del usuario de la BD}"

echo "Construyendo Secret '$SECRET' en namespace '$NS' y aplicándolo por stdin..."
{
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n' "$SECRET" "$NS"
  printf '  MARIADB_ROOT_PASSWORD: %s\n' "$(printf '%s' "$ROOT_PASSWORD" | base64 -w0)"
  printf '  MARIADB_DATABASE: %s\n' "$(printf '%s' "$DATABASE" | base64 -w0)"
  printf '  MARIADB_USER: %s\n' "$(printf '%s' "$USER" | base64 -w0)"
  printf '  MARIADB_PASSWORD: %s\n' "$(printf '%s' "$PASSWORD" | base64 -w0)"
} | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "Aplicando manifests (storageclass v4, namespace, pvc, deployment, service, networkpolicy)..."
cat "$MARIADB/storageclass-v4.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MARIADB/mariadb.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MARIADB/networkpolicy.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "Esperando a que el pod esté listo..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deployment/mariadb --timeout=300s"

echo
echo "OK: MariaDB desplegado en el namespace '$NS' (no expuesto al exterior)"
echo "Verificación sugerida:"
echo "  kubectl -n $NS get pods"
echo "  kubectl -n $NS exec -it deploy/mariadb -- mariadb -u root -p"
