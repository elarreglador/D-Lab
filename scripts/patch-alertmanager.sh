#!/bin/bash
# Parchea Alertmanager con routing Opción B (filtra FIRING de ruido LXC, deja RESOLVED)
# Fuente de verdad: files/monitoring/alertmanager-config.yaml -> Secret alertmanager-kube-prometheus-stack-alertmanager
# Idempotente, sin escribir claves en disco, via ssh "$KUBECTL_HOST"
# Uso: ./scripts/patch-alertmanager.sh

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$BASE/files/monitoring/alertmanager-config.yaml"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="monitoring"
SECRET="alertmanager-kube-prometheus-stack-alertmanager"

if [[ ! -f "$CFG" ]]; then
  echo "ERROR: no existe $CFG" >&2
  exit 1
fi

# Extrae el bloque alertmanager.yaml del fichero fuente (tras 'alertmanager.yaml: |')
YAML_CONTENT="$(sed -n '/^alertmanager\.yaml: |/,$p' "$CFG" | sed '1d')"
if [[ -z "$YAML_CONTENT" ]]; then
  echo "ERROR: no se pudo extraer alertmanager.yaml de $CFG" >&2
  exit 1
fi

# Valida YAML básico localmente (python)
if ! python3 -c "import yaml, sys; yaml.safe_load(sys.stdin.read())" <<< "$YAML_CONTENT"; then
  echo "ERROR: YAML inválido en $CFG" >&2
  exit 1
fi

echo "Obteniendo Secret actual $SECRET en $NS..."
EXISTING_B64="$(ssh "$KUBECTL_HOST" "kubectl -n $NS get secret $SECRET -o jsonpath='{.data.alertmanager\.yaml}'" 2>/dev/null || true)"
if [[ -z "$EXISTING_B64" ]]; then
  echo "ERROR: Secret $SECRET no encontrado en $NS" >&2
  exit 1
fi

echo "Parcheando Secret con nuevo alertmanager.yaml (routing Opción B)..."
# Codifica el nuevo yaml y parchea solo esa key (strategic merge via kubectl patch)
NEW_B64="$(printf '%s' "$YAML_CONTENT" | base64 -w0)"

# Usa kubectl patch para no tocar otras claves del Secret (p.ej. si hay más data)
ssh "$KUBECTL_HOST" "kubectl -n $NS patch secret $SECRET --type='json' -p='[{\"op\":\"replace\",\"path\":\"/data/alertmanager.yaml\",\"value\":\"$NEW_B64\"}]'"

echo "Secret parcheado. Verificación:"
ssh "$KUBECTL_HOST" "kubectl -n $NS get secret $SECRET -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | head -n 50"

echo
echo "Reiniciando Alertmanager (StatefulSet) para recargar config..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager 2>/dev/null || kubectl -n $NS delete pod -l app.kubernetes.io/name=alertmanager --wait=true"

echo "Esperando rollout..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status statefulset/alertmanager-kube-prometheus-stack-alertmanager --timeout=180s 2>/dev/null || kubectl -n $NS get pods -l app.kubernetes.io/name=alertmanager"

echo
echo "OK: Alertmanager Opción B aplicada"
echo "  - FIRING filtrado: Watchdog, TargetDown, etcdMembersDown, etcdInsufficientMembers, Kube*Overcommit, InfoInhibitor"
echo "  - RESOLVED: siempre pasa (send_resolved: true)"
echo "  - repeat_interval: 12h (útiles 6h) para no spamear"
echo "Verificación manual:"
echo "  ssh $KUBECTL_HOST \"kubectl -n $NS get secret $SECRET -o jsonpath='{.data.alertmanager\\.yaml}' | base64 -d\""
echo "  ssh $KUBECTL_HOST \"kubectl -n $NS logs statefulset/alertmanager-kube-prometheus-stack-alertmanager -c alertmanager --tail=20\""
