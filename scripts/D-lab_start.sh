#!/bin/bash
# Arranque controlado del cluster D-Lab.
#
# Requiere encender FÍSICAMENTE los hosts D1 y D2 (y DV0 si INCLUDE_DV0=1)
# antes de lanzarlo; el script espera a que respondan por SSH y ejecuta la
# secuencia de arranque. Se ejecuta en LOCAL y actúa en remoto por SSH.
#
# Orden de encendido: SSH del host → WireGuard activo (los proxies LXC escuchan
# en la IP WG del host, p. ej. 10.8.0.11:6443) → daemon LXD → contenedores →
# etcd/API Server → nodos Ready → almacenamiento → workloads.
#
# Uso:
#   ./scripts/D-lab_start.sh
#
# Variables de entorno (valor por defecto entre paréntesis):
#   KUBECTL_HOST  (server)   host con kubectl configurado contra el cluster
#   D1_HOST       (D1)       alias SSH del host D1 (192.168.1.11)
#   D2_HOST       (D2)       alias SSH del host D2 (192.168.1.12)
#   INCLUDE_DV0   (0)        1 = DV0 también forma parte del arranque
#   DV0_HOST      (DV0)      alias SSH de DV0 (solo con INCLUDE_DV0=1)
#   START_TIMEOUT (600)      segundos de espera para SSH / API / nodos

set -euo pipefail

BASE="$(cd "$(dirname "$0")/.." && pwd)"

KUBECTL_HOST="${KUBECTL_HOST:-server}"
D1_HOST="${D1_HOST:-D1}"
D2_HOST="${D2_HOST:-D2}"
DV0_HOST="${DV0_HOST:-DV0}"
INCLUDE_DV0="${INCLUDE_DV0:-0}"
START_TIMEOUT="${START_TIMEOUT:-600}"

SSH="ssh -o ConnectTimeout=10"

log()  { echo "» $*"; }
ok()   { echo "   ✓ $*"; }
warn() { echo "   ! $*"; }

wait_ssh() {
  local host=$1 desc=$2
  log "Esperando a que $desc ($host) responda SSH (hasta $START_TIMEOUT s)..."
  local elapsed=0
  while (( elapsed < START_TIMEOUT )); do
    if $SSH "$host" true >/dev/null 2>&1; then
      ok "$desc ($host) operativo"
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  echo "ERROR: $desc ($host) no responde tras $START_TIMEOUT s." >&2
  echo "       Asegúrese de que el host está físicamente encendido." >&2
  exit 1
}

check_sudo_nopasswd() {
  local host=$1
  if ! $SSH "$host" "sudo -n true" >/dev/null 2>&1; then
    echo "ERROR: 'sudo -n true' falla en '$host' (se requiere sudo sin contraseña)." >&2
    echo "       El arranque usa 'sudo systemctl start' para el daemon LXD." >&2
    echo "       Configure NOPASSWD (ver nota en 04-Operaciones.md)." >&2
    exit 1
  fi
  ok "$host: sudo sin contraseña OK"
}

wait_wireguard() {
  local host=$1 desc=$2
  log "Esperando wg-quick@wg0 activo en $desc ($host) — los proxies LXC escuchan en la IP WG del host..."
  local elapsed=0
  while (( elapsed < 120 )); do
    if $SSH "$host" "systemctl is-active wg-quick@wg0" >/dev/null 2>&1; then
      ok "$desc ($host): wg-quick@wg0 active"
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  echo "       wg-quick@wg0 no está activo en $desc ($host) tras 120 s." >&2
  echo "       Sin WG no se expone el cluster vía DV0 (proxies LXC sobre la IP WG del host)." >&2
  echo "       Revise 01-Network.md (split-tunnel) y el estado de WireGuard en el host." >&2
  return 1
}

wait_lxd_cluster() {
  log "Esperando a que ambos miembros del cluster LXD estén ONLINE..."
  local elapsed=0
  while (( elapsed < 120 )); do
    local out online
    out=$($SSH "$D1_HOST" "lxc cluster list -f csv" 2>/dev/null || true)
    online=$(printf '%s\n' "$out" | grep -c ONLINE || true)
    if [[ "${online:-0}" -ge 2 ]]; then
      ok "Cluster LXD con $online miembros ONLINE:"
      printf '%s\n' "$out" | awk -F, 'NR>1 {print "        " $1 "  " $NF}'
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  warn "El cluster LXD no muestra 2 miembros ONLINE; continúo (pueden tardar en volver)"
}

start_container() {
  local host=$1 name=$2
  local state
  state=$($SSH "$host" "lxc list $name -f csv -c s" 2>/dev/null | tr -d '[:space:]' || true)
  if [[ "$state" == "RUNNING" ]]; then
    ok "$name ($host): ya RUNNING"
    return 0
  fi
  log "Arrancando $name ($host)..."
  $SSH "$host" "lxc start $name"
  ok "$name ($host) arrancado"
}

wait_api_ready() {
  log "Esperando API Server (implica quorum de etcd en ambos masters)..."
  local elapsed=0
  while (( elapsed < START_TIMEOUT )); do
    local okv
    okv=$($SSH "$KUBECTL_HOST" "kubectl get --raw=/readyz" 2>/dev/null || true)
    if [[ "$okv" == "ok" ]]; then
      ok "API Server ready"
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  echo "ERROR: el API Server no responde tras $START_TIMEOUT s." >&2
  echo "       Compruebe etcd en ambos masters (ver 04-Operaciones.md y dr-restore.md)." >&2
  exit 1
}

wait_nodes_ready() {
  log "Esperando a que los nodos queden Ready..."
  local elapsed=0
  local out=""
  while (( elapsed < START_TIMEOUT )); do
    local bad
    out=$($SSH "$KUBECTL_HOST" "kubectl get nodes" 2>/dev/null || true)
    bad=$(printf '%s\n' "$out" | tail -n +2 | grep -E 'NotReady|Unknown' || true)
    if [[ -z "$bad" ]] && [[ -n "$out" ]]; then
      ok "Nodos Ready:"
      printf '%s\n' "$out"
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  echo "ERROR: hay nodos que no quedan Ready tras $START_TIMEOUT s." >&2
  printf '%s\n' "$out"
  echo "       Si el problema es kubelet, aplicar el troubleshooting de K8s en LXC de README-TECH.md." >&2
  exit 1
}

wait_service_active() {
  local host=$1 ctr=$2 svc=$3 timeout=$4
  local elapsed=0 s=""
  while (( elapsed < timeout )); do
    s=$($SSH "$host" "lxc exec $ctr -- systemctl is-active $svc" 2>/dev/null || true)
    if [[ "$s" == "active" ]]; then
      printf '%s' "$s"
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  printf '%s' "${s:-inactivo}"
  return 1
}

verify_storage() {
  log "Verificación de almacenamiento (GlusterFS / NFS-Ganesha / Keepalived)"
  local host ctr svc s
  for pair in "$D1_HOST k8s-worker-1" "$D2_HOST k8s-worker-2"; do
    set -- $pair
    host=$1; ctr=$2
    for svc in glusterd nfs-ganesha keepalived; do
      if s=$(wait_service_active "$host" "$ctr" "$svc" 30); then
        ok "$ctr/$svc: active"
        continue
      fi
      if [[ "$svc" == "nfs-ganesha" ]]; then
        warn "$ctr/nfs-ganesha: ${s}; reiniciando (race conocido con glusterd)..."
        $SSH "$host" "lxc exec $ctr -- systemctl restart nfs-ganesha" || true
        if s=$(wait_service_active "$host" "$ctr" nfs-ganesha 30); then
          ok "$ctr/nfs-ganesha: active (tras reinicio)"
        else
          warn "$ctr/nfs-ganesha: sigue sin active (${s})"
        fi
      else
        warn "$ctr/$svc: ${s}"
      fi
    done
  done
  log "Volumen GlusterFS (desde k8s-worker-1):"
  $SSH "$D1_HOST" "lxc exec k8s-worker-1 -- gluster volume status vol-storage" 2>/dev/null \
    | sed 's/^/        /' \
    || warn "no se pudo leer el estado del volumen (¿glusterd aún inicializándose?)"
  log "VIP 192.168.1.30:"
  if $SSH "$D1_HOST" "lxc exec k8s-worker-1 -- ip -4 addr show eth0" 2>/dev/null | grep -q "192.168.1.30"; then
    ok "VIP en k8s-worker-1 (MASTER)"
  else
    warn "VIP NO está en k8s-worker-1; compruebe keepalived"
  fi
  if $SSH "$D2_HOST" "lxc exec k8s-worker-2 -- ip -4 addr show eth0" 2>/dev/null | grep -q "192.168.1.30"; then
    warn "VIP también en k8s-worker-2 (no esperado; comprobar keepalived)"
  else
    ok "VIP no está en k8s-worker-2 (correcto: BACKUP)"
  fi
}

wait_workloads() {
  local failed=()
  log "Esperando workloads críticos (rollout status)..."
  if ! $SSH "$KUBECTL_HOST" "kubectl -n default rollout status deployment/landing --timeout=180s"; then
    failed+=("default/landing")
  fi
  if ! $SSH "$KUBECTL_HOST" "kubectl -n pods rollout status deployment/nodered --timeout=180s"; then
    failed+=("pods/nodered")
  fi
  if ! $SSH "$KUBECTL_HOST" "kubectl -n pods rollout status deployment/mariadb --timeout=180s"; then
    failed+=("pods/mariadb")
  fi
  if ! $SSH "$KUBECTL_HOST" "kubectl -n monitoring rollout status deployment/kube-prometheus-stack-grafana --timeout=180s"; then
    failed+=("monitoring/kube-prometheus-stack-grafana")
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "ERROR: los siguientes deployments no completaron el rollout:" >&2
    printf '       - %s\n' "${failed[@]}" >&2
    exit 1
  fi
  log "Resumen de pods:"
  $SSH "$KUBECTL_HOST" "kubectl get pods -A -o wide"
}

http_check() {
  local url=$1
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || true)
  echo "        $url → ${code:-sin respuesta}"
}

check_public() {
  log "Verificación de exposición pública (vía DV0):"
  http_check "https://elarreglador.eu"
  http_check "https://www.elarreglador.eu"
  http_check "https://grafana.elarreglador.eu"
  http_check "https://nodered.elarreglador.eu"
}

main() {
  echo
  echo "════════ Arranque controlado del cluster D-Lab ════════"
  echo "Asegúrese de que los hosts están físicamente encendidos:"
  echo "  - D1 (192.168.1.11)"
  echo "  - D2 (192.168.1.12)"
  if [[ "$INCLUDE_DV0" == "1" ]]; then echo "  - DV0 (VM IONOS)"; fi
  echo
  wait_ssh "$D1_HOST" "D1"
  wait_ssh "$D2_HOST" "D2"
  if [[ "$INCLUDE_DV0" == "1" ]]; then
    wait_ssh "$DV0_HOST" "DV0"
  fi
  echo
  log "Esperando WireGuard en los hosts (los proxies LXC hacia el cluster escuchan en su IP WG):"
  wait_wireguard "$D1_HOST" "D1"
  wait_wireguard "$D2_HOST" "D2" || warn "D2 sin wg-quick@wg0 activo; se continúa (D1 expone el API Server)"
  echo
  log "Comprobando sudo sin contraseña en los hosts..."
  check_sudo_nopasswd "$D1_HOST"
  check_sudo_nopasswd "$D2_HOST"
  echo
  log "Asegurando daemon LXD en ambos hosts..."
  $SSH "$D1_HOST" "sudo systemctl start snap.lxd.daemon.unix.socket snap.lxd.daemon.service"
  $SSH "$D2_HOST" "sudo systemctl start snap.lxd.daemon.unix.socket snap.lxd.daemon.service"
  wait_lxd_cluster
  echo
  log "Arrancando contenedores (los workers son pasivos hasta que el control-plane esté listo):"
  start_container "$D1_HOST" k8s-master-1
  start_container "$D2_HOST" k8s-master-2
  start_container "$D1_HOST" k8s-worker-1
  start_container "$D2_HOST" k8s-worker-2
  echo
  wait_api_ready
  wait_nodes_ready
  echo
  verify_storage
  echo
  wait_workloads
  echo
  check_public
  echo
  log "WireGuard en los hosts (split-tunnel):"
  $SSH "$D1_HOST" "systemctl is-active wg-quick@wg0" 2>/dev/null | sed 's/^/        D1: /' || true
  $SSH "$D2_HOST" "systemctl is-active wg-quick@wg0" 2>/dev/null | sed 's/^/        D2: /' || true
  echo
  echo "OK: arranque completado."
  echo "Recuerde: en Grafana seguirán 'firing' las alertas por diseño (TargetDown, etcdMembersDown, Watchdog)."
  echo "Tras un arranque correcto, actualice la fecha '(verificado YYYY-MM-DD)' en 04-Operaciones.md."
}

main "$@"
