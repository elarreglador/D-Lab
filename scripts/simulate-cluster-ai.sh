#!/bin/bash
# Simula interacción Telegram con cluster-ai-api sin necesitar Telegram.
# Uso: ./scripts/simulate-cluster-ai.sh "/get nodes"
#      ./scripts/simulate-cluster-ai.sh "hola que tal"  # sin / → Ollama+RAG
#      ./scripts/simulate-cluster-ai.sh --all  # batería completa
# Usa el endpoint POST /simulate del pod principal (comparte RAG en memoria).
set -euo pipefail
KUBECTL_HOST="${KUBECTL_HOST:-server}"
POD=$(ssh "$KUBECTL_HOST" "kubectl -n ia get pod -l app=cluster-ai-api -o jsonpath='{.items[0].metadata.name}'" 2>&1)
if [[ -z "$POD" ]]; then echo "ERROR: no se encontró pod cluster-ai-api" >&2; exit 1; fi

run_one() {
  local text="$1"
  local user="${2:-test-sim}"
  local esc_text=$(printf '%s' "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
  local esc_user=$(printf '%s' "$user" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
  ssh "$KUBECTL_HOST" "kubectl -n ia exec $POD -c api -- sh -c 'cat > /tmp/sim_http.py << PY
import json, httpx, asyncio
async def run():
    payload = {\"text\": $esc_text, \"user\": $esc_user}
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post(\"http://127.0.0.1:8000/simulate\", json=payload)
        print(r.json().get(\"reply\",\"\"))

asyncio.run(run())
PY
PYTHONPATH=/tmp/deps:/app timeout 200 python3 /tmp/sim_http.py 2>&1 | grep -v -E \"FutureWarning|onnxruntime|telemetry|chromadb|Failed to send\" | tail -n 500'" 2>&1 | tail -n 500
}

if [[ "${1:-}" == "--all" ]]; then
  echo "=== Batería completa Fase 14B/C ==="
  for cmd in "/get nodes" "/get ns" "/get pods default" "/get pods all" "/get deployments all" "/get events default" "/logs default landing-658cbd4668-87smj" "/top nodes" "/status" "/alerts" "/help" "/docs Gluster" "hola que tal" "¿qué VIP usa NFS?"; do
    echo -e "\n--- $cmd ---"
    run_one "$cmd"
    sleep 1
  done
  echo -e "\n=== Rate limit (6x /get nodes) ==="
  for i in 1 2 3 4 5 6; do echo -n "$i: "; run_one "/get nodes" | head -n 1; done
else
  if [[ $# -eq 0 ]]; then echo "Uso: $0 \"<texto>\" [--all]" >&2; exit 1; fi
  run_one "$*"
fi
