#!/bin/bash
# Exposición pública de los puertos P2P de aMule (ed2k/KAD).
#
# Cadena:
#   internet → DV0:4662/4672/4665 (nginx stream) → 10.8.0.11:4662/4672/4665 (LXD proxy devices en D1)
#     → 127.0.0.1:31682/31683/31684 dentro de k8s-worker-1 (NodePorts amule-p2p)
#     → pod amule (4662/4672/4665)
#
# Ejecutar desde la raíz del repo.
#
# Uso:
#   SUDO_PASS=<password_sudo_dv0> ./scripts/amule-expose-p2p.sh
#
# Variables de entorno:
#   SUDO_PASS     password de sudo en DV0 (obligatoria)
#   DV0_HOST      (server)
#   D1_HOST       (D1)
#   NODE          (k8s-worker-1)
#
# Idempotente.

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
DV0_HOST="${DV0_HOST:-server}"
D1_HOST="${D1_HOST:-D1}"
NODE="${NODE:-k8s-worker-1}"
WG_IP_D1="10.8.0.11"
PUBLIC_IP="82.223.50.169"

if [[ -z "${SUDO_PASS:-}" ]]; then
  echo "ERROR: falta SUDO_PASS (password de sudo de DV0)" >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes)

# Mapeo: puerto público → NodePort → protocolo LXC
declare -A MAP=(
  [4662]="31682:tcp"
  [4672]="31683:udp"
  [4665]="31684:udp"
)

echo "== [1/4] Proxy LXC en D1 (amule P2P) hacia NodePorts =="
for port in "${!MAP[@]}"; do
  IFS=":" read -r nodeport proto <<< "${MAP[$port]}"
  dev="proxyamule${port}"
  if ssh "${SSH_OPTS[@]}" "$D1_HOST" "lxc config device show $NODE | grep -q \"$dev:\""; then
    echo "  $dev ya existe -> omitido"
  else
    ssh "${SSH_OPTS[@]}" "$D1_HOST" \
      "lxc config device add $NODE $dev proxy listen=$proto:$WG_IP_D1:$port connect=$proto:127.0.0.1:$nodeport"
    echo "  $dev creado ($proto $port -> $nodeport)"
  fi
done

echo
echo "== [2/4] Config de stream nginx en DV0 =="
CONF="$BASE/files/amule-stream.conf"
cat > "$CONF" <<EOF
upstream amule_4662 {
    server $WG_IP_D1:4662;
}
server {
    listen 4662;
    proxy_pass amule_4662;
    proxy_timeout 300s;
}
upstream amule_4672 {
    server $WG_IP_D1:4672;
}
server {
    listen 4672 udp;
    proxy_pass amule_4672;
    proxy_timeout 300s;
}
upstream amule_4665 {
    server $WG_IP_D1:4665;
}
server {
    listen 4665 udp;
    proxy_pass amule_4665;
    proxy_timeout 300s;
}
EOF

sudo_stdin() { ssh "${SSH_OPTS[@]}" "$DV0_HOST" "echo '$SUDO_PASS' | sudo -S -p '' $*"; }

echo "  Instalando /etc/nginx/stream.conf.d/amule.conf..."
{ echo "$SUDO_PASS"; cat "$CONF"; } | ssh "${SSH_OPTS[@]}" "$DV0_HOST" \
  "sudo -S -p '' tee /etc/nginx/stream.conf.d/amule.conf >/dev/null"

echo
echo "== [3/4] Validación y reload de nginx =="
sudo_stdin "bash -c 'nginx -t && systemctl reload nginx'"
sudo_stdin "ss -tulnp" | grep -E ":(4662|4672|4665)\b" || echo "  (puertos aún no visibles, verificar tras reload)"

echo
echo "== [4/4] Verificación por capas =="
for port in 4662 4672 4665; do
  echo "  DV0 -> D1:$port"
  ssh "${SSH_OPTS[@]}" "$DV0_HOST" "nc -zv -w 5 $WG_IP_D1 $port" || echo "    AVISO: $port no responde (aMule aún no Ready?)"
done
echo "  Externo: nc -zv $PUBLIC_IP 4662 (TCP); UDP requiere cliente eDonkey real"
echo
echo "OK: amule P2P expuesto. Config persistida en:"
echo "  D1  : lxc config device show $NODE (proxyamule*)"
echo "  DV0 : /etc/nginx/stream.conf.d/amule.conf"
