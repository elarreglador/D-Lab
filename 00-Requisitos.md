# Requisitos para Cluster Kubernetes con LXC

## Descripción General

Este documento detalla los requisitos necesarios para crear un cluster Kubernetes bajo máquinas virtuales LXC. El cluster estará compuesto por dos nodos físicos Dell OptiPlex 3050 Micro: **D1** (control-plane) y **D2** (worker).

Para el checklist de implementación, consultar [README.md](./README.md#guía-de-instalación).

---

## Requisitos de Hardware

### Por Nodo (D1 y D2)

#### CPU
- **Modelo**: Intel Core i3-7100T @ 3.40GHz
- **Núcleos**: 2 núcleos / 4 hilos
- **Consideración**: Suficiente como mínimo, pero ajustado para cargas de trabajo moderadas

#### Memoria RAM
- **Configuración Actual**: 4 GB (INSUFICIENTE)
- **Mínimo Recomendado**: 8 GB por nodo
- **Ideal para K8S**: 16 GB por nodo
- **Urgencia**: Ampliación prioritaria antes de desplegar en producción

#### Almacenamiento
- **NVMe M.2 Sandisk SN520**: 238.5 GB (para SO, kubelet, contenedores)
  - Partición raíz: 100 GB (ext4)
  - Espacio libre: 133.4 GB disponible
- **Disco Mecánico Seagate ST500LM021**: 465.8 GB (para volúmenes persistentes)

#### GPU
- Intel HD Graphics 630 (iGPU) - no requerida para K8S básico

---

## Requisitos de Red

### Conectividad
- **Topología**: Ethernet dedicada a través de switch Mercusys MS105G
- **Velocidad**: Gigabit Ethernet (10 Gbps backplane)
- **Configuración**: Evitar WiFi, solo conexión por cable

### Direccionamiento IP
- **D1 (Control-Plane)**: `192.168.1.11/24` (actualmente configurada)
- **D2 (Worker)**: `192.168.1.X/24` (pendiente de asignación)
- **Puerta de enlace**: `192.168.1.1`
- **Máscara de red**: `/24` (255.255.255.0)

### Servidores DNS
- Primario: `8.8.8.8` (Google DNS)
- Secundario: `8.8.4.4` (Google DNS)
- *Recomendación*: Considerar DNS interno para entorno de cluster

### Configuración de IP Estática
- **Método**: netplan (deshabilitando DHCP)
- **Archivo**: `/etc/netplan/00-installer-config.yaml`
- **Requisito**: Ambos nodos (D1 y D2) deben tener IPs estáticas configuradas
- **Validez**: Permanente (`valid_lft forever`)

---

## Requisitos de Software

### Sistema Base (por nodo)
- **SO**: Ubuntu LTS (recomendado para estabilidad)
- **Kernel**: Compatible con LXC (4.x o superior)

### Virtualizador LXC
- **Instalación**: lxc y lxd en ambos nodos
- **Configuración**: Bridge de red para conectividad entre contenedores y nodos

### Contenedores LXC
- Mínimo 1 contenedor por nodo para ejecutar K8S
- SO: Ubuntu (mismo que el host o compatible)

### Componentes de Kubernetes

#### En Control-Plane (D1)
- `kubeadm` - herramienta de inicialización
- `kubectl` - CLI para gestión del cluster
- `kubelet` - agente de nodo
- etcd - base de datos del cluster
- API Server
- Controller Manager
- Scheduler

#### En Worker (D2)
- `kubeadm` - herramienta de inicialización
- `kubectl` - CLI para gestión
- `kubelet` - agente de nodo

### Runtime de Contenedores
- **Opción 1**: Docker (dentro de LXC)
- **Opción 2**: containerd (recomendado, más ligero)
- **Requisito**: Instalado en ambos nodos

### CNI (Container Network Interface)
- Necesario para comunicación entre pods
- Opciones: Calico, Flannel, Weave, Cilium

---

## Requisitos de Seguridad

### SSH
- [ ] Cambiar puerto por defecto (22)
- [ ] Implementar fail2ban para prevenir ataques de fuerza bruta
- [ ] Usar claves SSH en lugar de contraseñas

### Certificados TLS
- Necesarios para comunicación segura entre componentes de K8S
- Generados automáticamente por kubeadm

### RBAC (Role-Based Access Control)
- Habilitado por defecto en K8S
- Configurar permisos mínimos necesarios

### Red Privada
- Considerar VLAN o red aislada para tráfico de K8S
- Segregar tráfico de datos de gestión

### Firewall
- Permitir puertos específicos:
  - **6443**: Kubernetes API server
  - **10250**: kubelet
  - **10251**: kube-scheduler
  - **10252**: kube-controller-manager
  - **2379-2380**: etcd (si en nodo master)

---

## Requisitos Pendientes (del Roadmap)

### Configuración de Red
- [ ] Asignar IP estática en D2 (pendiente)
- [ ] Configurar netplan en ambos nodos de forma consistente
- [ ] Agregar equipos a VPN wireguard

### Hardware
- [ ] Ampliación de RAM a mínimo 8GB, idealmente 16GB por nodo
- [ ] Considerar agregar un tercer equipo físico para mayor resiliencia

---

## Limitaciones Actuales

### RAM
- **4 GB actual**: Insuficiente para ejecutar:
  - Sistema operativo Ubuntu
  - Servicio LXC
  - Contenedor con K8S
  - Aplicaciones de usuario
  - etcd y API server (en D1)

### CPU
- **2 núcleos**: Mínimo absoluto
  - Control-plane (D1): Requiere más CPU para etcd, scheduler, controller-manager
  - Worker (D2): Puede funcionar pero con limitaciones

### Almacenamiento
- **Partición raíz 100GB**: Podría ser limitante con múltiples contenedores y volúmenes persistentes
- **Disco mecánico 465GB**: Ideal para PVC (Persistent Volume Claims), requiere configuración de almacenamiento

---

## Recomendaciones

### Prioritarias (antes de desplegar K8S)

1. **Ampliación de RAM a 8GB mínimo** - Crítico
2. **Asignar IP estática a D2** - Requerido
3. **Instalar y configurar LXC** en ambos nodos
4. **Instalar runtime de contenedores** (containerd recomendado)

### Secundarias (para optimizar)

1. Ampliar RAM a 16GB por nodo
2. Configurar almacenamiento persistente en disco mecánico
3. Implementar VPN wireguard
4. Cambiar puerto SSH y activar fail2ban
5. Configurar CNI elegido (Calico recomendado para producción)
6. Configurar backups de etcd
