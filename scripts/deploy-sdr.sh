#!/bin/bash
# Despliegue del servidor de radio SDR remoto (rtl_tcp).
#
# Sirve el dongle RTL-SDR v3 (0bda:2838) + Ham It Up conectado en D1 a través
# de un pod privilegiado anclado a k8s-worker-1 (nodeSelector). rtl_tcp admite
# un único cliente a la vez. Ejecutar desde la raíz del repo.
#
# Uso:
#   ./scripts/deploy-sdr.sh [NODE]
#
# Variables de entorno (valor por defecto entre paréntesis):
#   KUBECTL_HOST  (server)   host con kubectl configurado contra el cluster
#
# Requisitos previos (una sola vez, en el host D1):
#   - Dongle pasado al contenedor k8s-worker-1: lxc config device add
#     k8s-worker-1 rtlsdr usb vendorid=0bda productid=2838
#   - Proxy LXC escuchando en la IP WG de D1:
#     lxc config device add k8s-worker-1 proxyrtlsdr proxy \
#       listen=tcp:10.8.0.11:1234 connect=tcp:127.0.0.1:31234
#   Detalles en 01-Network.md y 03-Aplicaciones.md.

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SDR="$BASE/files/sdr"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="pods"
NODE="${1:-k8s-worker-1}"
LABEL_KEY="eu.elarreglador/sdr"
LABEL_VALUE="true"

echo "Etiquetando el nodo '$NODE' ($LABEL_KEY=$LABEL_VALUE) — anclaje del pod SDR..."
ssh "$KUBECTL_HOST" "kubectl label node $NODE $LABEL_KEY=$LABEL_VALUE --overwrite"

echo
echo "Aplicando manifests (namespace, deployment, service, networkpolicy)..."
cat "$SDR/sdr.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
cat "$SDR/networkpolicy.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"

echo
echo "Esperando a que el pod esté listo..."
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deployment/rtl-sdr --timeout=300s"

echo
echo "OK: rtl_tcp desplegado en el namespace '$NS', anclado a '$NODE'"
echo "Verificación sugerida:"
echo "  kubectl -n $NS get pods -o wide"
echo "  Desde GQRX: dispositivo 'RTL-SDR (TCP)', host sdr.elarreglador.eu, puerto 1234, LNB LO = -125 MHz"
echo "  Cabecera DongleInfo (12 bytes) por TCP:"
echo "    timeout 3 python3 -c \"import socket; s=socket.socket(); s.settimeout(2); s.connect(('sdr.elarreglador.eu',1234)); print('bytes:', len(s.recv(12)))\""