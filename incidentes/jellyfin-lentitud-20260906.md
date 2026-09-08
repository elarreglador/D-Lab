# Informe de Incidente: Jellyfin con rueda de carga y "servidor no disponible" intermitente

**Fecha:** 2026-09-06
**Equipos Afectados:** k8s-worker-1 (192.168.1.31) / k8s-worker-2 (192.168.1.32), VIP `192.168.1.30`, Jellyfin `jellyfin.elarreglador.eu` (`192.168.1.53:8096`, `10.111.42.207`)
**Estado:** RESUELTO
**Severidad:** Media (degradación de UX, sin pérdida de biblioteca)

## Descripción

Desde finales de agosto Jellyfin mostraba **rueda de carga prolongada** al abrir el home (`Resume`, `NextUp`, `Latest`) y, de forma intermitente, `servidor no disponible`. El pod `jellyfin-d5979f8c8-d4rhv` acumulaba `2 restarts (exit 137 Error)` en 6 días (`finishedAt 2026-09-06T09:06:07Z`) sin evento `OOMKilled`. En `ingress-nginx` el `12:14:46` seis `GET /Users/.../Items/Resume|Latest|NextUp` tardaron **29s** cada uno (`499` por timeout cliente en `12:13:45` con `searchTerm=mario` a `0.70s`), mientras `pod→svc` respondía en `0.003s` y `ingress 0.07s` fuera del pico.

## Causa Raíz

`jellyfin-config 2Gi RWO nfs-storage-v4` (`files/multimedia/storage.yaml:40` → `/config`) sobre GlusterFS replica 2 + NFS-Ganesha + Keepalived `VIP 192.168.1.30`. `jellyfin.db 7.8M` con `PRAGMA synchronous=1;Cache=Default` (`log 11:06:42`) sufre `fsync ~66 ms` en HDD replicado (`README-TECH.md:1045`, mismo gotcha que crash-loopeó Sonarr/Radarr el `2026-08-20`). `io.pressure some avg60=0.60` y `EF Core MultipleCollectionIncludeWarning` evidenciaron stall de I/O aleatorio; las probes `liveness/readiness timeout 1s period 10s failure 3` (`files/multimedia/jellyfin.yaml:56`) agravaban el `137 Error` bajo esa latencia. OOM descartado: `container_oom_events_total{jellyfin}=0`, `memory.peak 446Mi << limit 2Gi`, `workingSet 257Mi`.

## Solución Implementada

**Móvil con paracaídas** (mantiene `eu.elarreglador/worker=true`, sin perder movilidad):

1. **PVs locales** `files/multimedia/storage-local-jellyfin.yaml` — `2× PV local-static 2Gi` (`/srv/k8s-local/jellyfin` en `k8s-worker-1/2`, `Retain`, `nodeAffinity k8s-worker-1/2`) + `PVC jellyfin-config-local 2Gi RWO local-static` (`Bound` a `worker-1`).
2. **Jellyfin** `files/multimedia/jellyfin.yaml:36` — `resources 500m/512Mi→1 CPU/1Gi / 1/2Gi→1500m/3Gi`, probes `timeout 5s period 15s failure 6` (`liveness initialDelay 60s`), `emptyDir 1Gi` en `/config/cache`, `initContainer restore` (`alpine:3.19`, `subPath: backup/jellyfin` sobre `media-data`) que restaura `latest.tgz` si el `PV` local está vacío, `claimName: jellyfin-config-local`.
3. **Paracaídas** `files/multimedia/jellyfin-backup.yaml` — `CronJob jellyfin-db-backup` `0 3 * * 1,4` (lunes/jueves 03:00) recortado (`data/data + *.xml/json`, sin `metadata 641M` ni `cache 120-300M` → `2.5M` verificado), `find -mtime +60` (16 copias ≈128M en `media-data:/backup/jellyfin` sobre `458G 343G 97G 79%`).
4. **Despliegue** `scripts/deploy-multimedia.sh:27` — aplica `storage-local`, crea `mkdir -p /srv/k8s-local/jellyfin && chown 1000:1000` en ambos workers, espera `PVC Bound` y aplica `jellyfin-backup`.

Migración: `migrator` copió `jellyfin.db 7.8M` de `jellyfin-config (nfs)` a `jellyfin-config-local` en `worker-1` (`cp -av`).

## Verificación

* `jellyfin-799fd4d8fb-g25g4 1/1 Running k8s-worker-1 10.244.2.198` `Startup 0:00:22` (antes `0:01:12`), `io.pressure some avg60 0.00` (antes `0.60`), `curl -k https://jellyfin.elarreglador.eu/ → 302 0.07s → -L 200`, `pod→svc 302 0.003s`, `svc 10.111.42.207 192.168.1.53:8096` `certificate True`.
* `CronJob` manual `jellyfin-20260906-1338.tgz 2.5M` + `latest.tgz` en `/data/backup/jellyfin`, `kubectl apply --dry-run=client` sin errores.

## Lecciones Aprendidas

1. `local-static` es cirugía para `fsync` aleatorio; `emptyDir` para `transcodes` alivia pero no cura `jellyfin.db`.
2. `timeout 1s` en probes es agresivo sobre NFS; `5s` evita falsos `137 Error`.
3. Retención mínima `2` copias protege contra `latest.tgz` corrupto; `lunes/jueves 60d` equilibra RPO 3-4d con 128M.

## Recomendaciones

1. Conservar `jellyfin-config (nfs)` `Bound` 22d como respaldo hasta validar 2 ciclos de paracaídas; luego decidir borrado.
2. Vigilar `container_oom_events_total` y `io.pressure` tras transcodes `4K→1080p`; si `throttling >10%`, subir a `2 CPU`.
3. Failover a `k8s-worker-2` requiere borrar `PVC jellyfin-config-local` (`Retain` → `Released`) y `restore` desde `latest.tgz` (pérdida ≤4d).

## Referencias

* `files/multimedia/jellyfin.yaml`, `storage-local-jellyfin.yaml`, `jellyfin-backup.yaml`, `storage.yaml`
* `scripts/deploy-multimedia.sh`
* `03-Aplicaciones.md` § Stack multimedia simplificado (`verificado 2026-09-06`)
* `README-TECH.md` § Almacenamiento / Fase 8
