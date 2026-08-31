# 03-Aplicaciones — Aplicaciones del cluster: pods y configuración

**Objetivo**: documentar las aplicaciones desplegadas en el cluster Kubernetes de D-Lab: sus pods (workloads, imágenes, réplicas, recursos), su configuración específica y cómo se aplican los cambios. **Este documento es público (GitHub): no incluye credenciales ni secretos.** Las credenciales viven en `info_sensible/` (gitignored) o se pasan por variable de entorno a los scripts, nunca en este repo.

**Contexto**: ver [README-TECH.md](./README-TECH.md#fase-12--monitoreo-y-observabilidad) para el procedimiento de instalación. Manifiestos del repo en `files/`.

---

## Stack multimedia simplificado (Jellyfin + qBittorrent + aMule)

Descarga manual por dos vías — **qBittorrent (torrent)** y **aMule (eDonkey/KAD)** — → servidor de medios **Jellyfin**. Namespace `multimedia`. **Simplificado el 2026-08-29**: retirados Jellyseerr, Sonarr, Radarr, Prowlarr, FlareSolverr y es-badge; se mantiene Jellyfin y qBittorrent, se añade aMule. **No existe cadena automática *arr**: no hay indexadores, ni Prowlarr/FlareSolverr, ni Sonarr/Radarr, ni Jellyseerr. Motivo: complejidad excesiva de la automatización para el uso real. Manifiestos retirados conservados en `files/multimedia/_retirado/` y `scripts/_retirado/` (ver git log).

### Resumen de workloads

| App | Workload | Imagen | Servicio | Puerto | IP LAN | Nodo (selector) |
|-----|----------|--------|----------|--------|--------|---------------------|
| Jellyfin | Deployment (1) | lscr.io/linuxserver/jellyfin | `jellyfin` | 8096 | `192.168.1.53` | worker (`eu.elarreglador/worker=true`) |
| qBittorrent | Deployment (1) | lscr.io/linuxserver/qbittorrent | `qbittorrent` | 8080 | `192.168.1.58` | worker (`eu.elarreglador/worker=true`) |
| qBittorrent (torrent) | idem | — | `qbittorrent-torrent` | 6881 T/U | `192.168.1.59` | idem |
| aMule | Deployment (1) | ngosang/amule | `amule` | 4711 | `192.168.1.54` | worker (`eu.elarreglador/worker=true`) |
| aMule (P2P) | idem | — | `amule-p2p` | 4662/T 4672/U 4665/U | `192.168.1.55` | idem |

### Almacenamiento

- **`media-data`**: PVC 400Gi RWX sobre `nfs-storage-v4` (GlusterFS/NFS-Ganesha, VIP `192.168.1.30`), montado en `/data`. Subárboles: `/data/media/{tv,movies}` (biblioteca Jellyfin), `/data/torrents/{tv,movies}` (qBittorrent) y `/data/amule/{incoming,temp}` (aMule). Owner `1000:1000` (`abc`).
- **Configs**: 3 PVC NFS `*-config` sobre `nfs-storage-v4` (1 por app, 2Gi): `qbittorrent-config` → `/config`, `jellyfin-config` → `/config`, `amule-config` → `/home/amule/.aMule`. Todos móviles entre workers (`eu.elarreglador/worker=true`). Los PV/PVC `local-static` y `*-config-local` de Sonarr/Radarr/Prowlarr/Jellyseerr se eliminaron el 2026-08-29 (ver git log `files/multimedia/_retirado/`). Historial del gotcha SQLite sobre NFS (fsync ~66 ms en Gluster-HDD) queda en `files/multimedia/_retirado/` y en el git log.
- **Permisos de `/data`** (`verificado 2026-08-15`): los archivos vía NFS quedan con uid `4294967294` (squash) pero `chown 1000:1000` persiste (`abc:users`). El job `init-media-dirs` (`files/multimedia/init-media-dirs.yaml`) hace `mkdir -p /data/torrents/{movies,tv} /data/media/{movies,tv} /data/amule/{incoming,temp}` + `chown -R 1000:1000` + `chmod 775/664`; reaplicar si se pierden permisos.

### Uso (manual, sin wizard)

Solo dos formas de descarga, ambas manuales y sin automatización *arr:

- **qBittorrent (torrent)**: WebUI `https://torrent.elarreglador.eu` (o LAN `192.168.1.58:8080`) con login propio (usuario `elarreglador`). Subida de `.torrent`/magnet → `save_path` en `/data/torrents`. No hay wizard `*arr`; mover manualmente el contenido completado a `/data/media/{movies,tv}` y escanear en Jellyfin (`Library → Scan` o `POST /Library/Refresh`).
- **aMule (eDonkey/KAD)**: WebUI `https://amule.elarreglador.eu` (o LAN `192.168.1.54:4711`) con login (`amule-secret` → `WEBUI_PWD`/`EC_PASSWORD` vía `AMULE_WEB_PWD`/`AMULE_EC_PWD` en `deploy-multimedia.sh`). Configurar `IncomingDir=/data/amule/incoming` y `TempDir=/data/amule/temp` en `amule.conf` (o vía WebUI → Preferences). Tras completar, mover a `/data/media`.
- **Jellyfin**: `https://jellyfin.elarreglador.eu` (LAN `192.168.1.53:8096`), usuario `elarreglador` (admin), librerías `Movies` → `/data/media/movies` y `TV Shows` → `/data/media/tv` (verificado 2026-08-15). Solo indexa `/data/media`.
- **Retirados (2026-08-29)**: cadena automática `Jellyseerr → Sonarr/Radarr → Prowlarr → FlareSolverr + es-badge` eliminada por completo. `scripts/_retirado/multimedia-wizard.sh` (bootstrap *arr/Prowlarr/Jellyseerr), `multimedia-language.sh`/`multimedia-verify.sh` y los manifiestos `files/multimedia/_retirado/sonarr|radarr|prowlarr|flaresolverr|jellyseerr|es-badge.yaml` ya no aplican; conservados en `_retirado/` por histórico. No hay indexadores ni búsqueda automática.

### Estado y notas

- **Jellyfin**: primer usuario `elarreglador` (admin) con librerías `Movies` (id `f137a2dd...`) → `/data/media/movies` y `TV Shows` (id `767bff...`) → `/data/media/tv` (verificado 2026-08-15).
- **qBittorrent**: login WebUI `forms` user `elarreglador` (configurado en `/config/qBittorrent/qBittorrent.conf`); `save_path=/data/torrents`, `temp_path` opcional. Backup en `/config`.
- **aMule**: `amuled` + `amuleweb` (4711). Credenciales en Secret `amule-secret` (`WEBUI_PWD`/`EC_PASSWORD`) vía `AMULE_WEB_PWD`/`AMULE_EC_PWD` en `deploy-multimedia.sh` (nunca en repo). Config `amule.conf` en `/home/amule/.aMule`; `IncomingDir`/`TempDir` apuntan a `/data/amule/{incoming,temp}`. Retirados es-badge/Jellyseerr (ver `_retirado/`).
- **qBittorrent P2P expuesto**: `TCP/UDP 6881` externo via DV0 → D1 → NodePort `31681` (ver [01-Network.md](./01-Network.md)). Cadena `scripts/multimedia-expose-torrent.sh` (stream nginx en DV0 + proxies LXC `proxytorrent`/`proxytorrentudp`). TCP+UDP verificados 2026-08-16 (`nc -zv 82.223.50.169 6881` OK, DHT `find_node` 297 B, `connection_status: connected`).
- **aMule P2P expuesto**: `4662/TCP 4672/UDP 4665/UDP` externo via DV0 → D1 → NodePorts `31682-31684` (ver `scripts/amule-expose-p2p.sh`). Ingress WebUI `amule.elarreglador.eu` (4711) con login; P2P requiere `scripts/amule-expose-p2p.sh` (proxies LXC `proxyamule*` + `stream.conf.d/amule.conf`).

- **Backups**: `files/backup-multimedia.sh` (tar de `/config` o `/home/amule/.aMule`) desde `install-multimedia-backup.sh`, cron `0 2 * * *` en ambos masters → `/backup/multimedia/`. Rotación 30 por app + copia al peer. Parametriza `CFG` por app (`/config` para qB/Jellyfin, `/home/amule/.aMule` para aMule) + snapshot sqlite si hay `sqlite3` en el pod.



- **IPs propias en LAN vía MetalLB** (`verificado 2026-08-16`, **actualizado 2026-08-29**): MetalLB v0.14.9 pool `dlab-lan` `192.168.1.50–192.168.1.64`. Estado simplificado: `.50` landing, `.51` grafana, `.52` nodered, `.53` jellyfin, `.54` amule, `.55` amule-p2p, `.58` qB WebUI, `.59` qB-torrent (NodePort `31681`), `.60` rtl-sdr (NodePort `31234`). **Liberadas** `.56`/.57 (antes radarr/prowlarr) y `.54` reasignada de jellyseerr a amule; `.55` reasignada de sonarr a amule-p2p. MariaDB sigue ClusterIP.
- **Gotcha ruteo asimétrico + IPs LAN**: cada host físico **no alcanza las IP propias de sus propios LXC** (D1 no ve `.52`, `.55`, `.58`, `.59`, `.60`; D2 no ve `.50`, `.51`, `.53`, `.54`), mismo motivo en `01-Network.md`. Desde otro equipo LAN todas responden.
- **Gotcha SQLite sobre NFS (histórico 2026-08-20, ya no aplica)**: los *arr (.NET `busytimeout=100`/`synchronous=FULL`) sobre Gluster-HDD Replicate 1×2 sufrían fsync ~66 ms → crash-loop Sonarr; se revirtieron a `local-static`. Al simplificar el stack (2026-08-29) se retiraron por completo; historial en `files/multimedia/_retirado/` y git log.
- **Failover MetalLB verificado** (`verificado 2026-08-16`): `cordon k8s-worker-2; delete pod grafana` → re-sched a worker-1 manteniendo `.51` (re-ARP). Aplicable a servicios sin `nodeSelector`.
- **Movilidad + masters blindados** (`verificado 2026-08-20`, **actualizado 2026-08-29**): masters con taint `NoSchedule`. Stack simplificado 100 % móvil: Jellyfin/qBittorrent/aMule con `eu.elarreglador/worker=true` sobre PVC NFS `nfs-storage-v4`; sin `local-static` ni anclajes `hostname`. Anclado solo `rtl-sdr` (`eu.elarreglador/sdr=true`).

---

## Stack de monitorización: kube-prometheus-stack

- **Helm release**: `kube-prometheus-stack` (chart v88.0.1), namespace `monitoring`.
- **Prometheus operator**: v0.93.0.
- **Values**: el fichero `/root/values-monitoring.yaml` **ya no existe** en k8s-master-1 ni en k8s-master-2 (verificado 2026-08-18). Se usó en la instalación original para pasar el `adminPassword` de Grafana, pero hoy la password efectiva de admin es la del Secret `kube-prometheus-stack-grafana` en `monitoring` (efímero, ver abajo). El chart sigue gestionado por helm; si algún día se reinstala, habría que reconstruir el values con `grafana.grafana.ini` y `adminPassword`.
- **Actualizar config**: hoy la configuración viva vive en el ConfigMap `kube-prometheus-stack-grafana` (`grafana.ini`), el Secret `kube-prometheus-stack-grafana` (admin) y los ConfigMaps de dashboards/datasources (sidecar kiwigrid). Cambios puntuales se aplican con `kubectl`; el mecanismo completo de helm upgrade exigiría reconstruir `values-monitoring.yaml` (ya no existe, ver arriba).

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
- **Acceso**: solo login propio de Grafana. **Sin** basic-auth web ni anonymous. La página de login es pública. Usuarios (las credenciales concretas no van a este repo público):
  - `elarreglador` — uso diario, **rol Admin en la org 1 + Grafana Admin global**. Garantizado por `scripts/grafana-user.sh` (idempotente; passwords en `info_sensible/grafana-user.env`, gitignored).
  - `admin` — mantenimiento; password en el Secret `kube-prometheus-stack-grafana` (`admin-password`, base64). Al ser el storage efímero, si se pierde se resetea vía `kubectl` (patch del Secret + `rollout restart`) o con la CLI de Grafana.
- **Nota de automatización**: el endpoint `POST /api/login` de Grafana 13 espera JSON y aplica *rate limiting* por IP tras varios intentos fallidos (~10 min). En scripts es más fiable autenticar con **Basic Auth** (`curl -u user:pass .../api/user`) que con el login por form.
- **Ingress** (`files/monitoring/grafana-ingress.yaml`): TLS con cert-manager (secret `grafana-elarreglador-eu-tls`), `force-ssl-redirect: true`, sin anotaciones de auth.
- **grafana.ini** (vía `grafana.grafana.ini` en los values):
  - `server.root_url = https://grafana.elarreglador.eu/` + `server.domain = grafana.elarreglador.eu` — **obligatorio** detrás del proxy TLS; sin ellos el frontend recibe `appUrl=http://localhost:3000/` y la sesión se pierde al navegar (login en cada página).
  - `security.cookie_secure = true` + `security.cookie_samesite = lax` — cookie de sesión solo por HTTPS.
- **Almacenamiento**: efímero (`persistence.enabled: false`). Tras reiniciar el pod se pierden cambios de UI no provisionados **y los usuarios** (incluidos los **public dashboards**, ver más abajo). Para re-garantizar `elarreglador` tras una recreación: `./scripts/grafana-user.sh` (lee las credenciales de `info_sensible/grafana-user.env`).
- **Dashboard provisionado «Sistema D-Lab»** (`files/monitoring/grafana-dashboard-sistema-dlab.yaml`, ConfigMap `grafana-dashboard-sistema-dlab` en `monitoring` con label `grafana_dashboard: "1"`): 7 tarjetas stat de CPU%/RAM% en tiempo real — **DV0** (job `dv0-host`, label `host="dv0"`, ancho completo en la 1.ª fila), hosts físicos D1/D2 (job `host-node`, label `host`) y los 4 nodos K8s (job `node-exporter`, filtrados por `instance`). El sidecar kiwigrid lo importa; cambios al CM se reflejan al pulsar "Refresh" sin reiniciar.
- **Monitorización de hosts D1/D2** (fuente del job `host-node`): ServiceMonitor + Service/Endpoints versionados en `files/monitoring/host-node.yaml` (replica del objeto vivo en el cluster). D2 se scrapea directo en `192.168.1.12:9100`; D1 vía relay socat en `192.168.1.12:19100`. El relabeling añade `host="d1"`/`host="d2"`.
- **Monitorización de DV0** (`verificado 2026-08-18`): node_exporter v1.12.1 instalado en DV0 (binario en `/usr/local/bin`, unit systemd `node-exporter.service`) escuchando solo en la IP del túnel `10.8.0.1:9100` (sin firewall; no expuesto a internet). Al no estar DV0 en la LAN, se scrapea vía un segundo relay socat en D2 (`TCP4-LISTEN:19200 → TCP4:10.8.0.1:9100`, unit `node-exporter-relay-dv0`); Service + Endpoints + ServiceMonitor en `files/monitoring/dv0-host.yaml` con relabeling `host="dv0"`. D2 responde `ping 10.8.0.1` (túnel WG activo).
- **Public dashboard de la landing** (`verificado 2026-08-18`): el dashboard «Sistema D-Lab» se expone sin login para incrustarlo en la landing (sección *Monitorización en vivo*). En el grafana.ini se añadieron `security.allow_embedding = true` (sin `X-Frame-Options`) y el feature toggle `publicDashboards`. El registro del public dashboard es **efímero** (se pierde al recrear el pod): lo garantiza `scripts/ensure-public-dashboard.sh` (idempotente; guarda la URL en `info_sensible/public-dashboard.env`, gitignored). **Ojo Grafana 13**: la ruta pública usa **guion** — `https://grafana.elarreglador.eu/public-dashboards/<token>`; la variante con barra (`/public/dashboards/`) cae en el handler de assets y responde 302 a `/login`. **Gotcha ventana temporal**: el public dashboard se creó con `timeSelectionEnabled=false`, así que **ignora los `from`/`to` de la URL del iframe** y muestra el rango guardado del dashboard. Para cambiar la ventana (hoy `now-24h`), se edita `"time"` en `files/monitoring/grafana-dashboard-sistema-dlab.yaml` y se reaplica el ConfigMap (el sidecar re-provisiona; el registro público se conserva).
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
- **node-exporter de DV0**: relay socat en D2 (`TCP4-LISTEN:19200 → TCP4:10.8.0.1:9100`, servicio systemd `node-exporter-relay-dv0`) + Service/Endpoints/ServiceMonitor `dv0-host` (ver arriba).
- **ServiceMonitor cert-manager**: Service `cert-manager:9402` en namespace `cert-manager`.
- **PrometheusRule `alertas-personalizadas`** (grupo `host-alertas`): `HostDown`, `ClusterNodeNotReady`, `DiskPressureHost` (>85%), `CertificateExpiring` (<30 días).

## Node-RED

- **URL pública**: `https://nodered.elarreglador.eu` (Ingress `nodered` en namespace `pods`).
- **IP LAN** (`verificado 2026-08-16`): `192.168.1.52:1880` (LoadBalancer via MetalLB, `externalTrafficPolicy: Local`).
- **Imagen**: `nodered/node-red:5.0.4` (Node.js 24), puerto 1880. Deployment 1 réplica en `pods`.
- **Login propio de Node-RED** (usuario `elarreglador`): definido en `settings.js` (`adminAuth` con hash bcrypt) montado desde el Secret `nodered-settings` (Opaque, gitignored — se genera en despliegue). **Sin** basic-auth web ni anonymous.
- **Secretos**: el hash bcrypt y el `credentialSecret` (cifrado de credenciales de nodos) se generan en el despliegue y **no** se versionan. Ver `scripts/deploy-nodered.sh`.
- **Almacenamiento**: PVC `nodered-data` (5Gi, RWO, `nfs-storage`) montado en `/data` (flows, credenciales y contextos persistentes).
- **Ingress** (`files/nodered/ingress.yaml`): TLS con cert-manager (Certificate `nodered-elarreglador-eu` → secret `nodered-elarreglador-eu-tls`), `force-ssl-redirect: true`. Certificate versionado en `files/nodered/certificate.yaml`.
- **NetworkPolicy** (`files/nodered/networkpolicy.yaml`): permite tráfico desde ingress-nginx (1880), egress DNS y salida a Internet (para instalar nodos del palette).
- **Recursos**: requests 100m/256Mi, limits 500m/512Mi.
- **Despliegue**: `NODERED_PASSWORD=<clave> ./scripts/deploy-nodered.sh` (la clave solo en el entorno; el hash se genera con python3-bcrypt sin escribirla en disco).

## Radio SDR remota (rtl_tcp)

- **Acceso público**: `sdr.elarreglador.eu:1234` (TCP) — servidor `rtl_tcp` (verificado 2026-08-14: cabecera DongleInfo `RTL0` en el extremo público). **Sin autenticación**: cualquiera con el host:puerto puede sintonizar; **un solo cliente a la vez** (comportamiento nativo de rtl_tcp; el segundo queda a la espera hasta que el primero desconecte).
- **Hardware**: dongle RTL-SDR v3 (USB `0bda:2838`) + upconverter Nooelec Ham It Up (+125 MHz), conectados en D1. El upconverter permite un rango útil de ~25 MHz a 1700 MHz (con la conversión +125 MHz activa, la recepción HF efectiva es ~0,1–30 MHz).
- **Workload**: Deployment `rtl-sdr` (1 réplica, imagen `skl256/rtl_tcp`, namespace `pods`), **privilegiado** y anclado a **k8s-worker-1** con `nodeSelector` (`eu.elarreglador/sdr=true`). Monta por `hostPath` el directorio `/dev/bus/usb` del nodo (el dongle se pasa al contenedor LXC k8s-worker-1 con un device `usb` de LXD). Sin PVC (stateless).
- **Service**: `rtl-sdr`, NodePort `1234 → 31234/TCP`. Las probes son `exec` (`pgrep rtl_tcp`) a propósito: una probe `tcpSocket` al 1234 consumiría el slot del único cliente. Desde MetalLB añade además IP LAN `192.168.1.60:1234` (LoadBalancer, `externalTrafficPolicy: Local`; el NodePort se conserva para el tráfico externo).
- **Recursos**: requests 50m/64Mi, limits 250m/256Mi.
- **Cadena de acceso**:
  ```
  GQRX (RTL-SDR TCP) → sdr.elarreglador.eu:1234
    → nginx stream DV0 (listen 1234 → 10.8.0.11:1234)
    → LXC proxy device `proxyrtlsdr` en D1 (10.8.0.11:1234 → 127.0.0.1:31234)
    → Service NodePort `rtl-sdr` 31234 → pod rtl-sdr → dongle USB en k8s-worker-1
  ```
- **NetworkPolicy** (`files/sdr/networkpolicy.yaml`): `rtlsdr-allow` — ingress TCP/1234 desde cualquier origen (el tráfico NodePort entra DNAT desde el nodo; el retorno lo cubre conntrack) y egress solo DNS.
- **Despliegue**: `./scripts/deploy-sdr.sh` (etiqueta el nodo, aplica manifests y espera rollout). Los pasos de infraestructura en D1 (device `usb` + proxy LXC) se hacen una sola vez y están en [01-Network.md](./01-Network.md).
- **Instrucciones GQRX del cliente** (los mismos parámetros están publicados en la landing, sección Servicios D-Lab):

  | Parámetro | Valor |
  |-----------|-------|
  | Dispositivo | RTL-SDR TCP |
  | Host | `sdr.elarreglador.eu` |
  | Puerto | `1234` |
  | LNB LO (compensación upconverter Ham It Up +125 MHz) | **−125 MHz** |
  | Sample rate (input rate) | `960000` (valor publicado en la landing; el defecto de 2.4 MS/s ≈ 38 Mbps puede saturar el enlace de DV0) |
  | Clientes simultáneos | 1 |

  Device string alternativo en GQRX: `rtl_tcp=sdr.elarreglador.eu:1234`.
- **Notas operativas**: si el dongle se desenchufa, rtl_tcp muere y el pod se reinicia (se recupera al reenchufar). El pod no tiene PDB: al drenar o apagar k8s-worker-1 queda `Pending` hasta que el nodo vuelva.

## MariaDB

- **Acceso**: solo interno al cluster. Sin URL pública ni Ingress: se gestiona por terminal vía `kubectl exec` / `kubectl run` desde el namespace `pods`.
- **Workload**: Deployment `mariadb` (1 réplica, imagen `mariadb:11`, namespace `pods`), Service ClusterIP `mariadb:3306`. Recursos requests 250m/256Mi, limits 1 CPU/1Gi.
- **BD**: `dlab` (usuario `dlab`, password en el Secret `mariadb-secret`, Opaque, gitignored — se genera en despliegue; la password solo viaja en el entorno de `deploy-mariadb.sh`). BD y usuario dedicados para **Node-RED**: `nodered`/`nodered` (password en `info_sensible/nodered-mariadb.env`, gitignored; acceso solo a su propia BD). Args: `--innodb-buffer-pool-size=256M`, `--innodb-flush-log-at-trx-commit=2` (durabilidad reducida: acepta el fsync lento del NFS, riesgo de perder los últimos ~1 s de transacciones en corte de energía).
- **Almacenamiento**: PVC `mariadb-data` (10Gi, RWO) sobre el **StorageClass `nfs-storage-v4`** (NFSv4), montado en `/var/lib/mysql` con `fsGroup: 999`. El RWO permite que el pod migre de worker manteniendo los datos (verificado: k8s-worker-1 → k8s-worker-2).
- **NetworkPolicy** (`files/mariadb/networkpolicy.yaml`): `mariadb-allow-pods` — ingress solo TCP/3306 desde pods del namespace `pods`; egress solo DNS (CoreDNS + ClusterIP). **Sin acceso exterior**.
- **Backups** (`files/backup-mariadb.sh`): dump `mariadb-dump --all-databases` vía `kubectl exec` sobre el pod (sin depender de la red del pod) + copia redundante al peer master por SSH. Desplegado en k8s-master-1 y k8s-master-2, cron `0 3 * * *` en `/etc/cron.d/mariadb-backup` → `/backup/mariadb/mariadb-<fecha>.sql`, rotación de 30, log `/var/log/mariadb-backup.log`. La password se lee del Secret en runtime, nunca se versiona.
  - **Nota** `(verificado 2026-08-10)`: el cron debe vivir en `/etc/cron.d/mariadb-backup` con el campo de usuario `root`; si se mete en el crontab de usuario (`crontab -e`) el `root` se interpreta como comando y el backup falla cada noche (`/bin/sh: 1: root: not found`). Requiere `/root/.kube/config` en **ambos** masters (kubeconfig `admin.conf`) para que `kubectl` llegue al API Server.
- **Despliegue**: `MARIADB_ROOT_PASSWORD=<clave> MARIADB_PASSWORD=<clave> ./scripts/deploy-mariadb.sh` (las claves solo en el entorno; el Secret se genera por stdin).

## Telegram Bot

Microservicio interno para enviar notificaciones a Telegram desde cualquier pod del cluster. Namespace `pods`.

- **Workload**: Deployment `telegram-bot` (1 réplica, imagen `python:3.12-alpine`, namespace `pods`), Service ClusterIP `telegram-bot:8080`. Sin PVC (stateless), sin Ingress ni LoadBalancer — solo consume el API público de Telegram.
- **Código**: Opción A (imagen pública + ConfigMap): `files/telegram-bot/telegram-bot.yaml` contiene el ConfigMap `telegram-bot-code` con `app.py` (FastAPI) y `requirements.txt` (`fastapi`, `uvicorn`, `httpx` pinnados); el Deployment monta el ConfigMap en `/app` (ro) y un `initContainer` instala deps en `emptyDir /tmp/deps` (`PYTHONPATH=/tmp/deps`). Ver `scripts/deploy-telegram-bot.sh`.
- **API** (acceso abierto intra-cluster, sin auth):
  - `GET /health` → `{"ok":true}` (probes)
  - `POST /notify` → `{"text": str, "parse_mode": "Markdown|HTML"?, "disable_notification": bool?}` → `{"ok":true,"message_id":123}`. Valida `text` no vacío, trunca a 4096 (límite Telegram).
  - `POST /alert` → payload Alertmanager (`{"alerts":[...]}`) → formatea cada alerta `🔥/✅ STATUS alertname [severity] @ instance — summary` y reenvía como `text`.
  - Uso desde cualquier pod: `curl -s http://telegram-bot.pods.svc:8080/notify -H 'Content-Type: application/json' -d '{"text":"hola"}'` o `curl -s http://telegram-bot.pods.svc:8080/alert -d @payload.json`
- **Secretos**: `telegram-bot-secret` (Opaque, gitignored — se genera en despliegue; las claves solo viajan en el entorno de `deploy-telegram-bot.sh`): `TELEGRAM_BOT_TOKEN` (de @BotFather) y `TELEGRAM_CHAT_ID` (de `getUpdates`). Nunca se versionan; `info_sensible/telegram.env` (gitignored).
- **Recursos**: requests 50m/64Mi, limits 250m/128Mi; `initContainer` 50m/64Mi → 500m/256Mi. `readOnlyRootFilesystem`, `runAsNonRoot` (1000), `drop ALL`, `seccomp RuntimeDefault`.
- **NetworkPolicy** (`files/telegram-bot/networkpolicy.yaml`): `telegram-bot-allow` — ingress TCP/8080 desde **cualquier namespace** (`namespaceSelector: {}`) + puerto abierto para probes; egress solo DNS (CoreDNS 53) + `0.0.0.0/0:443` (Telegram Bot API). Para hardening futuro restringir a `149.154.160.0/20` + `91.108.4.0/22`.
- **Probes**: `startup`/`readiness`/`liveness` con `httpGet /health` (`timeoutSeconds: 5`).
- **Despliegue**: `TELEGRAM_BOT_TOKEN=<token> TELEGRAM_CHAT_ID=<id> ./scripts/deploy-telegram-bot.sh` (las claves solo en el entorno; el Secret se genera por stdin, idempotente). Requiere `KUBECTL_HOST` (por defecto `server`).
- **Integración futura**: Alertmanager `webhook_configs: url: http://telegram-bot.pods.svc:8080/alert`, Node-RED `http request`, CronJobs con `curl`.

## Modelo de lenguaje local (Ollama + qwen2.5-coder)

LLM de código abierto autoalojado para uso con opencode y Node-RED. Namespace `ia`.

- **Workload**: Deployment `ollama` (1 réplica, imagen `ollama/ollama:0.32.14`, pin fijo), **solo en los workers** vía `nodeSelector` (`eu.elarreglador/worker=true`). Modelo `qwen2.5-coder:3b` (Q4_K_M, 1.9 GB, contexto 32 768) descargado en el despliegue y persistente en el PVC.
- **Acceso** (sin autenticación a propósito; la protección es por aislamiento de red):
  - Interno (Node-RED): `http://ollama.ia.svc:11434`
  - LAN: `http://192.168.1.31:31434` (NodePort en cualquier nodo; `.32` también responde)
  - WireGuard: `http://10.8.0.11:31434` (LXC proxy device `proxyollama` en D1: `10.8.0.11:31434 → 127.0.0.1:31434`)
- **Ollama no autentica peticiones por defecto** (la `OLLAMA_API_KEY` solo aplica a ollama.com). Si algún día se necesita, la protección razonable es una capa previa (p. ej. nginx stream con Bearer en DV0), no esperar auth nativa.
- **Almacenamiento**: PVC `ollama-models` (20Gi, RWO, `nfs-storage`) montado en `/models` (`OLLAMA_MODELS=/models`).
- **Parámetros** (env del Deployment): `OLLAMA_HOST=0.0.0.0`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_KEEP_ALIVE=5m`, `HOME=/tmp` (el contenedor corre como uid 1000 con `readOnlyRootFilesystem`).
- **Recursos**: requests 500m/1Gi, limits 2 CPU/4Gi. **Tope por pod**: 2 CPU es lo que hay disponible de margen real en los workers (~20% libre sobre 7.1 GiB); para un modelo más grande (7B+) habría que subir el límite y evaluar que no ahogue al cluster. **Nota (2026-08-18)**: el límite de memoria subió de 3Gi a 4Gi durante el benchmark de tareas de programación — con 3Gi, cargar modelos de 2-3 GB junto con la KV cache (4096 ctx ≈ 1.28 GB) hacía que el **liveness probe (timeout 1 s)** matase el pod en cada carga (eventos `Liveness probe failed ... connection refused`); se subió el `timeoutSeconds` de las probes a 5 (startup/readiness/liveness, failureThreshold 5 en liveness).
- **Benchmark de modelos ≤3B (2026-08-18)**: se probaron 8 modelos en el pod con sus límites reales (2 CPU/3 Gi, CPU i3-7100T). Metodología: para cada modelo `ollama pull` → consulta fría (carga a RAM, descartada) → **consulta caliente** con el prompt *«Responde con una sola palabra: pong»* (`/api/chat`, `stream:true`), midiendo time-to-first-token (TTFT) y tiempo total con un pod helper `curl` (curlimages/curl, ns `ia`). Tras medir se ejecutó `ollama rm`.

  | Modelo | Tamaño | TTFT (s) | Total (s) | Resultado |
  |--------|--------|----------|-----------|-----------|
  | tinyllama:1.1b | 0.6 GB | 0.212 | **0.531** | ✓ dentro del corte |
  | qwen2.5-coder:1.5b | 1.0 GB | 0.427 | **0.586** | ✓ |
  | qwen2.5:1.5b | 1.0 GB | 0.431 | **0.623** | ✓ |
  | qwen2.5-coder:3b | 1.9 GB | 0.569 | **1.009** | ✓ elegido |
  | gemma2:2b | 1.6 GB | 0.802 | **1.216** | ✓ |
  | llama3.2:3b | 2.0 GB | 0.613 | 6.195 | ✗ supera 5 s (genera largo, ~5 tok/s) |
  | qwen3:4b | 2.5 GB | — | — | ✗ descartado (reiniciaba el pod) |
  | phi3:mini | 2.2 GB | — | — | ✗ descartado (reiniciaba el pod) |

  Criterio: tiempo de respuesta total ≤ 5 s. **qwen3:4b y phi3:mini se descartaron por inestabilidad**: al cargarlos (2.2-2.5 GB) el daemon tarda en responder y el **liveness probe (`timeoutSeconds: 1`)** mata el pod (`kubectl get events` → `Liveness probe failed ... connection refused`; `restartCount` sube). Los 5 que pasan el corte dan TTFT ≤ 0.8 s. La medición se hizo sobre el pod con sus límites reales, no sobre el host completo, para que los tiempos reflejen el entorno de uso (opencode/Node-RED).
- **Benchmark de tarea de programación (2026-08-18)**: a los 6 candidatos que pasaron/entraron en el corte anterior (qwen2.5-coder:3b, granite-code:3b, llama3.2:3b, yi-coder:1.5b, deepseek-coder:1.3b, smollm2:1.7b) se les pidió implementar, en cada lenguaje, un **evaluador de expresiones aritméticas** (enteros, `+ - * /` división entera, paréntesis, precedencia; leer de stdin, imprimir resultado). Prompt idéntico en castellano por lenguaje, sin mencionar prácticas/tests/seguridad. Proceso por lenguaje/modelo: `ollama pull` → warm-up (descartado, carga a RAM) → petición medida (`stream:false`, `keep_alive:0`, TTFT+total por `curl`) → **extracción del bloque de código y compilación/ejecución real en G9** (`dart`, `gcc`, `python3`, `bash`, `node`, `javac`/`java`), validando la salida contra un corpus fijo (p. ej. `2 + 3 * 4` → 14, `(2+3)*4` → 20, `10 / 4` → 2, `2*(3+4)/7` → 2, `8 / 2 * 2` → 8). Criterio **`Funciona?` = compila y produce el resultado esperado**; si no, las demás columnas quedan `-`. **Prompts, corpus y metodología completos en [`Benchmark-LLM.md`](Benchmark-LLM.md)**. Resultados preliminares **Dart** (ronda 1, con Rust fallido en paralelo — los dos lenguajes a la vez degradaban la calidad, así que se repitió solo Dart): **ningún modelo ≤3B generó Dart válido** (el más cercano, qwen2.5-coder:3b, con lógica de precedencia correcta pero `Stack` inexistente en la stdlib de Dart + nullability; el resto, APIs/sintaxis inventadas o esqueletos).

  | Modelo | Lenguaje | Funciona? | Estabilidad | CiberSeguridad | Buenas prácticas | Tests | Tiempo (s) |
  |--------|----------|-----------|-------------|----------------|-------------------|-------|------------|
  | qwen2.5-coder:3b | Dart | No | — | — | — | — | 67.8 |
  | granite-code:3b | Dart | No | — | — | — | — | 27.3 |
  | llama3.2:3b | Dart | No | — | — | — | — | 132.3 |
  | yi-coder:1.5b | Dart | No | — | — | — | — | 38.8 |
  | deepseek-coder:1.3b | Dart | No | — | — | — | — | 29.7 |
  | smollm2:1.7b | Dart | No | — | — | — | — | 92.6 |

  **Ronda completa (2026-08-19)** — C, Python, bash, JS y Java (misma tarea y corpus). En esta ronda el pod ollama ya tenía el límite de 4 GiB y las probes con timeout 5 s; cada petición se midió con `keep_alive:0`, así que el **tiempo incluye la carga del modelo** en cada una (TTFT ≈ TOTAL). Resultado: **un solo caso funcional de 30 — yi-coder:1.5b en JS, y usando `eval()`** (lee el stdin con `readFileSync('/dev/stdin')` y lo evalúa directamente): pasa el corpus 10/10, pero es una **RCE (ejecución de código arbitrario)** desde la entrada → valor CiberSeguridad 1/10. Ningún otro modelo+lenguaje produjo un evaluador correcto; fallos dominantes: código incompleto/fragmentado (granite, smollm2), `eval`/APIs inventadas (yi-coder, deepseek, smollm2), y precedencia o división entera mal resueltas en los que sí compilaban (qwen2.5-coder en C/Python, deepseek en Python con división real).

  | Modelo | Lenguaje | Funciona? | Estabilidad | CiberSeguridad | Buenas prácticas | Tests | Tiempo (s) |
  |--------|----------|-----------|-------------|----------------|-------------------|-------|------------|
  | qwen2.5-coder:3b | C | No | — | — | — | — | 92.8 |
  | qwen2.5-coder:3b | Python | No | — | — | — | — | 97.4 |
  | qwen2.5-coder:3b | bash | No | — | — | — | — | 33.0 |
  | qwen2.5-coder:3b | JS | No | — | — | — | — | 95.2 |
  | qwen2.5-coder:3b | Java | No | — | — | — | — | 108.2 |
  | granite-code:3b | C | No | — | — | — | — | 59.7 |
  | granite-code:3b | Python | No | — | — | — | — | 45.0 |
  | granite-code:3b | bash | No | — | — | — | — | 48.2 |
  | granite-code:3b | JS | No | — | — | — | — | 67.1 |
  | granite-code:3b | Java | No | — | — | — | — | 62.9 |
  | llama3.2:3b | C | No | — | — | — | — | 504.7 |
  | llama3.2:3b | Python | No | — | — | — | — | 92.3 |
  | llama3.2:3b | bash | No | — | — | — | — | 58.4 |
  | llama3.2:3b | JS | No | — | — | — | — | 133.2 |
  | llama3.2:3b | Java | No | — | — | — | — | 95.3 |
  | yi-coder:1.5b | C | No | — | — | — | — | 37.8 |
  | yi-coder:1.5b | Python | No | — | — | — | — | 58.2 |
  | yi-coder:1.5b | bash | No | — | — | — | — | 22.9 |
  | yi-coder:1.5b | **JS** | **Sí** | 10 | **1** (eval = RCE) | No | No | 24.9 |
  | yi-coder:1.5b | Java | No | — | — | — | — | 74.5 |
  | deepseek-coder:1.3b | C | No | — | — | — | — | 99.2 |
  | deepseek-coder:1.3b | Python | No | — | — | — | — | 32.6 |
  | deepseek-coder:1.3b | bash | No | — | — | — | — | 51.1 |
  | deepseek-coder:1.3b | JS | No | — | — | — | — | 33.8 |
  | deepseek-coder:1.3b | Java | No | — | — | — | — | 79.8 |
  | smollm2:1.7b | C | No | — | — | — | — | 91.3 |
  | smollm2:1.7b | Python | No | — | — | — | — | 63.5 |
  | smollm2:1.7b | bash | No | — | — | — | — | 46.1 |
  | smollm2:1.7b | JS | No | — | — | — | — | 75.3 |
  | smollm2:1.7b | Java | No | — | — | — | — | 104.0 |

  **Conclusión del benchmark de programación**: ningún modelo ≤ 3B es fiable para generar código de esa complejidad en 6 lenguajes; el único acierto (yi-coder JS) es además un antipatrón de seguridad. Para el uso real (opencode), **qwen2.5-coder:3b sigue siendo la mejor opción** por su calidad relativa de código y tiempos razonables — asumiendo que se **revisa siempre el código generado** (los fallos de precedencia en C/Python lo demuestran). Los tiempos aquí (30-500 s) no son comparables a los del ping (0.5-6 s): la tarea de programación genera 1-9 KB de tokens y en cada petición se recarga el modelo. **Los 6 modelos probados se conservan descargados en el PVC** (decisión 2026-08-19). Tablas, prompts y corpus completos en [`Benchmark-LLM.md`](Benchmark-LLM.md).
- **Hardening** (`files/ia/ollama.yaml`): `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, capabilities `drop: ALL`, seccomp `RuntimeDefault`. Namespace `ia` con PSS `baseline` (enforce) / `restricted` (warn).
- **NetworkPolicy** (`files/ia/networkpolicy.yaml`): `ollama-allow` — ingress TCP/11434 desde el namespace `pods` (ClusterIP, para Node-RED) **y** desde cualquier origen (el tráfico NodePort entra DNAT desde el nodo). Egress solo DNS + **TCP/443 a los rangos de Cloudflare** (`104.16.0.0/12`, `172.64.0.0/13`, `173.245.48.0/20`, `198.41.128.0/17`, `190.93.240.0/20`, `188.114.96.0/20`): necesarios para que `ollama pull` funcione — `registry.ollama.ai` (manifests) y `*.r2.cloudflarestorage.com` (blobs, Cloudflare R2). **Gotcha verificado 2026-08-18**: sin esa regla el pull muere con `dial tcp 172.64.x.x:443: i/o timeout` tras bajar el manifest.
- **Quota** (`files/ia/quota.yaml`): ResourceQuota `ia-quota` (requests 4 CPU/8Gi, limits 8 CPU/16Gi, 3 pods, 2 PVC) + LimitRange (default 100m/128Mi request, 500m/512Mi limit).
- **Probes**: startup/readiness/liveness con `httpGet /api/tags` (el endpoint responde 200 con el daemon listo; el modelo se carga bajo demanda en la primera petición).
- **Acceso LAN**: el Service es `NodePort 31434` (no MetalLB, a diferencia del stack multimedia). Motivo: el NodePort se reenvía por kube-proxy a cualquier worker y funciona desde cualquier nodo; verificado 200 desde `192.168.1.31` y `.32`.
- **Despliegue**: `./scripts/deploy-ollama.sh` (etiqueta los workers `eu.elarreglador/worker=true` idempotente, aplica `files/ia/`, espera rollout y descarga el modelo con `ollama pull`).
- **Problema de descarga del modelo por SSH**: `kubectl exec` corta el `ollama pull` si la sesión SSH muere (SIGHUP); si hay que relanzarlo, `nohup kubectl -n ia exec deploy/ollama -- ollama pull qwen2.5-coder:3b > /tmp/ollama-pull.log 2>&1 &`.
- **Seguridad**: Ollama tiene CVE conocidos (p. ej. CVE-2025-15063, RCE en el servidor MCP, CVSS 9.8). Mitigación: imagen pinnada a la última estable (`0.32.14`), hardening del pod, y **ninguna exposición pública** (solo LAN/WG). Antes de subir la imagen, revisar CVE en [GitHub Advisory DB](https://github.com/advisories?query=ollama).

### opencode en el portátil (G9)

Config global `~/.config/opencode/opencode.jsonc` con dos providers `@ai-sdk/openai-compatible`:

| Provider | baseURL | Cuándo |
|----------|---------|--------|
| `ollama-lan` | `http://192.168.1.31:31434/v1` | G9 en la LAN doméstica |
| `ollama-wg` | `http://10.8.0.11:31434/v1` | G9 fuera de casa (WireGuard) |

Modelos registrados con prefijo `D-Lab_` (5 en el PVC; `id` = nombre real en Ollama; `limit.context` = `context_length` verificado en el pod 2026-08-20). Reemplazos 2026-08-20: `deepseek-coder:1.3b` + `yi-coder:1.5b` → `qwen2.5-coder:1.5b`; `granite-code:3b` → `granite3.2:2b`:

| Modelo (clave opencode) | id en Ollama | context | tools (manifiesto) |
|---|---|---|---|
| `D-Lab_granite3.2:2b` | `granite3.2:2b` | 131072 | ✓ |
| `D-Lab_llama3.2:3b` | `llama3.2:3b` | 131072 | ✓ |
| `D-Lab_qwen2.5-coder:1.5b` | `qwen2.5-coder:1.5b` | 32768 | ✓ |
| `D-Lab_qwen2.5-coder:3b` | `qwen2.5-coder:3b` | 32768 | ✓ |
| `D-Lab_smollm2:1.7b` | `smollm2:1.7b` | 8192 | ✓ |

Uso: `opencode run "..." --model ollama-lan/D-Lab_qwen2.5-coder:3b` (o `ollama-wg/...` vía WG).

**Limitación real de tools (verificado 2026-08-20)**: aunque los 5 modelos declaran `tools` en el manifiesto de Ollama (aceptan el array `tools` en la petición), **ninguno ≤3B emite `tool_calls` nativos fiables** en el agente de opencode: en tareas que requieren herramientas responden con JSON en texto (p. ej. `{"name":"read","arguments":...}`) que opencode no ejecuta (mismo caso que [anomalyco/opencode#234](https://github.com/anomalyco/opencode/issues/234)). El agente `build` funciona para conversación y generación de código, pero las tareas que exigen leer/editar archivos no se ejecutan de forma fiable con ningún modelo de este catálogo.

**Gotchas del pod (2026-08-20)**:
- **OOM**: cargar varios modelos en la ventana `OLLAMA_KEEP_ALIVE` (5 m) supera los 4 GiB del límite → `OOMKilled` (confirmado: restart del pod). Usar un modelo a la vez y esperar a que descargue.
- **`granite3.2:2b` es un modelo "thinking"**: lento en el pod (2 CPU), respuestas de ~1-2 min en frío. Operativo pero no recomendado para uso interactivo.
- `granite3.1-dense:2b` se probó como alternativa y se **descartó** (error de servidor persistente al cargarlo en este pod).
- Los 3 modelos antiguos sin tools (`deepseek-coder:1.3b`, `yi-coder:1.5b`, `granite-code:3b`) se eliminaron del PVC.

## Cluster AI — chat Telegram con IA local, RAG y monitor

Chat de Telegram con IA local (`@Dlab_assistant_bot`) que responde preguntas sobre el estado del cluster y la documentación versionada, con RAG sobre los docs del repo y monitor proactivo. Namespace `ia` (reusa `ia-quota` 4CPU/8Gi req 8CPU/16Gi lim).

- **Bot separado** `@Dlab_assistant_bot` (token distinto de `@Dlab_mrbot` en `pods`). `TELEGRAM_AI_TOKEN` + `TELEGRAM_CHAT_ID` allowlist (solo `836571451`) en `info_sensible/cluster-ai.env` (600, gitignored) → `Secret cluster-ai-secret` por `stdin` (`scripts/deploy-cluster-ai.sh` idempotente vía `ssh $KUBECTL_HOST` default `server`).
- **Workload**: `Deployment cluster-ai-api` 1 réplica `Recreate` (polling no soporta 2 consumers) `python:3.12-slim` (no `alpine` por `torch`/`chroma-hnswlib` con `build-essential`), `Service cluster-ai-api:8000` ClusterIP. `ConfigMap cluster-ai-code` con `app.py` + `rag.py` + `monitor.py` + `requirements.txt` (`fastapi`, `uvicorn`, `httpx`, `kubernetes`, `pyyaml`, `sentence-transformers==2.7.0`, `chromadb==0.4.22`, `numpy`, `apscheduler`). `initContainer install-deps` `pip --target /tmp/deps` (`PYTHONPATH=/tmp/deps`, `readOnlyRootFilesystem`).
- **Comandos deterministas** `/get nodes|ns|pods [ns]|deployments|events|logs <pod>|top|status|alerts|help` + `sin /` → Ollama. Orquestador `regex→tool` (no `tool_calls` nativos ≤3B) con `is_allowed("kubectl …")` + `AUDIT` + `check_rate 5/min` + `truncate 4096` + `asyncio.to_thread` (no bloquea `liveness`). `HELP` en `app.py:33`.
- **IA local**: `OLLAMA_URL=http://ollama.ia.svc:11434` `MODEL=qwen2.5-coder:3b` (`qwen2.5-coder:3b` 1.9Gi 32k, ya en `ollama-models` 20Gi). `ask_ollama()` `POST /api/generate` `timeout 90s` + `retry 1` fallback `/api/chat` 30s. `fetch_cluster_data()` live K8s `list_node/pods/deployments` inyectado en `build_prompt()` con `✅❌⚠️`.
- **RAG docs**: `PVC docs-cache 1Gi nfs-storage` montado en `/cache` (api y CronJob). `CronJob docs-sync` `*/15` `alpine/git` `git clone --depth 1 https://github.com/elarreglador/D-Lab.git → /cache/docs` + `wget POST http://cluster-ai-api.ia.svc:8000/reindex` + `notify ℹ️ Docs actualizados` vía `telegram-bot:8080/notify` si `HEAD` cambia. `POST /reindex` → `rag.index_docs()` 183 chunks `all-MiniLM-L6-v2` 384 `Chroma` `TOP_K=3` in-memory `Client` (`HF_HOME=/tmp/hf_cache` + `2Gi` + `build-essential`). `chunk_md()` `##` 500 tokens overlap 50 `file:line`. `rag_query()` normaliza `¿?¡!` y `VIP` keyword fallback `192.168.1.30`. `GET /debug/rag?q=&k=` + `POST /simulate {"text":…}` para tests sin Telegram. Fuentes `Fuentes:` solo si `rag_ctx` y `ans` sin `⚠️`, con `HTML` `<a href="https://github.com/elarreglador/D-Lab/blob/main/{file}#L{line}">{fp}:{line}</a>` + `parse_mode HTML` `disable_web_page_preview`.
- **Monitor 5m** `APScheduler` (`monitor.py` `CHECK_INTERVAL 300`): `check_pods` `CrashLoopBackOff` only, `Pending>5m`, `check_nodes` `NotReady/DiskPressure/MemoryPressure`, `check_storage` `socket 192.168.1.30:2049`, `check_etcd` `GET https://10.96.0.1:443/readyz` con SA token, `check_certs` `cert-manager.io` `<30d` + `NotReady`. `run_checks()` `asyncio.to_thread` + `notify()` `POST http://telegram-bot.pods.svc:8080/notify` `🚨 Cluster Alert` truncado 3000. `create_monitor(sched)` en `startup` (`app.py:347`).
- **Alertmanager**: `Secret alertmanager-kube-prometheus-stack-alertmanager` `alertmanager.yaml` `receiver telegram` `webhook http://telegram-bot.pods.svc:8080/alert` `send_resolved: true` (patch `kubectl patch secret` + `pod delete` restart). `Watchdog` permanece `null`.
- **RBAC** `ServiceAccount cluster-ai-sa` `ClusterRole cluster-ai-ro` `get/list/watch` `nodes,namespaces,pods,pods/log,events,deployments,metrics.k8s.io,cert-manager.io` **sin** `secrets` (`kubectl auth can-i get secrets --as=… → no`).
- **NetworkPolicy** `cluster-ai-allow` (`ia` `app=cluster-ai-api`): ingress `8000` abierto, egress `53` `kube-system/kube-dns` + `10.96.0.0/12`, `80/443` `0.0.0.0/0` (apt + Telegram `api.telegram.org` + `huggingface.co`), `443/6443/8443` `10.96.0.0/12` + `192.168.1.0/24` + `2049/111` `192.168.1.0/24` (NFS), `11434` `ia/ollama`, `8080` `pods/telegram-bot`, `8443`. Probes `startup/liveness/readiness` `httpGet /health`.
- **Recursos**: `api` `requests 200m/512Mi limits 1000m/2Gi` + `init 200m/256Mi→2000m/2Gi`; `ollama 500m/1Gi→2CPU/4Gi`; total `requests 700m/1.5Gi < 4CPU/8Gi` `limits 3CPU/6Gi < 8CPU/16Gi` (`ia-quota`).
- **Scripts**: `scripts/deploy-cluster-ai.sh` (Secret stdin, `KUBECTL_HOST` default `server`, `rollout status`) + `scripts/simulate-cluster-ai.sh` Plan B CLI (`--all` 12 cmds, `run_one` via `POST /simulate` en `127.0.0.1:8000` con `PYTHONPATH=/tmp/deps:/app` `timeout 200`, sin Telegram) + `POST /reindex` + `GET /debug/rag`.
- **Verificación** `(verificado 2026-08-22)`: `ssh server "kubectl -n ia rollout status deploy/cluster-ai-api"`, `curl --post-data "" http://127.0.0.1:8000/reindex → 183`, `simulate --all` 12/12 (`/get nodes 4 Ready`, `/docs Gluster → README-TECH.md:2597`, `VIP 192.168.1.30 → 03-Aplicaciones.md:28`), `Telegram /get nodes → 4 Ready`, `/logs → 100 líneas`, `/docs Gluster → cita`, `hola → ✅Hola` (Ollama), `VIP → 192.168.1.30` (RAG), `curl http://telegram-bot.pods.svc:8080/notify → message_id`, `run_checks []` healthy, `curl /alert → message_id 23`.

## Exposición pública

| Host | App | Protección |
|------|-----|-----------|
| `elarreglador.eu` / `www.elarreglador.eu` | Landing (pública) | ninguna (200 sin credenciales) |
| `grafana.elarreglador.eu` | Grafana | login de Grafana |
| `nodered.elarreglador.eu` | Node-RED | login propio de Node-RED |
| `jellyfin.elarreglador.eu` | Jellyfin | login de Jellyfin |
| `torrent.elarreglador.eu` | qBittorrent | login WebUI qBittorrent |
| `amule.elarreglador.eu` | aMule | login amuleweb (Secret `amule-secret`) |
| `sdr.elarreglador.eu:1234` | Radio SDR (rtl_tcp, GQRX) | ninguna (recepción abierta; un cliente a la vez) |
| prometheus / alertmanager / **mariadb** / **ollama** | — | internos (sin ingress; ollama solo LAN/WG, sin auth) |
| `192.168.1.50` … `.60` | IPs LAN (MetalLB, pool `.50–.64`) | ver mapa de IPs en el stack multimedia (`.53` jellyfin, `.54` amule, `.55` amule-p2p, `.58` qB, `.59` qB-torrent); solo LAN |

## PDBs y NetworkPolicies

- **PDBs** (manifiestos en `files/pdbs/`): `landing`, `coredns`, `ingress-nginx`, `calico-kube-controllers`, `calico-typha`, `grafana`, `prometheus`, `alertmanager`.
- **NetworkPolicies** (manifiestos en `files/networkpolicies/`, `files/mariadb/networkpolicy.yaml`, `files/nodered/networkpolicy.yaml`, `files/sdr/networkpolicy.yaml`, `files/ia/networkpolicy.yaml`, `files/telegram-bot/networkpolicy.yaml`, `files/multimedia/networkpolicy-*.yaml`): `landing-allow-ingress-nginx` (default, app=landing), `coredns-allow-dns` (kube-system), `mariadb-allow-pods`, `nodered-allow-ingress-nginx`, `rtlsdr-allow`, `ollama-allow`, `telegram-bot-allow` (pods → telegram-bot:8080 abierto + egress 443 Telegram), `media-public` (Jellyfin/qBittorrent/aMule, `ipBlock: 192.168.1.0/24`), `qbittorrent-allow-torrent` (6881), `amule-allow-p2p` (4662/4672/4665) y `multimedia-egress` (DNS + `0.0.0.0/0`). El resto del tráfico se rige por Calico policy-only. Las de acceso LAN se ampliaron para permitir `192.168.1.0/24` y solo funcionan si el Service LoadBalancer usa `externalTrafficPolicy: Local`.

## Notas operativas

- **Alertas firing por diseño**: `TargetDown`, `etcdMembersDown`, `etcdInsufficientMembers` (targets `kube-etcd`/`kube-scheduler`/`kube-controller-manager`/`kube-proxy` no exponen métricas en los puertos por defecto en LXC) y `Watchdog` (centinela). La cadena principal (kubelet, apiserver, coredns, node-exporter, hosts) está **up**.
- **Credenciales**: nunca en el repo. Grafana → usuario `elarreglador` (garantizado por `scripts/grafana-user.sh`; passwords en `info_sensible/grafana-user.env`, gitignored) y `admin` (Secret `kube-prometheus-stack-grafana`). Clave web / secretos → `info_sensible/` (gitignored).
- **sudo en DV0/D1/D2** (`verificado 2026-08-18`): el usuario `elarreglador` tiene `NOPASSWD: ALL` vía `/etc/sudoers.d/elarreglador-nopasswd` (antes solo `poweroff`/`systemctl`/`true` sin password). Se amplió para poder instalar/administrar agentes de monitoreo y gestionar unidades systemd remotas por SSH sin TTY. La password de sudo (no va al repo) sigue siendo la que define el señor en cada máquina.
- **CNI Calico — tokens de `calico-kubeconfig`**: el token del SA `calico-cni-plugin` usado por el plugin CNI en los 4 nodos (`/etc/cni/net.d/calico-kubeconfig`) **expira** (el emitido por kubeadm el 2026-08-01 caducó a las 24 h y todos los pods nuevos fallaban con `error getting ClusterInformation: ... Unauthorized`). Se fijó creando el Secret `calico-cni-plugin-token` (kube-system, anotación `kubernetes.io/service-account.name`) — sin expiración — y reescribiendo el `token:` de ese kubeconfig en los 4 nodos (`verificado 2026-08-15`; se renovó de nuevo con el static secret y el rollout de Radarr completó). Si vuelve a aparecer `FailedCreatePodSandBox` por Calico en pods nuevos, revisar la fecha de expiración de ese token: el proceso manual es copia de seguridad del kubeconfig, descarga del Secret de token estático y reescritura del campo `token` (`kubectl get secret calico-cni-plugin-token -n kube-system -o jsonpath='{.data.token}' | base64 -d`), en cada nodo.
- **Scripts útiles** (`scripts/`): `deploy-landing.sh`, `deploy-multimedia.sh` (stack simplificado Jellyfin+qBittorrent+aMule; opcionales `AMULE_WEB_PWD`/`AMULE_EC_PWD`), `multimedia-expose-torrent.sh` (exposición 6881), `amule-expose-p2p.sh` (exposición 4662/4672/4665), `install-multimedia-backup.sh`/`backup-multimedia.sh` (3 apps), `deploy-nodered.sh` (`NODERED_PASSWORD`), `deploy-mariadb.sh` (`MARIADB_*_PASSWORD`), `deploy-telegram-bot.sh` (`TELEGRAM_*`), `deploy-sdr.sh`, `deploy-ollama.sh`, `grafana-user.sh`, `ensure-public-dashboard.sh`, `computer_info.sh`. Retirados a `scripts/_retirado/`: `multimedia-wizard.sh`, `multimedia-language.sh`, `multimedia-verify.sh`.

## Referencias

- [README-TECH.md — Fase 12: Monitoreo y observabilidad](./README-TECH.md#fase-12--monitoreo-y-observabilidad)
- [README-TECH.md — Clave única de acceso web](./README-TECH.md#clave-única-de-acceso-web)
- [README-TECH.md — Web pública (landing)](./README-TECH.md#web-pública-landing)
- Manifiestos: `files/monitoring/grafana-ingress.yaml`, `files/nodered/`, `files/mariadb/`, `files/telegram-bot/`, `files/pdbs/`, `files/networkpolicies/`, `files/landing/`
