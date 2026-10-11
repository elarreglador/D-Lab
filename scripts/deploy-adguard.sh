#!/bin/bash
# Despliegue idempotente de AdGuard Home: DNS filtrante de la LAN en 192.168.1.61.
#
# Único resolutor DNS de la LAN (fallo ruidoso deliberado): el router anuncia
# 192.168.1.61 como primario SIN secundario (ver spec 01). El DHCP sigue en el
# router (broadcast, no viable desde overlay). El panel vive en
# https://adguard.elarreglador.eu (solo ingress-nginx).
#
# Ejecutar desde la raíz del repo.
#
# Uso:
#   ./scripts/deploy-adguard.sh
#
# Variables de entorno (valor por defecto entre paréntesis):
#   KUBECTL_HOST  (server) host con kubectl configurado contra el cluster
#
# Requiere info_sensible/adguard.env (gitignored) con:
#   ADGUARD_USER=elarreglador
#   ADGUARD_PASSWORD_HASH=$2b$...   (hash bcrypt; nunca el texto claro)
# El Secret adguard-web se crea por stdin, sin escribir la clave en disco.

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
DG="$BASE/files/adguard"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="adguard"
ENV_FILE="$BASE/info_sensible/adguard.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: no existe $ENV_FILE (gitignored). Debe contener ADGUARD_USER y ADGUARD_PASSWORD_HASH." >&2
  exit 1
fi

echo "[1/7] Namespace..."
cat "$DG/namespace.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "[2/7] Validando manifiestos con --dry-run=server..."
for f in pvc.yaml adguard.yaml service-dns.yaml service-web.yaml \
         certificate-adguard.yaml ingress.yaml networkpolicy.yaml \
         seed-config.yaml alerts.yaml; do
  printf '  -> %s ... ' "$f"
  cat "$DG/$f" | ssh "$KUBECTL_HOST" "kubectl apply --dry-run=server -f -"
done

echo
echo "[3/7] Secret del panel 'adguard-web' (por stdin desde info_sensible/adguard.env)..."
cat "$ENV_FILE" | ssh "$KUBECTL_HOST" "kubectl -n $NS create secret generic adguard-web --from-env-file=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -"

echo
echo "[4/7] PVC + configuración inicial (Job seed-config, idempotente)..."
cat "$DG/pvc.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
ssh "$KUBECTL_HOST" "kubectl -n $NS delete job adguard-seed-config --ignore-not-found" >/dev/null 2>&1 || true
cat "$DG/seed-config.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
ssh "$KUBECTL_HOST" "kubectl -n $NS wait --for=condition=complete job/adguard-seed-config --timeout=180s"
ssh "$KUBECTL_HOST" "kubectl -n $NS logs job/adguard-seed-config" 2>&1 | grep -v -i "password:" | head -n 10

echo
echo "[5/7] Deployment, servicios, Ingress, Certificate y NetworkPolicy..."
cat "$DG/adguard.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$DG/service-dns.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$DG/service-web.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$DG/certificate-adguard.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$DG/ingress.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$DG/networkpolicy.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "[6/7] Alerta AdguardDown (PrometheusRule) + routing en Alertmanager..."
cat "$DG/alerts.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
"$BASE/scripts/patch-alertmanager.sh" | tail -n 5

echo
echo "[7/7] Esperando Deployment y certificado TLS..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deploy/adguard --timeout=300s"
for i in $(seq 1 30); do
  st="$(ssh "$KUBECTL_HOST" "kubectl -n $NS get certificate adguard-elarreglador-eu -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || true)"
  printf '  certificate Ready=%s\n' "$st"
  [[ "$st" == "True" ]] && break
  sleep 5
done

echo
echo "OK: AdGuard Home desplegado (namespace '$NS')."
echo
echo "Verificación sugerida:"
echo "  ssh $KUBECTL_HOST \"kubectl -n $NS get pods,pvc,svc\""
echo "  dig @192.168.1.61 elarreglador.eu        # responde"
echo "  dig @192.168.1.61 doubleclick.net        # 0.0.0.0 (bloqueado)"
echo "  curl -sI https://adguard.elarreglador.eu # 302 a /login.html"
echo "Runbook/cutover del router y G9: ./04-Operaciones.md (spec 01, pasos 7-9)"