# 03-Aplicaciones — Aplicaciones del cluster: pods y configuración

**Objetivo**: documentar las aplicaciones desplegadas en el cluster Kubernetes de D-Lab: sus pods (workloads, imágenes, réplicas, recursos), su configuración específica y cómo se aplican los cambios. **Este documento es público (GitHub): no incluye credenciales ni secretos.** Las credenciales viven en `info_sensible/` (gitignored) y en `values-monitoring.yaml` dentro de k8s-master-1 (`/root/`), nunca en este repo.

**Contexto**: ver [README.md](./README.md#fase-12--monitoreo-y-observabilidad) para el procedimiento de instalación. Manifiestos del repo en `files/`.

---

## Stack de monitorización: kube-prometheus-stack

- **Helm release**: `kube-prometheus-stack` (chart v88.0.1), namespace `monitoring`.
- **Prometheus operator**: v0.93.0.
- **Values**: `/root/values-monitoring.yaml` en k8s-master-1 (no versionado; contiene el `adminPassword` de Grafana). Backup previo: `/root/values-monitoring.yaml.bak-*`.
- **Actualizar config**: editar el fichero (o local + `lxc file push - k8s-master-1/root/values-monitoring.yaml`) y ejecutar en k8s-master-1:
  ```bash
  helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
    --namespace monitoring --values /root/values-monitoring.yaml --wait --timeout 300s
  ```

### Resumen de workloads

| App | Workload | Réplicas | Imagen | Servicio (ClusterIP) | Puertos |
|-----|----------|----------|--------|-----------------------|---------|
| Grafana | Deployment `kube-prometheus-stack-grafana` | 1 | grafana/grafana:13.1.1 + 2× kiwigrid/k8s-sidecar:2.10.0 (dashboards y datasources) | `kube-prometheus-stack-grafana` | 80 |
| Prometheus | StatefulSet `prometheus-kube-prometheus-stack-prometheus` | 1 | quay.io/prometheus/prometheus:v3.13.2 + prometheus-config-reloader v0.93.0 | `kube-prometheus-stack-prometheus` (9090/8080) | 9090 |
| AlertManager | StatefulSet `alertmanager-kube-prometheus-stack-alertmanager` | 1 | quay.io/prometheus/alertmanager:v0.33.1 + config-reloader | `kube-prometheus-stack-alertmanager` (9093/8080) | 9093 |
| kube-state-metrics | Deployment `kube-prometheus-stack-kube-state-metrics` | 1 | registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.1 | `kube-prometheus-stack-kube-state-metrics` | 8080 |
| Prometheus operator | Deployment `kube-prometheus-stack-operator` | 1 | quay.io/prometheus-operator/prometheus-operator:v0.93.0 | `kube-prometheus-stack-operator` | 443 |
| node-exporter | DaemonSet `kube-prometheus-stack-prometheus-node-exporter` | 1 por nodo (4) | quay.io/prometheus/node-exporter:v1.12.1 | `kube-prometheus-stack-prometheus-node-exporter` | 9100 |

---

## Grafana

- **URL pública**: `https://grafana.elarreglador.eu` (Ingress `grafana` en `monitoring`).
- **Acceso**: solo login propio de Grafana (`admin` / `adminPassword` en `values-monitoring.yaml`). **Sin** basic-auth web ni anonymous. La página de login es pública.
- **Ingress** (`files/monitoring/grafana-ingress.yaml`): TLS con cert-manager (secret `grafana-elarreglador-eu-tls`), `force-ssl-redirect: true`, sin anotaciones de auth.
- **grafana.ini** (vía `grafana.grafana.ini` en los values):
  - `server.root_url = https://grafana.elarreglador.eu/` + `server.domain = grafana.elarreglador.eu` — **obligatorio** detrás del proxy TLS; sin ellos el frontend recibe `appUrl=http://localhost:3000/` y la sesión se pierde al navegar (login en cada página).
  - `security.cookie_secure = true` + `security.cookie_samesite = lax` — cookie de sesión solo por HTTPS.
- **Almacenamiento**: efímero (`persistence.enabled: false`). Tras reiniciar el pod se pierden cambios de UI no provisionados.
- **Recursos**: requests 100m/200Mi, limits 500m/512Mi.
- **Ojo Grafana 13**: el endpoint `POST /login` espera **JSON** (`Content-Type: application/json`, cuerpo `{"user":"...","password":"..."}`), no form-urlencoded. Afecta a la automatización con curl, no al navegador.

## Prometheus

- **Retention**: 6 días (`prometheusSpec.retention`).
- **Almacenamiento TSDB**: efímero (`emptyDir`). No soporta reinicio de nodo: los datos históricos se pierden (decisión por la incidencia con el PVC NFS).
- **Recursos**: requests 500m/600Mi, limits 1 CPU/2Gi.
- **Servicios**: `kube-prometheus-stack-prometheus` (9090) y `prometheus-operated` (headless). **Sin ingress** → no expuesto públicamente; acceso interno vía port-forward.

## AlertManager

- **Servicios**: `kube-prometheus-stack-alertmanager` (9093/8080) y `alertmanager-operated` (headless). **Sin ingress**.
- **Recursos**: requests 100m/100Mi, limits 200m/256Mi.
- **Almacenamiento DB**: `emptyDir` en el StatefulSet actual, pese a que los values declaran `persistentVolume.enabled: true` (storageClass `nfs-storage`, 2Gi). Motivo: los `volumeClaimTemplates` de un StatefulSet son **inmutables**; el sts se creó sin PVC durante la incidencia NFS y un `helm upgrade` no lo añade. Para migrar a PVC habría que recrear el StatefulSet.

## Observabilidad auxiliar

- **node-exporter de hosts (D1/D2)**: Service headless `host-node` (9100/19100) + Endpoints manuales + ServiceMonitor `host-node`. D2 se scrapea directo (`:9100`); D1 vía relay socat en D2 (`TCP4-LISTEN:19100 → TCP4:192.168.1.11:9100`, servicio systemd `node-exporter-relay-d1`). Los containers LXD usan macvlan y no alcanzan a su propio host.
- **ServiceMonitor cert-manager**: Service `cert-manager:9402` en namespace `cert-manager`.
- **PrometheusRule `alertas-personalizadas`** (grupo `host-alertas`): `HostDown`, `ClusterNodeNotReady`, `DiskPressureHost` (>85%), `CertificateExpiring` (<30 días).

## Exposición pública

| Host | App | Protección |
|------|-----|-----------|
| `elarreglador.eu` / `www.elarreglador.eu` | Landing (pública) | ninguna (200 sin credenciales) |
| `grafana.elarreglador.eu` | Grafana | login de Grafana |
| prometheus / alertmanager | — | internos (sin ingress) |

## PDBs y NetworkPolicies

- **PDBs** (manifiestos en `files/pdbs/`): `landing`, `coredns`, `ingress-nginx`, `calico-kube-controllers`, `calico-typha`, `grafana`, `prometheus`, `alertmanager`.
- **NetworkPolicies** (manifiestos en `files/networkpolicies/`): `landing-allow-ingress-nginx` (default, app=landing) y `coredns-allow-dns` (kube-system). El resto del tráfico se rige por el modelo policy-only de Calico.

## Notas operativas

- **Alertas firing por diseño**: `TargetDown`, `etcdMembersDown`, `etcdInsufficientMembers` (targets `kube-etcd`/`kube-scheduler`/`kube-controller-manager`/`kube-proxy` no exponen métricas en los puertos por defecto en LXC) y `Watchdog` (centinela). La cadena principal (kubelet, apiserver, coredns, node-exporter, hosts) está **up**.
- **Credenciales**: nunca en el repo. Grafana admin → `values-monitoring.yaml` en k8s-master-1. Clave web / secretos → `info_sensible/` (gitignored).
- **Scripts útiles** (`scripts/`): `deploy-landing.sh` (despliegue de la landing), `sync-web-auth.sh` (clave web; hoy **sin namespaces por defecto** — Grafana usa su propio login), `computer_info.sh`.

## Referencias

- [README.md — Fase 12: Monitoreo y observabilidad](./README.md#fase-12--monitoreo-y-observabilidad)
- [README.md — Clave única de acceso web](./README.md#clave-única-de-acceso-web)
- [README.md — Web pública (landing)](./README.md#web-pública-landing)
- Manifiestos: `files/monitoring/grafana-ingress.yaml`, `files/pdbs/`, `files/networkpolicies/`, `files/landing/`
