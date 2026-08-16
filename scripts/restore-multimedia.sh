#!/bin/bash
# Restauración de la configuración de una app del stack multimedia desde los
# backups de /backup/multimedia/ (masters). Ejecutar desde la raíz del repo.
#
# La BD de configuración contiene credenciales (API keys, tokens): el backup se
# extrae de los masters por la red privada y el fichero temporal es local.
#
# Uso:
#   ./scripts/restore-multimedia.sh <app> [timestamp]
#   ./scripts/restore-multimedia.sh sonarr            # lista backups y pide timestamp
#   ./scripts/restore-multimedia.sh sonarr 20260814-020000
#
# Variables de entorno (valor por defecto entre paréntesis):
#   KUBECTL_HOST  (server)   host con kubectl configurado contra el cluster
#
# Apps con config respaldada: sonarr radarr prowlarr qbittorrent jellyfin jellyseerr

set -euo pipefail

KUBECTL_HOST="${KUBECTL_HOST:-server}"
NS="multimedia"
BACKUP_DIR=/backup/multimedia
APPS="sonarr radarr prowlarr qbittorrent jellyfin jellyseerr"

APP="${1:-}"
[ -z "$APP" ] && { echo "ERROR: use: $0 <app> [timestamp]"; exit 1; }
case " $APPS " in
  *" $APP "*) ;;
  *) echo "ERROR: app desconocida '$APP'. Válidas: $APPS"; exit 1 ;;
esac

# Localización de los masters (LXC) desde los hosts
master_host() {
  case "$1" in
    k8s-master-1) echo "D1 k8s-master-1" ;;
    k8s-master-2) echo "D2 k8s-master-2" ;;
  esac
}

echo "Buscando backups de '$APP' en los masters..."
LIST=""
for m in k8s-master-1 k8s-master-2; do
  read -r HOST CTR <<< "$(master_host "$m")"
  L=$(ssh "$HOST" "lxc exec $CTR -- ls -1 ${BACKUP_DIR}/${APP}-*.tar 2>/dev/null" || true)
  [ -n "$L" ] && { LIST="$L"; SRC_HOST="$HOST"; SRC_CTR="$CTR"; break; }
done

if [ -z "$LIST" ]; then
  echo "ERROR: no hay backups de '$APP' en $BACKUP_DIR de los masters."
  exit 1
fi

echo "Backups disponibles (${SRC_HOST}/${SRC_CTR}):"
echo "$LIST"
FILE="${2:-}"
if [ -z "$FILE" ]; then
  FILE=$(echo "$LIST" | tail -n 1)
  echo "Usando el más reciente: $FILE"
else
  echo "$LIST" | grep -qx "$FILE" || { echo "ERROR: '$FILE' no está entre los backups."; exit 1; }
fi

echo
echo "AVISO: se sobrescribirá la configuración actual de '$APP'."
read -r -p "¿Restaurar $APP desde $FILE? [y/N] " ANS
case "$ANS" in y|Y|s|S) ;; *) echo "Abortado."; exit 0 ;; esac

# 1. Descargar el tar desde el master (por la red privada WG/LAN)
TMP=$(mktemp /tmp/restore-${APP}-XXXXXX.tar)
ssh "$SRC_HOST" "lxc exec $SRC_CTR -- cat $BACKUP_DIR/$FILE" > "$TMP"
echo "Backup descargado: $TMP ($(stat -c%s "$TMP") bytes)"

# 2. Escalar la app a 0 para liberar el PVC y evitar corrupción
REPLICAS=$(ssh "$KUBECTL_HOST" "kubectl -n $NS get deploy/$APP -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1")
[ -z "$REPLICAS" ] && REPLICAS=1

cleanup() {
  ssh "$KUBECTL_HOST" "kubectl -n $NS delete pod restore-$APP --ignore-not-found >/dev/null 2>&1" || true
  ssh "$KUBECTL_HOST" "kubectl -n $NS scale deploy/$APP --replicas=$REPLICAS >/dev/null 2>&1" || true
  rm -f "$TMP"
}
trap cleanup EXIT

echo "Escalando $APP a 0 réplicas..."
ssh "$KUBECTL_HOST" "kubectl -n $NS scale deploy/$APP --replicas=0"

# 3. Pod temporal que monta la PVC de config
PVC="${APP}-config"
POD_NAME="restore-$APP"
cat <<EOF | ssh "$KUBECTL_HOST" "kubectl apply -f -"
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NS
spec:
  restartPolicy: Never
  securityContext:
    fsGroup: 1000
  containers:
    - name: restore
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: config
          mountPath: /config
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: $PVC
EOF

echo "Esperando a que el pod temporal monte la PVC..."
ssh "$KUBECTL_HOST" "kubectl -n $NS wait --for=condition=Ready pod/$POD_NAME --timeout=180s"

# 4. Extraer el backup en /config
echo "Restaurando contenido..."
ssh "$KUBECTL_HOST" "kubectl exec -i -n $NS $POD_NAME -- tar -xf - -C /config" < "$TMP"
echo "Contenido extraído correctamente."

# 5. Limpiar pod temporal y volver a escalar
ssh "$KUBECTL_HOST" "kubectl -n $NS delete pod $POD_NAME --wait=false --ignore-not-found"
ssh "$KUBECTL_HOST" "kubectl -n $NS scale deploy/$APP --replicas=$REPLICAS"
ssh "$KUBECTL_HOST" "kubectl -n $NS rollout status deploy/$APP --timeout=300s"

# 6. Chequeo de integridad de las BD (informativo, no bloqueante)
NEW_POD=$(ssh "$KUBECTL_HOST" "kubectl get pod -n $NS -l app=$APP --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null")
if [ -n "$NEW_POD" ]; then
  echo
  echo "Chequeo de integridad SQLite (informativo):"
  ssh "$KUBECTL_HOST" "kubectl exec -i -n $NS $NEW_POD -- sh" <<'SH' || true
    if command -v sqlite3 >/dev/null 2>&1; then
      for db in /config/*.db; do
        [ -f "$db" ] || continue
        echo "== $db =="
        sqlite3 "$db" 'PRAGMA integrity_check;'
      done
    else
      echo "sqlite3 no disponible en el pod; se omite el chequeo."
    fi
SH
fi

trap - EXIT
echo
echo "OK: configuración de '$APP' restaurada desde $FILE."
echo "Nota: si la app regenera API keys internas en el primer arranque,"
echo "puede requerir reconectar Jellyseerr/Sonarr/Radarr (ver 03-Aplicaciones.md)."