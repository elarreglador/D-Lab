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
Internet (elarreglador.eu → 82.223.50.169)
    ↓
DV0 (Jumpbox / VPN Server) - VM IONOS
    │ WireGuard VPN (10.8.0.0/24)
    │
    ├── D1 - 192.168.1.11 (10.8.0.11)
    │   ├── k8s-master-1 (LXC) - 192.168.1.21  ← control-plane
    │   └── k8s-worker-1 (LXC) - 192.168.1.31  ← worker
    │
    └── D2 - 192.168.1.12 (10.8.0.12)
        ├── k8s-master-2 (LXC) - 192.168.1.22  ← control-plane
        └── k8s-worker-2 (LXC) - 192.168.1.32  ← worker
```

**Topología de Red**: Ethernet dedicada + VPN WireGuard  
**Acceso Externo**: vía DV0 (elarreglador.eu) - SSH/WireGuard  
**Control-Plane**: D1 (k8s-master-1) + D2 (k8s-master-2) — HA multi-master con etcd replicado  
**Workers**: D1 (k8s-worker-1) + D2 (k8s-worker-2)  
**Almacenamiento**: GlusterFS replica 2 vía NFS-Ganesha, VIP 192.168.1.30 (Keepalived), provisionado en los workers  
**Jumpbox**: DV0 con kubectl + lxc client para gestión remota (vía WireGuard)  

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

### DV0 - Nodo de Gestión (VM IONOS)

Máquina virtual en IONOS para acceso externo al cluster:

| Componente | Especificación |
|-----------|---------------|
| **CPU** | 1 vCPU Intel Xeon (Skylake, IBRS) |
| **RAM** | 394 MiB |
| **Almacenamiento** | 8.6 GB root (vda1) + 2 GB swap |
| **Red** | VirtIO NIC (ens6) - 82.223.50.169/32 |
| **SO** | Ubuntu Server 26.04 LTS |
| **Dominio** | elarreglador.eu |
| **VPN** | WireGuard (10.8.0.1/24, puerto 51820) |
| **Herramientas** | kubectl v1.32, lxd client |
| **Rol** | Jumpbox / VPN Server / Gestión remota |

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
- Control-plane HA: k8s-master-1 (D1) + k8s-master-2 (D2)
- Worker nodes: k8s-worker-1 (D1) + k8s-worker-2 (D2)
- etcd cluster replicado entre ambos control-planes (stacked)

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
| [files/wg0-client-d1.conf](./files/wg0-client-d1.conf) | Plantilla WireGuard para D1 (rellenar con claves reales) |
| [files/wg0-client-d2.conf](./files/wg0-client-d2.conf) | Plantilla WireGuard para D2 (rellenar con claves reales) |
| [files/setup-d1-d2.sh](./files/setup-d1-d2.sh) | Script de configuración para D1/D2 |
| [files/dv0-ssh-pubkey.txt](./files/dv0-ssh-pubkey.txt) | Instrucciones para obtener clave pública de DV0 |
| [01-Network.md#gestión-remota-desde-dv0](./01-Network.md#gestión-remota-desde-dv0) | Configuración de kubectl y lxc remote en DV0 |
| [README.md#fase-101--exposición-pública-de-servicios](./README.md#fase-101--exposición-pública-de-servicios) | Fase 10.1: Exposición pública de servicios K8s vía nginx DV0 + Let's Encrypt |
| [README.md#fase-11--nginx-ingress-controller](./README.md#fase-11--nginx-ingress-controller) | Fase 11: Ingress Controller passthrough total (nginx DV0 stream → ingress-nginx) + cert-manager |
| [README.md#fase-12--monitoreo-y-observabilidad](./README.md#fase-12--monitoreo-y-observabilidad) | Fase 12: kube-prometheus-stack (Prometheus/Grafana/AlertManager) + node-exporter hosts + alertas |

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
k8s-master-2  RUNNING  192.168.1.22  D2
k8s-worker-1  RUNNING  192.168.1.31  D1
k8s-worker-2  RUNNING  192.168.1.32  D2
```

**Notas**:
- `k8s-worker-1` puede perderse del registro al unir D2 al cluster. Recuperarlo con `lxd recover` post-unión.
- El perfil `k8s` y la red `macvlan0` deben crearse de nuevo en D2 tras la limpieza de base de datos.
- La contraseña sudo de D2 es necesaria para los pasos 3 y 4.

**Duración Estimada**: 30-45 minutos

---

### Fase 2.4 | DV0 como cliente remoto del cluster LXD

**Objetivo**: Gestionar el cluster LXD desde DV0 con comandos `lxc` sin el prefijo `d2:`, usando un remote por defecto.

Inicialmente se intentó unir DV0 como miembro del cluster, pero DV0 tiene solo 394MiB de RAM — insuficiente para ejecutar el daemon LXD (el binario snap se bloquea en lectura squashfs por falta de memoria). Como alternativa, DV0 actúa como **cliente remoto** con `d2` como remote por defecto, ofreciendo la misma experiencia de usuario sin ejecutar el daemon local.

**Solución**: Wrapper que usa el binario real de LXD directamente (sin pasar por snapd) con `d2` configurado como remote por defecto.

#### Configuración de Red (LAN vía WireGuard)

DV0 no puede alcanzar las IPs LAN (192.168.1.x) directamente. Para que DV0 se comunique con D1/D2, el tráfico LAN viaja a través del túnel WireGuard:

1. En DV0, añadir las IPs LAN a los `AllowedIPs` de cada peer en `/etc/wireguard/wg0.conf`:
   ```ini
   # Peer D1
   AllowedIPs = 10.8.0.11/32, fd42:42:42::11/128, 192.168.1.11/32, 192.168.1.21/32, 192.168.1.30/32, 192.168.1.31/32

   # Peer D2
   AllowedIPs = 10.8.0.12/32, fd42:42:42::12/128, 192.168.1.12/32, 192.168.1.22/32, 192.168.1.32/32
   ```

2. Añadir ruta estática en `PostUp` de wg0.conf (usar `replace` para que sea idempotente):
   ```bash
   ip route replace 192.168.1.0/24 dev wg0
   ```

#### Configuración del Cliente LXC

DV0 tiene el snap de LXD instalado pero snapd es inestable con 394MiB RAM. Se usa el binario real directamente:

1. **Copiar la configuración del cliente** desde el directorio snap a `~/.config/lxc/`:
   ```bash
   mkdir -p ~/.config/lxc
   cp ~/snap/lxd/common/config/config.yml ~/.config/lxc/
   cp ~/snap/lxd/common/config/client.crt ~/.config/lxc/
   cp ~/snap/lxd/common/config/client.key ~/.config/lxc/
   cp -r ~/snap/lxd/common/config/servercerts ~/.config/lxc/
   ```

2. **Configurar `d2` como remote por defecto** en `~/.config/lxc/config.yml`:
   ```yaml
   default-remote: d2
   ```

3. **Crear wrapper script** en `~/.local/bin/lxc`:
   ```bash
   mkdir -p ~/.local/bin
   cat > ~/.local/bin/lxc << 'EOF'
   #!/bin/bash
   exec /snap/lxd/40074/bin/lxc "$@"
   EOF
   chmod +x ~/.local/bin/lxc
   ```

4. **Añadir `~/.local/bin` al PATH** en `~/.bashrc`:
   ```bash
   echo 'export PATH=$HOME/.local/bin:$PATH' >> ~/.bashrc
   ```

**Uso**:
```bash
lxc cluster list    # equivalente a lxc cluster list d2:
lxc list            # lista contenedores del cluster
lxc info            # información del cluster vía D2
lxc exec k8s-master-2 -- kubectl get nodes   # desde cualquier miembro del cluster
```

**Notas**:
- El daemon LXD local de DV0 permanece detenido (snap disabled).
- Todos los comandos `lxc` se ejecutan contra el remote `d2` vía HTTPS sobre WireGuard.
- La ruta LAN vía WireGuard se ha probado exitosamente — DV0 alcanza `192.168.1.11:8443` y `192.168.1.12:8443` con ~15ms de latencia.

**Prerequisitos**: Fase 2.3 completada, WireGuard operativo  
**Duración Estimada**: 10 minutos

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
  k8s-worker-2   Ready    <none>   5h    v1.36.2
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
                              │ D1 (MASTER) 192.168.1.31    │ D2 (BACKUP) 192.168.1.32   │
                              │ k8s-worker-1                │ k8s-worker-2                │
                              │ nfs-ganesha                 │ nfs-ganesha                 │
                              │   └── libgfapi ─────────────┼── libgfapi                  │
                              │ glusterd ◄─── replica 2 ───►│ glusterd                    │
                              │   └── /mnt/data/brick       │   └── /mnt/data/brick       │
                              │        └── /dev/sda1 (HDD)  │        └── /dev/sda1 (HDD)  │
                              └─────────────────────────────┘─────────────────────────────┘
```

**Nota**: El almacenamiento corre exclusivamente en los workers (`k8s-worker-1` y `k8s-worker-2`). Los control-planes (`k8s-master-1` y `k8s-master-2`) no ejecutan servicios de almacenamiento para evitar contención de recursos.

#### 8.1 Detener NFS kernel server y preparar bricks

```bash
# En k8s-worker-1 (D1) y k8s-worker-2 (D2)
systemctl stop nfs-kernel-server 2>/dev/null || true
systemctl disable nfs-kernel-server 2>/dev/null || true
mkdir -p /mnt/data/brick
```

#### 8.2 Instalar dependencias en ambos workers

```bash
# En k8s-worker-1 y k8s-worker-2
apt update && apt install -y glusterfs-server nfs-ganesha nfs-ganesha-gluster keepalived
```

#### 8.3 Crear trusted pool GlusterFS

```bash
# En k8s-worker-1 (D1, 192.168.1.31) — probar worker-2
gluster peer probe 192.168.1.32
gluster pool list
# Debe mostrar: 192.168.1.32 Connected, localhost Connected
```

#### 8.4 Crear volumen replicado

```bash
# En k8s-worker-1
gluster volume create vol-storage replica 2 \
  192.168.1.31:/mnt/data/brick \
  192.168.1.32:/mnt/data/brick force
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

**En D1 (k8s-worker-1, 192.168.1.31)** — MASTER:

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
systemctl enable --now keepalived
```

**En D2 (k8s-worker-2, 192.168.1.32)** — BACKUP:

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

#### Nota sobre reconstrucción del almacenamiento (Jul 2026)

Tras la redistribución de workers y renombrado de contenedores (k8s-worker-1 → k8s-worker-2 en D2, nuevo k8s-worker-1 en D1), el almacenamiento GlusterFS quedó con peers y bricks rotos. Se reconstruyó desde cero:

1. **Stop/delete** volumen `vol-storage` en k8s-master-1
2. **Detach** peers huérfanos
3. **Reset** estado GlusterFS en ambos workers (`rm -rf /var/lib/glusterd/*` + reinicio glusterd) para regenerar UUIDs únicos
4. **Probe** y recreate volumen con las IPs correctas (192.168.1.31 + 192.168.1.32)
5. **Servicios de almacenamiento** (glusterd, nfs-ganesha, keepalived) deshabilitados en los control-planes (k8s-master-1, k8s-master-2) y activados en los workers

**Estado actual**: VIP 192.168.1.30 en k8s-worker-1 (MASTER, D1), k8s-worker-2 como BACKUP (D2), NFS exportando correctamente, provisioner operativo.

#### Incidencias durante la implementación

| Problema | Causa | Solución |
|----------|-------|----------|
| `mkdir: Bad message` en `/mnt/data` | Filesystem ext4 corrupto en D2 tras escrituras previas | `mkfs.ext4 -F /dev/sda1` (no había datos importantes) |
| NFS-Ganesha: `No export entries found` y `Incorrect or missing parameters for export` | El parámetro `volume_name` no es válido en FSAL GLUSTER; debe usarse `volume` | Cambiar `volume_name = "vol-storage"` → `volume = "vol-storage"` en `/etc/ganesha/ganesha.conf` |
| NFS mount falla con `mount system call failed` | NFSv4 requiere Kerberos en NFS-Ganesha sin configuración adicional | Forzar NFSv3 con `mountOptions: {nfsvers=3}` en el Helm chart del provisioner |
| D2 sin acceso a kubectl tras failover | API Server solo corre en D1; D2 no tiene kubeconfig configurado | Con etcd de **2 miembros** (quorum 2/2), la caída de D1 deja al cluster **sin quorum** (ver [Fase 13](#fase-13--resiliencia-y-alta-disponibilidad)): el API Server de k8s-master-2 no opera hasta recuperar D1. Lo que sí perdura es el **servicio NFS/GlusterFS** vía el worker vivo (replica 2 + VIP), por lo que los datos quedan intactos al recuperar el nodo. |
| Mismo UUID GlusterFS en ambos workers tras clone | k8s-worker-1 fue clonado de k8s-worker-2, heredando `/var/lib/glusterd/*` | `rm -rf /var/lib/glusterd/*` y reiniciar glusterd en cada worker para regenerar UUID único |
| GlusterFS peers apuntan a IP incorrecta tras reubicar contenedores | k8s-worker-1 renombrado y movido a D1 (192.168.1.31) pero peer/brick seguía referenciando 192.168.1.22 | Reconstruir GlusterFS desde cero: stop/delete volume, detach peers, reset workers, recreate con IPs correctas |

---

### Fase 9️ | Despliegues de Prueba

**Objetivo**: Validar funcionamiento del cluster: distribución de pods, persistencia con PVC, acceso cross-node y failover del almacenamiento.

Con el almacenamiento distribuido GlusterFS + NFS-Ganesha operativo (Fase 8), esta fase verifica que el cluster orquesta correctamente pods entre nodos, que los datos persisten tras fallos y que el failover del NFS funciona sin pérdida de información.

**Nota**: Se usa `type: NodePort` en vez de `LoadBalancer` porque el cluster no tiene un balanceador de carga externo. MetalLB se puede añadir en fases posteriores si se necesita una IP virtual para servicios.

---

#### 9.1 Desplegar Nginx stateless

```bash
kubectl create deployment nginx --image=nginx --replicas=3
kubectl expose deployment nginx --port=80 --type=NodePort
kubectl get pods -o wide
```

Verificar que los 3 pods se distribuyen entre ambos nodos. La salida debe mostrar pods en `k8s-master-1` y `k8s-worker-1`.

---

#### 9.2 StatefulSet con PVC persistente

Desplegar un StatefulSet que escribe la hora cada 10 segundos en un volumen persistente:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: nfs-storage
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: hello-storage
spec:
  serviceName: hello-storage
  replicas: 1
  selector:
    matchLabels:
      app: hello-storage
  template:
    metadata:
      labels:
        app: hello-storage
    spec:
      terminationGracePeriodSeconds: 1
      containers:
      - name: writer
        image: busybox
        command:
        - /bin/sh
        - -c
        - 'while true; do date >> /data/timestamps.log; sleep 10; done'
        volumeMounts:
        - name: data
          mountPath: /data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 100Mi
      storageClassName: nfs-storage
EOF
```

**Verificar persistencia**:

```bash
# Ver contenido inicial
kubectl exec hello-storage-0 -- cat /data/timestamps.log | tail -5

# Eliminar el pod
kubectl delete pod hello-storage-0 --now

# Esperar que el StatefulSet lo recrea automáticamente
sleep 15
kubectl get pod hello-storage-0

# Los datos deben seguir ahí
kubectl exec hello-storage-0 -- cat /data/timestamps.log | tail -5
```

---

#### 9.3 Acceso cross-node al mismo PVC

Verificar que un PVC puede ser montado por pods en distintos nodos:

```bash
# Pod en el nodo que quieras (el scheduler decide)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cross-node-pod
spec:
  volumes:
  - name: shared-vol
    persistentVolumeClaim:
      claimName: data-pvc
  containers:
  - name: writer
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: shared-vol
      mountPath: /shared
EOF

kubectl get pod cross-node-pod -o wide

# Escribir desde el pod
kubectl exec cross-node-pod -- sh -c \
  'echo "escrito desde $(hostname)" > /shared/cross-node.txt && cat /shared/cross-node.txt'

# Verificar desde el StatefulSet (puede estar en otro nodo)
kubectl exec hello-storage-0 -- cat /data/cross-node.txt
```

---

#### 9.4 Probar failover del NFS

Simular la caída del nodo que tiene el API Server y el NFS-Ganesha MASTER:

```bash
# 1. Escribir datos de referencia
kubectl exec hello-storage-0 -- date >> /data/timestamps.log

# 2. Detener D1 (pierdes kubectl)
lxc stop k8s-master-1

# 3. El pod en D2 sigue vivo y puede escribir (vía D2 host)
lxc exec k8s-worker-1 -- cat /data/timestamps.log | tail -5

# 4. Recuperar D1
lxc start k8s-master-1

# 5. Esperar que NFS-Ganesha se recupere (puede fallar al arrancar
#    si GlusterFS no está listo aún → restart manual)
systemctl restart nfs-ganesha

# 6. Verificar datos intactos tras failback
kubectl exec hello-storage-0 -- cat /data/timestamps.log | tail -5
```

**Nota sobre failback**: Al recuperar D1, el VIP vuelve a D1 y el NFS-Ganesha local
debe reexportar el volumen. Si arranca antes que GlusterFS, falla con
`Unable to initialize volume` y `showmount -e` aparece vacío. Solución:
`systemctl restart nfs-ganesha` en D1 tras confirmar que GlusterFS está conectado
(`gluster peer status`). Además, los pods existentes montados vía NFS pueden
quedar con `Stale file handle` al migrar el VIP de vuelta; eliminar y
dejar que el controlador (Deployment/StatefulSet) los recrea.

---

#### 9.5 Verificar replicación en GlusterFS

Comprobar que los datos escritos existen en ambos bricks:

```bash
# Obtener el PV name
PV_NAME=$(kubectl get pvc data-pvc -o jsonpath='{.spec.volumeName}')

# En D1
ls /mnt/data/brick/default-data-pvc-${PV_NAME}/
cat /mnt/data/brick/default-data-pvc-${PV_NAME}/timestamps.log | tail -3

# En D2
lxc exec k8s-worker-1 -- \
  cat /mnt/data/brick/default-data-pvc-${PV_NAME}/timestamps.log | tail -3
```

Ambos deben mostrar el mismo contenido.

---

#### 9.6 Limpiar recursos de prueba

```bash
kubectl delete deployment nginx
kubectl delete service nginx
kubectl delete statefulset hello-storage
kubectl delete pvc data-pvc
kubectl delete pod cross-node-pod
```

---

**Prerequisitos**: Fase 8 completada  
**Duración Estimada**: 1-2 horas

---

### Fase 10️ | Seguridad Avanzada

**Objetivo**: Implementar RBAC y políticas de seguridad

Un cluster expuesto sin controles de acceso es vulnerable. RBAC restringe qué puede hacer cada usuario o servicio, NetworkPolicies aíslan tráfico entre pods y la auditoría registra toda actividad en el API Server para forense.

- [x] Configurar RBAC
  - Crear ClusterRoles: `developer`, `readonly`, `namespace-admin`
  - Crear ClusterRoleBindings: `readonly-binding` (grupo `system:readonly`), `developer-binding` (grupo `system:developers`)
- [ ] Implementar NetworkPolicies
  - **¿Qué son?**: Aíslan tráfico entre pods. Por defecto todo pod puede hablar con cualquier otro pod. Con NetworkPolicies defines reglas como "el pod A solo acepta tráfico del pod B en el puerto 8080".
  - **Problema**: Flannel (nuestro CNI) **no soporta** NetworkPolicies. Solo gestiona la red overlay (IPs y rutas), no tiene motor de políticas para filtrar tráfico.
  - **Soluciones**:
    1. **Calico policy-only**: se instala junto a Flannel, añade el motor de políticas sin reemplazar la red. Requiere ajustar Flannel para evitar conflictos de iptables.
    2. **Cilium**: reemplazaría Flannel completamente (red + políticas integradas). Más moderno (eBPF) pero requiere migrar el CNI con downtime.
  - **Estado**: Pendiente de evaluar impacto e implementar una de las dos opciones.
- [x] Configurar Pod Security Standards (PSS)
  - `kube-system`, `kube-flannel`: privileged
  - `default`, `nfs-storage`: baseline con warn restricted
- [x] Habilitar auditoría en API Server
  - Audit policy en `/etc/kubernetes/audit/policy.yaml` (Metadata level, excluye healthz)
  - Logs en `/var/log/kubernetes/audit/audit.log` (max 7 días, 100MB, 10 backups)
  - Aplicado en ambos control-planes (k8s-master-1, k8s-master-2)
- [x] Configurar backups de etcd
  - Script: `/usr/local/bin/backup-etcd.sh` (snapshot diaria via etcdctl)
  - Destino: `/backup/etcd/` (rotación: últimas 30 copias)
  - Cron: `/etc/cron.d/etcd-backup` (diario a las 2:00 AM)

**Prerequisitos**: Fase 9 completada  
**Duración Estimada**: 2 horas

---

### Fase 10.1 | Exposición Pública de Servicios (nginx DV0 + Let's Encrypt)

**Objetivo**: Publicar servicios del cluster Kubernetes en internet a través de DV0 como punto de entrada único con TLS (Let's Encrypt).

Los Services de tipo ClusterIP o NodePort solo son alcanzables dentro de la red del cluster/LAN. Para exponer un servicio al exterior se construyó una cadena de proxy que aprovecha el túnel WireGuard y un LXC proxy device, sin necesidad de un Ingress Controller todavía (pendiente en Fase 11).

**Arquitectura**:
```
Internet → elarreglador.eu (DNS A → 82.223.50.169)
              ↓
DV0 nginx (443, TLS Let's Encrypt)
              ↓ proxy_pass
http://10.8.0.11:31113 (túnel WireGuard → D1)
              ↓
LXC proxy device `proxy31113` (listen tcp:10.8.0.11:31113)
              ↓ connect
tcp:127.0.0.1:31113 (k8s-worker-1)
              ↓
Service NodePort `test-web` 80:31113/TCP → pods nginx
```

**Por qué esta cadena**: DV0 no puede alcanzar las IPs LAN de los containers (ruteo asimétrico — sus respuestas salen por el router doméstico que no conoce 10.8.0.0/24). Por eso el proxy apunta a la **IP WG del host D1** (`10.8.0.11`), donde el LXC proxy device escucha y reenvía al NodePort.

**Procedimiento realizado**:

1. **Desplegar el servicio de prueba** en k8s-master-1:
   ```bash
   kubectl create deployment test-web --image=nginx:alpine --replicas=2
   kubectl expose deployment test-web --port=80 --type=NodePort --name=test-web
   # El NodePort asignado es 31113: 80:31113/TCP
   ```

2. **Añadir LXC proxy device** en D1 (host) para el container k8s-worker-1:
   ```bash
   lxc config device add k8s-worker-1 proxy31113 proxy \
     connect=tcp:127.0.0.1:31113 listen=tcp:10.8.0.11:31113
   ```

3. **Emitir certificado Let's Encrypt** en DV0:
   ```bash
   certbot certonly --nginx -d www.elarreglador.eu -d elarreglador.eu
   # Certificado en /etc/letsencrypt/live/www.elarreglador.eu/
   # Expiración: 2026-10-28 (renovación automática configurada)
   ```

4. **Configurar nginx** en `/etc/nginx/sites-available/k8s` (symlink en sites-enabled, default desactivado):
   ```nginx
   server {
       listen 80;
       server_name *.elarreglador.eu elarreglador.eu;
       return 301 https://$server_name$request_uri;
   }

   server {
       listen 443 ssl;
       http2 on;
       server_name www.elarreglador.eu elarreglador.eu;

       ssl_certificate /etc/letsencrypt/live/www.elarreglador.eu/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/www.elarreglador.eu/privkey.pem;

       location / {
           proxy_pass http://10.8.0.11:31113;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;
       }
   }
   ```
   ```bash
   nginx -t && systemctl reload nginx
   ```

**Verificación**:
```bash
curl https://www.elarreglador.eu   # → 200 (nginx welcome)
curl https://elarreglador.eu       # → 200
```

**Notas**:
- **DNS**: tras la Fase 11 existe un registro wildcard `*.elarreglador.eu` → `82.223.50.169` (TTL 300, añadido en Spaceship). Esta fase cubría únicamente `elarreglador.eu` y `www.elarreglador.eu`.
- **TLS y balanceo**: esta fase terminaba TLS en nginx de DV0 y apuntaba a un único NodePort. En la Fase 11 se migró a passthrough total con Ingress Controller dentro del cluster (ver [Fase 11](#fase-11--nginx-ingress-controller)); el certificado aquí descrito fue retirado de DV0 el 2026-07-31.
- Los handshakes WireGuard se mantienen frescos con `PersistentKeepalive=25` (ver [01-Network.md](./01-Network.md#wireguard-estabilidad-de-conexión)).

**Prerequisitos**: Fase 10 completada, WireGuard operativo  
**Duración Estimada**: 1-2 horas

---

### Fase 11️ | Nginx Ingress Controller

**Objetivo**: Migrar la exposición pública a passthrough total con Ingress Controller y certificado TLS gestionado dentro del cluster (cert-manager).

Los Services tipo ClusterIP o NodePort tienen limitaciones para enrutar tráfico HTTP/HTTPS. Un Ingress Controller actúa como proxy inverso dentro del cluster, permitiendo enrutar por dominio, TLS y balanceo de carga a múltiples servicios.

**Arquitectura** (passthrough total — DV0 solo reenvía bytes, sin TLS):
```
Internet → *.elarreglador.eu (DNS wildcard A → 82.223.50.169)
              ↓
DV0 nginx (módulo stream, TCP 80/443 → 10.8.0.11:30080/30443)
              ↓ túnel WireGuard
LXD proxy devices `proxy30080`/`proxy30443` (listen tcp:10.8.0.11:30080/30443)
              ↓ connect
tcp:127.0.0.1:30080/30443 (k8s-worker-1, NodePorts ingress-nginx)
              ↓
ingress-nginx (Ingress resources por hostname)
              ↓ TLS (cert-manager, Let's Encrypt)
Service `landing` → pods nginx (web estática, [Web pública](#web-pública-landing))
```

**Por qué este diseño**: DV0 tiene 1 vCPU y 394MB RAM, por lo que terminar TLS allí es costoso. Se optó por **passthrough total**: DV0 (módulo `stream`) reenvía los bytes TCP sin inspeccionarlos y el TLS lo termina ingress-nginx dentro del cluster. DV0 no puede alcanzar las IPs LAN de los containers (ruteo asimétrico), por eso los proxy apuntan a la IP WG del host D1 (`10.8.0.11`).

**DNS previo**: registro wildcard `*.elarreglador.eu` → `82.223.50.169` (TTL 300) añadido en Spaceship, verificado con `test.elarreglador.eu` y `foo.elarreglador.eu`.

**Procedimiento realizado**:

1. **Instalar ingress-nginx** (vía helm en k8s-master-1) como NodePort fijo:
   ```bash
   helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
   helm install ingress-nginx ingress-nginx/ingress-nginx \
     --namespace ingress-nginx --create-namespace \
     --set controller.service.type=NodePort \
     --set controller.service.nodePorts.http=30080 \
     --set controller.service.nodePorts.https=30443 \
     --set controller.kind=Deployment --wait --timeout 300s
   ```

2. **Añadir LXC proxy devices** en D1 (host) para el container k8s-worker-1:
   ```bash
   lxc config device add k8s-worker-1 proxy30080 proxy \
     connect=tcp:127.0.0.1:30080 listen=tcp:10.8.0.11:30080
   lxc config device add k8s-worker-1 proxy30443 proxy \
     connect=tcp:127.0.0.1:30443 listen=tcp:10.8.0.11:30443
   ```

3. **Activar módulo stream en nginx DV0** e instalar el passthrough:
   ```bash
   apt install libnginx-mod-stream   # carga /etc/nginx/modules-enabled/50-mod-stream.conf
   ```
   Añadir a `/etc/nginx/nginx.conf`:
   ```nginx
   stream {
       include /etc/nginx/stream.conf.d/*.conf;
   }
   ```
   `/etc/nginx/stream.conf.d/k8s-passthrough.conf`:
   ```nginx
   upstream k8s_ingress_http  { server 10.8.0.11:30080; }
   upstream k8s_ingress_https { server 10.8.0.11:30443; }

   server { listen 80;  proxy_pass k8s_ingress_http;  proxy_timeout 300s; }
   server { listen 443; proxy_pass k8s_ingress_https; proxy_timeout 300s; }
   ```
   Retirar el sitio HTTP antiguo (`sites-available/k8s` + symlink en sites-enabled) que ocupaba 80/443:
   ```bash
   nginx -t && systemctl reload nginx
   ```

4. **Instalar cert-manager** (vía helm en k8s-master-1):
   ```bash
   helm repo add jetstack https://charts.jetstack.io
   helm install cert-manager jetstack/cert-manager \
     --namespace cert-manager --create-namespace \
     --version v1.17.2 --set crds.enabled=true --wait --timeout 300s
   ```
   Crear ClusterIssuer HTTP-01 (solver `ingress: { class: nginx }`) y Certificate para `elarreglador.eu` y `www.elarreglador.eu` (secret TLS `elarreglador-eu-tls`; el SAN de `test.elarreglador.eu` se retiró el 2026-08-01 al quedar sin servicio).

   **Nota**: HTTP-01 no emite wildcards (solo DNS-01 con acceso a la API del DNS). Como los subdominios son fijos, HTTP-01 es suficiente.

5. **Crear Ingress resource** `elarreglador-landing` (`ingressClassName: nginx`) con los hostnames `elarreglador.eu` y `www.elarreglador.eu` → backend `landing:80` y `force-ssl-redirect: "true"` (sin autenticación; ver [Web pública (landing)](#web-pública-landing)). El antiguo Ingress `elarreglador-eu` (3 hostnames → `test-web`) fue retirado el 2026-08-01 junto con el servicio de prueba.

**Verificación**:
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://elarreglador.eu   # → 200 (sin credenciales)
curl -s -o /dev/null -w '%{http_code}\n' https://www.elarreglador.eu # → 200
curl -sk https://test.elarreglador.eu    # → 404 (host retirado)
echo | openssl s_client -connect elarreglador.eu:443 -servername elarreglador.eu \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
# subject=CN = elarreglador.eu, issuer=Let's Encrypt, SANs: elarreglador.eu, www.*
```

**Notas**:
- El certificado antiguo de DV0 (www + apex, certbot) fue retirado (`certbot delete --cert-name www.elarreglador.eu`) al quedar sin uso tras el passthrough.
- `test-web` (nginx de prueba de Fase 10.1) y su Ingress fueron retirados el 2026-08-01; su NodePort 31113 interno se eliminó junto al deployment y el service.
- La renovación del certificado la gestiona cert-manager automáticamente (HTTP-01 revalida ~30 días antes de expirar).

**Prerequisitos**: Fase 10.1 completada, WireGuard operativo, wildcard DNS en Spaceship  
**Duración Estimada**: 2-3 horas

---

### Fase 12️ | Monitoreo y Observabilidad

**Objetivo**: Desplegar un stack de monitoreo completo (Prometheus + Grafana + AlertManager) con métricas de cluster y de los hosts físicos, expuesto públicamente con autenticación.

Sin métricas ni logs, operar un cluster es como volar a ciegas. Prometheus recolecta métricas de todos los nodos y servicios, Grafana las visualiza en paneles y AlertManager agrupa y muestra las alertas.

**Arquitectura**:
```
kube-prometheus-stack (helm, namespace monitoring)
  ├─ prometheus-operator ── gestiona Prometheus/AlertManager vía CRDs
  ├─ prometheus-0        ── scrape: kubelet, apiserver, coredns, node-exporter,
  │                         kube-state-metrics, host-node (D1/D2), cert-manager
  ├─ grafana (3/3)       ── exposed en https://grafana.elarreglador.eu
  ├─ alertmanager        ── sin receiver (alertas solo UI)
  └─ node-exporter DS    ── métricas de los 4 nodos K8s
node-exporter nativo en D1/D2 (apt) ── métricas de los hosts físicos (OS)
```

**Decisiones de diseño**:
- **Almacenamiento efímero** (`emptyDir`) para Prometheus, Grafana **y AlertManager**: la TSDB de Prometheus sobre GlusterFS/NFS no es fiable (el primer intento con PVC NFS dejó `prometheus-0` sin poder arrancar la TSDB). No existe ningún PVC de monitoreo (verificado 2026-08-01: los StatefulSets usan `emptyDir`). La configuración vive en ConfigMaps/Secrets, así que se pierde solo el histórico.
- **Recursos ajustados**: el primer despliegue hizo OOM a Grafana (límite 256Mi → `exitCode 137`). Se subió a 512Mi/200Mi. DV0 con 1 vCPU no soportaría este stack; por eso corre en los nodos del cluster.
- **Node-exporter host en ambos modos**: DaemonSet para los 4 nodos K8s + paquete nativo `prometheus-node-exporter` en D1/D2 (métricas del OS físico del host, no del container).
- **Alertas sin notificación**: solo se ven en la UI de AlertManager (sin receiver). El usuario decidió no configurar envíos externos en esta fase.

**Limitación de red descubierta (macvlan)**:
Los containers LXD usan red **macvlan** (`macvlan0`), que por diseño impide que un container alcance a su **propio host**. D1 no es alcanzable desde los containers que corren en D1 (ni por IP LAN ni WG), mientras que D2 sí es alcanzable (los containers de D1 llegan a `192.168.1.12`). Solución adoptada para D1:
- `socat` en D2 como relay: `TCP4-LISTEN:19100 → TCP4:192.168.1.11:9100` (servicio systemd `node-exporter-relay-d1`).
- El ServiceMonitor `host-node` scrapea D2 directo (`:9100`) y D1 vía relay (`:19100`), con relabeling `host=d2`/`host=d1`.

**Procedimiento realizado**:

1. **Instalar kube-prometheus-stack** (vía helm en k8s-master-1), namespace `monitoring`, con `values-monitoring.yaml`:
   ```bash
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
     --namespace monitoring --create-namespace \
     --values /root/values-monitoring.yaml --wait --timeout 300s
   ```
   Values destacados: Prometheus/Grafana/AlertManager efímeros (`emptyDir`), Grafana `requests 200Mi/limits 512Mi`, `adminPassword` generada.

   **Incidencias resueltas**: (1) Grafana OOM con 256Mi → límite a 512Mi. (2) Prometheus sin arrancar la TSDB sobre PVC NFS → storage efímero. (3) `helm upgrade --wait` en estado `failed` → desinstalar y reinstalar limpio con los values corregidos (causa raíz: el values subido al container era una versión antigua, el `lxc file push` no se había repetido tras editar el local).

2. **node-exporter nativo en D1/D2**:
   ```bash
   apt-get install -y prometheus-node-exporter   # escucha en 0.0.0.0:9100
   ```
   Durante este paso se detectó que **systemd-resolved de D1/D2 no resolvía** (los intentos de apt quedaban colgados). El stub `127.0.0.53` no respondía aunque los upstream (1.1.1.1/8.8.8.8) sí resolvían por `nslookup` directo. Solución de laboratorio: `resolv.conf` estático con `nameserver 1.1.1.1`/`8.8.8.8`.
   Manifiestos: Service headless `host-node` (ports 9100/19100) + Endpoints manuales + ServiceMonitor `host-node` (con label `release: kube-prometheus-stack`, requerida por el `serviceMonitorSelector` de Prometheus).

3. **Grafana público con clave de acceso web** (ver [Clave única de acceso web](#clave-única-de-acceso-web)):
   - Ingress `grafana` con `auth-type: basic`, `force-ssl-redirect`, TLS → `grafana.elarreglador.eu`.
   - Certificate `grafana-elarreglador-eu` (cert-manager, HTTP-01) en namespace `monitoring` — los secrets TLS deben vivir en el mismo namespace que el Ingress, por eso no se reutilizó el secret `elarreglador-eu-tls` (que está en `default`).
   - Grafana configurado con **anonymous Viewer** (`grafana.ini` → `auth.anonymous`): la clave compartida es la única barrera, sin login interno.

4. **ServiceMonitor cert-manager** (Service `cert-manager:9402` en namespace `cert-manager`) + **PrometheusRule `alertas-personalizadas`** (grupo `host-alertas`): `HostDown` (hosts), `ClusterNodeNotReady`, `DiskPressureHost` (>85%), `CertificateExpiring` (<30 días).

**Verificación**:
```bash
# Public path: clave de acceso web 401 sin credenciales, 200 con ellas
curl -s -o /dev/null -w '%{http_code}\n' https://grafana.elarreglador.eu/   # 401
curl -s -o /dev/null -w '%{http_code}\n' -u elarreglador:CLAVE https://grafana.elarreglador.eu/  # 200 (carga sin login interno)
echo | openssl s_client -connect grafana.elarreglador.eu:443 -servername grafana.elarreglador.eu \
  | openssl x509 -noout -subject -issuer -dates   # CN=grafana.elarreglador.eu, Let's Encrypt

# Targets Prometheus (API v1): host-node x2 up, cert-manager up, node-exporter x4 up
curl -s http://127.0.0.1:9090/api/v1/targets   # (vía port-forward)

# Datos de hosts con label correcta
curl -s 'http://127.0.0.1:9090/api/v1/query?query=node_uname_info'
# host=d1 → D1 scrapeado vía relay socat de D2 (192.168.1.12:19100 → D1:9100)
# host=d2 → D2 scrapeado directo (192.168.1.12:9100)
```

**Credenciales** (guardar en backup local):
- Clave única de acceso web (todos los servicios): usuario `elarreglador` / clave canónica en `info_sensible/htpasswd-web` (gitignored). Ver [Clave única de acceso web](#clave-única-de-acceso-web).
- Grafana admin (mantenimiento): `admin` / password en `values-monitoring.yaml` (`adminPassword`).

**Notas**:
- Las alertas por defecto de kube-prometheus-stack `TargetDown`, `etcdMembersDown` e `etcdInsufficientMembers` aparecen **firing** en AlertManager porque los targets `kube-etcd`, `kube-scheduler`, `kube-controller-manager` y `kube-proxy` no exponen métricas en los puertos por defecto en este cluster LXC. Es ruido esperable en esta configuración; la cadena principal (kubelet, apiserver, coredns, node-exporter, hosts) está **up**.
- `Watchdog` siempre está en firing por diseño (alerta centinela para validar el pipeline).

**Prerequisitos**: Fase 11 completada, WireGuard operativo, DNS wildcard en Spaceship  
**Duración Estimada**: 3-4 horas

### Clave única de acceso web

**Objetivo**: que cualquier servicio web expuesto públicamente pida siempre la misma clave de acceso, gestionada desde un único sitio (equivalente al `auth_basic_user_file` de un virtual server nginx clásico).

**Cómo funciona**: ingress-nginx exige HTTP Basic Auth a nivel de Ingress mediante anotaciones. La clave (usuario `elarreglador`) se guarda como un único fichero htpasswd canónico y se replica como Secret `web-basic-auth` en cada namespace que tenga un Ingress público. Todos los servicios usan el mismo Secret.

**Fichero canónico y sincronización**:
- Fuente única: `info_sensible/htpasswd-web` (gitignored, formato `$apr1$`).
- Script `scripts/sync-web-auth.sh`: lee el fichero local y crea/actualiza el Secret `web-basic-auth` en los namespaces listados (`monitoring` por defecto). Genera el YAML localmente y lo aplica por stdin vía `ssh server` (el hash nunca se escribe en disco de DV0).
  ```bash
  ./scripts/sync-web-auth.sh            # namespaces por defecto (monitoring)
  WEB_AUTH_NAMESPACES="monitoring" ./scripts/sync-web-auth.sh
  ```

**Anotaciones necesarias en cada Ingress público** (el valor de `auth-realm` es libre; el resto es idéntico en todos):
```yaml
nginx.ingress.kubernetes.io/auth-type: basic
nginx.ingress.kubernetes.io/auth-secret: web-basic-auth
nginx.ingress.kubernetes.io/auth-realm: "Elarreglador - autenticacion requerida"
nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```

**Proteger un nuevo servicio**: (1) ejecutar el script con su namespace en la lista, (2) añadir las 4 anotaciones a su Ingress, (3) comprobar 401/200. Nada más.

**Rotar la clave** (todos los servicios a la vez):
```bash
htpasswd -nbB elarreglador '<NUEVA_CLAVE>' > info_sensible/htpasswd-web
./scripts/sync-web-auth.sh
```

**Verificación actual** (hostnames públicos protegidos):
```bash
curl -s -o /dev/null -w 'grafana sin-auth=%{http_code}\n' https://grafana.elarreglador.eu/
curl -s -o /dev/null -w 'grafana con-auth=%{http_code}\n' -u elarreglador:CLAVE https://grafana.elarreglador.eu/
# 401 sin credenciales, 200 con ellas
```

**Excepción**: `elarreglador.eu` y `www.elarreglador.eu` están **fuera** de esta protección: sirven la landing pública (ver [Web pública (landing)](#web-pública-landing)) y responden 200 sin credenciales.

**Nota de seguridad**: la clave sudo/LXD se reutiliza como clave web por decisión del señor (una sola clave para todo). Esto amplía su superficie de exposición (viaja en cada petición, cifrada por TLS). Mitigado con: `force-ssl-redirect`, hash `$apr1$` en Secret, fichero canónico gitignored y rotación centralizada. Si algún día se separan, solo hay que rotar la web por el procedimiento anterior.

### Web pública (landing)

**Objetivo**: exponer `elarreglador.eu` (y `www.elarreglador.eu`) como página de presentación **pública, sin credenciales**, alojada dentro del cluster en pods Kubernetes.

**Dónde se aloja**:
- **Fuente de verdad**: repositorio, `files/landing/` (`index.html`, `styles.css`, `*.svg`, `*.webp`).
- **En el cluster**: un **ConfigMap `landing-html`** (vive en etcd) con todos los ficheros; el Deployment monta ese ConfigMap (solo lectura) en `/usr/share/nginx/html/` de los pods `landing` (nginx:alpine, 2 réplicas). Los pods son efímeros: si caen, el Deployment los recrea y re-montan el contenido desde etcd.
- **Ruta**: `elarreglador.eu`/`www` → Ingress `elarreglador-landing` → Service `landing` (ClusterIP:80) → pods nginx. Sin anotaciones de auth.

**Características de la página**:
- Solo **HTML + CSS** (CSS en fichero independiente `styles.css`), **sin JS ni assets externos**; imágenes locales (ficheros `.svg` y `.webp` servidos por el propio pod).
- **Fotografía generada por IA** (pollinations.ai, optimizada a WebP 800px, ~10 KB): `hero.webp` como foto del hero. Sin info sensible; se trata como el resto de la web. (Las anteriores `iot.webp`/`rack.webp`/`control.webp` se retiraron el 2026-08-01 por decisión del señor.)
- **Tema heredado del sistema del visitante**: variables CSS con `prefers-color-scheme` (claro/oscuro) y `color-scheme: light dark`; las fotos se atenúan ligeramente en modo oscuro.
- **Responsive** (grid `auto-fit`, `clamp()` en tipografías, media queries para móvil) y accesible (HTML semántico, `lang="es"`, `alt`, skip-link, `prefers-reduced-motion`).
- Contenido compacto: presentación con apodo `@elarreglador` (subtítulo enlazado al perfil de GitHub), tecnologías (SRE/IoT/Desarrollo/Herramientas), contacto (GitHub, repositorios, Currículum, correo, LinkedIn, D-Lab) y pie.
- Cabecera fija (sticky): logo monograma `DM` + nombre en la brand y navegación por anclas; fondo al 96% de opacidad (oscurecida) con blur y borde inferior.

**Desplegar/actualizar** (el contenido viaja por stdin, método probado):
```bash
./scripts/deploy-landing.sh
```
El script construye el ConfigMap `landing-html` desde `files/landing/` (claves planas: `index.html`, `styles.css`, `*.svg`, `*.webp` — ConfigMap no admite `/` en las claves). Todas las claves se escriben en `binaryData` (base64), incluidos los ficheros de texto, por simplicidad del generador; los pods las montan igualmente como ficheros. Aplica ConfigMap + Deployment/Service + Ingress vía `ssh server`, reiniciando los pods para forzar la carga del contenido.

**Verificación**:
```bash
curl -s -o /dev/null -w '%{http_code}\n' https://elarreglador.eu    # 200 sin credenciales
curl -s -o /dev/null -w '%{http_code}\n' https://www.elarreglador.eu # 200
curl -s -o /dev/null -w '%{http_code}\n' https://elarreglador.eu/styles.css  # 200 (assets locales)
```

**Nota**: la imagen `nginx:alpine` stock requiere root (entrypoint y cachés), por lo que el pod no cumple el perfil PSA `restricted` (solo `warn` en este namespace; `enforce: baseline` sí se cumple). Para `restricted` habría que servir con imagen no-root (p. ej. puerto 8080 + usuario `nginx`), fuera de alcance para una landing estática.

**Límite y fallback**: el ConfigMap no puede superar ~1 MiB. El script `deploy-landing.sh` aborta con un mensaje claro antes de aplicar si se supera (el contenido actual pesa ~25 KB). Si algún día la web creciera más allá del límite, se migra a **imagen nginx custom**: `Dockerfile` (nginx:alpine + `COPY` de `files/landing/`), build en DV0 con docker, importar en cada nodo (`docker save | lxc exec k8s-master-1 -- ctr images import`, idem workers) y `imagePullPolicy: IfNotPresent` en el Deployment.

---

### Fase 13️ | Resiliencia y Alta Disponibilidad

**Objetivo**: Mejorar tolerancia a fallos

Con un solo control-plane y 2 workers, el cluster tolera la caída de un worker pero no la del maestro. Esta fase implementa control-plane HA con etcd replicado entre ambos nodos físicos.

### ¿Qué es etcd?

etcd es la base de datos del cluster Kubernetes. Es un almacén **clave-valor** distribuido que usa el **protocolo Raft** para mantener el consenso entre nodos.

**¿Qué guarda etcd?**
- Todo el estado del cluster: pods, Services, Deployments, ConfigMaps, Secrets, nodos...
- Cada `kubectl apply` o cambio en el cluster se traduce en una escritura en etcd.

**¿Por qué es crítico?**
- Si etcd se corrompe o pierde datos, **el cluster entero muere** — no hay API Server, los pods siguen corriendo pero no se pueden gestionar.
- Por eso se hacen backups diarios (Fase 10).

**En nuestro cluster**: Modo **stacked** — cada control-plane ejecuta su propio etcd (1 miembro por master). Con 2 miembros, si uno falla el cluster etcd pierde quorum (necesita mayoría = 2 de 2). Para HA real se necesita un tercer miembro.

**Nota sobre roles (verificado 2026-08-01)**: `k8s-master-1` ejecuta los componentes de control-plane (apiserver, etcd, scheduler, controller-manager) pero **no tiene** la etiqueta `node-role.kubernetes.io/control-plane` ni el taint `NoSchedule`; solo `k8s-master-2` los conserva. Consecuentemente, el scheduler puede ubicar pods de usuario en `k8s-master-1`. Se documenta el estado real por decisión del señor (sin cambios en el cluster).

- [x] Agregar segundo control-plane (k8s-master-2 en D2)
- [x] etcd replicado (stacked, 2 miembros)
- [ ] Agregar tercer nodo (D3) para quorum etcd (3 nodos mínimo)
- [ ] Implementar Pod Disruption Budgets
- [ ] Crear estrategia de disaster recovery

**Nota técnica**: etcd con 2 miembros es funcional pero no tolera fallos de un control-plane (pierde quorum). Para HA real se necesita un tercer miembro (D3 o miembro externo).

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

- [x] Nodo de Gestión DV0
  - VM IONOS (Ubuntu 26.04) con dominio elarreglador.eu
  - WireGuard VPN server reinstaurado (10.8.0.1/24, puerto 51820)
  - WireGuard estabilizado con `PersistentKeepalive=25` en D1/D2 (evita caída del túnel por NAT timeout)
  - WireGuard migrado a **split-tunnel** (`AllowedIPs = 10.8.0.1/32`) en D1/D2 — elimina bucles de ruteo y la dependencia de internet por el túnel (ver [01-Network.md#wireguard-estabilidad-y-split-tunnel](./01-Network.md#wireguard-estabilidad-y-split-tunnel))
  - kubectl v1.32 instalado y configurado (kubeconfig vía LXC proxy device 10.8.0.11:6443)
  - LXD client instalado y configurado (remote `d2` apuntando a `https://10.8.0.12:8443`)
  - Clave SSH generada para acceso a D1/D2
  - Plantillas WireGuard para D1/D2 en files/ (claves reales en backup local)
  - LXC proxy device en D1: `10.8.0.11:6443 → k8s-master-1:6443`
  - API LXD de D2 cambiada a `[::]:8443` para acceso desde DV0 vía WireGuard
  - Repositorio sanitizado: `filter-branch` para eliminar claves reales del historial git
  - Documentación de gestión remota en [01-Network.md#gestión-remota-desde-dv0](./01-Network.md#gestión-remota-desde-dv0)
  - Documentación de estabilidad WireGuard en [01-Network.md#wireguard-estabilidad-de-conexión](./01-Network.md#wireguard-estabilidad-de-conexión)
  - Documentación del split-tunnel y resolución de pérdida de conectividad en [01-Network.md#wireguard-estabilidad-y-split-tunnel](./01-Network.md#wireguard-estabilidad-y-split-tunnel)

- [x] **Fase 10.1: Exposición Pública de Servicios**:
  - nginx en DV0 como punto de entrada único con TLS (Let's Encrypt para `www.elarreglador.eu` y `elarreglador.eu`, expira 2026-10-28)
  - Cadena de proxy: nginx DV0 → `http://10.8.0.11:31113` (WG) → LXC proxy device `proxy31113` → NodePort `test-web` 80:31113
  - Deployment `test-web` (nginx:alpine, 2 réplicas) + Service NodePort en el cluster
  - Verificado: `curl https://www.elarreglador.eu` → 200
  - Detalle en [README.md#fase-101--exposición-pública-de-servicios](./README.md#fase-101--exposición-pública-de-servicios)

- [x] **Fase 11: Nginx Ingress Controller (passthrough total)**:
  - ingress-nginx instalado vía helm (NodePort fijo 30080/30443), namespace `ingress-nginx`
  - LXC proxy devices `proxy30080`/`proxy30443` en k8s-worker-1 (10.8.0.11 → 127.0.0.1)
  - nginx DV0 migrado a módulo `stream` (passthrough total, sin TLS) — retirado sitio HTTP antiguo
  - cert-manager v1.17.2 (helm) + ClusterIssuer HTTP-01 `letsencrypt-http`
  - Certificate `elarreglador.eu`/`www.*` emitido por Let's Encrypt (secret `elarreglador-eu-tls`, renovación automática; SAN de `test.*` retirado el 2026-08-01)
  - Ingress `elarreglador-landing` → `landing:80` (web estática pública) con `force-ssl-redirect`; retirados Ingress `elarreglador-eu` y `test-web`
  - DNS wildcard `*.elarreglador.eu` → 82.223.50.169 añadido en Spaceship
  - Retirados: certificado DV0 (certbot), LXC proxy device `proxy31113` y `test-web`
  - Verificado: HTTPS 200 en `elarreglador.eu`/`www.*` sin credenciales, `test.*` → 404, HTTP → HTTPS, SANs correctos
  - Detalle en [README.md#fase-11--nginx-ingress-controller](./README.md#fase-11--nginx-ingress-controller)

- [x] **Fase 12: Monitoreo y Observabilidad**:
  - kube-prometheus-stack (helm): Prometheus, Grafana, AlertManager, prometheus-operator, kube-state-metrics, node-exporter DaemonSet — namespace `monitoring`
  - Almacenamiento efímero para Prometheus/Grafana (TSDB sobre NFS no fiable; se perdió tiempo en ello)
  - Recursos ajustados: Grafana 512Mi/200Mi (evita OOM), Prometheus 2Gi/600Mi
  - node-exporter nativo en D1/D2 (`apt`) + Service/Endpoints/ServiceMonitor `host-node` — D1 scrapeado vía relay socat en D2 (:19100) por limitación macvlan container↔host
  - `resolv.conf` estático en D1/D2 (systemd-resolved roto bloqueaba apt)
  - Grafana público en `https://grafana.elarreglador.eu` protegido por la clave única de acceso web (anonymous Viewer, sin login interno) y Certificate Let's Encrypt dedicado en `monitoring`
  - ServiceMonitor cert-manager + PrometheusRule `alertas-personalizadas` (HostDown, ClusterNodeNotReady, DiskPressureHost, CertificateExpiring)
  - AlertManager sin receiver (alertas solo UI)
  - Verificado: targets up (host-node ×2, cert-manager), HTTPS 401/200, cert válido, métricas `node_uname_info` con labels `host=d1`/`host=d2`
  - Detalle en [README.md#fase-12--monitoreo-y-observabilidad](./README.md#fase-12--monitoreo-y-observabilidad)

- [x] Fase 8: Almacenamiento Persistente (GlusterFS + NFS-Ganesha)
- [x] Fase 9: Despliegues de Prueba
- [x] **Fase 2.4**: DV0 como cliente remoto LXC con remote `d2` por defecto

- [x] **HA Multi-Master (Fase 13 extendida)**:
  - Segundo control-plane k8s-master-2 en D2 (192.168.1.22)
  - etcd cluster de 2 miembros (stacked, replicado)
  - Worker k8s-worker-1 renombrado y movido a D1 (192.168.1.31)
  - Nuevo worker k8s-worker-2 en D2 (192.168.1.32, antes k8s-worker-1)
  - 4 nodos en total: 2 control-planes + 2 workers
  - Resolución de bug dqlite en LXD 5.21 → upgrade a LXD 6.9
  - Recuperación de etcd cluster (force-new-cluster + member remove) tras join fallido

- [x] **Reubicación del almacenamiento a workers**:
  - GlusterFS, NFS-Ganesha y Keepalived movidos de k8s-master-1 a k8s-worker-1 (D1, 192.168.1.31)
  - k8s-worker-2 (D2, 192.168.1.32) como peer GlusterFS BACKUP
  - UUIDs GlusterFS regenerados (conflicto por clone resuelto)
  - Volumen replica 2 recreado con bricks en `/mnt/data/brick` de cada worker
  - VIP 192.168.1.30 ahora en k8s-worker-1 (MASTER), failover a k8s-worker-2
  - NFS-Ganesha exportando correctamente en ambos workers
  - Test de migración exitoso: datos escritos en un worker persisten al migrar el pod al otro

- [x] **Fase 10: Seguridad Avanzada**:
  - RBAC: ClusterRoles `developer`, `readonly`, `namespace-admin` + bindings
  - Pod Security Standards: namespaces etiquetados (privileged/baseline)
  - Auditoría API Server: policy + logs en ambos masters
  - Backups etcd: script diario + rotación a `/backup/etcd/`

### En Progreso 🔄

- [ ] **Fase 13**: tercer nodo de control-plane (D3) para quorum etcd (3 miembros mínimo)
- [ ] **Fase 13**: Pod Disruption Budgets
- [ ] **Fase 13**: estrategia de disaster recovery

### Pendiente ⏳

- **RAM**: 8GB por nodo (mínimo alcanzado, ideal 16GB)
  - D1: 8GB (Samsung + SK Hynix, Dual Channel)
  - D2: 8GB (2× Micron, Dual Channel)
  
- **CPU**: 2 núcleos es mínimo absoluto
  - Control-plane (D1): Requiere más CPU
  - Worker (D2): Puede funcionar con limitaciones

- **Alimentación**: Ambos nodos disponen de SAI
  - Apagar graceful del nodo worker ante corte eléctrico prolongado

- **Almacenamiento en workers**: GlusterFS + NFS-Ganesha + Keepalived se ejecutan en los workers (k8s-worker-1, k8s-worker-2). Si un worker cae, el otro sigue sirviendo el NFS (gracias a GlusterFS replica 2 + VIP). Sin embargo, los datos solo son accesibles por pods corriendo en workers; los control-planes no montan el NFS directamente.

- **Kubernetes en LXC**: Se requieren configuraciones especiales

- **GlusterFS con 2 nodos y replica 2**: El volumen replica 2 sobrevive la caída de un nodo (el otro sigue sirviendo). Sin embargo, ningún nodo puede caer permanentemente sin dejar el volumen degradado. Al añadir D3 se migrará a disperse (erasure code) para ~1TB usable con tolerancia a 1 fallo.

- **etcd con 2 miembros**: El cluster etcd tolera la caída de un control-plane pero pierde quorum (necesita mayoría = 2 de 2). Con 3 miembros toleraría 1 fallo. Alternativa: añadir un miembro etcd externo o un tercer nodo D3.

---

## Troubleshooting: Kubernetes en LXC

### Configuración necesaria para los contenedores LXC

```bash
# Habilitar nesting y modo privilegiado
lxc config set k8s-master-1 security.nesting=true security.privileged=true
lxc config set k8s-master-2 security.nesting=true security.privileged=true
lxc config set k8s-worker-1 security.nesting=true security.privileged=true
lxc config set k8s-worker-2 security.nesting=true security.privileged=true
lxc restart k8s-master-1 k8s-master-2 k8s-worker-1 k8s-worker-2
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
