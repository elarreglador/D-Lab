# Informe de Disaster Recovery: etcd y cluster

**Fecha:** 1 de agosto de 2026
**Alcance:** Estrategia de respaldo y recuperación de etcd (Fase 13)

## Objetivos de recuperación

| Métrica | Valor | Nota |
|---------|-------|------|
| **RPO** | 24 h | Backup diario a las 02:00 en cada control-plane |
| **RTO** | ~15-30 min | Restauración de etcd + rejoin de nodos (depende del escenario) |
| **Cobertura** | Pérdida de un nodo físico | La copia redundante en el peer cubre la pérdida de D1 o D2 |

## Esquema de backups

- **Script**: `/usr/local/bin/backup-etcd.sh`, **idéntico en ambos control-planes** (`k8s-master-1` y `k8s-master-2`). Copia canónica en `files/backup-etcd.sh`.
- **Cron**: `0 2 * * * root /usr/local/bin/backup-etcd.sh >> /var/log/etcd-backup.log 2>&1` (`/etc/cron.d/etcd-backup` en cada master).
- **Mecánica**: usa `crictl exec` para ejecutar `etcdctl snapshot save` dentro del **pod etcd local**. Al no pasar por el API Server, funciona aunque el peer esté caído (sin quorum) — cierra el hueco que dejaba el enfoque `kubectl exec`.
- **Doble copia**: cada master guarda su snapshot en `/backup/etcd/` (rotación: últimas 30) **y además lo envía por SSH al peer** (`root@192.168.1.21` / `root@192.168.1.22`, claves ed25519 configuradas en `/root/.ssh/`). Como etcd está replicado en tiempo real (Raft), las snapshots de ambos miembros son equivalentes: cualquier copia sirve para restaurar.
- **Dependencias**: `crictl` **v1.36.0 en ambos masters** (alineado el 2026-08-01) y `/etc/crictl.yaml` apuntando a containerd.

## Verificación del backup

```bash
# Estado del snapshot (ambos masters)
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot status /backup/etcd/snapshot-<fecha>.db
# Debe devolver revision y hash válidos (sin "Error")
```

```bash
# Revisar log diario
tail -n 20 /var/log/etcd-backup.log
# Verificar las dos copias (local + peer)
ls -lt /backup/etcd/           # en ambos masters
```

## Escenarios de recuperación

### Escenario A — Cae un control-plane pero el otro tiene quorum (D1 o D2)

El miembro superviviente mantiene el quorum **solo si** el clúster etcd sigue teniendo mayoría. Con 2 miembros esto **no** ocurre (quorum 2/2): la caída de cualquier miembro deja etcd sin quorum. Por tanto, **en el estado actual (2 masters) no existe el Escenario A**: la caída de un master deriva al Escenario B.

### Escenario B — Pérdida total de un nodo (D1 o D2)

Ejemplo: se pierde el disco/contenedor de k8s-master-1.

1. **Reconstruir el miembro etcd** en el nodo superviviente usando una snapshot válida del peer:
   ```bash
   # En el nodo sano (p. ej. k8s-master-2), como root
   ETCDCTL_API=3 etcdctl snapshot restore \
     --data-dir /tmp/etcd-restore \
     --name <nodo-nuevo> \
     /backup/etcd/snapshot-<fecha>.db
   ```
2. **Reiniciar el clúster etcd** desde cero en el nodo sano (modo `force-new-cluster`) o volver a unir el nodo reconstruido como miembro (`etcdctl member add` + `kubeadm`/manifest con el `--initial-cluster` correcto).
3. **Recuperar el API Server**: si se perdió el control-plane original, re-inicializar con `kubeadm` o volver a unir un control-plane nuevo.
4. **Verificar**: `etcdctl endpoint health` en todos los miembros y `kubectl get nodes`.

### Escenario C — Reconstrucción total del laboratorio (pérdida de ambos hosts)

1. **Reinstalar** D1/D2 (SO + LXC + contenedores) según `README.md` (Guía de Instalación).
2. **Reinicializar** el cluster con `kubeadm init` (Fase 5) y unir workers (Fase 7).
3. **Restaurar etcd** desde la snapshot (Escenario B), **preferiblemente la del nodo que no falló**, o desde el backup local si un nodo sobrevive.
4. **Reinstalar addons** desde el repo (flannel, ingress-nginx, cert-manager, kube-prometheus-stack, provisioner NFS) y reaplicar los manifiestos de `files/`.
5. El código/configuración del proyecto están en el repo Git (GitHub) → copia offsite de la configuración.

## Decisiones y limitaciones

- **Sin copia offsite (DV0/IONOS)**: decisión del señor (2026-08-01). La DR cubre la pérdida de un nodo del laboratorio, **no** la pérdida total del sitio. RPO=24 h solo se garantiza si **al menos un master está operativo a las 02:00**.
- **RPO real**: la doble copia no reduce el RPO de 24 h (una snapshot diaria); sí elimina el riesgo de perder la única copia junto con el nodo.
- **Backup manual de otros datos**: `info_sensible/` (claves WG/SSH, htpasswd) y `values-monitoring.yaml` no están en el repo; deben respaldarse aparte (ver backup local del señor).
- **Drill recomendado**: ejecutar periódicamente `etcdctl snapshot status` y, de forma puntual, una restauración de prueba en un etcd temporal para validar que el backup es restaurable.
- **Pendiente (2026-08-02)**: la primera ejecución automática del cron (02:00) no se ha producido aún (el script se instaló el 2026-08-01 ~11:52, tras la hora del cron). Verificar que el 2026-08-02 existe `/var/log/etcd-backup.log` en **ambos** masters y que cada uno generó su snapshot local + copia al peer.
- **crictl alineado (2026-08-01)**: ambos masters con crictl **v1.36.0** (master-2 actualizado; backup del binario anterior en `/usr/local/bin/crictl.1.31.0.bak`, verificado por sha256 contra el asset oficial). El dueño del script `backup-etcd.sh` en master-2 ya es `root:root` (igual que master-1).
