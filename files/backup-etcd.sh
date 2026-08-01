#!/bin/bash
# Backup de etcd + copia redundante al peer (DR)
# Desplegado en k8s-master-1 y k8s-master-2 (mismo fichero; se auto-parametriza por hostname).
# Usa crictl para ejecutar etcdctl en el pod etcd local: no depende del API Server,
# por lo que funciona aunque el peer esté caído (sin quorum).
# Cron: 0 2 * * * root /usr/local/bin/backup-etcd.sh >> /var/log/etcd-backup.log 2>&1
set -u

BACKUP_DIR=/backup/etcd
DATE=$(date +%Y%m%d-%H%M%S)

HOST=$(hostname)
case "$HOST" in
  k8s-master-1) ETCD_POD=etcd-k8s-master-1; PEER_IP=192.168.1.22 ;;
  k8s-master-2) ETCD_POD=etcd-k8s-master-2; PEER_IP=192.168.1.21 ;;
  *) echo "ERROR: host desconocido: $HOST"; exit 1 ;;
esac

mkdir -p $BACKUP_DIR

ETCD_CTR=$(crictl ps --label io.kubernetes.pod.name="$ETCD_POD" --state Running -q 2>/dev/null | head -1)
if [ -z "$ETCD_CTR" ]; then
  echo "ERROR: contenedor etcd ($ETCD_POD) no encontrado"
  exit 1
fi

crictl exec "$ETCD_CTR" \
  etcdctl --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save /var/lib/etcd/snapshot-${DATE}.db 2>&1

if [ -f /var/lib/etcd/snapshot-${DATE}.db ]; then
  cp /var/lib/etcd/snapshot-${DATE}.db "$BACKUP_DIR/"
  rm /var/lib/etcd/snapshot-${DATE}.db
  echo "Backup saved: $BACKUP_DIR/snapshot-${DATE}.db ($HOST)"

  # Copia redundante al peer (los datos de etcd son idénticos en ambos miembros)
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$PEER_IP" \
      "mkdir -p $BACKUP_DIR && cat > $BACKUP_DIR/snapshot-${DATE}.db" \
      < "$BACKUP_DIR/snapshot-${DATE}.db" 2>/dev/null; then
    echo "Copia al peer $PEER_IP: OK"
  else
    echo "WARN: copia al peer $PEER_IP fallida (continuando con copia local)"
  fi
else
  echo "ERROR: snapshot file not found"
fi

# Rotación local (últimas 30)
ls -t ${BACKUP_DIR}/snapshot-*.db 2>/dev/null | tail -n +31 | xargs -r rm
