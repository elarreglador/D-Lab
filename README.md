# D-Lab: Cluster Kubernetes sobre LXC

Proyecto de virtualización y orquestación de contenedores usando LXC (Linux Containers) y Kubernetes en dos nodos Dell OptiPlex 3050 Micro.

---

## Tabla de Contenidos

- [Arquitectura](#arquitectura)
- [Hardware](#hardware)
- [Tecnologías](#tecnologías)
- [Documentación](#documentación)
- [Plan de Implementación](#plan-de-implementación)
- [Requisitos Pendientes](#requisitos-pendientes-críticos)

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

Plan progresivo unificado de instalación y desarrollo del cluster.

### **Fase 1: Preparación Hardware (CRÍTICA)**

*Prerequisito antes de cualquier otra tarea*

- [ ] **Ampliar RAM en D1 y D2 a mínimo 8GB** ⚠️ BLOQUEANTE
  - Actual: 4GB (insuficiente)
  - Mínimo: 8GB
  - Ideal: 16GB
- [ ] Verificar conectividad Ethernet en ambos nodos
- [ ] Validar UPS y disponibilidad de energía continua
- [ ] Realizar pruebas de estrés de hardware (stress-ng)

### **Fase 2: Configuración Base de Red**

- [ ] Configurar IP estática en D2 (siguiendo modelo en [01-Network.md](./01-Network.md))
  - Rango: 192.168.1.X/24
  - Puerta de enlace: 192.168.1.1
  - DNS: 8.8.8.8, 8.8.4.4
- [ ] Validar conectividad entre D1 ↔ D2 (ping, traceroute)
- [ ] Actualizar SO en D1: `apt update && apt upgrade`
- [ ] Actualizar SO en D2: `apt update && apt upgrade`
- [ ] Sincronizar hora en ambos nodos (NTP)

### **Fase 3: Seguridad Base**

- [ ] Cambiar puerto SSH en D1 (22 → puerto custom)
- [ ] Cambiar puerto SSH en D2 (22 → puerto custom)
- [ ] Implementar fail2ban en D1
- [ ] Implementar fail2ban en D2
- [ ] Generar y copiar claves SSH entre nodos (sin contraseña)
- [ ] Configurar firewall básico en D1
- [ ] Configurar firewall básico en D2

### **Fase 4: Infraestructura LXC**

- [ ] Instalar LXC/LXD en D1
  - `apt install lxd`
  - `lxd init` (configuración interactiva)
- [ ] Instalar LXC/LXD en D2
  - `apt install lxd`
  - `lxd init` (configuración interactiva)
- [ ] Configurar bridge de red `lxdbr0` en D1
- [ ] Configurar bridge de red `lxdbr0` en D2
- [ ] Crear contenedor LXC con Ubuntu 22.04 LTS en D1
  - Nombre: `k8s-master`
  - IP: 192.168.1.12 (estática dentro del contenedor)
- [ ] Crear contenedor LXC con Ubuntu 22.04 LTS en D2
  - Nombre: `k8s-worker`
  - IP: 192.168.1.13 (estática dentro del contenedor)
- [ ] Validar conectividad D1 → contenedor D1
- [ ] Validar conectividad D2 → contenedor D2
- [ ] Validar conectividad contenedor D1 ↔ contenedor D2

### **Fase 5: Runtime de Contenedores (containerd)**

*Ejecutar en ambos contenedores: k8s-master y k8s-worker*

- [ ] Instalar dependencias en k8s-master y k8s-worker
  - `apt install curl wget gnupg2 apt-transport-https ca-certificates`
- [ ] Instalar containerd en k8s-master
  - `apt install containerd.io`
  - `mkdir -p /etc/containerd`
  - `containerd config default | tee /etc/containerd/config.toml`
  - `systemctl restart containerd`
- [ ] Instalar containerd en k8s-worker
  - (Mismo procedimiento que en k8s-master)
- [ ] Validar estado de containerd en ambos contenedores
  - `systemctl status containerd`
- [ ] Probar imagen básica: `crictl pull alpine`

### **Fase 6: Kubernetes Base**

*Ejecutar en ambos contenedores: k8s-master y k8s-worker*

- [ ] Añadir repositorio Kubernetes en k8s-master
  - `curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -`
  - `apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"`
- [ ] Añadir repositorio Kubernetes en k8s-worker (mismo procedimiento)
- [ ] Instalar kubeadm, kubelet, kubectl en k8s-master
  - `apt install kubeadm kubelet kubectl`
  - `apt-mark hold kubeadm kubelet kubectl` (prevenir actualizaciones automáticas)
- [ ] Instalar kubeadm, kubelet, kubectl en k8s-worker
  - (Mismo procedimiento que k8s-master)
- [ ] Deshabilitar swap en k8s-master
  - `swapoff -a` (temporal)
  - Editar `/etc/fstab` (permanente)
- [ ] Deshabilitar swap en k8s-worker (mismo procedimiento)

### **Fase 7: Inicializar Control-Plane**

*Ejecutar solo en k8s-master*

- [ ] Inicializar control-plane con kubeadm
  ```bash
  kubeadm init \
    --pod-network-cidr=10.244.0.0/16 \
    --apiserver-advertise-address=192.168.1.12
  ```
- [ ] Guardar token de unión (salida del comando anterior)
- [ ] Configurar kubeconfig para usuario actual
  ```bash
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  ```
- [ ] Validar acceso a cluster: `kubectl cluster-info`
- [ ] Verificar nodos: `kubectl get nodes` (solo master visible)

### **Fase 8: Configurar CNI (Network Plugin)**

*Ejecutar solo en k8s-master*

- [ ] Instalar Flannel como CNI
  - `kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml`
- [ ] Verificar pods de Flannel: `kubectl get pods -n kube-flannel`
- [ ] Esperar a que todos los pods de Flannel estén en estado `Running`
- [ ] Verificar que master esté listo: `kubectl get nodes` (debe mostrar `Ready`)

*Alternativa: usar Calico para producción*
- [ ] Opcionalmente instalar Calico
  - `kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/tigera-operator.yaml`

### **Fase 9: Unir Worker al Cluster**

*Ejecutar solo en k8s-worker*

- [ ] Obtener comando de unión del master
  - Desde k8s-master: `kubeadm token create --print-join-command`
- [ ] Ejecutar comando de unión en k8s-worker
  ```bash
  kubeadm join 192.168.1.12:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH>
  ```
- [ ] Validar desde k8s-master: `kubectl get nodes`
  - Debe mostrar 2 nodos (master y worker)
- [ ] Esperar a que ambos nodos estén en estado `Ready`

### **Fase 10: Validación de Cluster**

*Ejecutar en k8s-master*

- [ ] Verificar nodos: `kubectl get nodes -o wide`
- [ ] Verificar pods del sistema: `kubectl get pods -A`
- [ ] Verificar servicios: `kubectl get svc -A`
- [ ] Desplegar aplicación de prueba (nginx)
  ```bash
  kubectl create deployment nginx --image=nginx
  kubectl expose deployment nginx --port=80 --type=LoadBalancer
  ```
- [ ] Verificar despliegue: `kubectl get deployments`
- [ ] Verificar pods: `kubectl get pods`
- [ ] Acceder a la aplicación (obtener IP y puerto)
- [ ] Validar distribución entre nodos

### **Fase 11: Configuración de Seguridad Avanzada**

- [ ] Configurar firewall en D1 para puertos K8S
  - 6443 (API Server)
  - 10250 (kubelet)
  - 2379-2380 (etcd)
- [ ] Configurar firewall en D2 para puertos K8S
  - 10250 (kubelet)
- [ ] Implementar RBAC (Role-Based Access Control)
  - Crear roles personalizados según necesidad
  - Crear bindings de roles
- [ ] Configurar backups de etcd en k8s-master
  ```bash
  ETCDCTL_API=3 etcdctl --endpoints=127.0.0.1:2379 snapshot save backup.db
  ```

### **Fase 12: Almacenamiento Persistente**

- [ ] Particionar disco mecánico en D1
  - Usar disco sda (465.8G sin formato)
  - Crear partición ext4
- [ ] Particionar disco mecánico en D2
  - (Mismo procedimiento que D1)
- [ ] Configurar local-path-provisioner (solución simple)
  ```bash
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
  ```
- [ ] Crear PersistentVolume (PV) en D1
- [ ] Crear PersistentVolume (PV) en D2
- [ ] Crear StorageClass para local-path
- [ ] Probar PVC con aplicación de prueba

### **Fase 13: Conectividad VPN (wireguard)**

- [ ] Instalar wireguard en D1
  - `apt install wireguard wireguard-tools`
- [ ] Instalar wireguard en D2
  - `apt install wireguard wireguard-tools`
- [ ] Generar claves privadas y públicas en D1
- [ ] Generar claves privadas y públicas en D2
- [ ] Configurar interfaz wg0 en D1
- [ ] Configurar interfaz wg0 en D2
- [ ] Habilitar forwarding de IP en D1
- [ ] Habilitar forwarding de IP en D2
- [ ] Validar conectividad sobre wireguard
- [ ] Integrar wireguard con K8S (opcional, si se requiere)

### **Fase 14: Monitoreo y Observabilidad**

- [ ] Instalar Prometheus en el cluster
  - Crear namespace: `kubectl create namespace monitoring`
  - Desplegar Prometheus
- [ ] Instalar Grafana en el cluster
  - Configurar datasources (Prometheus)
  - Importar dashboards predefinidos
- [ ] Instalar node-exporter en ambos nodos
- [ ] Configurar alertas en Prometheus
- [ ] Crear dashboards personalizados en Grafana
- [ ] Implementar ELK stack para logs (opcional)
  - Elasticsearch
  - Logstash
  - Kibana

### **Fase 15: Mejoras de Rendimiento y Escalabilidad**

- [ ] Ampliar RAM a 16GB en D1 (si es posible)
- [ ] Ampliar RAM a 16GB en D2 (si es posible)
- [ ] Optimizar configuración de containerd
- [ ] Ajustar límites de recursos en kubelet
- [ ] Implementar auto-scaling horizontal (HPA)
- [ ] Implementar auto-scaling vertical (VPA)
- [ ] Configurar pod disruption budgets

### **Fase 16: Producción y Mantenimiento**

- [ ] Documentar configuración final
- [ ] Crear runbooks de operación
- [ ] Implementar política de backups (daily)
- [ ] Establecer plan de actualización de K8S
- [ ] Crear alertas para eventos críticos
- [ ] Implementar auditoría y logging
- [ ] Planificar estrategia de disaster recovery
- [ ] Agregar tercer nodo (si se requiere alta disponibilidad)

---

## Requisitos Pendientes (Críticos)

Consultar [00-Requisitos.md](./00-Requisitos.md) para detalles completos.

**Bloqueantes para comenzar:**

1. ⚠️ **Ampliar RAM a 8GB mínimo** - CRÍTICO, bloqueante para Fase 1
2. **Configurar IP estática en D2** - Requerido para Fase 2

**Recomendados antes de Fase 4:**

3. Instalar herramientas de diagnóstico (stress-ng, iperf)
4. Validar estabilidad de red y hardware

---

## Estado del Proyecto

**Última actualización**: 2026-06-20
**Estado**: Fase de Configuración Inicial
**Nodos Operacionales**: D1 parcialmente configurado
**Bloqueante Crítico**: Ampliación RAM (Fase 1)

---

## Contacto y Contribuciones

Este proyecto es parte del laboratorio de desarrollo (D-Lab) para investigación en infraestructura de contenedores y Kubernetes.
