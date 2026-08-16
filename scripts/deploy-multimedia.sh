#!/bin/bash
# Despliegue del stack multimedia en el namespace "multimedia".
#
# Cadena: Jellyseerr (facade) → Sonarr/Radarr (organizadores) → Prowlarr +
# FlareSolverr (rastreo) → qBittorrent (descarga) → Jellyfin (servidor).
# Ejecutar desde la raíz del repo.
#
# Uso:
#   ./scripts/deploy-multimedia.sh
#
# Variables de entorno (valor por defecto entre paréntesis):
#   KUBECTL_HOST  (server)   host con kubectl configurado contra el cluster
#
# Nota: el puerto de torrent (6881/tcp+udp) expuesto por la cadena pública se
# documenta en 01-Network.md (LXC proxy devices en D1 + nginx stream en DV0).

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
MM="$BASE/files/multimedia"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="multimedia"

echo "[1/5] Aplicando namespace y almacenamiento (PVC media-data RWX 400Gi + PVCs de config)..."
cat "$MM/namespace.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/storage.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo "Esperando a que las PVCs queden Bound..."
ssh "$KUBECTL_HOST" "kubectl -n $NS wait --for=jsonpath='{.status.phase}'=Bound pvc --all --timeout=180s"
ssh "$KUBECTL_HOST" "kubectl -n $NS get pvc"

echo
echo "[2/5] Creando el árbol /data en la librería (Job init-media-dirs)..."
cat "$MM/init-media-dirs.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
ssh "$KUBECTL_HOST" "kubectl -n $NS wait --for=condition=complete job/init-media-dirs --timeout=180s"

echo
echo "[3/5] Desplegando aplicaciones (flaresolverr, prowlarr, sonarr, radarr, qbittorrent, jellyseerr, jellyfin)..."
for app in flaresolverr prowlarr sonarr radarr qbittorrent jellyseerr jellyfin; do
  echo "  -> $app"
  cat "$MM/$app.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
done

echo
echo "[4/5] Aplicando NetworkPolicies, Certificados e Ingress (jellyseerr/jellyfin públicos)..."
cat "$MM/networkpolicy-internal.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/networkpolicy-acme-http01.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/networkpolicy-public.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/networkpolicy-qbittorrent.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/certificate-jellyseerr.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/ingress-jellyseerr.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/certificate-jellyfin.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$MM/ingress-jellyfin.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "[5/5] Esperando a que todos los Deployments estén listos..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deploy --timeout=420s"

echo
echo "OK: stack multimedia desplegado en el namespace '$NS'"
echo
echo "Verificación sugerida:"
echo "  kubectl -n $NS get pods -o wide"
echo "  kubectl -n $NS get pvc"
echo "  curl -s -o /dev/null -w '%{http_code}' https://jellyseerr.elarreglador.eu/"
echo "  curl -s -o /dev/null -w '%{http_code}' https://jellyfin.elarreglador.eu/"
echo "  kubectl -n $NS get certificate"
echo
echo "Siguiente: bootstrap del stack vía API (idempotente, sin navegador):"
echo "  source info_sensible/multimedia.env && ./scripts/multimedia-wizard.sh"
echo "Los detalles de configuración de cada app viven en 03-Aplicaciones.md."