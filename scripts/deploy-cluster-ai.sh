#!/bin/bash
# Despliegue Fase 14A cluster-ai — bot separado @Dlab_assistant_bot
# Idempotente, Secret por stdin (sin escribir claves), via ssh "$KUBECTL_HOST"
# Recibe claves por env TELEGRAM_AI_TOKEN + TELEGRAM_CHAT_ID (allowlist)
# Uso: source info_sensible/cluster-ai.env && ./scripts/deploy-cluster-ai.sh
set -euo pipefail
BASE="$(cd "$(dirname "$0")/.." && pwd)"
CA="$BASE/files/cluster-ai"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="ia"
SECRET="cluster-ai-secret"
TOKEN="${TELEGRAM_AI_TOKEN:?Defina TELEGRAM_AI_TOKEN (bot @Dlab_assistant_bot)}"
CHAT_ID="${TELEGRAM_CHAT_ID:?Defina TELEGRAM_CHAT_ID (allowlist, solo usted)}"
for f in rbac.yaml networkpolicy.yaml whitelist.yaml api.yaml docs-sync.yaml monitor-patch.yaml; do
  if [[ ! -f "$CA/$f" ]]; then echo "ERROR: no existe $CA/$f" >&2; exit 1; fi
done
echo "Construyendo Secret '$SECRET' en '$NS' por stdin..."
{
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n' "$SECRET" "$NS"
  printf '  TELEGRAM_AI_TOKEN: %s\n' "$(printf '%s' "$TOKEN" | base64 -w0)"
  printf '  TELEGRAM_CHAT_ID: %s\n' "$(printf '%s' "$CHAT_ID" | base64 -w0)"
} | ssh "$KUBECTL_HOST" "kubectl apply -f -"
echo "Aplicando RBAC + NetworkPolicy + whitelist + monitor-patch..."
cat "$CA/rbac.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$CA/networkpolicy.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$CA/whitelist.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$CA/monitor-patch.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
echo "Aplicando api (ConfigMap code + Deployment + Service)..."
cat "$CA/api.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
echo "Aplicando docs-sync (PVC + CronJob)..."
cat "$CA/docs-sync.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
echo "Esperando rollout cluster-ai-api..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deployment/cluster-ai-api --timeout=180s"
echo
echo "OK: cluster-ai-api desplegado (Fase A)"
echo "Verificación:"
echo "  ssh $KUBECTL_HOST \"kubectl -n ia get pods; kubectl -n ia rollout status deploy/cluster-ai-api\""
echo "  ssh $KUBECTL_HOST \"kubectl -n ia exec deploy/cluster-ai-api -- wget -qO- http://127.0.0.1:8000/health\""
echo "  Telegram: /get nodes → 4 Ready, /help → ayuda"
echo "  RBAC: kubectl auth can-i get secrets --as=system:serviceaccount:ia:cluster-ai-sa → no"
