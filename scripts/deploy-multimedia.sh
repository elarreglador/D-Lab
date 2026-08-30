#!/bin/bash
# Despliegue del stack multimedia simplificado en el namespace "multimedia".
#
# Stack: qBittorrent (torrent, WebUI torrent.elarreglador.eu) + aMule
# (eDonkey/KAD, WebUI amule.elarreglador.eu) → Jellyfin (jellyfin.elarreglador.eu).
# Cadena anterior Jellyseerr→*arr→Prowlarr→FlareSolverr retirada el 2026-08-29.
# Ejecutar desde la raíz del repo.
#
# Uso:
#   AMULE_WEB_PWD=<pwd> AMULE_EC_PWD=<pwd> ./scripts/deploy-multimedia.sh
#
# Variables de entorno (valor por defecto entre paréntesis):
#   KUBECTL_HOST   (server) host con kubectl configurado contra el cluster
#   AMULE_WEB_PWD  password WebUI aMule (opcional; si se omite amule arranca sin auth)
#   AMULE_EC_PWD   password EC aMule (opcional)
#
# Nota: los puertos P2P (qB 6881, aMule 4662/4672/4665) expuestos por la cadena
# pública se documentan en 01-Network.md (LXC proxy devices en D1 + nginx stream en DV0).

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
MM="$BASE/files/multimedia"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="multimedia"

echo "[1/5] Aplicando namespace y almacenamiento (media-data + qbittorrent/jellyfin/amule)..."
cat "$MM/namespace.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/storage.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo "Esperando a que las PVCs queden Bound..."
ssh "$KUBECTL_HOST" "kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Bound pvc --all --timeout=180s"
ssh "$KUBECTL_HOST" "kubectl -n $NS get pvc"

echo
echo "[2/5] Creando el árbol /data en la librería (Job init-media-dirs)..."
# Recrear el Job si ya existía (kubectl apply no lo recrea al cambiar el pod spec)
ssh "$KUBECTL_HOST" "kubectl -n $NS delete job init-media-dirs --ignore-not-found"
cat "$MM/init-media-dirs.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
ssh "$KUBECTL_HOST" "kubectl -n $NS wait --for=condition=complete job/init-media-dirs --timeout=180s"

echo
echo "[3/5] Configurando Secret de aMule (si se pasan AMULE_*_PWD)..."
if [ -n "${AMULE_WEB_PWD:-}" ] || [ -n "${AMULE_EC_PWD:-}" ]; then
  ssh "$KUBECTL_HOST" "kubectl -n $NS create secret generic amule-secret \
    --from-literal=WEBUI_PWD='${AMULE_WEB_PWD:-}' \
    --from-literal=EC_PASSWORD='${AMULE_EC_PWD:-}' \
    --dry-run=client -o yaml | kubectl apply -f -"
  echo "  Secret amule-secret aplicado"
else
  echo "  Sin AMULE_*_PWD -> amule arrancará sin password (cambiar luego con kubectl create secret)"
fi

echo
echo "[3/5] Desplegando aplicaciones (qbittorrent, jellyfin, amule)..."
for app in qbittorrent jellyfin amule; do
  echo "  -> $app"
  cat "$MM/$app.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
done

echo
echo "[4/5] Aplicando NetworkPolicies, Certificados e Ingress (jellyfin/qbittorrent/amule públicos)..."
cat "$MM/networkpolicy-multimedia.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/networkpolicy-acme-http01.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/certificate-jellyfin.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/ingress-jellyfin.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/certificate-qbittorrent.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/ingress-qbittorrent.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/certificate-amule.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/ingress-amule.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "[5/5] Esperando a que todos los Deployments estén listos..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deploy/qbittorrent --timeout=300s"
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deploy/jellyfin --timeout=300s"
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deploy/amule --timeout=300s"

echo
echo "OK: stack multimedia simplificado desplegado en el namespace '$NS'"
echo
echo "Verificación sugerida:"
echo "  kubectl -n $NS get pods -o wide"
echo "  kubectl -n $NS get pvc"
echo "  curl -s -o /dev/null -w '%{http_code}' https://jellyfin.elarreglador.eu/  (login Jellyfin)"
echo "  curl -s -o /dev/null -w '%{http_code}' https://torrent.elarreglador.eu/   (login qBittorrent)"
echo "  curl -s -o /dev/null -w '%{http_code}' https://amule.elarreglador.eu/     (login amuleweb)"
echo "  kubectl -n $NS get certificate"
echo
echo "Notas:"
echo "  - qBittorrent WebUI: subir .torrent/magnet por UI (login propio, no necesita wizard)"
echo "  - aMule: WebUI en 4711, definir incoming=/data/amule/incoming temp=/data/amule/temp"
echo "  - IPs liberadas: 192.168.1.54 (ahora amule), .55 (ahora amule-p2p), .56/.57 libres"
echo "Los detalles viven en 03-Aplicaciones.md."