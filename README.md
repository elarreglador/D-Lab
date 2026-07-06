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
- Configuración Actual: 4 GB (INSUFICIENTE)
- Recomendación: 8 GB mínimo, 16 GB ideal para K8S
- Tipo: Micron Technology 2400MHz
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
| [Incidente_ssh_socket.md](./Incidente_ssh_socket.md) | Análisis y resolución del conflicto entre ssh.socket y ssh.service |

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

### Fase 3️ | Runtime de Contenedores

**Objetivo**: Instalar y configurar containerd

Ejecutar en `k8s-master-1` y `k8s-worker-1`:

- [ ] Instalar dependencias
  ```bash
  apt install curl wget gnupg2 apt-transport-https ca-certificates
  ```
- [ ] Instalar containerd.io
  ```bash
  apt install containerd.io
  ```
- [ ] Generar configuración default
  ```bash
  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml
  ```
- [ ] Reiniciar servicio
  ```bash
  systemctl restart containerd
  ```
- [ ] Validar estado
  ```bash
  systemctl status containerd
  crictl pull alpine
  ```

**Prerequisitos**: Fase 2 completada, RAM ampliada a 8GB  
**Duración Estimada**: 30 minutos

---

### Fase 4️ | Instalación de Kubernetes

**Objetivo**: Instalar componentes de K8S

Ejecutar en `k8s-master-1` y `k8s-worker-1`:

- [ ] Añadir repositorio de Kubernetes
  ```bash
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
  ```
- [ ] Instalar componentes
  ```bash
  apt install kubeadm kubelet kubectl
  ```
- [ ] Prevenir actualizaciones automáticas
  ```bash
  apt-mark hold kubeadm kubelet kubectl
  ```
- [ ] Deshabilitar swap (permanentemente en `/etc/fstab`)
  ```bash
  swapoff -a
  ```
- [ ] Cargar módulos de kernel necesarios
  ```bash
  modprobe br_netfilter
  sysctl -w net.ipv4.ip_forward=1
  ```

**Prerequisitos**: Fase 3 completada  
**Duración Estimada**: 30 minutos

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

### En Progreso 🔄

- [ ] Fase 3: Runtime de Contenedores (containerd)

### Pendiente ⏳

- [ ] Fases 4-13: Instalación de Kubernetes y componentes avanzados

### Limitaciones Conocidas ⚠️

- **RAM**: 4GB actual es insuficiente
  - Mínimo recomendado: 8GB por nodo
  - Ideal: 16GB por nodo
  
- **CPU**: 2 núcleos es mínimo absoluto
  - Control-plane (D1): Requiere más CPU
  - Worker (D2): Puede funcionar con limitaciones

- **Almacenamiento**: Partición raíz 100GB podría ser limitante
  - Disco mecánico 465GB ideal para PVC (Persistent Volume Claims)

---

## Recomendaciones Prioritarias

1. **Ampliación de RAM a 8GB mínimo** - Crítico para Fase 3+
2. **Continuar con Fase 3**: Runtime de Contenedores
3. **Monitoreo activo** de rendimiento durante despliegue inicial
4. **Backups regulares** de configuración y etcd

---

## Contacto y Contribuciones

Este proyecto es parte del laboratorio de desarrollo (D-Lab) para investigación en infraestructura de contenedores y Kubernetes.
