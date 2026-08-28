# Informe de Incidente: Grafana sin datos en k8s-master-2/k8s-worker-2 y mapeo IP inconsistente

**Fecha:** 2026-08-28
**Equipos Afectados:** k8s-master-2 (192.168.1.22), k8s-worker-2 (192.168.1.32), k8s-worker-1 (192.168.1.31), Grafana/Prometheus (monitoring)
**Estado:** RESUELTO
**Severidad:** Media (monitorización degradada, sin pérdida de datos)

## Descripción

Tras un ciclo de apagado/encendido controlado (`04-Operaciones.md`), Grafana (dashboard `Sistema D-Lab`) mostraba **sin datos** en los paneles `D2 · k8s-master-2` y `D2 · k8s-worker-2`, mientras `D1 · k8s-master-1` y `D1 · k8s-worker-1` sí tenían valores. Los nodos figuraban `Ready` y los `node-exporter` `Running`, por lo que el síntoma apuntaba a capa de monitorización, no a kubelet.

## Causa Raíz

`kubelet` sin `--node-ip` (`/etc/default/kubelet` vacío; `10-kubeadm.conf` lee `KUBELET_EXTRA_ARGS`). Tras el arranque, `kubelet` eligió `flannel.1` (`10.244.x.0/32`) como `InternalIP` del Node (verificado: los 4 nodos reportaban `10.244.0.0/.3.0/.2.0/.1.0` en `kubectl get nodes -o wide`, cuando `eth0` tenía `192.168.1.21/.22/.31/.32` + VIP `.30`).

El DaemonSet `kube-prometheus-stack-prometheus-node-exporter` (`hostNetwork: true`, `HOST_IP=0.0.0.0`) publica `podIP` = IP del host en el momento de inicio. En D2 publicó `10.244.3.0:9100` y `10.244.1.0:9100`; en `k8s-worker-1` publicó la VIP secundaria `192.168.1.30:9100` en vez de `192.168.1.31:9100`. Prometheus scrapeaba `health=up` bajo esas `instance`, pero el dashboard `files/monitoring/grafana-dashboard-sistema-dlab.yaml:166,220,326,378` filtra por `instance="192.168.1.22:9100"` / `"192.168.1.32:9100"` (y `.31` para worker-1), resultando en 0 series (`api/v1/query` con `192.168.1.22:9100` → `success []`).

Mapeo esperado (penúltimo = rol `2` master / `3` worker, último = máquina `1` D1 / `2` D2): `.21` master-1, `.22` master-2, `.31` worker-1, `.32` worker-2. No se cumplía.

## Solución Implementada

1. **Fijar `InternalIP` determinista** — en los 4 LXC crear `/etc/default/kubelet`:
   * `k8s-master-1`: `KUBELET_EXTRA_ARGS=--node-ip=192.168.1.21`
   * `k8s-master-2`: `KUBELET_EXTRA_ARGS=--node-ip=192.168.1.22`
   * `k8s-worker-1`: `KUBELET_EXTRA_ARGS=--node-ip=192.168.1.31`
   * `k8s-worker-2`: `KUBELET_EXTRA_ARGS=--node-ip=192.168.1.32`
   Reinicio escalonado `systemctl restart kubelet` (workers → master-2 → master-1, para preservar quorum etcd 2/2).

2. **Corregir dashboard** — `files/monitoring/grafana-dashboard-sistema-dlab.yaml:220,228` `192.168.1.30:9100` → `192.168.1.31:9100` en panel `D1 · k8s-worker-1` y `kubectl apply -f` (ConfigMap `grafana_dashboard: "1"`).

3. **Re-publicar métricas** — `kubectl rollout restart ds/kube-prometheus-stack-prometheus-node-exporter` en `monitoring`. Nuevos pods con `IP` `.21/.22/.31/.32` y `instance` alineada.

El fichero `/etc/default/kubelet` persiste en el filesystem LXC tras `poweroff`/`lxc start`, por lo que el mapeo es permanente.

## Verificación

* `kubectl get nodes -o wide` → 4 `Ready` con `INTERNAL-IP` `192.168.1.21/.22/.31/.32`.
* `kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus-node-exporter -o wide` → IPs `.21/.22/.31/.32`.
* `api/v1/targets` (`job="node-exporter"`) → 4 `instance` `192.168.1.x:9100` `health=up`; `api/v1/query?query=node_memory_MemTotal_bytes{instance="192.168.1.22:9100"}` → 1 serie 7.6 GiB (antes 0).
* Grafana `Sistema D-Lab` → 7 paneles con CPU%/RAM% (incluidos `D2 · k8s-master-2` y `D2 · k8s-worker-2`); `https://grafana.elarreglador.eu` `302` → login.
* VIP `192.168.1.30/24` permanece `secondary` en `eth0` de `k8s-worker-1` (MASTER Keepalived), sin contaminar `instance`.

## Lecciones Aprendidas

1. `hostNetwork:true` + `flannel` + VIP secundaria Keepalived inducen deriva de `podIP`/`instance` si no se fija `--node-ip`.
2. Filtrar por `instance` es frágil; `nodename` sería inmune a IP, pero el mapeo `.21/.22/.31/.32` es ahora contrato explícito y determinista.
3. El `InternalIP` debe auditarse en el checklist post-arranque (`kubectl get nodes -o custom-columns`).

## Recomendaciones

1. En el checklist de creación de contenedores LXC, fijar `--node-ip` en `/etc/default/kubelet`.
2. Tras cada `D-lab_start.sh`, verificar `InternalIP` y `api/v1/targets` como parte de `04-Operaciones.md` Verificación post-arranque.
3. Mantener dashboard con `instance` alineada al mapeo permanente; evaluar migración futura a `nodename` si se introduce otro nodo.

## Referencias

* `04-Operaciones.md` — Apagado y arranque controlado
* `03-Aplicaciones.md` — Stack de monitorización
* `files/monitoring/grafana-dashboard-sistema-dlab.yaml`
* `files/monitoring/host-node.yaml`, `files/monitoring/dv0-host.yaml`
* `README-TECH.md` — Troubleshooting de K8s en LXC
