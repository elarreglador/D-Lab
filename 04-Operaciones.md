# 04-Operaciones — Apagado y arranque controlado del cluster

**Objetivo**: apagar y encender el cluster D-Lab (D1 + D2) de forma controlada y segura, minimizando el riesgo de problemas tanto durante el apagado como durante el arranque.

**Estado**: procedimiento validado con arranque real del cluster `(verificado 2026-08-14)` y ciclo completo apagado/encendido con mapeo IP permanente `(verificado 2026-08-28)`. Observaciones del drill:
- El race GlusterFS↔NFS-Ganesha se manifestó tal como se documenta: `nfs-ganesha` quedaba `active` (systemd) **sin export creado** (`showmount` vacío), por lo que los montajes NFS fallaban con `access denied`. Tras el drill se reforzó el script para detectar y auto-reparar esta condición (ver [Arranque controlado](#arranque-controlado)).
- El 2026-08-28 se detectó Grafana sin datos en `k8s-master-2`/`k8s-worker-2` por `kubelet` sin `--node-ip` (`InternalIP` `10.244.x.0` en vez de `192.168.1.x`); se fijó `--node-ip` permanente (`.21/.22/.31/.32`) y se corrigió el dashboard `D1 · k8s-worker-1` de `192.168.1.30:9100` a `31:9100` (ver `incidentes/grafana-sin-datos-d2-mapeo-ip.md`).

**Alcance**: cluster Kubernetes + hosts D1/D2. En un apagado normal **DV0 se deja encendido** (preserva WireGuard, nginx y el acceso remoto); para apagado total del laboratorio usar `INCLUDE_DV0=1`.

---

## Por qué este orden (y no otro)

| Componente | Riesgo si se ignora el orden |
|------------|------------------------------|
| **etcd** (stacked, 2 miembros, quorum 2/2) | Un solo master no alcanza quorum → el API Server no opera. Ambos masters deben arrancar y quedar sanos. En el apagado, `k8s-master-1` (quien sirve kubectl) se apaga el último. |
| **GlusterFS replica 2 + NFS-Ganesha** | NFS-Ganesha puede fallar al arrancar si GlusterFS no está listo aún (race documentado). Verificar `glusterd` → volumen → `nfs-ganesha` (reiniciar si procede) → `keepalived`/VIP. |
| **PDB `minAvailable: 1` en réplica única** | Bloquean `kubectl drain`. Por eso el apagado **no usa drain**: la parada graceful de LXC envía SIGTERM (systemd) y desmonta los volúmenes NFS limpiamente. |
| **LXD cluster (D1 leader, D2 standby)** | Los contenedores **no auto-arrancan** con el host (sin `boot.autostart`): hace falta `lxc start` explícito tras cada boot. |
| **DV0 (jumpbox / WG / nginx)** | Es la puerta de entrada: se apaga el último (apagado total) y arranca el primero. |
| **WireGuard (`wg-quick@wg0` en D1/D2)** | Los proxies LXC (p. ej. `10.8.0.11:6443`) escuchan en la IP WG del host. Al arrancar hay que esperar a que esté **active antes de `lxc start`**; al apagar **no se toca** (se detiene solo con el `poweroff` del host). |

## Inventario relevante

| Contenedor | Host | Rol | Servicios destacados |
|------------|------|-----|----------------------|
| k8s-master-1 | D1 | control-plane | etcd, apiserver, scheduler, controller-manager, kubectl, cron backups |
| k8s-worker-1 | D1 | worker | kubelet, **GlusterFS + NFS-Ganesha (MASTER) + Keepalived (VIP)** |
| k8s-master-2 | D2 | control-plane | etcd, apiserver, scheduler, controller-manager, cron backups |
| k8s-worker-2 | D2 | worker | kubelet, **GlusterFS + NFS-Ganesha (BACKUP) + Keepalived** |

- SSH hosts: D1 `192.168.1.11`, D2 `192.168.1.12`, puerto 9622 (alias `D1`/`D2` en `~/.ssh/config`).
- kubectl vía `KUBECTL_HOST` (alias `server`; p. ej. DV0 con kubeconfig a `https://10.8.0.11:6443`).
- Servicios públicos servidos por el cluster: `elarreglador.eu` (landing, público), `grafana.elarreglador.eu`, `nodered.elarreglador.eu` (con login).

### Requisitos de operación (hosts)

- **SSH sin contraseña** a `D1`/`D2` (y `DV0`): puerto 9622, ya configurado en `~/.ssh/config`.
- **sudo sin contraseña** (NOPASSWD) en D1, D2 y DV0: los scripts ejecutan `sudo poweroff` y `sudo systemctl start …` sin prompt. Configurado vía `/etc/sudoers.d/dlab` (permite `poweroff`, `systemctl` y `true`) `(verificado 2026-08-10)`. Verificar con `ssh D1 "sudo -n true"` (debe volver sin pedir clave).
- **WireGuard activo** en D1/D2: `wg-quick@wg0` está `enabled` y se regenera solo en cada boot (split-tunnel). **No se apaga a mano**: se detiene con el `poweroff` del host.

---

## Antes de apagar (pre-check)

1. **Cluster sano y backups frescos**:

```bash
ssh server "kubectl get nodes"              # los 4 Ready
ssh server "kubectl get pods -A -o wide"    # sin CrashLoopBackOff relevantes

# backups de las últimas 24 h en ambos masters (cron: etcd 02:00, mariadb 03:00)
ssh D1 "lxc exec k8s-master-1 -- find /backup/etcd    -type f -mmin -1440 | wc -l"   # ≥ 1
ssh D1 "lxc exec k8s-master-1 -- find /backup/mariadb -type f -mmin -1440 | wc -l"   # ≥ 1
ssh D2 "lxc exec k8s-master-2 -- find /backup/etcd    -type f -mmin -1440 | wc -l"   # ≥ 1
ssh D2 "lxc exec k8s-master-2 -- find /backup/mariadb -type f -mmin -1440 | wc -l"   # ≥ 1
```

2. **Si no hay backups recientes**, generarlos a mano:

```bash
ssh D1 "lxc exec k8s-master-1 -- /usr/local/bin/backup-etcd.sh"
ssh D2 "lxc exec k8s-master-2 -- /usr/local/bin/backup-etcd.sh"
ssh D1 "lxc exec k8s-master-1 -- /usr/local/bin/backup-mariadb.sh"
ssh D2 "lxc exec k8s-master-2 -- /usr/local/bin/backup-mariadb.sh"
```

3. **Alertas**: en Grafana solo deben estar *firing* las de diseño (`TargetDown`, `etcdMembersDown`, `Watchdog`).
4. **Anotar el estado** de referencia: `ssh server "kubectl get nodes -o wide"` (IPs y pods por nodo).

---

## Apagado controlado

### Automático (recomendado)

```bash
./scripts/D-lab_stop.sh
```

Incluye el pre-check, pide confirmación y aborta con mensaje claro si algo falla. Opciones y variables:

| Opción / variable | Efecto |
|-------------------|--------|
| `--skip-preflight` | Omite el pre-check de cluster y backups |
| `--yes` | No pide confirmación interactiva |
| `KUBECTL_HOST=server` | Host con kubectl (por defecto `server`) |
| `D1_HOST=D1` / `D2_HOST=D2` | Alias SSH de los hosts |
| `INCLUDE_DV0=1` | Apaga también DV0 al final (apagado total) |
| `DV0_HOST=DV0` | Alias SSH de DV0 (solo con `INCLUDE_DV0=1`) |
| `STOP_TIMEOUT=120` | Segundos de espera por contenedor (parada graceful) |

> **WireGuard no se apaga**: es un servicio del host; `sudo poweroff` lo detiene con el host y se regenera solo en el siguiente arranque. El script solo exige `sudo -n` (NOPASSWD) en los hosts que va a apagar.

### Manual (equivalente)

1. **Parada graceful de contenedores** — workers primero, `k8s-master-1` el último:

```bash
ssh D2 "lxc stop --timeout 120 k8s-worker-2"
ssh D1 "lxc stop --timeout 120 k8s-worker-1"
ssh D2 "lxc stop --timeout 120 k8s-master-2"
ssh D1 "lxc stop --timeout 120 k8s-master-1"
```

Verificar: `ssh D1 "lxc list"` → los 4 `STOPPED`.

2. **Apagar los hosts** (D2 antes que D1, que es el leader del cluster LXD):

```bash
ssh D2 "sudo poweroff"
ssh D1 "sudo poweroff"
```

3. *(Opcional, apagado total)* DV0 al final:

```bash
ssh DV0 "sudo poweroff"
```

> No hace falta parar el daemon LXD a mano: `poweroff` lo detiene limpiamente vía systemd.

---

## Arranque controlado

### Automático (recomendado)

```bash
./scripts/D-lab_start.sh
```

El script: espera a que D1/D2 respondan por SSH (hay que **encenderlos físicamente**), espera a que **WireGuard esté activo en D1/D2** (los proxies LXC bindean la IP WG del host, p. ej. `10.8.0.11:6443`; sin WG no hay API Server ni exposición vía DV0), comprueba **sudo sin contraseña**, asegura el daemon LXD, espera al cluster LXD, arranca los 4 contenedores, espera el API Server (quorum etcd), espera nodos `Ready`, verifica el almacenamiento, espera los workloads, comprueba los endpoints públicos y el estado de WireGuard. Variables iguales que en el apagado, más `START_TIMEOUT=600` (espera total para SSH/API/nodos).

> **Race GlusterFS ↔ NFS-Ganesha (auto-reparado por el script)**: `nfs-ganesha` puede quedar `active` aunque su export no se haya creado (si arrancó antes de que `glusterd` estuviera listo; log: `Could not create export for (/vol-storage)`). El script, tras confirmar `active`, verifica el export con `showmount -e localhost` y, si `/vol-storage` no aparece, **reinicia `nfs-ganesha` y re-verifica**. Si tras el reinicio el export sigue ausente, avisa explícitamente (los PVCs de `pods/mariadb` y `pods/nodered` fallarían). `(verificado 2026-08-14)`

### Manual (equivalente)

1. **Encender físicamente D1 y D2** (y DV0 si es apagado total). Esperar a que respondan.
2. **Esperar a que WireGuard esté activo en D1 y D2** (los proxies LXC hacia el cluster escuchan en su IP WG; sin WG no llegan las peticiones vía DV0):

```bash
ssh D1 "systemctl is-active wg-quick@wg0"   # → active
ssh D2 "systemctl is-active wg-quick@wg0"   # → active
```

> Normalmente ya está `active` al arrancar el host (servicio `enabled`); si tardara, esperar y revisar [01-Network.md](./01-Network.md#wireguard-estabilidad-y-split-tunnel).

3. **Levantar LXD** (si no estuviera) y esperar al cluster:

```bash
ssh D1 "sudo systemctl start snap.lxd.daemon.unix.socket snap.lxd.daemon.service"
ssh D2 "sudo systemctl start snap.lxd.daemon.unix.socket snap.lxd.daemon.service"
ssh D1 "lxc cluster list"    # ambos miembros ONLINE
```

4. **Arrancar los 4 contenedores** (los workers son pasivos hasta que el control-plane esté listo):

```bash
ssh D1 "lxc start k8s-master-1 && lxc start k8s-worker-1"
ssh D2 "lxc start k8s-master-2 && lxc start k8s-worker-2"
```

5. **Esperar quorum de etcd / API Server / nodos**:

```bash
ssh server "kubectl get --raw=/readyz"   # → ok (implica quorum de etcd en ambos masters)
ssh server "kubectl get nodes"           # → los 4 Ready
```

6. **Verificar almacenamiento** (orden: glusterd → volumen → ganesha → VIP):

```bash
ssh D1 "lxc exec k8s-worker-1 -- systemctl is-active glusterd nfs-ganesha keepalived"
ssh D2 "lxc exec k8s-worker-2 -- systemctl is-active glusterd nfs-ganesha keepalived"
# si nfs-ganesha no está active, reiniciarlo (race conocido con glusterd):
ssh D1 "lxc exec k8s-worker-1 -- systemctl restart nfs-ganesha"
ssh D2 "lxc exec k8s-worker-2 -- systemctl restart nfs-ganesha"
# volumen y VIP:
ssh D1 "lxc exec k8s-worker-1 -- gluster volume status vol-storage"
ssh D1 "lxc exec k8s-worker-1 -- ip -4 addr show eth0 | grep 192.168.1.30"   # VIP en MASTER
```

7. **Si algún nodo no queda `Ready`** (kubelet), aplicar el [Troubleshooting de K8s en LXC](./README-TECH.md#troubleshooting-kubernetes-en-lxc): symlink `/dev/kmsg`, `mount -o remount,rw /proc/sys` (el `failSwapOn: false` ya está persistido en la config de kubelet).
8. **Verificar workloads y exposición pública** (ver tabla siguiente).

---

## Especificación 01 — AdGuard Home: runbook de rescate y cutover

AdGuard Home resuelve el DNS de la LAN en `192.168.1.61` (namespace `adguard`, spec [01](./specs/01-adguard-home.md)). Hasta que el router apunte a él, **nadie depende de AdGuard**; tras el cutover, el runbook siguiente es la ruta de vuelta si el DNS de la LAN colapsa.

### Verificación rápida (post-despliegue o post-arranque)

| Check | Comando | Esperado |
|-------|---------|----------|
| Pod | `ssh server "kubectl -n adguard get pods"` | `adguard-*` `1/1 Running`; `adguard-seed-config-*` `Completed` |
| PVC | `ssh server "kubectl -n adguard get pvc"` | `adguard-data` `Bound` |
| Resolución | `dig +short @192.168.1.61 elarreglador.eu` | `82.223.50.169` |
| Bloqueo | `dig +short @192.168.1.61 doubleclick.net` | `0.0.0.0` |
| Panel | `curl -s -o /dev/null -w '%{http_code}' https://adguard.elarreglador.eu/login.html` | `200` |
| Alerta | Alertmanager → Telegram | solo `AdguardDown` si el pod no está `Running` |

### Cutover del router (paso 8 de la spec — requiere acceso a la web del router)

Router: **H3600P V9.0** (interfaz ZTE, firmware `V9.0.0P5_DIGI`). Login `http://192.168.1.1/` (solo alcanzable desde la LAN; DV0/G9 no llegan por WireGuard). Credenciales de administración en `info_sensible/router.env` (gitignored).

> **Previo**: probar aquí mismo la Vía A de rescate (hotspot + `ssh server "kubectl -n adguard get pods"`) **antes** de tocar el router. `(verificado 2026-10-11`)`

Configuración objetivo y **estado actual `(verificado 2026-10-11)`**:
1. **Red local → LAN → IPv4 → «Servidor DHCP»**: `Servidor DHCP: Activado`; **`ISP DNS: Desactivado`**; **DNS principal `192.168.1.61`**; **DNS secundario `0.0.0.0`** (vacío — no mezclar con 8.8.8.8: un fallo de AdGuard ocultaría el problema).
2. **Red local → LAN → IPv6**: **`Servidor DHCPv6: Desactivado`** y **`Servicio RA: Desactivado`** (cierra el bypass de DNS IPv6: el router ya no anuncia DNS v6 por RA/DHCPv6; los clientes conservan IPv4).
3. Aplicar y **renovar la concesión del cliente** (modo avión/WiFi off/on). Verificación: ajustes WiFi → DNS `192.168.1.61`; en el móvil `elarreglador.eu` resuelve y los anuncios no cargan; si falla → **Vía A de rescate** (abajo).
4. Sweep de equipos: al renovar el DHCP dejan de recibir el DNS del ISP. Inspeccionar `Query Log` del panel de AdGuard para confirmar clientes.

### Cutover de G9 (paso 9 — el último)

```bash
nmcli connection modify DIGIFIBRA-PLUS-eQeY ipv4.dns 192.168.1.61 ipv4.ignore-auto-dns yes ipv6.method disabled
nmcli connection up DIGIFIBRA-PLUS-eQeY
dig elarreglador.eu          # → 82.223.50.169
dig doubleclick.net          # → 0.0.0.0
```

Tras este paso, **el portátil del señor (y el agente que corre en él) deja de resolver por 8.8.8.8** y depende de AdGuard: si la LAN se rompe, la Vía A de rescate requiere pasar el DNS del ordenador a otro dispositivo del hotspot (o a 8.8.8.8 vía nmcli, con acceso físico a la LAN).

### Runbook de rescate

- **Vía A — DNS LAN caído pero cluster operativo** (prioridad): el IP local del host sigue libre →
  1. Móvil → **hotspot** (compartir datos; el ordenador se conecta al WiFi del móvil, no al router).
  2. `mkdir -p ~/.ssh && ssh server "kubectl -n adguard get pods"` (kubeconfig local; el nombre `server` vive en `~/.ssh/config` del SEÑOR).
     - Si el cluster está caído, la prioridad es **arrancarlo** (`./scripts/D-lab_start.sh` desde el repo local) y re-verificar; AdGuard vuela con el cluster (pods en workers + PVC NFS + VIP Ganesha).
  3. Si el pod está `Running` pero el DNS no responde: `ssh server "kubectl -n adguard logs deploy/adguard --tail=50"`; si `AdGuardHome.yaml` quedó corrupto, restaurar desde Git (`files/adguard/seed-config.yaml`) con `./scripts/deploy-adguard.sh`.
- **Vía B — router inaccesible / se quiere volver atrás** (el señor, con acceso al ordenador):
  - Solo G9: `nmcli connection modify DIGIFIBRA-PLUS-eQeY ipv4.dns "8.8.8.8,1.1.1.1" ipv4.ignore-auto-dns no` y `nmcli connection up DIGIFIBRA-PLUS-eQeY`.
  - El resto de la LAN: el router vuelve a su DNS defecto si se dejan los campos secundarios/primarios como estaban; AdGuard deja de ser crítico (no obstante, **no desplegar a la inversa**: la VIP `.61` solo la usa AdGuard).
- **Escape definitivo**: `ssh server "kubectl -n adguard scale deploy/adguard --replicas=0"` y luego el router a su DNS original → `dig elarreglador.eu` desde la LAN recupera `82.223.50.169`. La alerta `AdguardDown` se disparará en ~2 min (responder a Telegram, no desatender).

---

## Verificación post-arranque

| Check | Comando | Esperado |
|-------|---------|----------|
| Nodos | `kubectl get nodes` | 4 `Ready` |
| Pods | `kubectl get pods -A` | `Running` (o `Completed`) |
| PVC | `kubectl get pvc -A` | `Bound`; mariadb/nodered sin errores de montaje |
| Almacenamiento | `gluster volume status vol-storage` | bricks `Online` (heal pendiente no crítico, se autosana) |
| VIP | `ip addr show eth0` en k8s-worker-1 | `192.168.1.30` presente |
| Landing | `curl -s -o /dev/null -w '%{http_code}' https://elarreglador.eu` | `200` |
| Grafana | ídem `https://grafana.elarreglador.eu` | `200` (página de login) |
| Node-RED | ídem `https://nodered.elarreglador.eu` | `200` (página de login) |
| AdGuard | `ssh server "kubectl -n adguard get pods"` + `dig @192.168.1.61 elarreglador.eu` | pod `Running` y DNS responde (si el cutover ya está hecho) |
| WireGuard hosts | `systemctl is-active wg-quick@wg0` en D1/D2 | `active` (split-tunnel se regenera en cada boot) |
| Alertas | Grafana | solo las de diseño |

---

## Riesgos y mitigaciones

| Riesgo | Probabilidad | Mitigación |
|--------|--------------|------------|
| etcd sin quorum tras el arranque (un master no levanta) | Baja (parada limpia) | Arrancar **ambos** masters y verificar `readyz`. Si un etcd no arranca, usar DR: `etcdctl snapshot restore` ([incidentes/dr-restore.md](./incidentes/dr-restore.md)). |
| NFS-Ganesha no arranca tras un glusterd lento | Media (conocido) | El arranque automático verifica el export (`showmount -e localhost`) y reinicia `nfs-ganesha` si no aparece, con re-verificación. `(verificado 2026-08-14)` |
| Nodo `NotReady` por kubelet en LXC (`/proc/sys`, kmsg) | Baja (config persistida) | Aplicar el troubleshooting de K8s en LXC de README-TECH.md. |
| PDB bloqueando evictions | n/a | No se usa `drain` en apagado total. Para mantenimiento de **un solo** nodo, ver nota de PDBs en [03-Aplicaciones.md](./03-Aplicaciones.md). |
| Ruteo WireGuard roto tras boot | Baja (split-tunnel) | El arranque automático espera `wg-quick@wg0` activo en D1/D2 antes de levantar los contenedores. Si hay bucles de ruteo, seguir [01-Network.md](./01-Network.md#wireguard-estabilidad-y-split-tunnel). |
| **DNS LAN caído tras el cutover de AdGuard** | Media (depende del cluster) | Alerta `AdguardDown` → Telegram; si es cluster caído, `D-lab_start.sh`; si es solo DNS, runbook de la especificación 01 (Vía A hotspot o Vía B nmcli 8.8.8.8). **Probar la Vía A antes de tocar el router.** |
| Corte de luz durante el proceso | Baja (SAI) | El SAI cubre micro-cortes. Apagar siempre con `poweroff`, nunca con el botón. |

---

## Referencias

- [README-TECH.md — Troubleshooting de K8s en LXC](./README-TECH.md#troubleshooting-kubernetes-en-lxc)
- [README-TECH.md — Fase 8: Almacenamiento (GlusterFS + NFS-Ganesha + Keepalived)](./README-TECH.md)
- [README-TECH.md — Fase 13: Resiliencia y HA (etcd)](./README-TECH.md)
- [incidentes/dr-restore.md](./incidentes/dr-restore.md) — estrategia de disaster recovery de etcd
- [01-Network.md — Gestión remota desde DV0](./01-Network.md#gestión-remota-desde-dv0)
- `files/backup-etcd.sh`, `files/backup-mariadb.sh` — copias canónicas de los scripts de backup
