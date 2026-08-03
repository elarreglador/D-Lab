#!/bin/bash
# Backup de MariaDB (dumps SQL) + copia redundante al peer (DR)
# Desplegado en k8s-master-1 y k8s-master-2 (mismo fichero; se auto-parametriza por hostname).
# El dump se hace vía kubectl exec sobre el pod mariadb: sin dependencia de red hacia el pod
# (kubectl va por el API Server). La contraseña se lee del Secret, no se versiona en el repo.
# Cron: 0 3 * * * root /usr/local/bin/backup-mariadb.sh >> /var/log/mariadb-backup.log 2>&1
set -u

BACKUP_DIR=/backup/mariadb
DATE=$(date +%Y%m%d-%H%M%S)

HOST=$(hostname)
case "$HOST" in
  k8s-master-1) PEER_IP=192.168.1.22 ;;
  k8s-master-2) PEER_IP=192.168.1.21 ;;
  *) echo "ERROR: host desconocido: $HOST"; exit 1 ;;
esac

POD=$(kubectl get pod -n pods -l app=mariadb --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "ERROR: pod mariadb no encontrado"
  exit 1
fi

# La contraseña se lee del Secret del cluster (nunca hardcodeada)
ROOT_PW=$(kubectl get secret -n pods mariadb-secret -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' \
  | base64 -d 2>/dev/null)
if [ -z "$ROOT_PW" ]; then
  echo "ERROR: no se pudo leer el Secret mariadb-secret"
  exit 1
fi

mkdir -p $BACKUP_DIR
DUMP="$BACKUP_DIR/mariadb-${DATE}.sql"

# --single-transaction: snapshot consistente en InnoDB sin bloquear
kubectl exec -n pods "$POD" -- mariadb-dump \
  --single-transaction --routines --triggers --all-databases \
  -uroot -p"$ROOT_PW" > "$DUMP" 2>/tmp/mariadb-dump.err

if [ -s "$DUMP" ]; then
  echo "Backup saved: $DUMP ($HOST)"
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$PEER_IP" \
      "mkdir -p $BACKUP_DIR && cat > $BACKUP_DIR/mariadb-${DATE}.sql" \
      < "$DUMP" 2>/dev/null; then
    echo "Copia al peer $PEER_IP: OK"
  else
    echo "WARN: copia al peer $PEER_IP fallida (continuando con copia local)"
  fi
else
  echo "ERROR: dump vacío. mariadb-dump dijo:"
  cat /tmp/mariadb-dump.err
  rm -f "$DUMP"
fi

# Rotación local (últimas 30)
ls -t ${BACKUP_DIR}/mariadb-*.sql 2>/dev/null | tail -n +31 | xargs -r rm
