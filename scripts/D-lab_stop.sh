#!/bin/bash
# Apagado controlado del cluster D-Lab.
#
# Detiene de forma graceful los contenedores LXC (workers primero, master-1 el
# último), apaga los hosts D1/D2 y, opcionalmente, DV0. Se ejecuta en LOCAL y
# actúa en remoto por SSH. Ejecutar desde la raíz del repo.
#
# WireGuard NO se toca: es un servicio del host que se detiene con el poweroff
# y se regenera solo en cada boot (split-tunnel).
#
# Uso:
#   ./scripts/D-lab_stop.sh [--skip-preflight] [--yes]
#
# Variables de entorno (valor por defecto entre paréntesis):
#   KUBECTL_HOST  (server)   host con kubectl configurado contra el cluster
#   D1_HOST       (D1)       alias SSH del host D1 (192.168.1.11)
#   D2_HOST       (D2)       alias SSH del host D2 (192.168.1.12)
#   INCLUDE_DV0   (0)        1 = apagar también DV0 al final (apagado total)
#   DV0_HOST      (DV0)      alias SSH de DV0 (solo con INCLUDE_DV0=1)
#   STOP_TIMEOUT  (120)      segundos de espera por contenedor (parada graceful)

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"

KUBECTL_HOST="${KUBECTL_HOST:-server}"
D1_HOST="${D1_HOST:-D1}"
D2_HOST="${D2_HOST:-D2}"
DV0_HOST="${DV0_HOST:-DV0}"
INCLUDE_DV0="${INCLUDE_DV0:-0}"
STOP_TIMEOUT="${STOP_TIMEOUT:-120}"

SSH="ssh -o ConnectTimeout=10"
SKIP_PREFLIGHT=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --skip-preflight) SKIP_PREFLIGHT=1 ;;
    --yes)            ASSUME_YES=1 ;;
    *) echo "Uso: $0 [--skip-preflight] [--yes]" >&2; exit 1 ;;
  esac
done

log()  { echo "» $*"; }
ok()   { echo "   ✓ $*"; }
warn() { echo "   ! $*"; }

container_state() {
  local host=$1 name=$2 state
  state=$($SSH "$host" "lxc list $name -f csv -c s" 2>/dev/null || echo "SSH-FAIL")
  state=$(printf '%s' "$state" | tr -d '[:space:]')
  if [[ "$state" == "SSH-FAIL" ]]; then
    echo "ERROR: no se pudo consultar el estado de $name en $host." >&2
    exit 1
  fi
  printf '%s' "$state"
}

check_kubectl() {
  if ! $SSH "$KUBECTL_HOST" "kubectl get nodes" >/dev/null 2>&1; then
    echo "ERROR: no se puede contactar con kubectl vía '$KUBECTL_HOST'." >&2
    echo "       Configure el alias SSH y el kubeconfig, o use KUBECTL_HOST=<host>." >&2
    exit 1
  fi
}

check_sudo_nopasswd() {
  local host=$1
  if ! $SSH "$host" "sudo -n true" >/dev/null 2>&1; then
    echo "ERROR: 'sudo -n true' falla en '$host' (se requiere sudo sin contraseña)." >&2
    echo "       El apagado usa 'sudo poweroff' sin prompt; configure NOPASSWD" >&2
    echo "       (ver nota en 04-Operaciones.md)." >&2
    exit 1
  fi
  ok "$host: sudo sin contraseña OK"
}

backup_age_check() {
  local host=$1 container=$2 dir=$3
  local n
  n=$($SSH "$host" "lxc exec $container -- bash -lc 'find $dir -type f -mmin -1440 2>/dev/null | wc -l'" 2>/dev/null || true)
  if [[ "${n:-0}" -ge 1 ]]; then
    ok "$container: backups recientes (últimas 24 h) en $dir ($n fichero/s)"
  else
    warn "$container: SIN backups de $dir en las últimas 24 h"
    echo "           Ejecute backup manual antes de apagar, p. ej.:"
    echo "           ssh $host \"lxc exec $container -- /usr/local/bin/backup-etcd.sh\""
    echo "           (y backup-mariadb.sh para la BD)"
  fi
}

preflight() {
  log "Preflight: estado del cluster"
  check_kubectl
  $SSH "$KUBECTL_HOST" "kubectl get nodes"
  echo
  log "Workloads (resumen):"
  $SSH "$KUBECTL_HOST" "kubectl get pods -A -o wide" | head -40 || true
  echo
  log "Backups (cron etcd 02:00, mariadb 03:00):"
  backup_age_check "$D1_HOST" k8s-master-1 /backup/etcd
  backup_age_check "$D2_HOST" k8s-master-2 /backup/etcd
  backup_age_check "$D1_HOST" k8s-master-1 /backup/mariadb
  backup_age_check "$D2_HOST" k8s-master-2 /backup/mariadb
}

confirm_shutdown() {
  if [[ "$ASSUME_YES" == "1" ]]; then return 0; fi
  read -r -p "¿Apagar el cluster D-Lab (D1 + D2) y detener los servicios públicos? [s/N] " r
  case "${r,,}" in
    s|si|sí) return 0 ;;
    *) echo "Apagado cancelado."; exit 0 ;;
  esac
}

stop_container() {
  local host=$1 name=$2
  local state
  state="$(container_state "$host" "$name")"
  if [[ "$state" == "STOPPED" ]]; then
    ok "$name ($host): ya estaba parado"
    return 0
  fi
  if [[ "$state" != "RUNNING" ]]; then
    warn "$name ($host): estado '$state'; se intenta la parada igualmente"
  fi
  log "Parando $name ($host) — graceful, hasta $STOP_TIMEOUT s..."
  $SSH "$host" "lxc stop --timeout $STOP_TIMEOUT $name"
  state="$(container_state "$host" "$name")"
  if [[ "$state" != "STOPPED" ]]; then
    echo "ERROR: $name ($host) no quedó STOPPED (estado: '$state')." >&2
    exit 1
  fi
  ok "$name ($host) STOPPED"
}

shutdown_host() {
  local host=$1
  log "Apagando host $host..."
  $SSH "$host" "sudo poweroff" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 20); do
    if ! $SSH "$host" true >/dev/null 2>&1; then
      ok "$host no responde (apagado)"
      return 0
    fi
    sleep 3
  done
  warn "$host sigue respondiendo tras 60 s; compruebe manualmente"
}

main() {
  if [[ "$SKIP_PREFLIGHT" != "1" ]]; then
    preflight
  fi
  confirm_shutdown
  echo
  echo "════════ Apagado controlado ════════"
  log "0/2 Comprobación de privilegios (sudo sin contraseña) para el poweroff remoto"
  check_sudo_nopasswd "$D2_HOST"
  check_sudo_nopasswd "$D1_HOST"
  if [[ "$INCLUDE_DV0" == "1" ]]; then
    check_sudo_nopasswd "$DV0_HOST"
  fi
  log "1/2 Parada graceful de contenedores (workers primero; master-1 el último)"
  stop_container "$D2_HOST" k8s-worker-2
  stop_container "$D1_HOST" k8s-worker-1
  stop_container "$D2_HOST" k8s-master-2
  stop_container "$D1_HOST" k8s-master-1
  log "2/2 Apagado de hosts"
  shutdown_host "$D2_HOST"
  shutdown_host "$D1_HOST"
  if [[ "$INCLUDE_DV0" == "1" ]]; then
    shutdown_host "$DV0_HOST"
    echo
    echo "OK: laboratorio apagado por completo (incluido DV0)."
  else
    echo
    echo "OK: cluster apagado. DV0 sigue encendido (VPN/nginx)."
    echo "Para arrancar de nuevo: ./scripts/D-lab_start.sh"
  fi
}

main "$@"
