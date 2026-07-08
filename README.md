# D-Lab: Cluster Kubernetes sobre LXC

Proyecto de virtualización y orquestación de contenedores usando LXC (Linux Containers) y Kubernetes en dos nodos Dell OptiPlex 3050 Micro.

---

## Tabla de Contenidos

- [Arquitectura](#arquitectura)
- [Hardware](#hardware)
- [Tecnologías](#tecnologías)
- [Documentación Técnica](#documentación-técnica)
- [Guía de Instalación](#guía-de-instalación)
- [Estado del Proyecto](#estado-del-proyecto)

---

## Arquitectura

El cluster está diseñado con la siguiente estructura:

```
Internet (Router ZTE H3600P - 192.168.1.1)
    ↓
Switch Mercusys MS105G (10 Gbps)
    ├── D1 (Control-Plane) - 192.168.1.11
    │   └── k8s-master-1 (LXC) - 192.168.1.21
    │
    └── D2 (Worker) - 192.168.1.12
        └── k8s-worker-1 (LXC) - 192.168.1.22
```

**Topología de Red**: Ethernet dedicada, sin WiFi  
**Control-Plane**: D1 con contenedor k8s-master-1  
**Worker**: D2 con contenedor k8s-worker-1  

---

## Hardware

### Sistema de Alimentación (SAI)

**Riello UPS RPR 650 230VAC** (aprox. 360 W)

Sistema de alimentación ininterrumpida para protección contra:
- Cortes de energía
- Sobretensiones
- Fluctuaciones de voltaje

Características: 2 salidas tipo schuko, nivel básico, ideal para infraestructura pequeña.

### Red (Switch)

**Mercusys MS105G**

Switch Gigabit de escritorio:
- **Puertos**: 5 puertos RJ45 (10/100/1000 Mbps)
- **Capacidad de Conmutación**: 10 Gbps (Backplane)
- **Auto-negociación**: Sí

### Router

**ZTE H3600P V9.0**

Router del proveedor (192.168.1.1, DHCP, WiFi). Más información en [01-Network.md](./01-Network.md#router).

### Periféricos

**Nooelec Ham It Up**

Dispositivo receptor de radio definido por software (SDR):
- Tratamiento previo de frecuencias para recepción SDR de bandas bajas
- Suma 125 MHz a la frecuencia para permitir recepción en el SDR
- Rango: Aproximadamente 25 MHz a 1700 MHz
- Conector: SMA

### Equipos Computacionales

#### Dell OptiPlex 3050 Micro (x2)

**Procesador (CPU)**
- Modelo: Intel Core i3-7100T @ 3.40GHz
- Núcleos: 2 / Hilos: 4
- TDP: Bajo (T = Baja disipación térmica)

**Memoria RAM**
- D1: 8 GB (2 × 4GB DDR4-2400 SODIMM) — Samsung M471A5143SB1-CRC + SK Hynix HMA851S6AFR6N-UH
- D2: 8 GB (2 × 4GB DDR4-2400 SODIMM) — 2 × Micron 4ATF51264HZ-2G3B1
- Configuración Original: 4 GB por nodo (1 módulo) — ampliado a 8 GB por nodo (Dual Channel)
- Swap: 4.0 GB

**Almacenamiento**

Disco Mecánico (sda):
```
sda             465,8G (sin formato - disponible para PVC)
└─sda1          465,8G
```

NVMe M.2 (nvme0n1):
```
nvme0n1         238,5G
├─nvme0n1p1     1G     (fat32) - /boot/efi
├─nvme0n1p2     4G     (swap)  - SWAP
├─nvme0n1p3     100G   (ext4)  - / (raíz)
└─nvme0n1p4     133,4G (sin formato - disponible)
```

**Gráfica**
- Intel HD Graphics 630 (iGPU) - No requerida para K8S básico

**Adaptador de Red**
- RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet

---

## Tecnologías

### Virtualización

**LXC (Linux Containers)**
- Base de la infraestructura de virtualización
- Contenedores ligeros a nivel del SO
- Aislamiento de recursos y aplicaciones

### Orquestación

**Kubernetes (K8S)**
- Gestión automática de pods (contenedores)
- Balanceo de carga
- Auto-escalado
- Control-plane en D1
- Worker node en D2

### Conectividad

**Topología de Red**
- Conexión Ethernet dedicada (sin WiFi)
- Router ZTE H3600P → Switch → Nodos
- IPs estáticas configuradas con netplan
- DNS: Google (8.8.8.8 / 8.8.4.4)

---

## Documentación Técnica

| Documento | Descripción |
|-----------|-------------|
| [00-Requisitos.md](./00-Requisitos.md) | Requisitos de hardware, software y seguridad para el cluster K8S |
| [01-Network.md](./01-Network.md) | Configuración de red estática, SSH, fail2ban, WireGuard VPN y router ZTE H3600P |
| [02-vm.md](./02-vm.md) | Instalación y configuración de LXD, contenedores y conectividad |
| [Hardware.md](./Hardware.md) | Especificaciones técnicas verificadas del Dell OptiPlex 3050 Micro (CPU, GPU, RAM, almacenamiento, red) |
| [README.md](./README.md#fase-23--cluster-lxd) | Fase 2.3: Unificación de D1 y D2 en un mismo cluster LXD (sección en este documento) |
| [incidentes/ssh_socket.md](./incidentes/ssh_socket.md) | Análisis y resolución del conflicto entre ssh.socket y ssh.service |
| [incidentes/network-pcie-aspm.md](./incidentes/network-pcie-aspm.md) | NIC no responde ARP por ASPM + driver r8169 — solución con pcie_aspm=off |

---

## Guía de Instalación

### Fase 1️ | Preparación de Infraestructura

**Objetivo**: Establecer base de red y seguridad

- [x] Configurar red estática en D1 (192.168.1.11)
- [x] Configurar red estática en D2 (192.168.1.12)
- [x] Validar conectividad D1 ↔ D2 (ping, ssh)
- [x] Actualizar SO en ambos nodos (`apt update && apt upgrade`)
- [x] Sincronizar hora NTP en ambos nodos:
  ```bash
  sudo timedatectl set-ntp on
  timedatectl status
  ```
- [x] Cambiar puerto SSH (22 → 9622)
- [x] Implementar fail2ban en ambos nodos
- [x] Implementar VPN Wireguard para comunicación segura interna

**Ver**: [01-Network.md](./01-Network.md)

---

### Fase 2 | Infraestructura LXC y Containerización

**Objetivo**: Establecer contenedores base para Kubernetes

- [x] Instalar LXC/LXD en D1 y D2
  ```bash
  sudo snap install lxd
  ```
- [x] Configurar LXD con storage pool ZFS
  ```bash
  lxd init
  ```
- [x] Crear red macvlan sobre enp2s0 en ambos nodos
  ```bash
  lxc network create macvlan0 --type=macvlan parent=enp2s0
  ```
- [x] Crear perfil k8s con macvlan en ambos nodos
- [x] Crear contenedor `k8s-master-1` en D1
  - Imagen: Ubuntu 22.04 LTS
  - IP estática: 192.168.1.21
  - RAM: 3GB mínimo, 6GB ideal
- [x] Crear contenedor `k8s-worker-1` en D2
  - Imagen: Ubuntu 22.04 LTS
  - IP estática: 192.168.1.22
  - RAM: 2GB mínimo, 4GB ideal
- [x] Validar conectividad entre contenedores
- [x] Instalar dependencias base en ambos contenedores

**Ver**: [02-vm.md](./02-vm.md)

---

### Fase 2.2 | Ampliación de Memoria RAM

**Objetivo**: Alcanzar 8 GB por nodo (mínimo requerido para fases siguientes)

**Situación Original**: Cada nodo contaba con 1 módulo de 4 GB DDR4-2400 SODIMM (total 4 GB por nodo, Single Channel), insuficiente para Kubernetes.

**Procedimiento Realizado**:

1. Extraer el módulo de 4 GB de D2 (SK Hynix HMA851S6AFR6N-UH, en DIMM1)
2. Instalar ese módulo en D1, ranura DIMM2 (junto al Samsung M471A5143SB1-CRC existente en DIMM1)
3. Instalar 2 módulos nuevos Micron 4ATF51264HZ-2G3B1 (4 GB c/u) en D2, ranuras DIMM1 y DIMM2

**Configuración Final**:

| Nodo | DIMM1 | DIMM2 | Total | Canal |
|------|-------|-------|-------|-------|
| D1 | Samsung 4GB DDR4-2400 | SK Hynix 4GB DDR4-2400 | **8 GB** | Dual Channel |
| D2 | Micron 4GB DDR4-2400 | Micron 4GB DDR4-2400 | **8 GB** | Dual Channel |

**Verificación**:
```bash
# Capacidad total visible
free -h

# Detalle de cada módulo
sudo dmidecode -t memory | grep -E 'Size:|Locator:|Speed:|Manufacturer:|Part Number:'

# Modo Dual Channel activo (2 dispositivos)
sudo dmidecode -t memory | grep 'Number Of Devices'
```

**Requisito**: Hardware compatible (Dell OptiPlex 3050 Micro, 2 ranuras SODIMM DDR4, máximo 32 GB)  
**Duración**: 15 minutos

---

### Fase 2.3 | Cluster LXD

**Objetivo**: Unificar D1 y D2 en un mismo cluster LXD para gestionar contenedores de ambos nodos desde cualquier miembro.

**Problema Inicial**: Tras `lxd init`, cada nodo creó su propio cluster independiente (single-node). `lxc cluster list` solo mostraba el nodo local.

**Procedimiento**:

1. **Verificar estado inicial** en ambos nodos:
   ```bash
   lxc cluster list
   ```

2. **En D2**: Salir de su cluster individual modificando la base de datos local:
   ```bash
   lxd sql local "DELETE FROM raft_nodes"
   lxd sql local "DELETE FROM config WHERE key='cluster.https_address'"
   lxd shutdown --force
   ```

3. **En D2**: Eliminar la base de datos y reiniciar el servicio:
   ```bash
   sudo systemctl stop snap.lxd.daemon.unix.socket snap.lxd.daemon.service
   sudo rm -rf /var/snap/lxd/common/lxd/database/
   sudo systemctl start snap.lxd.daemon.unix.socket
   ```

4. **En D2**: Recuperar el pool de almacenamiento ZFS y contenedores existentes:
   ```bash
   lxd recover
   ```

5. **En D1**: Generar token de unión para D2:
   ```bash
   lxc cluster add D2
   ```

6. **En D2**: Unirse al cluster de D1 mediante preseed:
   ```bash
   cat > join.yaml << EOF
   cluster:
     server_name: D2
     enabled: true
     cluster_address: 192.168.1.11:8443
     cluster_token: "<TOKEN>"
     server_address: 192.168.1.12:8443
   EOF
   lxd init --preseed < join.yaml
   ```

7. **Verificar** desde cualquier nodo:
   ```bash
   lxc cluster list
   lxc list --all-projects
   ```

**Resultado**:
```
lxc cluster list:
D1 (database-leader)  ONLINE  https://192.168.1.11:8443
D2 (database-standby) ONLINE  https://192.168.1.12:8443

lxc list --all-projects:
k8s-master-1  RUNNING  192.168.1.21  D1
k8s-worker-1  RUNNING  192.168.1.22  D2
```

**Notas**:
- `k8s-worker-1` puede perderse del registro al unir D2 al cluster. Recuperarlo con `lxd recover` post-unión.
- El perfil `k8s` y la red `macvlan0` deben crearse de nuevo en D2 tras la limpieza de base de datos.
- La contraseña sudo de D2 es necesaria para los pasos 3 y 4.

**Duración Estimada**: 30-45 minutos

---

### Fase 3️ | Runtime de Contenedores

**Objetivo**: Instalar y configurar containerd

Ejecutar en `k8s-master-1` y `k8s-worker-1`:

- [x] Instalar dependencias
  ```bash
  apt install curl wget gnupg2 apt-transport-https ca-certificates
  ```
- [x] Instalar containerd.io
  ```bash
  apt install containerd.io
  ```
- [x] Generar configuración default
  ```bash
  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml
  ```
- [x] Reiniciar servicio
  ```bash
  systemctl restart containerd
  ```
- [x] Validar estado
  ```bash
  systemctl status containerd
  ctr image pull docker.io/library/alpine:latest
  ```

**Prerequisitos**: Fase 2 completada, RAM ampliada a 8GB  
**Duración Estimada**: 30 minutos

---

### Fase 4️ | Instalación de Kubernetes

**Objetivo**: Instalar componentes de K8S (kubeadm, kubelet, kubectl) y configurar el nodo.

Ejecutar todos los pasos en `k8s-master-1` y `k8s-worker-1`.

- [ ] Configurar containerd para systemd cgroup driver
  ```bash
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd
  ```

- [ ] Deshabilitar swap (permanentemente en `/etc/fstab`)
  ```bash
  sudo swapoff -a
  sudo sed -i '/ swap / s/^/#/' /etc/fstab
  ```

- [ ] Cargar módulos de kernel necesarios
  ```bash
  sudo modprobe overlay
  sudo modprobe br_netfilter
  ```

- [ ] Configurar sysctl para red de Kubernetes
  ```bash
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
  net.bridge.bridge-nf-call-iptables = 1
  net.bridge.bridge-nf-call-ip6tables = 1
  net.ipv4.ip_forward = 1
  EOF
  sudo sysctl --system
  ```

- [ ] Instalar dependencias para el repositorio
  ```bash
  sudo apt-get update
  sudo apt-get install -y apt-transport-https ca-certificates curl gpg
  ```

- [ ] Añadir repositorio oficial de Kubernetes (v1.36)
  ```bash
  # Descargar clave GPG
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key |
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  # Añadir repositorio (firmado con signed-by)
  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' |
    sudo tee /etc/apt/sources.list.d/kubernetes.list
  ```

- [ ] Instalar kubeadm, kubelet y kubectl
  ```bash
  sudo apt-get update
  sudo apt-get install -y kubelet kubeadm kubectl
  ```

- [ ] Prevenir actualizaciones automáticas
  ```bash
  sudo apt-mark hold kubelet kubeadm kubectl
  ```

- [ ] Habilitar kubelet
  ```bash
  sudo systemctl enable --now kubelet
  ```

**Prerequisitos**: Fase 3 completada  
**Duración Estimada**: 45 minutos

---

### Fase 5️ | Control-Plane

**Objetivo**: Inicializar cluster Kubernetes

Ejecutar solo en `k8s-master-1`:

- [ ] Inicializar control-plane
  ```bash
  kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address=192.168.1.21
  ```
- [ ] Copiar kubeconfig
  ```bash
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  ```
- [ ] Guardar token de unión (para Fase 6)
  ```bash
  kubeadm token create --print-join-command
  ```
- [ ] Validar acceso a cluster
  ```bash
  kubectl cluster-info
  kubectl get nodes
  ```

**Prerequisitos**: Fase 4 completada  
**Duración Estimada**: 15 minutos

---

### Fase 6️ | Network Plugin (CNI)

**Objetivo**: Configurar red entre pods

Ejecutar solo en `k8s-master-1`:

- [ ] Instalar Flannel (opción simple)
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
  ```
- [ ] Verificar pods de red
  ```bash
  kubectl get pods -n kube-flannel
  ```
- [ ] Esperar a que todos estén en `Running`
- [ ] Verificar que master esté `Ready`
  ```bash
  kubectl get nodes
  ```

**Alternativa**: Calico para producción
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml
  ```

**Prerequisitos**: Fase 5 completada  
**Duración Estimada**: 5-10 minutos

---

### Fase 7️ | Unir Worker

**Objetivo**: Incorporar segundo nodo al cluster

Ejecutar solo en `k8s-worker-1`:

- [ ] Ejecutar comando de unión (obtenido en Fase 5)
  ```bash
  kubeadm join 192.168.1.21:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
  ```
- [ ] Esperar sincronización (2-3 minutos)
- [ ] Validar desde `k8s-master-1`
  ```bash
  kubectl get nodes
  kubectl get pods -A
  ```

**Prerequisitos**: Fase 6 completada  
**Duración Estimada**: 5 minutos

---

### Fase 8️ | Almacenamiento Persistente

**Objetivo**: Configurar volúmenes persistentes

- [ ] Particionar disco mecánico en D1
  ```bash
  lsblk
  fdisk /dev/sda
  mkfs.ext4 /dev/sda1
  ```
- [ ] Montar en `/mnt/data-d1`
- [ ] Particionar disco mecánico en D2 (mismo procedimiento)
  ```bash
  mkfs.ext4 /dev/sda1
  ```
- [ ] Montar en `/mnt/data-d2`
- [ ] Instalar local-path-provisioner en cluster
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  ```
- [ ] Crear StorageClass personalizado
- [ ] Validar con PVC de prueba

**Prerequisitos**: Fase 7 completada  
**Duración Estimada**: 1-2 horas

---

### Fase 9️ | Despliegues de Prueba

**Objetivo**: Validar funcionamiento básico del cluster

- [ ] Desplegar Nginx de prueba
  ```bash
  kubectl create deployment nginx --image=nginx
  kubectl expose deployment nginx --port=80 --type=LoadBalancer
  ```
- [ ] Verificar distribución entre nodos
  ```bash
  kubectl get pods -o wide
  ```
- [ ] Probar persistencia
  - Desplegar StatefulSet con PVC
  - Verificar que datos persisten tras reinicio
- [ ] Validar logs y eventos
  ```bash
  kubectl logs <pod>
  kubectl describe pod <pod>
  ```

**Prerequisitos**: Fase 8 completada  
**Duración Estimada**: 30 minutos

---

### Fase 10️ | Seguridad Avanzada

**Objetivo**: Implementar RBAC y políticas de seguridad

- [ ] Configurar RBAC
  - Crear roles personalizados
  - Crear RoleBindings
- [ ] Implementar NetworkPolicies
- [ ] Configurar Pod Security Standards
- [ ] Habilitar auditoría en API Server
- [ ] Configurar backups de etcd
  ```bash
  ETCDCTL_API=3 etcdctl snapshot save backup.db
  ```

**Prerequisitos**: Fase 9 completada  
**Duración Estimada**: 2 horas

---

### Fase 11️ | Nginx Ingress Controller

**Objetivo**: Configurar enrutamiento avanzado de tráfico

- [ ] Instalar Nginx Ingress Controller
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.1/deploy/static/provider/cloud/deploy.yaml
  ```
- [ ] Crear Ingress resources
- [ ] Configurar certificados TLS (opcional: cert-manager)
- [ ] Validar enrutamiento de múltiples servicios

**Prerequisitos**: Fase 10 completada  
**Duración Estimada**: 1-2 horas

---

### Fase 12️ | Monitoreo y Observabilidad

**Objetivo**: Implementar stack de monitoreo

- [ ] Instalar Prometheus
- [ ] Instalar Grafana
- [ ] Instalar AlertManager
- [ ] Instalar node-exporter en nodos host
- [ ] Crear alertas personalizadas

**Prerequisitos**: Fase 11 completada  
**Duración Estimada**: 3-4 horas

---

### Fase 13️ | Resiliencia y Alta Disponibilidad

**Objetivo**: Mejorar tolerancia a fallos

**Nota**: Requiere ampliación RAM a 16GB y/o adición de D3

- [ ] Considerar agregar tercer nodo (D3) para HA
- [ ] Replicar etcd (3 nodos mínimo)
- [ ] Configurar Longhorn para almacenamiento distribuido
- [ ] Implementar Pod Disruption Budgets
- [ ] Crear estrategia de disaster recovery

**Prerequisitos**: Fase 12 completada, hardware mejorado  
**Duración Estimada**: Variable

---

## Estado del Proyecto

### Completado ✅

- [x] Fase 1: Preparación de Infraestructura
  - Configuración de red estática (D1, D2)
  - SSH seguro con puerto personalizado (9622)
  - Fail2ban activado
  - WireGuard VPN configurada
  - Resolución del incidente ssh.socket/ssh.service

- [x] Fase 2: Infraestructura LXC
  - LXD instalado en D1 y D2
  - Storage pool ZFS configurado
  - Red macvlan0 creada
  - Contenedores k8s-master-1 y k8s-worker-1 creados
  - IPs estáticas asignadas (192.168.1.21, 192.168.1.22)
  - Conectividad validada entre contenedores

- [x] Fase 2.2: Ampliación de Memoria RAM
  - D1: Samsung 4GB (original) + SK Hynix 4GB (desde D2) = 8GB
  - D2: 2 × Micron 4GB (nuevos) = 8GB
  - Ambos en Dual Channel

- [x] Fase 2.3: Cluster LXD
  - D1 y D2 unificados en un mismo cluster LXD
  - `lxc cluster list` muestra ambos nodos (D1 leader, D2 standby)
  - Contenedores visibles desde cualquier miembro del cluster
  - Recuperación de contenedor k8s-worker-1 tras unión al cluster

- [x] Fase 3: Runtime de Contenedores (containerd)
  - Repositorio Docker añadido en ambos contenedores
  - containerd.io instalado (v2.2.5)
  - Configuración default generada
  - Servicio activo y validado (pull de alpine exitoso)

### En Progreso 🔄

- [ ] Fase 4: Instalación de Kubernetes

### Pendiente ⏳

- [ ] Fases 4-13: Instalación de Kubernetes y componentes avanzados

### Limitaciones Conocidas ⚠️

- **RAM**: 8GB por nodo (mínimo alcanzado, ideal 16GB)
  - D1: 8GB (Samsung + SK Hynix, Dual Channel)
  - D2: 8GB (2× Micron, Dual Channel)
  
- **CPU**: 2 núcleos es mínimo absoluto
  - Control-plane (D1): Requiere más CPU
  - Worker (D2): Puede funcionar con limitaciones

- **Almacenamiento**: Partición raíz 100GB podría ser limitante
  - Disco mecánico 465GB ideal para PVC (Persistent Volume Claims)

---

## Recomendaciones Prioritarias

1. ✅ **Ampliación de RAM completada** — 8 GB por nodo (Dual Channel)
2. ✅ **Fase 3 completada** — containerd instalado y validado en ambos contenedores
3. **Continuar con Fase 4**: Instalación de Kubernetes
4. **Monitoreo activo** de rendimiento durante despliegue inicial
5. **Backups regulares** de configuración y etcd

---

## Contacto y Contribuciones

Este proyecto es parte del laboratorio de desarrollo (D-Lab) para investigación en infraestructura de contenedores y Kubernetes.
