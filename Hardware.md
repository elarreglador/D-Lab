# Especificaciones Técnicas: Dell OptiPlex 3050 Micro
## Cluster D-Lab (Nodos D1 y D2)

**Fecha de Documento**: Junio de 2026  
**Nodos en Cluster**: 2 (D1 - Control-Plane, D2 - Worker)  
**Modelo**: Dell OptiPlex 3050 Micro  
**Generación**: 7ª Generación Intel (Kaby Lake)  

---

## 1. PROCESADOR (CPU)

### Intel Core i3-7100T

**Datos Técnicos Verificados**:
- **Modelo**: Intel Core i3-7100T
- **Generación**: 7ª Generación Intel Core (Kaby Lake)
- **Arquitectura**: 14nm
- **Socket**: LGA1151 (H4)
- **Familia de CPU**: 6
- **Modelo de CPU**: 158
- **Stepping**: 9

**Configuración de Núcleos y Threads**:
- **Núcleos Físicos**: 2
- **Threads por Núcleo**: 2 (Hyper-Threading activo)
- **Total de Threads Lógicos**: 4
- **Frecuencia Base**: 3.4 GHz (3400.0000 MHz según lscpu)
- **Frecuencia Mínima**: 800.0 MHz (C-states/power management)
- **Frecuencia Máxima**: 3400.0 MHz (sin Turbo Boost)

**Memoria Caché Verificada**:
- **L1 Data Cache**: 64 KiB × 2 instancias
- **L1 Instruction Cache**: 64 KiB × 2 instancias
- **L2 Cache**: 512 KiB × 2 instancias
- **L3 Cache (Shared)**: 3 MiB (1 instancia)
- **Tamaño Total Caché**: 3072 KB reportado en /proc/cpuinfo

**Especificaciones de Poder**:
- **TDP (Thermal Design Power)**: 35W
- **Consumo Observado Idle**: ~1000 MHz (CPU scaling activo)
- **BogoMIPS**: 6799.81

**Tecnologías de Virtualización**:
- **VT-x (Virtualization)**: Presente en flags
- **VMX (Virtual Machine Extensions)**: Activo
- **Features VMX Disponibles**: vnmi, preemption_timer, invvpid, ept_x_only, ept_ad, ept_1gb, flexpriority, tsc_offset, vtpr, mtf, vapic, ept, vpid, unrestricted_guest, ple, pml, ept_violation_ve, ept_mode_based_exec

**Conjuntos de Instrucciones Soportados** (flags verificados):
- **Base**: 64-bit (lm flag presente)
- **SIMD**: fpu, mmx, sse, sse2, sse3 (pni), ssse3, sse4_1, sse4_2
- **Vectorización Avanzada**: avx, avx2, f16c
- **Criptografía**: aes, pclmulqdq
- **Otras**: fma, bmi1, bmi2, popcnt, movbe, lzcnt (abm)

**Vulnerabilidades Conocidas** (detectadas por sistema):
- Meltdown (Mitigado con PTI)
- Spectre v1/v2 (Mitigadas)
- L1TF (Mitigado)
- MDS (Mitigado con Clear CPU buffers)
- MMIO Stale Data (Mitigado)
- Retbleed (Mitigado con IBRS)

---

## 2. GRÁFICOS INTEGRADOS

### Intel HD Graphics 630 (Kaby Lake GT2)

**Verificación del Sistema**:
- **Identificación lspci**: 00:02.0 VGA compatible controller: Intel Corporation Kaby Lake-S GT2 [HD Graphics 630]
- **Subsistema**: Dell Device 07a3
- **Controlador del Kernel**: i915
- **Módulos Kernel**: i915

**Asignación de Memoria**:
- **Memory Mapped I/O (64-bit, non-prefetchable)**: 16 MB (rango: f6000000)
- **Prefetchable Memory (64-bit, prefetchable)**: 256 MB (rango: e0000000)
- **I/O Ports**: 64 bytes (rango: f000)
- **Expansion ROM**: 128 KB (range 000c0000, disabled)

**Características Reportadas**:
- **Bus Master**: Activo
- **Fast Select**: Activo
- **Latency Timer**: 0
- **IRQ**: 136

**Especificaciones de GPU** (del estándar Kaby Lake GT2):
- **Unidades de Ejecución (EUs)**: 24
- **Shaders Unificados**: 192
- **Frecuencia Base**: 350 MHz
- **Frecuencia Dinámica Máxima**: 1.1 GHz

---

## 3. MEMORIA (RAM)

### Configuración del Sistema

**Datos Reales del Sistema**:
- **Memoria Total Instalada**: 3.2 GB
- **Memoria en Uso**: 821 MB
- **Memoria Libre**: 1.7 GB
- **Memoria en Caché/Buffers**: 900 MB
- **Memoria Disponible para Aplicaciones**: 2.4 GB
- **Swap Configurado**: 4.0 GB
- **Swap en Uso**: 0 B

**Especificaciones Técnicas**:
- **Tipo**: DDR4 SODIMM (Small Outline DIMM)
- **Ranuras Físicas**: 2 (según especificaciones OptiPlex 3050)
- **Velocidad Nominal**: DDR4-2400 o DDR4-2133
- **Voltaje Nominal**: 1.2V
- **Arquitectura**: 64-bit
- **Modo de Operación**: Dual Channel (si ambas ranuras pobladas)

**Capacidad Máxima Soportada**:
- **Máximo Teórico**: 32 GB (2 × 16 GB DDR4 SODIMM)
- **Configuración Actual**: 4 GB (1 módulo instalado)

---

## 4. ALMACENAMIENTO

### 4.1 Unidad NVMe M.2 (Sistema Operativo)

**Verificación del Sistema**:

Dispositivo nvme0n1 (256 GB):
```
Capacidad Total: 256,060,514,304 bytes (256.06 GB)
Particiones:
  ├─ nvme0n1p1:   1.127 GB (EFI Boot: /boot/efi)
  ├─ nvme0n1p2:   4.294 GB (SWAP)
  ├─ nvme0n1p3: 107.374 GB (Raíz filesystem: /)
  └─ nvme0n1p4: 143.261 GB (sin asignar/disponible)
```

**Identificación**:
- **Modelo**: WDC PC SN520 SDAPNUW-256G-1006 (Sandisk/Western Digital)
- **Interfaz**: NVMe (PCIe)
- **Form Factor**: M.2 2280

---

### 4.2 Disco Mecánico SATA (Almacenamiento Persistente)

**Verificación del Sistema**:

Dispositivo sda (500 GB):
```
Capacidad Total: 500,107,862,016 bytes (465.8 GB)
Particiones:
  └─ sda1: 500,105,740,288 bytes (465.8 GB, sin formato detectado)
```

**Identificación**:
- **Tipo**: Disco mecánico SATA
- **Capacidad**: 500.1 GB (nominales)
- **Estado**: No formateado en partición principal

---

## 5. ADAPTADOR DE RED

### Realtek RTL8111/8168/8211/8411 Gigabit Ethernet

**Verificación del Sistema**:
- **Dispositivo lspci**: 02:00.0 Ethernet controller: Realtek Semiconductor Co., Ltd. RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet Controller (rev 15)
- **Interfaz del Sistema**: enp2s0
- **Controlador Kernel**: r8169

**Información de Controlador**:
- **Driver**: r8169
- **Versión**: 7.0.0-22-generic
- **Firmware Version**: rtl8168h-2_0.0.2 02/26/15
- **Bus Info**: 0000:02:00.0

**Características Reportadas**:
- **Soporte de Estadísticas**: Sí
- **Soporte de Test**: No
- **Acceso a EEPROM**: No
- **Dump de Registros**: Sí
- **Banderas Privadas**: No

**Especificaciones de Red**:
- **Velocidades**: 10 Mbps, 100 Mbps, 1000 Mbps (Gigabit)
- **Modo Duplex**: Full/Half duplex (auto-negotiation)
- **Conector**: RJ-45 (8P8C)

---

## 6. CONTROLADOR DE ALMACENAMIENTO

**Información lspci**:
- **Controlador SATA**: Intel Corporation 200 Series PCH SATA controller [AHCI mode]

---

## 7. CONTROLADOR USB y SMBus

**Información lspci**:
- **USB 3.0 xHCI**: 00:14.0 USB controller: Intel Corporation 200 Series/Z370 Chipset Family USB 3.0 xHCI Controller
- **Power Management**: 00:1f.2 Memory controller: Intel Corporation 200 Series/Z370 Chipset Family Power Management Controller
- **SMBus**: 00:1f.4 SMBus: Intel Corporation 200 Series/Z370 Chipset Family SMBus Controller

---

## 8. ARQUITECTURA DE DIRECCIÓN Y MEMORIA

**Especificaciones Verificadas**:
- **Modo de Operación CPU**: 32-bit, 64-bit
- **Tamaño de Dirección Física**: 39 bits
- **Tamaño de Dirección Virtual**: 48 bits
- **Orden de Bytes**: Little Endian

**NUMA (Non-Uniform Memory Architecture)**:
- **Nodos NUMA**: 1
- **CPUs en NUMA node0**: 0-3 (todos los 4 threads)

---

## 9. INFORMACIÓN DE CACHÉ

**Caché de Línea de Limpieza**:
- **clflush size**: 64 bytes
- **cache_alignment**: 64 bytes

---

## 10. DIMENSIONES Y CHASIS

**Form Factor**: Micro (Mini-PC)

**Dimensiones**:
- **Alto**: 182 mm
- **Ancho**: 178 mm
- **Profundidad**: 36 mm

**Peso**: ~1.18 kg

---

## 11. CONFIGURACIÓN DE ARCHIVO SWAP

**Datos Reales del Sistema**:
- **Partición SWAP**: nvme0n1p2
- **Tamaño del SWAP**: 4 GB
- **SWAP en Uso**: 0 B
- **SWAP Disponible**: 4.0 GB

---

## TABLA RESUMEN DE ESPECIFICACIONES

| Componente | Especificación Verificada | Unidad |
|-----------|--------------------------|--------|
| CPU Cores | 2 | núcleos físicos |
| CPU Threads | 4 | threads lógicos |
| Frecuencia Base | 3400 | MHz |
| Frecuencia Mínima | 800 | MHz |
| L3 Cache | 3 | MB |
| Memoria Instalada | 3.2 | GB |
| Memoria Disponible | 2.4 | GB |
| RAM Máxima Soportada | 32 | GB |
| Almacenamiento NVMe | 256 | GB |
| Almacenamiento SATA | 465.8 | GB |
| GPU (Integrada) | HD Graphics 630 | - |
| Red | Gigabit Ethernet | - |
| Dirección Física | 39 | bits |
| Dirección Virtual | 48 | bits |
| BogoMIPS | 6799.81 | - |

---

## NOTAS TÉCNICAS

1. **Frecuencia de CPU Actual**: El sistema reporta frecuencias dinámicas (~1000 MHz cuando está idle debido a escalado de CPU)

2. **Microcode**: 0xf8 (actualización de microcode disponible del fabricante)

3. **Configuración de Almacenamiento**: 
   - Partición EFI: 1.1 GB
   - Swap: 4.3 GB
   - Raíz (/): 107.4 GB
   - Espacio no asignado en NVMe: 143.3 GB

4. **Kernel y Controladores**: Linux kernel 7.0.0-22-generic con soporte completo para virtualización VT-x/VMX

5. **Mitigaciones de Seguridad**: Múltiples mitigaciones de vulnerabilidades CPU implementadas (PTI, IBRS, IBPB, etc.)

6. **Drivers de Gráficos**: i915 (Intel GPU driver para Linux)

7. **Driver de Red**: r8169 (Realtek Gigabit Ethernet driver para Linux)

---

**Documento Generado**: Junio 2026  
**Verificado en**: D-Lab D1 (Control-Plane Node)  
**Método de Verificación**: Comandos del sistema (lscpu, lspci, lshw, dmidecode, /proc/cpuinfo, lsblk, ethtool)
