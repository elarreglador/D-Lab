#!/bin/bash
# Despliegue del modelo de lenguaje local (Ollama) en el cluster.
#
# Despliega el namespace `ia`, el Deployment `ollama` (solo en los workers,
# vía nodeSelector eu.elarreglador/worker=true), su PVC, Service NodePort y
# NetworkPolicy. Al terminar descarga el modelo qwen2.5-coder:3b dentro del pod.
#
# Uso:
#   ./scripts/deploy-ollama.sh
#
# Variables de entorno (valor por defecto entre paréntesis):
#   KUBECTL_HOST  (server)   host con kubectl configurado contra el cluster
#   OLLAMA_MODEL  (qwen2.5-coder:3b)   modelo a descargar tras el rollout
#
# Requisitos previos (una sola vez, en el host D1):
#   - Proxy LXC para acceso WireGuard:
#     lxc config device add k8s-worker-1 proxyollama proxy \
#       listen=tcp:10.8.0.11:31434 connect=tcp:127.0.0.1:31434
#   Detalles en 03-Aplicaciones.md.

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
IA="$BASE/files/ia"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="ia"
MODEL="${OLLAMA_MODEL:-qwen2.5-coder:3b}"
LABEL_KEY="eu.elarreglador/worker"
LABEL_VALUE="true"

echo "Etiquetando los workers ($LABEL_KEY=$LABEL_VALUE) — anclaje del pod Ollama..."
for node in k8s-worker-1 k8s-worker-2; do
  ssh "$KUBECTL_HOST" "kubectl label node $node $LABEL_KEY=$LABEL_VALUE --overwrite"
done

echo
echo "Aplicando manifests (namespace, pvc, deployment, service, networkpolicy, quota)..."
cat "$IA/ollama.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$IA/networkpolicy.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$IA/quota.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "Esperando a que el pod esté listo..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deployment/ollama --timeout=600s"

echo
echo "Descargando modelo '$MODEL' (primera vez; persiste en el PVC)..."
ssh "$KUBECTL_HOST" "kubectl -n $NS exec deploy/ollama -- ollama pull $MODEL"

echo
echo "OK: Ollama desplegado en el namespace '$NS'"
echo "Accesos:"
echo "  Interno (Node-RED): http://ollama.ia.svc:11434"
echo "  LAN:                 http://192.168.1.31:31434 (o .32)"
echo "  WireGuard:           http://10.8.0.11:31434"
echo "Verificación sugerida:"
echo "  curl http://<acceso>/api/tags"
echo "  curl -X POST http://<acceso>/v1/chat/completions -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Hola\"}]}'"