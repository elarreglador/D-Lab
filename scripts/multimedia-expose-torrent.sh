#!/bin/bash
# Exposición pública del puerto de torrents de qBittorrent (TCP + UDP).
#
# Cadena:
#   internet → DV0:6881 (nginx stream) → 10.8.0.11:6881 (LXD proxy device en D1)
#     → 127.0.0.1:31681 dentro de k8s-worker-1 (NodePort qbittorrent-torrent)
#     → pod qbittorrent (6881)
#
# Ejecutar desde la raíz del repo.
#
# Uso:
#   SUDO_PASS=<password_sudo_dv0> ./scripts/multimedia-expose-torrent.sh
#
# Variables de entorno:
#   SUDO_PASS     password de sudo en DV0 (obligatoria; no se persiste)
#   DV0_HOST      (server)  alias SSH de DV0
#   D1_HOST       (D1)      alias SSH de D1
#   NODE          (k8s-worker-1) contenedor LXC que aloja qBittorrent
#   TORRENT_PORT  (6881)   puerto público de torrent
#   NODEPORT      (31681)  puerto NodePort del Service qbittorrent-torrent
#
# Idempotente: no duplica proxies LXC ni reinicia nginx si el stream ya existe.

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
DV0_HOST="${DV0_HOST:-server}"
D1_HOST="${D1_HOST:-D1}"
NODE="${NODE:-k8s-worker-1}"
TORRENT_PORT="${TORRENT_PORT:-6881}"
NODEPORT="${NODEPORT:-31681}"
WG_IP_D1="10.8.0.11"
PUBLIC_IP="82.223.50.169"

if [[ -z "${SUDO_PASS:-}" ]]; then
  echo "ERROR: falta SUDO_PASS (password de sudo de DV0)" >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes)

echo "== [1/4] Proxy LXC en D1 (TCP + UDP) hacia el NodePort $NODEPORT =="
for proto in tcp udp; do
  dev="proxytorrent"
  [[ "$proto" == udp ]] && dev="proxytorrentudp"
  if ssh "${SSH_OPTS[@]}" "$D1_HOST" "lxc config device show $NODE | grep -q \"$dev:\""; then
    echo "  $dev ya existe -> omitido"
  else
    ssh "${SSH_OPTS[@]}" "$D1_HOST" \
      "lxc config device add $NODE $dev proxy listen=$proto:$WG_IP_D1:$TORRENT_PORT connect=$proto:127.0.0.1:$NODEPORT"
    echo "  $dev creado ($proto)"
  fi
done

echo
echo "== [2/4] Config de stream nginx en DV0 =="
CONF="$BASE/files/torrent-stream.conf"
cat > "$CONF" <<EOF
upstream torrent_upstream {
    server $WG_IP_D1:$TORRENT_PORT;
}

server {
    listen $TORRENT_PORT;
    proxy_pass torrent_upstream;
    proxy_timeout 300s;
}

server {
    listen $TORRENT_PORT udp;
    proxy_pass torrent_upstream;
    proxy_timeout 300s;
}
EOF

# La password se inyecta por stdin de la sesión ssh (sudo -S). Sin soporte TTY,
# el timestamp de sudo no persiste entre sesiones: se pasa en cada comando.
sudo_stdin() { ssh "${SSH_OPTS[@]}" "$DV0_HOST" "echo '$SUDO_PASS' | sudo -S -p '' $*"; }

echo "  Instalando /etc/nginx/stream.conf.d/torrent.conf..."
{ echo "$SUDO_PASS"; cat "$CONF"; } | ssh "${SSH_OPTS[@]}" "$DV0_HOST" \
  "sudo -S -p '' tee /etc/nginx/stream.conf.d/torrent.conf >/dev/null"

echo
echo "== [3/4] Validación y reload de nginx =="
sudo_stdin "bash -c 'nginx -t && systemctl reload nginx'"
sudo_stdin "ss -tulnp" | grep ":$TORRENT_PORT\b"

echo
echo "== [4/4] Verificación por capas =="
echo "  a) DV0 → D1:$TORRENT_PORT (proxy LXC):"
ssh "${SSH_OPTS[@]}" "$DV0_HOST" "nc -zv -w 5 $WG_IP_D1 $TORRENT_PORT"
echo "  b) D1 → NodePort dentro de $NODE:"
ssh "${SSH_OPTS[@]}" "$D1_HOST" "lxc exec $NODE -- sh -c 'nc -zv -w 5 127.0.0.1 $NODEPORT'"
echo "  c) Externo TCP (${PUBLIC_IP}:$TORRENT_PORT):"
if timeout 8 nc -zv -w 5 "$PUBLIC_IP" "$TORRENT_PORT"; then
  echo "    OK: puerto TCP abierto desde el exterior"
else
  echo "    AVISO: nc no confirma (puede ser filtrado); verificar con una descarga real." >&2
fi
echo "  d) UDP: sin eco fiable -> comprobar con magnet/DHT real en qBittorrent (wizard)."

echo
echo "OK: torrent expuesto (TCP+UDP). Config persistida en:"
echo "  D1  : lxc config device show $NODE (proxytorrent / proxytorrentudp)"
echo "  DV0 : /etc/nginx/stream.conf.d/torrent.conf"