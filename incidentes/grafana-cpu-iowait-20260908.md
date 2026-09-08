# Informe de Incidente: Grafana mostraba 100% CPU en D2 por iowait contabilizado como ocupado

**Fecha:** 2026-09-08
**Equipos Afectados:** D2 (192.168.1.12), k8s-master-2 (192.168.1.22), k8s-worker-2 (192.168.1.32), Grafana `Sistema D-Lab` (monitoring)
**Estado:** RESUELTO (visualización corregida; causa raíz IO documentada)
**Severidad:** Baja (visualización) / Media (presión IO subyacente)

## Descripción

Grafana (dashboard `Sistema D-Lab` `files/monitoring/grafana-dashboard-sistema-dlab.yaml`) mostraba **100% CPU** constante en los tres paneles de D2 (`D2 · Host` `id:4`, `D2 · k8s-master-2` `id:5`, `D2 · k8s-worker-2` `id:6`), mientras `htop`/`top` en D2 indicaba CPU usuario+sistema ~15% y el señor reportaba que no era cierto. D1 y DV0 mostraban valores normales (73% y ~20%).

## Causa Raíz

**Fórmula histórica del dashboard** `03-Aplicaciones.md:151` (hasta 2026-09-08):

```promql
100 - avg by (host|instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100
```

En Linux `idle` es CPU sin trabajo, `iowait` es CPU ociosa esperando IO. La fórmula contaba `iowait` como ocupado, por lo que un host bloqueado en IO aparecía como 100% CPU aunque `top` separase `wa`.

**Estado real de D2 (verificado 2026-09-08):**

* Prometheus `curl -G /api/v1/query --data-urlencode "query=100 - avg by (host) (rate(node_cpu_seconds_total{job=\"host-node\",host=\"d2\",mode=\"idle\"}[5m]))*100"` → `100` ; `rate(iowait)` → `3.22/4 = 82%` ; `sum by(mode)` → `idle 0, iowait 3.22, system 0.26, user 0.33`
* D1 mismo query → `73.6%` con `iowait 1.9%`
* Host D2 `uptime` `load 12.16` `pressure io some 99.49% full 79.68%` `vmstat wa 89% b 10` `dmesg: task du:974319 blocked for 122s. folio_wait_writeback` ; `sda %util 0.008` (disco ocioso)
* `ps D` `folio_wait_bit_common → filemap_write_and_wait_range → nfs_getattr` sobre `/data/media/movies` (PVC `media-data` `VIP 192.168.1.30` Gluster replica 2 HDD `fsync ~66ms` `README-TECH.md:1045`, ambos bricks `97%` `421G/458G`, `Committed_AS 10.3G > CommitLimit 7.9G`). Pods en `k8s-worker-2` (`qbittorrent`, `amule`, `jellyfin-auto-scan`) ensucian páginas vía NFS; `ls/du` hacen `stat` y bloquean en `writeback` hasta que Gluster confirme ambas réplicas. `hostNetwork:true` del DaemonSet hace que los 3 paneles de D2 lean el mismo kernel host, de ahí el 100% triple.

No es bug de scrape (`up{host="d2"} 1`, `InternalIP 192.168.1.22/.32` correcto tras fix `incidentes/grafana-sin-datos-d2-mapeo-ip.md`), sino semántica.

## Solución Implementada

**Opción A2** — corrección de visualización + exposición de `iowait`:

1. **Dashboard** `files/monitoring/grafana-dashboard-sistema-dlab.yaml:62,115,167,220,274,327,379` (7 tarjetas): CPU pasa a `100 - (avg(rate(idle)) + avg(rate(iowait)))*100`, nueva serie `B` `avg(rate(iowait))*100` (`legendFormat: iowait`), RAM `B→C` (`C`). `kubectl apply --server-side -f files/monitoring/grafana-dashboard-sistema-dlab.yaml` → `configmap/grafana-dashboard-sistema-dlab serverside-applied`, sidecar `Writing /tmp/dashboards/sistema-dlab.json reload 200` (verificado 2026-09-08).

2. **Resultado** `curl -G /api/v1/query --data-urlencode "query=100 - (avg by (host) (rate(node_cpu_seconds_total{host=\"d2\",mode=\"idle\"}[5m])) + avg by (host) (rate(node_cpu_seconds_total{host=\"d2\",mode=\"iowait\"}[5m])))*100"` → `17.85%` CPU + `82.14%` iowait (D1 `39.6%` + `1.9%`), coherente con `pidstat us 8% sy 6%`.

## Verificación

* `kubectl -n monitoring get configmap grafana-dashboard-sistema-dlab -o jsonpath='{.data.sistema-dlab\.json}' | python3 -m json.tool` → 7 paneles con 3 targets `A:CPU B:iowait C:RAM`
* `kubectl -n monitoring logs deploy/kube-prometheus-stack-grafana -c grafana-sc-dashboard --tail=5` → `Response: 200`
* `curl -G .../api/v1/query` con nueva PromQL → D2 `17.85%` (antes `100%`)
* `https://grafana.elarreglador.eu` y `public-dashboards/<token>` → `200`

## Lecciones Aprendidas

1. `100 - idle` funde `iowait` con CPU ocupado; para laboratorio con Gluster/NFS sobre HDD es engañoso. Separar `iowait` visibiliza la contención de almacenamiento sin falsear el umbral `60/85`.
2. `pressure io`, `load` y `sda %util` deben leerse juntos: `some 99%` con `util 0.8%` apunta a bloqueo NFS/Gluster, no a disco.
3. `Committed_AS > CommitLimit` + bricks `97%` agravan `fsync ~66ms` y el `folio_wait_writeback` bajo `nfs_getattr`.

## Recomendaciones

1. Mantener `iowait` como serie propia; evaluar panel `timeseries` dedicado de `iowait` si vuelve a >30%.
2. Vigilar capacidad `media-data` por debajo de `85%` (hoy `97%`); rotar torrents y limpiar `archived-*` en `/mnt/data-d2/brick`.
3. Evaluar `mountOptions` `actimeo=60` en `StorageClass nfs-storage-v4` para reducir `getattr` y/o mover `qbittorrent` junto al VIP (`k8s-worker-1`) para evitar RTT.
4. Documentar PromQL con `verificado 2026-09-08` y comando `curl -s -G .../api/v1/query --data-urlencode "query=..."`.

## Referencias

* `files/monitoring/grafana-dashboard-sistema-dlab.yaml:62,115,167,220,274,327,379`
* `03-Aplicaciones.md#grafana` (PromQL corregida)
* `README-TECH.md#fase-12--monitoreo-y-observabilidad`
* `incidentes/grafana-sin-datos-d2-mapeo-ip.md` (mapeo IP determinista)
* `01-Network.md` (WireGuard), `04-Operaciones.md` (apagado/arranque)
