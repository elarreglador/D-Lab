# AGENTS.md — D-Lab

Vault Obsidian + scripts de despliegue K8s sobre LXC. **No hay código de app ni build/test/lint/CI ni `opencode.json`**. Documentación es el artefacto. Idioma: docs/commits en español, identificadores/scripts en inglés.

## Convenciones

- Commits en pretérito ("Despliega X", "Corrige Y"), descriptivos.
- Afirmaciones verificadas: `(verificado YYYY-MM-DD)` + comando exacto (p. ej. `curl -s -o /dev/null -w '%{http_code}' https://elarreglador.eu` → 200).
- `TODO.md` es el checklist vivo (Features / Fix / Tareas finalizadas).

## Secretos — regla crítica

- `info_sensible/` y `.worktrees/` están en `.gitignore`; nunca versionar.
- Credenciales fuera del repo: Grafana `elarreglador` (`scripts/grafana-user.sh` + `info_sensible/grafana-user.env`) y `admin` (Secret `kube-prometheus-stack-grafana` en `monitoring`); WireGuard en `~/server/wireguard/`; `values-monitoring.yaml` ya no existe en los masters.
- Scripts reciben claves por env (`NODERED_PASSWORD`, `MARIADB_ROOT_PASSWORD`, `MARIADB_PASSWORD`, `AMULE_WEB_PWD`/`AMULE_EC_PWD`, `TELEGRAM_BOT_TOKEN`) y crean Secrets por stdin (`kubectl apply -f -`) — nunca escribir claves en disco/repo.
- `files/wg0-client-*.conf` son plantillas con placeholders.

## Arquitectura (resumen)

| Host | Rol | IP LAN | IP WG | Notas |
|------|-----|--------|-------|-------|
| DV0 | VM IONOS: jumpbox, VPN, nginx stream | — | 10.8.0.1 | 394 MiB RAM; snapd inestable → `~/.local/bin/lxc` (`/snap/lxd/*/bin/lxc`) |
| D1 | OptiPlex 3050: k8s-master-1 (.21) + k8s-worker-1 (.31) | 192.168.1.11 | 10.8.0.11 | NVMe 238G + HDD 465G |
| D2 | OptiPlex 3050: k8s-master-2 (.22) + k8s-worker-2 (.32) | 192.168.1.12 | 10.8.0.12 | idem D1 |
| D3/D4 | OptiPlex 3040 **en incorporación** (Sep 2026) | 192.168.1.13/.14 | 10.8.0.13/.14 | 1×HDD 500G (8G swap + 50G `/` + resto PVC 400G); VGA requiere `nomodeset` en GRUB |
| G9 | Portátil cliente WG | 192.168.1.102 | 10.8.0.100 | split-tunnel |

- SSH **puerto 9622** (alias `D1`/`D2`/`server` en `~/.ssh/config`). Acceso externo solo vía DV0 WireGuard (`10.8.0.0/24`).
- CNI: **Flannel overlay + Calico policy-only** (`files/calico-policy-only.yaml` v3.32.1, fix `get clusterinformations`).
- Almacenamiento: **GlusterFS replica 2 + NFS-Ganesha + VIP `192.168.1.30` (Keepalived)** en workers. PVC `media-data` 400Gi. StorageClasses: `nfs-storage` (v3, sin locks) para `nodered-data`/`ollama-models`/`docs-cache`; `nfs-storage-v4` (v4, locks) para `media-data`/`mariadb-data`/`qbittorrent-config`/`amule-config`; `local-static` (hostPath `/srv/k8s-local/jellyfin`) para `jellyfin-config-local` (paracaídas; ver `incidentes/jellyfin-lentitud-20260906.md`).
- Red LAN: **MetalLB `192.168.1.50-.64`** (`files/metallb/config-dlab.yaml`). Asimétrico: cada host no alcanza las LB-IPs de sus propios LXC.

## Cómo se despliega

- **Ejecutar desde la raíz del repo** — los scripts calculan `BASE` relativo y hacen `ssh "$KUBECTL_HOST"` (default `server`, override `KUBECTL_HOST=...`). No se necesita `kubectl` local.
- Patrones: `cat files/.../*.yaml | ssh "$KUBECTL_HOST" "kubectl apply -f -"` o Scripts `scripts/deploy-*.sh` (`deploy-landing.sh`, `deploy-multimedia.sh`, `deploy-nodered.sh`, `deploy-mariadb.sh`, `deploy-ollama.sh`, `deploy-sdr.sh`, `deploy-telegram-bot.sh`, `deploy-cluster-ai.sh`).
- `deploy-landing.sh`: `files/landing/` → ConfigMap `landing-html` en `binaryData` base64 (fuentes `.woff2` en raíz; ConfigMap no admite `/`). Guard etcd ~1,5 MiB/objeto: avisa desde ~0,9 MiB, aborta ~1,35 MiB. **Obligatorio `kubectl apply --server-side`** (client-side duplica contenido en `last-applied` → tope 256 KiB y falla).
- `deploy-multimedia.sh`: idempotente; crea dir hostPath `/srv/k8s-local/jellyfin` en workers + `init-media-dirs` (symlinks `/data/torrents|amule → /data/media`) + garantiza `Secret jellyfin-apikey` + Job `jellyfin-ensure-apikey` (sqlite); despliega `qbittorrent`/`jellyfin`/`amule` + ingress/cert + `CronJob jellyfin-auto-scan` (horario) y `jellyfin-db-backup` (lun/jue 03:00).
- Verificación manual (sin tests automatizados): `ssh server "kubectl get nodes; kubectl get pods -A; kubectl get pvc -A"` + `curl -s -o /dev/null -w '%{http_code}' https://elarreglador.eu` (→200) / `grafana` / `nodered` / `jellyfin`. Almacenamiento: `gluster volume status vol-storage` + `showmount -e localhost | grep /vol-storage`.
- Arranque/parada controlados: **`scripts/D-lab_stop.sh` y `D-lab_start.sh`** se ejecutan **en local** vía SSH (`D1`/`D2`/`server`), no dentro de contenedores. Orden: workers primero, `k8s-master-1` el último; arranque verifica `wg-quick@wg0 active` → LXD → contenedores → `kubectl get --raw=/readyz` (quorum etcd 2/2) → nodos Ready → almacenamiento → workloads → `curl` públicos. **No usar `kubectl drain`** (PDBs `minAvailable:1` en réplica 1 lo bloquean).

## Documentación — fuentes de verdad

- **`README-TECH.md`** — guía técnica por fases, estado autoritativo (incluye troubleshooting K8s-en-LXC: `/dev/kmsg` → `/dev/console`, `mount -o remount,rw /proc/sys`, `security.nesting/privileged`, `failSwapOn:false`).
- **`03-Aplicaciones.md`** — inventario autoritativo de workloads/imágenes/storage/exposición (sin credenciales).
- `04-Operaciones.md` — procedimiento apagado/arranque + matriz de riesgos.
- `README.md` — vista divulgativa; `00-Requisitos.md`/`01-Network.md`/`02-vm.md`/`Hardware.md` — capas históricas (describen cluster inicial 2 contenedores; cruzar con README-TECH.md).
- `incidentes/` — postmortems con estructura fija (fecha, equipos, causa, solución, verificación `verificado YYYY-MM-DD`, lecciones). `files/` — manifiestos K8s; `scripts/` — despliegues.

## Gotchas operacionales

- **etcd 2 miembros = quorum 2/2**: caído un master → API sin escritura. Backups `files/backup-etcd.sh`/`backup-mariadb.sh` cron `02:00`/`03:00` en ambos masters (`/backup/etcd|mariadb/`); verificar `find /backup -mmin -1440 | wc -l` antes de parar.
- **Race GlusterFS↔NFS-Ganesha**: `nfs-ganesha` puede quedar `active` sin export (`showmount -e` vacío, log `Could not create export`). `D-lab_start.sh` lo detecta y hace `systemctl restart nfs-ganesha`; manual: `lxc exec k8s-worker-1 -- systemctl restart nfs-ganesha`.
- **Grafana efímero**: `persistence.enabled:false` + public dashboard efímero. Tras recrear pod, re-ejecutar `scripts/grafana-user.sh` y `scripts/ensure-public-dashboard.sh` (guarda URL en `info_sensible/public-dashboard.env`, usada por `deploy-landing.sh` para `__PUBLIC_DASHBOARD_URL__`; en Grafana 13 ruta es `/public-dashboards/<token>`, no `/public/dashboards/`).
- **PDB `minAvailable:1` en réplica única**: bloquea `drain`; parada graceful de LXC (`lxc stop --timeout 120`) hace SIGTERM limpio y desmonta NFS.
- **Calico token CNI** (`verificado 2026-09-06`): `calico-cni-plugin` usa Secret legacy `calico-cni-plugin-token` sin `exp`/`iat`; si `FailedCreatePodSandBox Unauthorized`, verificar `cat /etc/cni/net.d/calico-kubeconfig | grep token` vs Secret y rotar (ver `03-Aplicaciones.md`).
- **WireGuard split-tunnel**: D1/D2 `AllowedIPs 10.8.0.0/24,fd42:42:42::/64` (no `0.0.0.0/0`), DV0 `PostUp ip route replace 192.168.1.0/24 dev wg0`; `wg syncconf` no toca rutas — `wg-quick down/up` sí. `PersistentKeepalive 25` para NAT.
- **Vault Obsidian**: `.obsidian/` gitignored; enlaces internos markdown válidos.
