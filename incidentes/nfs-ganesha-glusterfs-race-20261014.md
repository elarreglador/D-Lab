# Informe de Incidente: Race Condition NFS-Ganesha / GlusterFS tras Fallo de Alimentación

**Fecha:** 2026-10-14
**Equipos Afectados:** `k8s-worker-1` (192.168.1.31), `k8s-worker-2` (192.168.1.32), namespace `adguard`, PVC `adguard-data`
**Estado:** RESUELTO
**Severidad:** Alta (AdGuard DNS inoperativo → toda la LAN sin resolución filtrada)

---

## Descripción

Tras un fallo de alimentación en D1 y D2 (transformador defectuoso), ambos hosts se reiniciaron. Al arrancar, los contenedores LXC y el cluster Kubernetes subieron correctamente (4 nodos Ready), pero **AdGuard Home** quedó en estado `Unknown` / `0/1 Ready` sin poder montar su PVC `adguard-data`.

**Síntomas:**
- `kubectl -n adguard get pods` → `adguard-* 0/1 Unknown`, `READY 0/1`
- `describe pod` → `FailedMount: mount.nfs: No such file or directory` sobre `192.168.1.30:/vol-storage/adguard-adguard-data-pvc-...`
- `dig @192.168.1.61 elarreglador.eu` → timeout (AdGuard DNS no respondía)
- Todo el stack multimedia (Jellyfin, qBittorrent, aMule) funcionaba (sus PVCs ya existían y estaban exportados por NFS)

**Impacto:** Los clientes LAN (WiFi DIGIFIBRA) con DNS = router (192.168.1.1) → AdGuard (192.168.1.61) perdían resolución filtrada. La landing `elarreglador.eu` y subdominios no cargaban. TV y smartphone afectados.

---

## Causa Raíz

**Race condition en el arranque de servicios de almacenamiento en los workers:**

1. **Orden de arranque tras power-on:**
   - Host D1/D2 → LXD → contenedores (`k8s-worker-1/2`) → systemd dentro del contenedor
   - Dentro del contenedor: `glusterd` + `nfs-ganesha` + `keepalived` se inician en paralelo (no hay dependencia `After=` entre ellos)

2. **El problema:**
   - `nfs-ganesha` inicia **antes** de que `glusterd` haya conectado al peer y montado el volumen `vol-storage` via FUSE
   - `nfs-ganesha` escanea `/mnt/data/brick/` (o `/vol-storage` via libgfapi) al arrancar y construye su tabla de exports
   - Si el subdirectorio del PVC nuevo (`adguard-adguard-data-pvc-...`) **no existe aún** en el brick (porque GlusterFS no ha replicado/montado), NFS-Ganesha **no lo exporta**
   - El directorio **sí se crea después** (por el provisioner NFS al hacer bind-mount del PVC), pero NFS-Ganesha **no detecta la creación** (no hay inotify/re-export automático)

3. **Resultado:** El export base `/vol-storage` está visible (`showmount -e 192.168.1.30` → `/vol-storage (everyone)`), pero el subdirectorio concreto del PVC **no**.

4. **El pod AdGuard** intenta montar `192.168.1.30:/vol-storage/adguard-adguard-data-pvc-...` → `No such file or directory` → `FailedMount` → `Unknown`.

---

## Evidencia (verificado 2026-10-14)

```
# En k8s-worker-2 (brick GlusterFS):
lxc exec k8s-worker-2 -- ls -la /mnt/data/brick/ | grep adguard
→ drwxrwxrwx   3 root  root  4096 Oct 14 09:00 adguard-adguard-data-pvc-023bd992-...  ← EXISTE en brick

# En NFS-Ganesha (worker-1) ANTES del fix:
showmount -e 192.168.1.30
→ Export list for 192.168.1.30:
   /vol-storage (everyone)                              ← SOLO el export base

# Pod AdGuard:
Events:
  Warning  FailedMount  20s (x50 over 85m)  kubelet
    MountVolume.SetUp failed for volume "pvc-023bd992-..."
    mount.nfs: mounting 192.168.1.30:/vol-storage/adguard-adguard-data-pvc-... failed, reason given by server: No such file or directory

# Logs AdGuard (tras reinicio manual del pod):
2026/10/14 11:39:22 [info] starting adguard home version="v0.107.79"
2026/10/14 11:39:22 [info] webapi: AdGuard Home is available at ...
2026/10/14 11:39:24 [error] dnsproxy: upstream 10.96.0.10:53 i/o timeout (PTR internos, irrelevante)
```

---

## Solución Aplicada

1. **Refrescar exports NFS-Ganesha en ambos workers:**
   ```bash
   lxc exec k8s-worker-1 -- systemctl restart nfs-ganesha
   lxc exec k8s-worker-2 -- systemctl restart nfs-ganesha
   ```

2. **Verificar export del subdirectorio:**
   ```bash
   lxc exec k8s-worker-1 -- showmount -e 192.168.1.30
   → /vol-storage (everyone)
   → /vol-storage/adguard-adguard-data-pvc-... (everyone)  ← AHORA VISIBLE
   ```

3. **Rollout restart del deployment AdGuard (re-mount):**
   ```bash
   kubectl -n adguard rollout restart deploy/adguard
   ```

4. **Verificación final:**
   - Pod `adguard-b5cb6f7bb-5j62x` → `1/1 Running`, `Ready`
   - `dig @192.168.1.61 elarreglador.eu` → `82.223.50.169`
   - `dig @192.168.1.61 doubleclick.net` → `0.0.0.0`
   - `https://elarreglador.eu` → `200`

---

## Lecciones Aprendidas

1. **NFS-Ganesha no vigila creación de subdirectorios.** El export se construye al inicio. Si GlusterFS no está listo, los PVCs creados *después* del arranque de NFS-Ganesha no se exportan.

2. **El script `D-lab_start.sh` ya contempla esto**, pero solo si se ejecuta **tras** el arranque completo. En este caso, los hosts arrancaron solos (power-on) y los servicios subieron en orden no determinista.

3. **`showmount -e` solo muestra exports de nivel superior.** Un export `/vol-storage` visible **no garantiza** que los subdirectorios sean accesibles.

4. **Los PVCs preexistentes funcionaron** porque sus directorios ya existían en el brick antes del reinicio y NFS-Ganesha los exportó al arrancar. El PVC nuevo (`adguard-data`, creado 2026-10-11) fue el único afectado.

---

## Propuesta de Prevención (para que no vuelva a ocurrir)

### Opción A: systemd `After=` + `Wants=` (recomendada, bajo impacto)

En **ambos workers** (`k8s-worker-1` y `k8s-worker-2`), editar el servicio `nfs-ganesha` para que espere a `glusterd`:

```bash
# En cada worker (como root):
mkdir -p /etc/systemd/system/nfs-ganesha.service.d/
cat > /etc/systemd/system/nfs-ganesha.service.d/override.conf << 'EOF'
[Unit]
After=glusterd.service
Wants=glusterd.service
EOF
systemctl daemon-reload
```

**Por qué funciona:** `glusterd` tarda ~10-15s en conectar peer, montar FUSE y poblar `/mnt/data/brick/`. Con `After=`, `nfs-ganesha` no inicia hasta que `glusterd` reporta `active`.

**Verificación:**
```bash
systemctl show nfs-ganesha -p After,Wants
# Debe incluir glusterd.service
```

### Opción B: Script de "warm-up" en `ExecStartPre` de nfs-ganesha

Añadir un `ExecStartPre` que espere a que GlusterFS esté listo:

```bash
cat > /etc/systemd/system/nfs-ganesha.service.d/wait-gluster.conf << 'EOF'
[Service]
ExecStartPre=/bin/bash -c 'for i in {1..30}; do gluster peer status 2>/dev/null | grep -q "Connected" && gluster volume status vol-storage 2>/dev/null | grep -q "Started" && break; sleep 2; done'
EOF
systemctl daemon-reload
```

### Opción C: Añadir reinicio de nfs-ganesha al `D-lab_start.sh` (ya existe, reforzar)

En `scripts/D-lab_start.sh`, tras verificar GlusterFS conectado, forzar reinicio:

```bash
# Ya existe en D-lab_start.sh (línea ~XX):
# "systemctl restart nfs-ganesha" en ambos workers
# Asegurar que se ejecute SIEMPRE, no solo si falla showmount
```

### Opción D: systemd `Restart=on-failure` + `StartLimitIntervalSec=0` en nfs-ganesha

Si NFS-Ganesha falla al arrancar (porque Gluster no listo), que reintente automáticamente:

```bash
cat > /etc/systemd/system/nfs-ganesha.service.d/restart.conf << 'EOF'
[Service]
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=0
EOF
systemctl daemon-reload
```

---

## Recomendación Final

**Implementar Opción A (`After=glusterd.service` + `Wants=glusterd.service`)** en ambos workers. Es la solución más limpia, declarativa y compatible con systemd. No requiere scripts adicionales ni lógica de reintentos.

**Pasos para aplicar:**

```bash
# En D1 (k8s-worker-1)
ssh -p 9622 elarreglador@192.168.1.11 "
  lxc exec k8s-worker-1 -- bash -c '
    mkdir -p /etc/systemd/system/nfs-ganesha.service.d/
    cat > /etc/systemd/system/nfs-ganesha.service.d/override.conf << \"EOFF\"
[Unit]
After=glusterd.service
Wants=glusterd.service
EOFF
    systemctl daemon-reload
    systemctl show nfs-ganesha -p After,Wants
  '
"

# En D2 (k8s-worker-2)
ssh -p 9622 elarreglador@192.168.1.12 "
  lxc exec k8s-worker-2 -- bash -c '
    mkdir -p /etc/systemd/system/nfs-ganesha.service.d/
    cat > /etc/systemd/system/nfs-ganesha.service.d/override.conf << \"EOFF\"
[Unit]
After=glusterd.service
Wants=glusterd.service
EOFF
    systemctl daemon-reload
    systemctl show nfs-ganesha -p After,Wants
  '
"
```

**Validación post-aplicación:**
```bash
# Simular power-off/power-on o reiniciar nfs-ganesha tras glusterd:
lxc exec k8s-worker-1 -- systemctl restart glusterd
sleep 5
lxc exec k8s-worker-1 -- systemctl restart nfs-ganesha
lxc exec k8s-worker-1 -- showmount -e 192.168.1.30
# Debe mostrar /vol-storage y todos los subdirectorios PVC
```

---

## Referencias

- `04-Operaciones.md` — Procedimiento arranque/parada + `D-lab_start.sh`
- `README-TECH.md` Fase 8 — Arquitectura GlusterFS + NFS-Ganesha + Keepalived
- `files/adguard/adguard.yaml` — Deployment AdGuard con PVC `adguard-data`
- `incidentes/jellyfin-lentitud-20260906.md` — Race condition similar (NFS/GlusterFS + SQLite)