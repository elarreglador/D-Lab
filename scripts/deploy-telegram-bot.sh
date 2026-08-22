#!/bin/bash
# Despliegue del bot de notificaciones Telegram en el cluster.
#
# Crea el Secret telegram-bot-secret por stdin (sin escribir claves en disco)
# y aplica los manifests de files/telegram-bot/ (ConfigMap con app.py,
# Deployment, Service y NetworkPolicy). Namespace: pods, acceso abierto
# intra-cluster (ClusterIP 8080, /notify y /alert).
#
# Uso:
#   TELEGRAM_BOT_TOKEN=<token> TELEGRAM_CHAT_ID=<id> ./scripts/deploy-telegram-bot.sh
#   # o
#   source info_sensible/telegram.env && ./scripts/deploy-telegram-bot.sh
#
# Variables de entorno (requeridas):
#   TELEGRAM_BOT_TOKEN  token del bot de @BotFather (ej. 123456:ABC...)
#   TELEGRAM_CHAT_ID    chat id destino (ej. 123456789 o -100... para canal)
#
# Opcionales:
#   KUBECTL_HOST  (server)  host con kubectl configurado contra el cluster

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
TB="$BASE/files/telegram-bot"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="pods"
SECRET="telegram-bot-secret"
TOKEN="${TELEGRAM_BOT_TOKEN:?Defina TELEGRAM_BOT_TOKEN con el token de @BotFather}"
CHAT_ID="${TELEGRAM_CHAT_ID:?Defina TELEGRAM_CHAT_ID con el chat id destino}"

if [[ ! -f "$TB/telegram-bot.yaml" ]]; then
  echo "ERROR: no existe $TB/telegram-bot.yaml" >&2
  exit 1
fi
if [[ ! -f "$TB/networkpolicy.yaml" ]]; then
  echo "ERROR: no existe $TB/networkpolicy.yaml" >&2
  exit 1
fi

echo "Construyendo Secret '$SECRET' en namespace '$NS' y aplicandolo por stdin..."
{
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n' "$SECRET" "$NS"
  printf '  TELEGRAM_BOT_TOKEN: %s\n' "$(printf '%s' "$TOKEN" | base64 -w0)"
  printf '  TELEGRAM_CHAT_ID: %s\n' "$(printf '%s' "$CHAT_ID" | base64 -w0)"
} | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "Aplicando manifests (namespace, configmap, deployment, service, networkpolicy)..."
cat "$TB/telegram-bot.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$TB/networkpolicy.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "Esperando a que el pod este listo..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deployment/telegram-bot --timeout=180s"

echo
echo "OK: telegram-bot desplegado en namespace '$NS'"
echo "  Service: telegram-bot.pods.svc.cluster.local:8080 (ClusterIP)"
echo "Verificacion sugerida:"
echo "  kubectl -n $NS get pods -l app=telegram-bot"
echo "  kubectl -n $NS exec deploy/telegram-bot -- wget -qO- http://127.0.0.1:8080/health"
echo "  kubectl run curl-test --rm -i --restart=Never --image=curlimages/curl -- \\"
echo "    curl -s -X POST http://telegram-bot.pods.svc:8080/notify \\"
echo "         -H 'Content-Type: application/json' -d '{\"text\":\"D-Lab: test\"}'"
