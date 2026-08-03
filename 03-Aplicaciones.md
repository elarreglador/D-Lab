# 03-Aplicaciones — Aplicaciones del cluster: pods y configuración

**Objetivo**: documentar las aplicaciones desplegadas en el cluster Kubernetes de D-Lab: sus pods (workloads, imágenes, réplicas, recursos), su configuración específica y cómo se aplican los cambios. **Este documento es público (GitHub): no incluye credenciales ni secretos.** Las credenciales viven en `info_sensible/` (gitignored) y en `values-monitoring.yaml` dentro de k8s-master-1 (`/root/`), nunca en este repo.

**Contexto**: ver [README-TECH.md](./README-TECH.md#fase-12--monitoreo-y-observabilidad) para el procedimiento de instalación. Manifiestos del repo en `files/`.

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
- **Datos de los paneles**: Grafana **consulta** a Prometheus y AlertManager (no al revés: Prometheus recolecta y almacena; Grafana hace las consultas cuando pinta un panel). Datasources definidos en el ConfigMap `kube-prometheus-stack-grafana-datasource` (montado por el sidecar kiwigrid):
  - `Prometheus` (default, `access: proxy`): `http://kube-prometheus-stack-prometheus.monitoring:9090/` — cada panel lanza queries PromQL.
  - `Alertmanager`: `http://kube-prometheus-stack-alertmanager.monitoring:9093/` — para visualizar alertas en paneles.
  - Ambas son ClusterIP internas (`:9090` y `:9093`), comunicación pod↔pod por la red del cluster; **no** necesitan dominio público.

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

## Node-RED

- **URL pública**: `https://nodered.elarreglador.eu` (Ingress `nodered` en namespace `pods`).
- **Imagen**: `nodered/node-red:5.0.4` (Node.js 24), puerto 1880. Deployment 1 réplica en `pods`.
- **Login propio de Node-RED** (usuario `elarreglador`): definido en `settings.js` (`adminAuth` con hash bcrypt) montado desde el Secret `nodered-settings` (Opaque, gitignored — se genera en despliegue). **Sin** basic-auth web ni anonymous.
- **Secretos**: el hash bcrypt y el `credentialSecret` (cifrado de credenciales de nodos) se generan en el despliegue y **no** se versionan. Ver `scripts/deploy-nodered.sh`.
- **Almacenamiento**: PVC `nodered-data` (5Gi, RWO, `nfs-storage`) montado en `/data` (flows, credenciales y contextos persistentes).
- **Ingress** (`files/nodered/ingress.yaml`): TLS con cert-manager (Certificate `nodered-elarreglador-eu` → secret `nodered-elarreglador-eu-tls`), `force-ssl-redirect: true`. Certificate versionado en `files/nodered/certificate.yaml`.
- **NetworkPolicy** (`files/nodered/networkpolicy.yaml`): permite tráfico desde ingress-nginx (1880), egress DNS y salida a Internet (para instalar nodos del palette).
- **Recursos**: requests 100m/256Mi, limits 500m/512Mi.
- **Despliegue**: `NODERED_PASSWORD=<clave> ./scripts/deploy-nodered.sh` (la clave solo en el entorno; el hash se genera con python3-bcrypt sin escribirla en disco).

## MariaDB

- **Acceso**: solo interno al cluster. Sin URL pública ni Ingress: se gestiona por terminal vía `kubectl exec` / `kubectl run` desde el namespace `pods`.
- **Workload**: Deployment `mariadb` (1 réplica, imagen `mariadb:11`, namespace `pods`), Service ClusterIP `mariadb:3306`. Recursos requests 250m/256Mi, limits 1 CPU/1Gi.
- **BD**: `dlab` (usuario `dlab`, password en el Secret `mariadb-secret`, Opaque, gitignored — se genera en despliegue; la password solo viaja en el entorno de `deploy-mariadb.sh`). BD y usuario dedicados para **Node-RED**: `nodered`/`nodered` (password en `info_sensible/nodered-mariadb.env`, gitignored; acceso solo a su propia BD). Args: `--innodb-buffer-pool-size=256M`, `--innodb-flush-log-at-trx-commit=2` (durabilidad reducida: acepta el fsync lento del NFS, riesgo de perder los últimos ~1 s de transacciones en corte de energía).
- **Almacenamiento**: PVC `mariadb-data` (10Gi, RWO) sobre el **StorageClass `nfs-storage-v4`** (NFSv4), montado en `/var/lib/mysql` con `fsGroup: 999`. El RWO permite que el pod migre de worker manteniendo los datos (verificado: k8s-worker-1 → k8s-worker-2).
- **NetworkPolicy** (`files/mariadb/networkpolicy.yaml`): `mariadb-allow-pods` — ingress solo TCP/3306 desde pods del namespace `pods`; egress solo DNS (CoreDNS + ClusterIP). **Sin acceso exterior**.
- **Backups** (`files/backup-mariadb.sh`): dump `mariadb-dump --all-databases` vía `kubectl exec` sobre el pod (sin depender de la red del pod) + copia redundante al peer master por SSH. Desplegado en k8s-master-1 y k8s-master-2, cron `0 3 * * *` → `/backup/mariadb/mariadb-<fecha>.sql`, rotación de 30, log `/var/log/mariadb-backup.log`. La password se lee del Secret en runtime, nunca se versiona.
- **Despliegue**: `MARIADB_ROOT_PASSWORD=<clave> MARIADB_PASSWORD=<clave> ./scripts/deploy-mariadb.sh` (las claves solo en el entorno; el Secret se genera por stdin).

## Exposición pública

| Host | App | Protección |
|------|-----|-----------|
| `elarreglador.eu` / `www.elarreglador.eu` | Landing (pública) | ninguna (200 sin credenciales) |
| `grafana.elarreglador.eu` | Grafana | login de Grafana |
| `nodered.elarreglador.eu` | Node-RED | login propio de Node-RED |
| prometheus / alertmanager / **mariadb** | — | internos (sin ingress) |

## PDBs y NetworkPolicies

- **PDBs** (manifiestos en `files/pdbs/`): `landing`, `coredns`, `ingress-nginx`, `calico-kube-controllers`, `calico-typha`, `grafana`, `prometheus`, `alertmanager`.
- **NetworkPolicies** (manifiestos en `files/networkpolicies/`): `landing-allow-ingress-nginx` (default, app=landing) y `coredns-allow-dns` (kube-system). El resto del tráfico se rige por el modelo policy-only de Calico.

## Notas operativas

- **Alertas firing por diseño**: `TargetDown`, `etcdMembersDown`, `etcdInsufficientMembers` (targets `kube-etcd`/`kube-scheduler`/`kube-controller-manager`/`kube-proxy` no exponen métricas en los puertos por defecto en LXC) y `Watchdog` (centinela). La cadena principal (kubelet, apiserver, coredns, node-exporter, hosts) está **up**.
- **Credenciales**: nunca en el repo. Grafana admin → `values-monitoring.yaml` en k8s-master-1. Clave web / secretos → `info_sensible/` (gitignored).
- **CNI Calico — tokens de `calico-kubeconfig`**: el token del SA `calico-cni-plugin` usado por el plugin CNI en los 4 nodos (`/etc/cni/net.d/calico-kubeconfig`) **expira** (el emitido por kubeadm el 2026-08-01 caducó a las 24 h y todos los pods nuevos fallaban con `error getting ClusterInformation: ... Unauthorized`). Se fijó creando el Secret `calico-cni-plugin-token` (kube-system, anotación `kubernetes.io/service-account.name`) — sin expiración — y reescribiendo el `token:` de ese kubeconfig en los 4 nodos. Si vuelve a aparecer `FailedCreatePodSandBox` por Calico en pods nuevos, revisar la fecha de expiración de ese token.
- **Scripts útiles** (`scripts/`): `deploy-landing.sh` (despliegue de la landing), `deploy-nodered.sh` (despliegue de Node-RED; requiere `NODERED_PASSWORD` en el entorno), `deploy-mariadb.sh` (despliegue de MariaDB; requiere `MARIADB_ROOT_PASSWORD` y `MARIADB_PASSWORD` en el entorno), `sync-web-auth.sh` (clave web; hoy **sin namespaces por defecto** — Grafana y Node-RED usan su propio login), `computer_info.sh`.

## Referencias

- [README-TECH.md — Fase 12: Monitoreo y observabilidad](./README-TECH.md#fase-12--monitoreo-y-observabilidad)
- [README-TECH.md — Clave única de acceso web](./README-TECH.md#clave-única-de-acceso-web)
- [README-TECH.md — Web pública (landing)](./README-TECH.md#web-pública-landing)
- Manifiestos: `files/monitoring/grafana-ingress.yaml`, `files/nodered/`, `files/mariadb/`, `files/pdbs/`, `files/networkpolicies/`, `files/landing/`
