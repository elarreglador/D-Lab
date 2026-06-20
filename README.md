# D-Lab: Cluster Kubernetes sobre LXC

Proyecto de virtualización y orquestación de contenedores usando LXC (Linux Containers) y Kubernetes en dos nodos Dell OptiPlex 3050 Micro.

---

## Tabla de Contenidos

- [Arquitectura](#arquitectura)
- [Hardware](#hardware)
- [Tecnologías](#tecnologías)
- [Documentación](#documentación)
- [Plan de Implementación](#plan-de-implementación)
- [Estado del Proyecto](#estado-del-proyecto)

---

## Arquitectura

El cluster está diseñado con la siguiente estructura:

```
Internet (Router) 
    ↓
Switch Mercusys MS105G (10 Gbps)
    ├── D1 (Control-Plane)
    └── D2 (Worker)
```

**Topología de Red**: Ethernet dedicada, sin WiFi
**Control-Plane**: D1 (192.168.1.11)
**Worker**: D2 (192.168.1.X)

---

## Hardware

### Sistema de Alimentación (SAI)

**Riello UPS RPR 650 230VAC** (aprox. 360 W)

Sistema de alimentación ininterrumpida compacto para protección contra:
- Cortes de energía
- Sobretensiones
- Fluctuaciones de voltaje

Características:
- 2 salidas tipo schuko
- Nivel básico
- Ideal para infraestructura pequeña

### Red (Switch)

**Mercusys MS105G**

Switch Gigabit de escritorio para redes domésticas o pequeñas oficinas.

Especificaciones:
- **Puertos**: 5 puertos RJ45 (10/100/1000 Mbps)
- **Capacidad de Conmutación**: 10 Gbps (Backplane)
- **Dimensiones**: 105 x 70 x 24.9 mm
- **Características**: Auto-negociación

### Periféricos

**Nooelec Ham It Up**

Tratamiento previo de frecuencias para recepción SDR de bandas bajas.
- Permite sintonizar frecuencias por debajo de 25MHz
- Suma 125 MHz a la frecuencia para permitir recepcion en el SDR

Dispositivo receptor de radio definido por software (SDR) basado en el chip RTL2832U.
- Rango de frecuencia: Aproximadamente 25 MHz a 1700 MHz.
- Conector de antena: Tipo SMA (estándar común).
- Uso principal: Recepción de radiofrecuencias, escaneo de espectro y proyectos de radioafición.

### Equipos Computacionales

#### Dell OptiPlex 3050 Micro (x2)

Especificaciones técnicas base (comando: `sudo lshw`):

**Procesador (CPU)**
- Modelo: Intel Core i3-7100T @ 3.40GHz
- Núcleos: 2 / Hilos: 4
- TDP: Bajo (T = Baja disipación térmica)
- Rendimiento: Suficiente para K8S, ajustado para carga moderada

**Memoria RAM**
- Configuración Actual: 4 GB (INSUFICIENTE)
- Recomendación: 8 GB mínimo, 16 GB ideal
- Tipo: Micron Technology 2400MHz
- Swap: 4.0 GB

```
RAM:           3,2G Micron Technology 2400MHz
Swap:          4,0G
```

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
- RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet (integrado en placa base)

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
- Router del ISP → Switch → Nodos
- IPs estáticas configuradas con netplan
- DNS: Google (8.8.8.8 / 8.8.4.4)

---

## Documentación

### Referencias de Consulta

1. **[00-Requisitos.md](./00-Requisitos.md)**
   - Requisitos técnicos detallados (hardware, software, seguridad)
   - Limitaciones actuales del sistema
   - Recomendaciones para optimización

2. **[01-Network.md](./01-Network.md)**
   - Configuración actual de red (D1)
   - Detalles de IP estática
   - Configuración netplan
   - Servidores DNS

---

## Plan de Implementación

### Fase 1️ | Preparación de Infraestructura

**Objetivo**: Establecer base de red y seguridad

- [x] Configurar red estática en D1 (192.168.1.11)
- [x] Configurar red estática en D2 (192.168.1.12)
- [ ] Validar conectividad D1 ↔ D2 (ping, ssh)
- [ ] Actualizar SO en ambos nodos (`apt update && apt upgrade`)
- [ ] Sincronizar hora NTP en ambos nodos
- [ ] Cambiar puerto SSH (22 → custom)
- [ ] Implementar fail2ban en ambos nodos
- [ ] Implementar VPN Wireguard para comunicación segura interna

**Duración Estimada**: 2-3 horas

---

### Fase 2 | Infraestructura LXC y Containerización

**Objetivo**: Establecer contenedores base para Kubernetes

- [ ] Instalar LXC/LXD en D1 y D2
  - `apt install lxd`
  - `lxd init` (configuración interactiva)
- [ ] Crear bridge de red `lxdbr0` en ambos nodos
- [ ] Crear contenedor `k8s-master` en D1
  - Imagen: Ubuntu 22.04 LTS
  - IP estática: 192.168.1.12
  - RAM: 3GB mínimo, 6GB ideal
- [ ] Crear contenedor `k8s-worker` en D2
  - Imagen: Ubuntu 22.04 LTS
  - IP estática: 192.168.1.13
  - RAM: 2GB mínimo, 4GB ideal
- [ ] Validar conectividad entre contenedores
- [ ] Instalar dependencias base en ambos contenedores

**Prerequisitos**: Fase 1 completada, RAM ampliada a 8GB

**Duración Estimada**: 1-2 horas

---

### Fase 3️ | Runtime de Contenedores

**Objetivo**: Instalar y configurar containerd

Ejecutar en `k8s-master` y `k8s-worker`:

- [ ] Instalar dependencias
  - `apt install curl wget gnupg2 apt-transport-https ca-certificates`
- [ ] Instalar containerd.io
  - `apt install containerd.io`
- [ ] Generar configuración default
  - `mkdir -p /etc/containerd`
  - `containerd config default | tee /etc/containerd/config.toml`
- [ ] Reiniciar servicio
  - `systemctl restart containerd`
- [ ] Validar estado
  - `systemctl status containerd`
  - `crictl pull alpine` (prueba)

**Prerequisitos**: Fase 2 completada

**Duración Estimada**: 30 minutos

---

### Fase 4️ | Instalación de Kubernetes

**Objetivo**: Instalar componentes de K8S

Ejecutar en `k8s-master` y `k8s-worker`:

- [ ] Añadir repositorio de Kubernetes
  ```bash
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
  apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
  ```
- [ ] Instalar componentes
  - `apt install kubeadm kubelet kubectl`
- [ ] Prevenir actualizaciones automáticas
  - `apt-mark hold kubeadm kubelet kubectl`
- [ ] Deshabilitar swap (permanentemente en `/etc/fstab`)
  - `swapoff -a`
- [ ] Cargar módulos de kernel necesarios
  - `modprobe br_netfilter`
  - `sysctl -w net.ipv4.ip_forward=1`

**Prerequisitos**: Fase 3 completada

**Duración Estimada**: 30 minutos

---

### Fase 5️ | Control-Plane

**Objetivo**: Inicializar cluster Kubernetes

Ejecutar solo en `k8s-master`:

- [ ] Inicializar control-plane
  ```bash
  kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address=192.168.1.12
  ```
- [ ] Copiar kubeconfig
  ```bash
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  ```
- [ ] Guardar token de unión (para Fase 6)
  - `kubeadm token create --print-join-command`
- [ ] Validar acceso a cluster
  - `kubectl cluster-info`
  - `kubectl get nodes` (solo master visible)

**Prerequisitos**: Fase 4 completada

**Duración Estimada**: 15 minutos

---

### Fase 6️ | Network Plugin (CNI)

**Objetivo**: Configurar red entre pods

Ejecutar solo en `k8s-master`:

- [ ] Instalar Flannel (opción simple)
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
  ```
- [ ] Verificar pods de red
  - `kubectl get pods -n kube-flannel`
- [ ] Esperar a que todos estén en `Running`
- [ ] Verificar que master esté `Ready`
  - `kubectl get nodes` (debe mostrar `Ready`)

**Alternativa**: Calico para producción
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml
  ```

**Prerequisitos**: Fase 5 completada

**Duración Estimada**: 5-10 minutos

---

### Fase 7️ | Unir Worker

**Objetivo**: Incorporar segundo nodo al cluster

Ejecutar solo en `k8s-worker`:

- [ ] Ejecutar comando de unión (obtenido en Fase 5)
  ```bash
  kubeadm join 192.168.1.12:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
  ```
- [ ] Esperar sincronización (2-3 minutos)
- [ ] Validar desde `k8s-master`
  - `kubectl get nodes` (debe mostrar 2 nodos)
  - `kubectl get pods -A` (verificar pods del sistema)

**Prerequisitos**: Fase 6 completada

**Duración Estimada**: 5 minutos

---

### Fase 8 ️| Almacenamiento Persistente

**Objetivo**: Configurar volúmenes persistentes

- [ ] Particionar disco mecánico en D1
  - `lsblk` (identificar sda)
  - `fdisk /dev/sda` (crear partición ext4)
  - `mkfs.ext4 /dev/sda1`
  - Montar en `/mnt/data-d1`
- [ ] Particionar disco mecánico en D2 (mismo procedimiento)
  - Montar en `/mnt/data-d2`
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
  - `kubectl get pods -o wide`
- [ ] Probar persistencia
  - Desplegar StatefulSet con PVC
  - Verificar que datos persisten tras reinicio
- [ ] Validar logs y eventos
  - `kubectl logs <pod>`
  - `kubectl describe pod <pod>`

**Prerequisitos**: Fase 8 completada

**Duración Estimada**: 30 minutos

---

### Fase 10 | Seguridad Avanzada

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

### Fase 1️1️| Nginx Ingress Controller

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

### Fase 1️2️ | Monitoreo y Observabilidad

**Objetivo**: Implementar stack de monitoreo

- [ ] Instalar Prometheus
  - Crear namespace `monitoring`
  - Desplegar Prometheus
  - Configurar scrape targets
- [ ] Instalar Grafana
  - Conectar datasource Prometheus
  - Importar dashboards predefinidos
- [ ] Instalar AlertManager
- [ ] Instalar node-exporter en nodos host
- [ ] Crear alertas personalizadas

**Prerequisitos**: Fase 11 completada

**Duración Estimada**: 3-4 horas

---

### Fase 1️️3 | Resiliencia y Alta Disponibilidad

**Objetivo**: Mejorar tolerancia a fallos

**Nota**: Requiere ampliación RAM a 16GB y/o adición de D3

- [ ] Considerar agregar tercer nodo (D3) para HA
- [ ] Replicar etcd (3 nodos mínimo)
- [ ] Configurar Longhorn para almacenamiento distribuido (futuro)
- [ ] Implementar Pod Disruption Budgets
- [ ] Crear estrategia de disaster recovery

**Prerequisitos**: Fase 12 completada, hardware mejorado

**Duración Estimada**: Variable (depende de decisiones arquitectónicas)

---
# Contacto y Contribuciones

Este proyecto es parte del laboratorio de desarrollo (D-Lab) para investigación en infraestructura de contenedores y Kubernetes.
