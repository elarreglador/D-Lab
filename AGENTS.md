# AGENTS.md — D-Lab

Vault de documentación (Obsidian) + scripts de despliegue del laboratorio casero D-Lab: cluster Kubernetes sobre LXC. El artefacto principal es la **documentación**; no hay código de aplicación ni sistema de build/test/lint. Todo está en español.

## Convenciones

- Docs, comentarios y commits en español; identificadores de código/scripts en inglés.
- Commits descriptivos en pretérito ("Despliega X", "Agrega Y").
- Las afirmaciones verificadas llevan fecha `(verificado YYYY-MM-DD)` y el comando usado en la verificación (p. ej. `curl -s -o /dev/null -w '%{http_code}' https://…` → esperar 200).

## Secretos: regla crítica

- `info_sensible/` está en `.gitignore` y nunca debe versionarse.
- Las credenciales viven fuera del repo: `/root/values-monitoring.yaml` en k8s-master-1 (admin de Grafana), `~/server/wireguard/` (claves WG).
- Los scripts de despliegue reciben las claves por variable de entorno (`NODERED_PASSWORD`, `MARIADB_ROOT_PASSWORD`, `MARIADB_PASSWORD`) y construyen el Secret por stdin (`kubectl apply -f -`) — nunca escribir claves en disco ni en el repo.
- `files/wg0-client-*.conf` son plantillas con placeholders, no claves reales.

## Arquitectura (resumen)

| Host | Rol | IP LAN | IP WG (10.8.0.0/24) |
|------|-----|--------|----------------------|
| DV0 | VM IONOS: jumpbox, VPN, nginx | — | 10.8.0.1 |
| D1 | OptiPlex: k8s-master-1 (.21) + k8s-worker-1 (.31) | 192.168.1.11 | 10.8.0.11 |
| D2 | OptiPlex: k8s-master-2 (.22) + k8s-worker-2 (.32) | 192.168.1.12 | 10.8.0.12 |

- SSH en puerto **9622** (no 22). Acceso externo solo vía DV0 (WireGuard).
- CNI: Flannel (overlay) + Calico policy-only. Almacenamiento: GlusterFS + NFS-Ganesha + VIP `192.168.1.30` (Keepalived).

## Cómo se despliega

- Scripts en `scripts/`, ejecutados **desde la raíz del repo** (calculan `BASE` relativo).
- Hacen `ssh "$KUBECTL_HOST"` (alias SSH por defecto `server`; override con env `KUBECTL_HOST`) y aplican manifiestos por stdin — no se necesita `kubectl` local.
- `deploy-landing.sh`: `files/landing/` → ConfigMap `landing-html`. Claves planas en `binaryData` base64. Guard por bandas frente al techo de etcd (~1,5 MiB/objeto): avisa desde ~0,9 MiB y aborta cerca de ~1,35 MiB (no bloquea en 1 MiB).
- Verificación manual: `curl` con código 200 y `kubectl get pods`. Sin tests automatizados.

## Documentación: fuentes de verdad

- **`README-TECH.md`** — guía técnica completa por fases; estado actual autoritativo (incluye Troubleshooting de K8s en LXC: kmsg, swap, /proc/sys, nesting).
- **`03-Aplicaciones.md`** — aplicaciones desplegadas y cómo actualizarlas (estado actual, sin credenciales).
- **`README.md`** — vista divulgativa no técnica.
- `00-Requisitos.md`, `01-Network.md`, `02-vm.md`, `Hardware.md` — capas del build; **parcialmente históricas** (describen el cluster inicial de 2 contenedores y contradicen el estado real). Cruzar siempre con README-TECH.md y 03-Aplicaciones.md.
- `incidentes/` — informes con estructura fija (fecha, equipos, causa raíz, solución, verificación, lecciones).
- **`04-Operaciones.md`** — apagado/arranque controlado del cluster (scripts `scripts/D-lab_stop.sh` y `scripts/D-lab_start.sh`; se ejecutan en local y actúan por SSH con los alias `D1`/`D2`/`server`).
- `files/` — manifiestos K8s y plantillas; `scripts/` — despliegues.

## Gotchas

- Vault Obsidian: `.obsidian/` está gitignored; los enlaces internos markdown son válidos.
- PDBs con `minAvailable: 1` sobre workloads de réplica única bloquean `kubectl drain`.
- El token CNI de Calico (`calico-cni-plugin`) expira; si aparecen `FailedCreatePodSandBox`, revisar (ver notas de 03-Aplicaciones.md).
- DV0 tiene 394 MiB de RAM: snapd es inestable; se usa el binario real de lxc en `~/.local/bin`.
