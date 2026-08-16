#!/bin/bash
# Instala el backup del stack multimedia en los dos control-planes (masters).
# Copia files/backup-multimedia.sh a /usr/local/bin/ en k8s-master-1 y k8s-master-2
# y crea el cron diario (02:00) con log en /var/log/multimedia-backup.log.
# Ejecutar desde la raíz del repo. No necesita credenciales: el LXC se accede
# como root por lxc exec (igual que el procedimiento del backup de MariaDB).
#
# Uso:
#   ./scripts/install-multimedia-backup.sh

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_SRC="$BASE/files/backup-multimedia.sh"
CRON_LINE='0 2 * * * root /usr/local/bin/backup-multimedia.sh >> /var/log/multimedia-backup.log 2>&1'

[ -f "$SCRIPT_SRC" ] || { echo "ERROR: no existe $SCRIPT_SRC"; exit 1; }

for node in "D1 k8s-master-1" "D2 k8s-master-2"; do
  read -r HOST CTR <<< "$node"
  echo "--- Instalando en $HOST / $CTR ---"
  ssh "$HOST" "lxc exec $CTR -- sh -c 'cat > /usr/local/bin/backup-multimedia.sh'" < "$SCRIPT_SRC"
  ssh "$HOST" "lxc exec $CTR -- sh -c 'chmod 700 /usr/local/bin/backup-multimedia.sh'"
  ssh "$HOST" "lxc exec $CTR -- sh -c 'mkdir -p /backup/multimedia && chmod 700 /backup/multimedia'"
  ssh "$HOST" "lxc exec $CTR -- sh -c \"echo '$CRON_LINE' > /etc/cron.d/multimedia-backup && chmod 644 /etc/cron.d/multimedia-backup\""
  ssh "$HOST" "lxc exec $CTR -- ls -l /usr/local/bin/backup-multimedia.sh /etc/cron.d/multimedia-backup"
done

echo
echo "OK: backup multimedia instalado en ambos masters (cron 0 2 * * *)."
echo "Prueba manual en un master:"
echo "  lxc exec k8s-master-1 -- /usr/local/bin/backup-multimedia.sh"
echo "Verificación:"
echo "  lxc exec k8s-master-1 -- ls -l /backup/multimedia/"