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
| [incidentes/ip-dinamica-netplan.md](./incidentes/ip-dinamica-netplan.md) | IPs DHCP secundarias por conflicto netplan — solución: eliminar 50-cloud-init.yaml |

---

## Guía de Instalación

### Fase 1️ | Preparación de Infraestructura

**Objetivo**: Establecer base de red y seguridad

Sin una red estática y segura, Kubernetes no puede garantizar comunicación fiable entre nodos. Esta fase configura IPs fijas, SSH seguro, fail2ban y WireGuard para proteger el laboratorio antes de desplegar cualquier servicio.

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

Kubernetes necesita nodos donde ejecutarse. En lugar de instalar Kubernetes directamente sobre el SO del host, usamos LXC para aislar el cluster en contenedores ligeros, facilitando la gestión y el mantenimiento del laboratorio.

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

Los Dell OptiPlex 3050 Micro venían de serie con 4 GB — justos para el SO pero insuficientes para Kubernetes, que necesita al menos 2 GB solo para el control-plane. Esta fase reasigna y amplía los módulos para alcanzar 8 GB en Dual Channel.

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

Tener dos nodos LXD independientes obliga a gestionar contenedores por separado. Un cluster LXD unificado permite controlar ambos desde un solo punto, simplificando la administración del laboratorio.

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

Kubernetes no gestiona contenedores directamente: necesita un runtime que los cree y administre. containerd es el runtime estándar, encargado de descargar imágenes, arrancar pods y gestionar su ciclo de vida.

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

kubeadm, kubelet y kubectl son el trío base de Kubernetes: kubeadm inicializa el cluster, kubelet orquesta los pods en cada nodo y kubectl permite interactuar con el API Server. Esta fase los instala desde el repositorio oficial.

Ejecutar todos los pasos en `k8s-master-1` y `k8s-worker-1`.

- [x] Configurar containerd para systemd cgroup driver
  ```bash
  sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  sudo systemctl restart containerd
  ```

- [x] Deshabilitar swap — **no aplica en LXC** (swap virtual gestionado por el host). Se usa `failSwapOn: false` en Fase 5.

- [x] Cargar módulos de kernel necesarios (ejecutar en los **hosts** D1 y D2, no dentro del contenedor)
  ```bash
  ssh D1 "echo <CLAVE_SUDO> | sudo -S modprobe overlay && sudo modprobe br_netfilter"
  ssh -p 9622 elarreglador@192.168.1.12 \
    "echo <CLAVE_SUDO> | sudo -S modprobe overlay && sudo modprobe br_netfilter"
  ```

- [x] Configurar sysctl para red de Kubernetes
  ```bash
  cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
  net.bridge.bridge-nf-call-iptables = 1
  net.bridge.bridge-nf-call-ip6tables = 1
  net.ipv4.ip_forward = 1
  EOF
  sudo sysctl --system
  ```

- [x] Instalar dependencias para el repositorio
  ```bash
  sudo apt-get update
  sudo apt-get install -y apt-transport-https ca-certificates curl gpg
  ```

- [x] Añadir repositorio oficial de Kubernetes (v1.36)
  ```bash
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key |
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /' |
    sudo tee /etc/apt/sources.list.d/kubernetes.list
  ```

- [x] Instalar kubeadm, kubelet y kubectl
  ```bash
  sudo apt-get update
  sudo apt-get install -y kubelet kubeadm kubectl
  ```

- [x] Prevenir actualizaciones automáticas
  ```bash
  sudo apt-mark hold kubelet kubeadm kubectl
  ```

- [x] Habilitar kubelet
  ```bash
  sudo systemctl enable --now kubelet
  ```

**Prerequisitos**: Fase 3 completada  
**Duración Estimada**: 45 minutos

---

### Fase 5️ | Control-Plane

**Objetivo**: Inicializar cluster Kubernetes

El control-plane es el cerebro del cluster: aloja etcd (base de datos), el API Server (puerta de entrada), el scheduler (asignación de pods) y el controller-manager (gestión de estado). Con `kubeadm init` generamos todos estos componentes y los certificados necesarios.

Ejecutar solo en `k8s-master-1`:

- [x] Configurar LXC para Kubernetes (ejecutar UNA VEZ por contenedor)
  ```bash
  lxc config set k8s-master-1 security.nesting=true security.privileged=true
  lxc restart k8s-master-1
  # Dentro del contenedor tras reinicio:
  echo "L! /dev/kmsg - - - - /dev/console" | sudo tee /usr/lib/tmpfiles.d/kmsg.conf
  sudo ln -sf /dev/console /dev/kmsg
  sudo mount -o remount,rw /proc/sys
  ```

- [x] Inicializar control-plane (con config para LXC)
  ```bash
  cat <<EOF > /tmp/kubeadm-config.yaml
  kind: InitConfiguration
  apiVersion: kubeadm.k8s.io/v1beta4
  ---
  kind: ClusterConfiguration
  apiVersion: kubeadm.k8s.io/v1beta4
  kubernetesVersion: v1.36.2
  networking:
    podSubnet: "10.244.0.0/16"
  apiServer:
    certSANs:
    - "192.168.1.21"
  controlPlaneEndpoint: "192.168.1.21:6443"
  ---
  kind: KubeletConfiguration
  apiVersion: kubelet.config.k8s.io/v1beta1
  failSwapOn: false
  cgroupDriver: systemd
  localStorageCapacityIsolation: false
  EOF
  kubeadm init --config=/tmp/kubeadm-config.yaml --ignore-preflight-errors=SystemVerification
  ```

- [x] Subir configuraciones faltantes
  ```bash
  kubeadm init phase upload-config kubeadm --config=/tmp/kubeadm-config.yaml
  kubeadm init phase upload-config kubelet --config=/tmp/kubeadm-config.yaml
  kubeadm init phase bootstrap-token
  kubectl create clusterrolebinding kubeadm-config-reader --clusterrole=cluster-admin --group=system:bootstrappers
  ```

- [x] Copiar kubeconfig
  ```bash
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/super-admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  ```

- [x] Guardar token de unión (para Fase 7)
  ```bash
  kubeadm token create --print-join-command
  ```

- [x] Validar acceso a cluster
  ```bash
  kubectl get nodes
  ```

**Prerequisitos**: Fase 4 completada  
**Duración Estimada**: 20 minutos

---

### Fase 5.1️ | kubectl en el host D1

**Objetivo**: Poder ejecutar `kubectl` desde el host sin entrar al contenedor.

La red macvlan aísla los contenedores LXC en su propia subred, impidiendo que el host acceda directamente al API Server de Kubernetes. Este wrapper ejecuta kubectl dentro del contenedor automáticamente, dando una experiencia transparente desde D1.

Ejecutar en **D1** (no dentro del contenedor):

- [x] Instalar kubectl en D1
  ```bash
  sudo snap install kubectl --classic
  ```

- [ ] Crear directorio kubeconfig y copiarlo desde el contenedor
  ```bash
  mkdir -p $HOME/.kube
  sudo lxc exec k8s-master-1 -- cat /etc/kubernetes/super-admin.conf > $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  ```

- [x] Crear script wrapper para kubectl (solución para macvlan)
  ```bash
  mkdir -p $HOME/.local/bin
  cat > $HOME/.local/bin/kubectl << 'EOF'
  #!/bin/bash
  exec lxc exec k8s-master-1 -- kubectl "$@"
  EOF
  chmod +x $HOME/.local/bin/kubectl
  echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
  export PATH=$HOME/.local/bin:$PATH
  ```

- [x] Verificar acceso al cluster desde D1
  ```bash
  kubectl get nodes
  ```
  Resultado esperado:
  ```
  NAME           STATUS   ROLES    AGE   VERSION
  k8s-master-1   Ready    <none>   5h    v1.36.2
  k8s-worker-1   Ready    <none>   5h    v1.36.2
  ```

**Nota**: Con redes macvlan, el host NO puede contactar directamente al contenedor. El wrapper ejecuta kubectl dentro del contenedor vía `lxc exec`.

**Prerequisitos**: Fase 5 completada  
**Duración Estimada**: 5 minutos

---

### Fase 6️ | Network Plugin (CNI)

**Objetivo**: Configurar red entre pods

Los pods necesitan una red plana donde cada uno tenga una IP única y pueda comunicarse con cualquier otro sin NAT. Flannel implementa esta red overlay usando VXLAN o host-gw, asignando subredes /24 a cada nodo.

Ejecutar solo en `k8s-master-1`:

- [x] Instalar Flannel (CNI por defecto)
  ```bash
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
  ```
- [x] Subir configuración de kube-proxy (si no se genera automáticamente)
  ```bash
  kubeadm init phase addon kube-proxy --config=/tmp/kubeadm-config.yaml
  # Si kube-proxy falla por conntrack (LXC), editar ConfigMap:
  kubectl edit configmap -n kube-system kube-proxy
  # Cambiar conntrack.maxPerCore: 0 y conntrack.min: 0
  kubectl rollout restart daemonset -n kube-system kube-proxy
  ```
- [x] Verificar pods de red
  ```bash
  kubectl get pods -A
  ```
- [x] Esperar a que todos estén en `Running`
- [x] Verificar que nodos estén `Ready`
  ```bash
  kubectl get nodes
  ```

**Prerequisitos**: Fase 5 completada  
**Duración Estimada**: 5-10 minutos

---

### Fase 7️ | Unir Worker

**Objetivo**: Incorporar segundo nodo al cluster

Un cluster de un solo nodo no demuestra orquestación real. Al unir k8s-worker-1 desde D2, Kubernetes puede distribuir pods entre dos máquinas físicas, sentando las bases para alta disponibilidad y balanceo de carga.

Ejecutar en `k8s-worker-1`:

- [x] Aplicar configuración LXC para Kubernetes
  ```bash
  lxc config set k8s-worker-1 security.nesting=true security.privileged=true
  lxc restart k8s-worker-1
  # Dentro del contenedor tras reinicio:
  echo "L! /dev/kmsg - - - - /dev/console" | sudo tee /usr/lib/tmpfiles.d/kmsg.conf
  sudo ln -sf /dev/console /dev/kmsg
  sudo mount -o remount,rw /proc/sys
  ```

- [x] Ejecutar comando de unión (obtenido en Fase 5) con configuración para LXC
  ```bash
  cat <<EOF > /tmp/kubeadm-join.yaml
  apiVersion: kubeadm.k8s.io/v1beta4
  kind: JoinConfiguration
  discovery:
    bootstrapToken:
      token: "<TOKEN>"
      apiServerEndpoint: "192.168.1.21:6443"
      caCertHashes:
      - "sha256:<HASH>"
  nodeRegistration:
    kubeletExtraArgs:
      - name: "fail-swap-on"
        value: "false"
  EOF
  kubeadm join --config=/tmp/kubeadm-join.yaml --ignore-preflight-errors=SystemVerification
  ```

- [x] Esperar sincronización (2-3 minutos)
- [x] Validar desde `k8s-master-1`
  ```bash
  kubectl get nodes
  kubectl get pods -A
  ```

**Prerequisitos**: Fase 6 completada  
**Duración Estimada**: 5 minutos

---

### Fase 8️ | Almacenamiento Persistente Distribuido (GlusterFS + NFS-Ganesha + Keepalived)

**Objetivo**: Configurar volúmenes persistentes con alta disponibilidad usando GlusterFS replicado.

Longhorn y Rook/Ceph fallaron en este entorno LXC:
- **Longhorn**: `iscsid` crashea (`sendmsg: bug? ctrl_fd 4`) en kernel 7.0.0-27 dentro de LXC.
- **Rook/Ceph**: Los dispositivos de bloque LXD no son visibles dentro de pods Kubernetes (`/dev` es tmpfs).

**Solución**: GlusterFS replica datos entre nodos via FUSE (userspace, sin módulos de kernel problemáticos). Se exporta como NFS via NFS-Ganesha y se usa un VIP con Keepalived para failover automático.

**Arquitectura**:
```
Pod PVC → nfs-subdir-external-provisioner → VIP 192.168.1.30 (Keepalived)
                                                            │
                              ┌─────────────────────────────┼─────────────────────────────┐
                              │ D1 (MASTER) 192.168.1.21    │ D2 (BACKUP) 192.168.1.22   │
                              │ nfs-ganesha                 │ nfs-ganesha                 │
                              │   └── libgfapi ─────────────┼── libgfapi                  │
                              │ glusterd ◄─── replica 2 ───►│ glusterd                    │
                              │   └── /mnt/data/brick       │   └── /mnt/data/brick       │
                              │        └── /dev/sda1 (HDD)  │        └── /dev/sda1 (HDD)  │
                              └─────────────────────────────┘─────────────────────────────┘
```

#### 8.1 Detener NFS kernel server y preparar bricks

```bash
# En k8s-master-1
systemctl stop nfs-kernel-server
systemctl disable nfs-kernel-server
mkdir -p /mnt/data/brick

# En k8s-worker-1
mkdir -p /mnt/data/brick
```

#### 8.2 Instalar dependencias en ambos contenedores

```bash
# En k8s-master-1 y k8s-worker-1
apt update && apt install -y glusterfs-server nfs-ganesha nfs-ganesha-gluster keepalived
```

#### 8.3 Crear trusted pool GlusterFS

```bash
# En k8s-master-1
gluster peer probe 192.168.1.22
gluster peer status
```

#### 8.4 Crear volumen replicado

```bash
# En k8s-master-1
gluster volume create vol-storage replica 2 \
  192.168.1.21:/mnt/data/brick \
  192.168.1.22:/mnt/data/brick force
gluster volume start vol-storage
gluster volume info vol-storage
```

#### 8.5 Configurar NFS-Ganesha en ambos nodos

`/etc/ganesha/ganesha.conf` (idéntico en ambos nodos):

```ini
NFS_CORE_PARAM {
    Protocols = 3,4;
    mount_path_pseudo = true;
}
EXPORT {
    Export_Id = 1;
    Path = "/vol-storage";
    Pseudo = "/vol-storage";
    Access_Type = RW;
    Squash = No_Root_Squash;
        FSAL {
            Name = GLUSTER;
            volume = "vol-storage";
            hostname = "localhost";
        }
}
```

```bash
# En ambos nodos
systemctl enable --now nfs-ganesha
systemctl status nfs-ganesha
```

#### 8.6 Configurar Keepalived (VIP 192.168.1.30)

**En D1 (k8s-master-1)** — `/etc/keepalived/keepalived.conf`:

```bash
cat > /etc/keepalived/keepalived.conf << 'EOF'
vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass labcluster
    }
    virtual_ipaddress {
        192.168.1.30/24
    }
}
EOF
```

**En D2 (k8s-worker-1)** — mismo archivo pero `state BACKUP` y `priority 100`:

```bash
cat > /etc/keepalived/keepalived.conf << 'EOF'
vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass labcluster
    }
    virtual_ipaddress {
        192.168.1.30/24
    }
}
EOF
```

```bash
# En ambos nodos
systemctl enable --now keepalived
```

**Verificar VIP**:

```bash
# En D1 (MASTER) — debe tener la VIP
ip addr show eth0 | grep 192.168.1.30
# En D2 (BACKUP) — NO debe tenerla aún
ip addr show eth0 | grep 192.168.1.30
```

Probar failover:
```bash
# En D1
systemctl stop keepalived
# En D2 — ahora debe tener la VIP
ip addr show eth0 | grep 192.168.1.30
# Restaurar en D1
systemctl start keepalived
```

#### 8.7 Migrar NFS provisioner a la VIP

```bash
helm upgrade nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
  --namespace nfs-storage \
  --reuse-values \
  --set nfs.server=192.168.1.30 \
  --set nfs.path=/vol-storage \
  --set nfs.mountOptions="{nfsvers=3}"
```

#### 8.8 Validar con PVC de prueba

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-gluster-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: nfs-storage
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  volumes:
    - name: test-vol
      persistentVolumeClaim:
        claimName: test-gluster-pvc
  containers:
    - name: test-container
      image: busybox
      command: ["sleep", "3600"]
      volumeMounts:
        - name: test-vol
          mountPath: /data
EOF

kubectl exec test-pod -- sh -c \
  'echo "GlusterFS OK" > /data/test.txt && cat /data/test.txt'
```

#### 8.9 Probar failover

```bash
# 1. Escribir un timestamp desde el pod
kubectl exec test-pod -- sh -c 'date > /data/timestamp.txt && cat /data/timestamp.txt'

# 2. Matar D1 (desde el host D1)
lxc stop k8s-master-1

# 3. Verificar que el pod sigue accesible (puede tardar ~30s en reprogramarse)
kubectl exec test-pod -- cat /data/timestamp.txt

# 4. Recuperar D1
lxc start k8s-master-1

# 5. Escribir desde el pod de nuevo (tras reconexión)
kubectl exec test-pod -- sh -c 'date >> /data/timestamp.txt && cat /data/timestamp.txt'
```

**Prerequisitos**: Fase 7 completada, Helm instalado  
**Duración Estimada**: 1-2 horas

#### Incidencias durante la implementación

| Problema | Causa | Solución |
|----------|-------|----------|
| `mkdir: Bad message` en `/mnt/data` | Filesystem ext4 corrupto en D2 tras escrituras previas | `mkfs.ext4 -F /dev/sda1` (no había datos importantes) |
| NFS-Ganesha: `No export entries found` y `Incorrect or missing parameters for export` | El parámetro `volume_name` no es válido en FSAL GLUSTER; debe usarse `volume` | Cambiar `volume_name = "vol-storage"` → `volume = "vol-storage"` en `/etc/ganesha/ganesha.conf` |
| NFS mount falla con `mount system call failed` | NFSv4 requiere Kerberos en NFS-Ganesha sin configuración adicional | Forzar NFSv3 con `mountOptions: {nfsvers=3}` en el Helm chart del provisioner |
| D2 sin acceso a kubectl tras failover | API Server solo corre en D1; D2 no tiene kubeconfig configurado | Esperado — el cluster tiene un solo control-plane. Los pods existentes en D2 continúan funcionando y accediendo al NFS sin interrupción |

---

### Fase 9️ | Despliegues de Prueba

**Objetivo**: Validar funcionamiento básico del cluster

Antes de añadir capas de seguridad o monitoreo, conviene verificar que el cluster orquesta correctamente: despliegues, servicios, persistencia y distribución entre nodos. Un Nginx de prueba basta para validar el core.

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

Un cluster expuesto sin controles de acceso es vulnerable. RBAC restringe qué puede hacer cada usuario o servicio, NetworkPolicies aíslan tráfico entre pods y la auditoría registra toda actividad en el API Server para forense.

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

Los Services tipo ClusterIP o NodePort tienen limitaciones para enrutar tráfico HTTP/HTTPS. Un Ingress Controller actúa como proxy inverso dentro del cluster, permitiendo enrutar por dominio, TLS y balanceo de carga a múltiples servicios.

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

Sin métricas ni logs, operar un cluster es como volar a ciegas. Prometheus recolecta métricas de todos los nodos y servicios, Grafana las visualiza en paneles y AlertManager notifica cuando algo va mal.

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

Con un solo control-plane y 2 workers, el cluster tolera la caída de un worker pero no la del maestro. Esta fase prepara el camino hacia un cluster de producción: etcd replicado, Pod Disruption Budgets y un plan de disaster recovery para cuando llegue D3.

**Nota**: Requiere ampliación RAM a 16GB y/o adición de D3

- [ ] Considerar agregar tercer nodo (D3) para HA
- [ ] Replicar etcd (3 nodos mínimo)

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

- [x] Fase 4: Instalación de Kubernetes
  - Repositorio oficial pkgs.k8s.io con signed-by
  - kubeadm/kubelet/kubectl v1.36.2 instalados
  - containerd configurado con SystemdCgroup
  - kubelet habilitado

- [x] Fase 5: Control-Plane
  - kubeadm init con kubeadm-config.yaml (failSwapOn, localStorageCapacityIsolation)
  - ConfigMaps subidos (kubeadm-config, kubelet-config, bootstrap-token)
  - RBAC para system:bootstrappers configurado
  - kubeconfig operativo (super-admin.conf)

- [x] Fase 6: Network Plugin (Flannel CNI)
  - Flannel v0.28.7 instalado como DaemonSet
  - kube-proxy configurado (conntrack deshabilitado para LXC)
  - Ambos nodos Ready

- [x] Fase 7: Unir Worker
  - k8s-worker-1 unido al cluster via kubeadm join con config
  - kube-proxy y flannel funcionando en worker

### Cluster Info

```
kubectl get nodes
NAME           STATUS   ROLES    AGE   VERSION
k8s-master-1   Ready    <none>   19m   v1.36.2
k8s-worker-1   Ready    <none>   7m    v1.36.2

kubectl get pods -A
NAMESPACE      NAME                                   READY   STATUS
kube-flannel   kube-flannel-ds-xxx                    1/1     Running
kube-system    etcd-k8s-master-1                      1/1     Running
kube-system    kube-apiserver-k8s-master-1            1/1     Running
kube-system    kube-controller-manager-k8s-master-1   1/1     Running
kube-system    kube-proxy-xxx                         1/1     Running
kube-system    kube-scheduler-k8s-master-1            1/1     Running
```

### En Progreso 🔄

- [x] Fase 8: Almacenamiento Persistente (GlusterFS + NFS-Ganesha)

### Limitaciones Conocidas ⚠️

- **RAM**: 8GB por nodo (mínimo alcanzado, ideal 16GB)
  - D1: 8GB (Samsung + SK Hynix, Dual Channel)
  - D2: 8GB (2× Micron, Dual Channel)
  
- **CPU**: 2 núcleos es mínimo absoluto
  - Control-plane (D1): Requiere más CPU
  - Worker (D2): Puede funcionar con limitaciones

- **Alimentación**: Ambos nodos disponen de SAI
  - Apagar graceful del nodo worker ante corte eléctrico prolongado

- **Kubernetes en LXC**: Se requieren configuraciones especiales

- **GlusterFS con 2 nodos y replica 2**: El volumen replica 2 sobrevive la caída de un nodo (el otro sigue sirviendo). Sin embargo, ningún nodo puede caer permanentemente sin dejar el volumen degradado. Al añadir D3 se migrará a disperse (erasure code) para ~1TB usable con tolerancia a 1 fallo.

---

## Troubleshooting: Kubernetes en LXC

### Configuración necesaria para los contenedores LXC

```bash
# Habilitar nesting y modo privilegiado
lxc config set k8s-master-1 security.nesting=true security.privileged=true
lxc config set k8s-worker-1 security.nesting=true security.privileged=true
lxc restart k8s-master-1 k8s-worker-1
```

### Después de reiniciar el contenedor

```bash
# Crear symlink persistente para /dev/kmsg
echo "L! /dev/kmsg - - - - /dev/console" | tee /usr/lib/tmpfiles.d/kmsg.conf
ln -sf /dev/console /dev/kmsg

# Remontar /proc/sys como rw para kubelet
mount -o remount,rw /proc/sys

# Configurar kubelet para ignorar swap (swap virtual de LXC)
# Añadir en InitConfiguration.nodeRegistration.kubeletExtraArgs:
#   - name: "fail-swap-on"
#     value: "false"
# Y en KubeletConfiguration: localStorageCapacityIsolation: false
```

### Problemas conocidos (resueltos)

| Problema | Causa | Solución |
|----------|-------|----------|
| `SystemVerification` - kernel config no disponible | LXC no expone `/proc/config.gz` | `--ignore-preflight-errors=SystemVerification` |
| `failed to get rootfs info` | cAdvisor no reconoce device ZFS | `localStorageCapacityIsolation: false` en KubeletConfiguration |
| `open /dev/kmsg: no such file or directory` | LXC no crea /dev/kmsg | Symlink a /dev/console + tmpfiles.d |
| `running with swap on is not supported` | Swap virtual de LXC siempre activo | `failSwapOn: false` en KubeletConfiguration |
| `can't get final child's PID from pipe: EOF` | runc no funciona en contenedor no privilegiado | `security.privileged=true` + `security.nesting=true` |
| `open /proc/sys/vm/overcommit_memory: read-only` | /proc/sys montado ro en LXC | `mount -o remount,rw /proc/sys` |
| `cluster-info ConfigMap not found` | kubeadm init no completó fase upload-config | `kubeadm init phase bootstrap-token` |
| `kubelet-config ConfigMap not found` | No se subió configuración de kubelet | `kubeadm init phase upload-config kubelet` |
| Bootstrap token sin permisos RBAC | Falta ClusterRoleBinding para system:bootstrappers | `kubectl create clusterrolebinding kubeadm-config-reader --clusterrole=cluster-admin --group=system:bootstrappers` |

### Nota sobre el token de unión

El token generado por `kubeadm token create --print-join-command` requiere que el ConfigMap `cluster-info` exista en `kube-public`. Si falta:

```bash
kubeadm init phase bootstrap-token
```

---

## Contacto y Contribuciones

Este proyecto es parte del laboratorio de desarrollo (D-Lab) para investigación en infraestructura de contenedores y Kubernetes.
