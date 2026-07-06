# Informe de Incidente: NIC no responde ARP por ASPM + driver r8169

**Fecha del Incidente:** 6 de julio de 2026  
**Equipos Afectados:** D1, D2  
**Estado:** RESUELTO  

## Descripción del Problema

Los nodos D1 (192.168.1.11) y D2 (192.168.1.12) no eran accesibles por red a pesar de estar encendidos y con los LEDs de Ethernet activos (link presente y tráfico). La interrogación ARP fallaba (`No route to host`, entrada `FAILED` en `ip neigh`), y los equipos no aparecían en la lista de dispositivos del router ZTE H3600P.

La causa raíz fue la incapacidad del driver `r8169` para deshabilitar ASPM (Active State Power Management) en el controlador de red Realtek RTL8168h. La BIOS del Dell OptiPlex 3050 Micro retiene el control de ASPM, impidiendo que el driver lo desactive. En determinadas condiciones, ASPM pone el NIC en un estado de bajo consumo del que no logra recuperarse correctamente, dejando la interfaz sin respuesta a nivel de red (capa 3) aunque el enlace físico (capa 1) permanezca activo.

## Síntomas

- Ping a D1/D2: 100% pérdida
- SSH: `No route to host` (ARP fallido)
- Router: equipos no visibles en la lista de dispositivos
- Switch Mercusys MS105G: LEDs fijos (link OK)
- OptiPlex: LEDs de Ethernet parpadeando (tráfico)
- Conexión directa al router (sin switch): mismo resultado

## Análisis de Logs

### Mensajes clave del kernel

```
r8169 0000:02:00.0: can't disable ASPM; OS doesn't have ASPM control
ACPI FADT declares the system doesn't support PCIe ASPM, so disable it
acpi PNP0A08:00: FADT indicates ASPM is unsupported, using BIOS configuration
```

El sistema detecta que la BIOS no reporta soporte ASPM en la tabla FADT, pero la BIOS retiene el control sobre ASPM. El driver `r8169` intenta desactivarlo pero no puede.

### Secuencia de arranque (normal)

```
jul 06 11:58:35 D1 kernel: r8169 0000:02:00.0 enp2s0: Link is Down   (inicialización PHY)
jul 06 11:58:39 D1 kernel: r8169 0000:02:00.0 enp2s0: Link is Up - 1Gbps/Full
```

La transición Link Down/Up es normal durante la inicialización del PHY. No hay errores en `systemd-networkd` ni en la configuración de red.

### Hardware y drivers

| Componente | Detalle |
|-----------|---------|
| NIC | Realtek RTL8168h/8111h (PCI Express) |
| Driver | r8169 (kernel 7.0.0-27-generic) |
| Firmware | rtl8168h-2_0.0.2 02/26/15 |
| BIOS | Dell 1.31.0 (07/09/2024) |
| Equipo | Dell OptiPlex 3050 Micro |

## Solución Implementada

Añadir `pcie_aspm=off` a los parámetros del kernel para forzar ASPM desactivado desde el arranque, evitando que la BIOS o el hardware activen modos de bajo consumo en el controlador PCIe.

### Pasos ejecutados en D1 y D2

```bash
# 1. Añadir parámetro al kernel en GRUB
sudo sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="pcie_aspm=off"/' /etc/default/grub

# 2. Regenerar configuración de GRUB
sudo update-grub

# 3. Verificar que se aplicó correctamente
grep 'pcie_aspm' /boot/grub/grub.cfg
# Salida esperada:
#   linux /boot/vmlinuz-... ro pcie_aspm=off crashkernel=...

# 4. Reiniciar para aplicar
sudo reboot
```

### Verificación

Tras el reinicio, comprobar que el parámetro está activo:

```bash
cat /proc/cmdline | grep pcie_aspm
# Debe mostrar "pcie_aspm=off" en la línea de comandos del kernel
```

## Lecciones Aprendidas

1. **Driver r8169 vs r8168**: El driver `r8169` incluido en el kernel tiene problemas conocidos de gestión energética con chips Realtek más recientes. Alternativas: usar el driver `r8168` de Realtek (dkms) o deshabilitar ASPM vía kernel parameter.

2. **ASPM y BIOS**: Aunque la BIOS declare `FADT indicates ASPM is unsupported`, puede retener el control sobre ASPM a nivel de hardware, causando comportamientos impredecibles en el NIC.

3. **Diagnóstico remoto**: La combinación de LED de red activo + fallo ARP + router sin detectar el equipo es indicativa de problemas de gestión energética en la NIC, no de configuración de red.

## Recomendaciones

1. Documentar `pcie_aspm=off` como parte del setup inicial de cualquier OptiPlex 3050 Micro con este hardware
2. Considerar migrar al driver `r8168-dkms` de Realtek para mayor estabilidad
3. Monitorear periódicamente el estado de la interfaz (`ethtool enp2s0`, `ip -s link show enp2s0`) para detectar reinicios de link no esperados
4. Mantener actualizado el firmware del NIC si Dell publica actualizaciones
