#!/bin/bash
# Conecta la GPU integrada Intel HD 630 a los contenedores LXC de los workers,
# despliega el device plugin que la expone al cluster y ajusta el pod de
# Jellyfin para usarla (VAAPI).
#
# SPEC 02 — Aceleración por hardware VAAPI para Jellyfin.
#
# Ejecutar desde la raíz del repo. Requiere acceso SSH a D1 (miembro del
# cluster LXD) y a $KUBECTL_HOST.
#
# Uso:
#   KUBECTL_HOST=server ./scripts/jellyfin-gpu-passthrough.sh
#
# Variables de entorno:
#   KUBECTL_HOST  (server) host con kubectl configurado contra el cluster
#   LXC_HOST      (D1)     miembro del cluster LXD desde el que aplicar devices
#
# Idempotente: se puede ejecutar las veces que se quiera. No reinicia los
# contenedores LXC ni reinicia Jellyfin salvo que cambie el manifiesto.
#
# Notas de diseño (ver specs/02-vaapi-jellyfin-gpu.md):
#   - No se usa hostPath ni privileged en el pod de Jellyfin: el namespace
#     multimedia está en PodSecurity baseline y runc denegaría la apertura del
#     char device. El privilegio queda en el DaemonSet de kube-system.
#   - El plugin necesita /sys/class/drm, que no existe dentro del LXC: se
#     monta readonly.
#   - El hostfs del snap LXD en D1 no ve /tmp, así que no uses 'lxc file push'
#     desde rutas temporales: usa stdin (tee) o 'lxc exec' directo.

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
MM="$BASE/files/multimedia"
KUBECTL_HOST="${KUBECTL_HOST:-server}"
LXC_HOST="${LXC_HOST:-D1}"
WORKERS=(k8s-worker-1 k8s-worker-2)

echo "[1/6] Conectando /dev/dri (device GPU, gid 44) a los workers..."
for w in "${WORKERS[@]}"; do
  if ssh "$LXC_HOST" "lxc config device get $w gpu type" >/dev/null 2>&1; then
    echo "  $w: device gpu ya presente, se mantiene"
  else
    ssh "$LXC_HOST" "lxc config device add $w gpu gpu gid=44"
    echo "  $w: device gpu añadido"
  fi
done

echo "[2/6] Montando /sys/class/drm (readonly) en los workers..."
for w in "${WORKERS[@]}"; do
  if ssh "$LXC_HOST" "lxc config device get $w sysdrm type" >/dev/null 2>&1; then
    echo "  $w: device sysdrm ya presente, se mantiene"
  else
    ssh "$LXC_HOST" "lxc config device add $w sysdrm disk source=/sys/class/drm path=/sys/class/drm readonly=true"
    echo "  $w: device sysdrm añadido"
  fi
done

echo "[3/6] Verificando acceso dentro de cada contenedor..."
for w in "${WORKERS[@]}"; do
  ssh "$LXC_HOST" "lxc exec $w -- sh -c 'ls /dev/dri/renderD128 >/dev/null && ls /sys/class/drm/renderD128 >/dev/null'" \
    && echo "  $w: /dev/dri y /sys/class/drm OK" \
    || { echo "  ERROR: $w no ve la GPU"; exit 1; }
done

echo "[4/6] Desplegando el device plugin (DaemonSet en kube-system)..."
cat "$MM/intel-gpu-plugin.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
ssh "$KUBECTL_HOST" "kubectl -n kube-system rollout status ds/intel-gpu-plugin --timeout=180s"

echo "[5/6] Ajustando el pod de Jellyfin (gpu.intel.com/i915 + cache 10Gi)..."
cat "$MM/jellyfin.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
ssh "$KUBECTL_HOST" "kubectl -n multimedia rollout status deploy/jellyfin --timeout=300s"

echo "[6/6] Activando VAAPI dentro de Jellyfin (POST /System/Configuration)..."
cat "$MM/jellyfin-vaapi.yaml" | ssh "$KUBECTL_HOST" "kubectl apply -f -"
if ssh "$KUBECTL_HOST" "kubectl -n multimedia wait --for=condition=complete job/jellyfin-vaapi --timeout=180s" 2>/dev/null; then
  ssh "$KUBECTL_HOST" "kubectl -n multimedia logs job/jellyfin-vaapi" 2>&1 | grep -v -i token | tail -6
else
  echo "  AVISO: jellyfin-vaapi no completó; revisa:"
  echo "    ssh $KUBECTL_HOST kubectl -n multimedia logs job/jellyfin-vaapi"
fi

echo
echo "OK: GPU conectada y expuesta al cluster."
echo
echo "Verificación sugerida:"
echo "  ssh $KUBECTL_HOST kubectl get nodes -o custom-columns=NAME:.metadata.name,'GPU:.status.allocatable.gpu\.intel\.com/i915'"
echo "  ssh $KUBECTL_HOST kubectl -n multimedia exec deploy/jellyfin -- /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128"
echo
echo "Nota: el Job deja AVISOS (no fallos) si Jellyfin rechaza el tonemapping VPP"
echo "      o hevc en HardwareDecodingCodecs. Ver el estado completo en"
echo "      specs/02-vaapi-jellyfin-gpu.md, sección «Estado de la verificación»."
