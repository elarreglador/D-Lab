#!/bin/bash
# Backup de la configuración del stack multimedia (BDs SQLite + ajustes de las apps).
# Desplegado en k8s-master-1 y k8s-master-2 (mismo fichero; se auto-parametriza por hostname).
# El tar se genera vía kubectl exec sobre cada pod: sin dependencia de la red del pod.
#
#  SENSIBLE: /backup/multimedia/ contiene credenciales (API keys de trackers,
#  clientes de descarga, tokens, hashes de contraseñas). Tratar como datos
#  sensibles; NUNCA versionar ni mover fuera del cluster sin cifrar.
#
# Cron: 0 2 * * * root /usr/local/bin/backup-multimedia.sh >> /var/log/multimedia-backup.log 2>&1
# Requiere /root/.kube/config en ambos masters (kubeconfig admin.conf).
set -u

BACKUP_DIR=/backup/multimedia
DATE=$(date +%Y%m%d-%H%M%S)
NS=multimedia
APPS="qbittorrent jellyfin amule"

HOST=$(hostname)
case "$HOST" in
  k8s-master-1) PEER_IP=192.168.1.22 ;;
  k8s-master-2) PEER_IP=192.168.1.21 ;;
  *) echo "ERROR: host desconocido: $HOST"; exit 1 ;;
esac

mkdir -p "$BACKUP_DIR"

for app in $APPS; do
  POD=$(kubectl get pod -n $NS -l app=$app --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ -z "$POD" ]; then
    echo "WARN: pod $app no encontrado en $NS; se omite"
    continue
  fi

  # qBittorrent/Jellyfin usan /config; aMule usa /home/amule/.aMule
  case "$app" in
    amule) CFG=/home/amule/.aMule ;;
    *) CFG=/config ;;
  esac

  OUT="$BACKUP_DIR/${app}-${DATE}.tar"

  # ¿El contenedor trae sqlite3? Si sí, hacemos snapshot consistente de cada .db.
  if kubectl exec -n "$NS" "$POD" -- sh -c 'command -v sqlite3 >/dev/null' 2>/dev/null; then
    kubectl exec -n "$NS" "$POD" -i -- sh -c '
      CFG=$1
      rm -rf "$CFG/.backup-tmp" && mkdir -p "$CFG/.backup-tmp"
      find "$CFG" -name "*.db" -type f | while read -r db; do
        rel="${db#$CFG/}"
        mkdir -p "$CFG/.backup-tmp/$(dirname "$rel")"
        sqlite3 "$db" ".backup \"$CFG/.backup-tmp/$rel\"" || echo "  AVISO: fallo .backup de $rel"
      done
' _ "$CFG" >/dev/null 2>&1
    # Tar de todo el config salvo *.db, más el snapshot (paths relativos idénticos)
    kubectl exec -n "$NS" "$POD" -- tar -C "$CFG" -cf - --exclude='*.db' . > "$OUT"
    kubectl exec -n "$NS" "$POD" -- tar -C "$CFG/.backup-tmp" -rf - . >> "$OUT"
    kubectl exec -n "$NS" "$POD" -- rm -rf "$CFG/.backup-tmp"
    SRC="snapshot sqlite"
  else
    # Sin sqlite3: tar directo (db+wal+shm en una sola pasada, ventana mínima)
    kubectl exec -n "$NS" "$POD" -- tar -C "$CFG" -cf - . > "$OUT"
    SRC="tar directo (wal incluido)"
  fi

  if [ -s "$OUT" ]; then
    echo "Backup saved: $OUT ($HOST, $SRC)"
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$PEER_IP" \
        "mkdir -p $BACKUP_DIR && cat > $BACKUP_DIR/${app}-${DATE}.tar" \
        < "$OUT" 2>/dev/null; then
      echo "Copia al peer $PEER_IP: OK"
    else
      echo "WARN: copia al peer $PEER_IP fallida (continua la copia local)"
    fi
  else
    echo "ERROR: tar vacío para $app"
    rm -f "$OUT"
  fi

  # Rotación por app (últimas 30)
  ls -t ${BACKUP_DIR}/${app}-*.tar 2>/dev/null | tail -n +31 | xargs -r rm
done

echo "Backup multimedia completado: $(date)"
