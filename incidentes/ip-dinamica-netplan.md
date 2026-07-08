# Informe de Incidente: IPs dinámicas por conflicto netplan

**Fecha del Incidente:** 8 de julio de 2026  
**Equipos Afectados:** k8s-master-1, k8s-worker-1 (contenedores LXC)  
**Estado:** RESUELTO  

## Descripción del Problema

Los contenedores `k8s-master-1` y `k8s-worker-1` presentaban **dos direcciones IP** en la misma interfaz `eth0`: la IP estática configurada (`.21` / `.22`) y una IP secundaria asignada por DHCP del router (`.128` / `.129`).

```
k8s-master-1: 192.168.1.21 (estática) + 192.168.1.129 (DHCP)
k8s-worker-1: 192.168.1.22 (estática) + 192.168.1.128 (DHCP)
```

## Causa Raíz

Coexistencia de dos archivos **netplan** que configuraban la misma interfaz `eth0`:

| Archivo | Contenido | Propósito |
|---------|-----------|-----------|
| `/etc/netplan/01-k8s.yaml` | `dhcp4: no`, IP estática `.21`/`.22` | Configuración manual del laboratorio |
| `/etc/netplan/50-cloud-init.yaml` | `dhcp4: true` | Heredado de cloud-init al crear el contenedor |

netplan **fusiona** todas las configuraciones para una misma interfaz. Como `50-cloud-init.yaml` se procesa después alfabéticamente y define `dhcp4: true`, el sistema obtiene tanto la IP estática (de `01-k8s.yaml`) como una IP por DHCP (del router).

La IP secundaria no causaba problemas funcionales pero:
- Contaminaba la salida de `lxc list`
- Podía causar confusión en diagnóstico de red
- Era una IP efímera (con lease DHCP de 24h)

## Solución Implementada

Eliminar el archivo `50-cloud-init.yaml` (ya obsoleto, cloud-init solo se ejecuta en el primer arranque) y regenerar la configuración netplan.

### Pasos ejecutados

En **k8s-master-1** y **k8s-worker-1**:

```bash
# 1. Eliminar configuración DHCP heredada de cloud-init
rm /etc/netplan/50-cloud-init.yaml

# 2. Regenerar y aplicar configuración netplan
netplan apply
```

### Verificación

```bash
# Antes:
k8s-master-1 | 192.168.1.21 (eth0), 192.168.1.129 (eth0)
k8s-worker-1 | 192.168.1.22 (eth0), 192.168.1.128 (eth0)

# Después:
k8s-master-1 | 192.168.1.21 (eth0)
k8s-worker-1 | 192.168.1.22 (eth0)
```

Comprobación adicional con `networkctl`:

```
# Master: DHCP lease lost
Jul 08 13:01:48 k8s-master-1 systemd-networkd[178]: eth0: DHCP lease lost

# Worker: IP dinámica liberada tras netplan apply
systemd-networkd liberó la concesión DHCP al regenerar la configuración.
```

## Lecciones Aprendidas

1. **netplan mergea configs**: Múltiples archivos en `/etc/netplan/` se fusionan. El orden alfabético importa: archivos posteriores pueden sobrescribir o complementar configuraciones de archivos anteriores.

2. **cloud-init no se limpia solo**: Los archivos generados por cloud-init durante el primer arranque persisten aunque ya no sean necesarios. Es buena práctica revisar y limpiar `/etc/netplan/` tras la configuración inicial.

3. **Verificar IPs con `ip addr`**: `lxc list` muestra todas las IPs, pero `ip addr show eth0` permite distinguir entre IPs estáticas (`scope global`) y dinámicas (`scope global secondary dynamic`).

## Recomendaciones

1. En el setup inicial de cualquier contenedor LXC con IP estática, eliminar o modificar `50-cloud-init.yaml` para deshabilitar DHCP
2. Después de configurar netplan, verificar con `networkctl status eth0` que no haya leases DHCP activos
3. Incluir este paso en el checklist de creación de nuevos contenedores
