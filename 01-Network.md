# Configuración de Red - IP Estática

## Descripción General

Se ha configurado una dirección IP estática en la interfaz de red Ethernet `enp2s0`. La configuración se gestiona mediante **netplan**, que es el sistema de gestión de red moderno en Ubuntu.

## Detalles de la Configuración

Para D1 se aplica la ip acabada en .11 , mientras que para D2 se aplica la .12

- **Interfaz de red**: `enp2s0` (ethernet)
- **Dirección IP**: `192.168.1.11/24`
- **Máscara de red**: `/24` (255.255.255.0)
- **Puerta de enlace (Gateway)**: `192.168.1.1`
- **Servidores DNS**: 
  - `8.8.8.8` (Google DNS)
  - `8.8.4.4` (Google DNS)

## Método de Configuración

La IP estática se ha configurado a través de **netplan**, deshabilitando DHCP (`dhcp4: no`) en la interfaz y asignando manualmente los parámetros de red.

## Archivo de Configuración

El archivo de configuración se encuentra en `/etc/netplan/00-installer-config.yaml` con el siguiente contenido:

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    enp2s0:
      dhcp4: no
      addresses:
        - 192.168.1.11/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
```

## Validez de la Configuración

La configuración está activa y permanente (`valid_lft forever`), lo que significa que la IP estática se mantendrá después de cada reinicio del equipo.

# SSH

agregamos ambos equipos en .ssh/config tanto en D1 como en D2

```
cat .ssh/config 
Host D1
    HostName 192.168.1.11
    User elarreglador

Host D2
    HostName 192.168.1.12
    User elarreglador
```

Esto facilitara la conexion entre ellos

# Cambio de puerto SSH (22 -> 9622)

Para evitar ataques de bots basicos pasamos del puerto 22 al 9622 (o cualquier otro) tanto D1 como D2i

```
sudo sed -i 's/#Port 22/Port 9622/' /etc/ssh/sshd_config
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket
sudo systemctl restart ssh
sudo ss -tulpn | grep ssh
```

Recuerda atcualizar .ssh/config indicando el nuevo puerto de conexion

```
Host D1
    HostName 192.168.1.11
    User elarreglador
    Port 9622

Host D2
    HostName 192.168.1.12
    User elarreglador
    Port 9622
```

# Fail2Ban

Instalamos fail2ban para que en caso de ataque de fuerza bruta bloqueemos al atacante por un tiempo

```
sudo apt install fail2ban -y
```

para configurar fail2ban y que proteja el nuevo puerto SSH (9622), debemos crear un archivo de configuración local.

```
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
```

editamos /etc/fail2ban/jail.local dejando los campos asi:

```
sudo nano /etc/fail2ban/jail.local
```

```
[sshd]
enabled = true
port = 9622
```

Reiniciamos fail2ban

```
sudo systemctl restart fail2ban
```

# WireGuard VPN

## Configuración de Cliente WireGuard

Se ha instalado y configurado WireGuard para establecer una conexión VPN segura.

## Instalación

```bash
sudo apt install wireguard wireguard-tools -y
```

## Configuración por Equipo

### Servidor WireGuard (DV0 - VM IONOS)

DV0 actúa como servidor WireGuard en `82.223.50.169:51820`, con IP interna `10.8.0.1/24`.

Configuración del servidor en `/etc/wireguard/wg0.conf`:

```ini
[Interface]
Address = 10.8.0.1/24, fd42:42:42::1/64
ListenPort = 51820
PrivateKey = <PRIVADA_DV0>

PostUp = iptables -I INPUT -p udp --dport 51820 -j ACCEPT
PostUp = iptables -I FORWARD -i ens6 -o wg0 -j ACCEPT
PostUp = iptables -I FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ens6 -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport 51820 -j ACCEPT
PostDown = iptables -D FORWARD -i ens6 -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ens6 -j MASQUERADE
```

### Clientes WireGuard

Los configs actualizados están en `files/` del proyecto.

#### D1 (`files/wg0-client-d1.conf`)

```ini
[Interface]
PrivateKey = <PRIVATE_KEY_D1>
Address = 10.8.0.11/32,fd42:42:42::11/128
DNS = 10.8.0.1,1.8.0.1

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY_D1>
Endpoint = 82.223.50.169:51820
AllowedIPs = 0.0.0.0/0,::/0
```

#### D2 (`files/wg0-client-d2.conf`)

```ini
[Interface]
PrivateKey = <PRIVATE_KEY_D2>
Address = 10.8.0.12/32,fd42:42:42::12/128
DNS = 10.8.0.1,1.8.0.1

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY_D2>
Endpoint = 82.223.50.169:51820
AllowedIPs = 0.0.0.0/0,::/0
```

## Aplicación de la Configuración

```bash
# Crear directorio si no existe
sudo mkdir -p /etc/wireguard

# Copiar la configuración
sudo cp wg0-client-d1.conf /etc/wireguard/wg0.conf
# O para D2, copiar la versión correspondiente:
# sudo cp wg0-client-d2.conf /etc/wireguard/wg0.conf

# Establecer permisos
sudo chmod 600 /etc/wireguard/wg0.conf

# Activar la interfaz
sudo wg-quick up wg0

# Habilitar en el arranque
sudo systemctl enable wg-quick@wg0
```

## Verificación

```bash
# Verificar la interfaz WireGuard
sudo wg show

# Verificar direcciones IP asignadas
ip addr show wg0

# Verificar la IP pública del servidor VPN
curl ifconfig.me
```

## Desactivación (si es necesario)

```bash
sudo wg-quick down wg0
sudo systemctl disable wg-quick@wg0
```

# Router

## Modelo

**ZTE H3600P V9.0** (H3600P V9.0.0P5_DIGI)

Router del proveedor de Internet. Hace las veces de gateway (192.168.1.1), servidor DHCP y punto de acceso WiFi.

La interfaz de administración web está en `http://192.168.1.1/` (puertos 80 y 443).

## Acceso Programático

El router utiliza un mecanismo de login con SHA256. El flujo es:

1. Obtener un token de sesión vía GET:
   ```bash
   curl -s "http://192.168.1.1/?_type=loginData&_tag=login_token"
   ```
   Devuelve un número (ej: `81594066`).

2. Hacer login vía POST al mismo endpoint:
   ```bash
   curl -s "http://192.168.1.1/?_type=loginData&_tag=login_entry" \
     -d "Username=<usuario>&Password=<sha256(password + token)>&_sessionTOKEN=<token>"
   ```
   La contraseña se envía como `SHA256(contraseña + token)` (en hexadecimal).

3. La respuesta contiene un `sess_token` que debe enviarse en peticiones posteriores como `_sessionTOKEN`.

### Ejemplo en Python

```python
import requests, hashlib

base = "http://192.168.1.1"
s = requests.Session()

r = s.get(f"{base}/?_type=loginData&_tag=login_token")
token = r.text.strip()

sha = hashlib.sha256((password + token).encode()).hexdigest()
r = s.post(f"{base}/?_type=loginData&_tag=login_entry",
           data={"Username": user, "Password": sha, "_sessionTOKEN": token})

sess_token = r.json()["sess_token"]
# Usar sess_token en peticiones posteriores
```

## Lista de Dispositivos

Una vez autenticado, la página principal (`/`) muestra una tabla con los dispositivos conectados (Nombre, MAC, IPv4, IPv6). Los dispositivos cableados (LAN) aparecen en la misma lista que los WiFi.

---

# Gestión Remota desde DV0

DV0 actúa como jumpbox para gestionar el cluster de forma remota. Desde DV0 se puede acceder a Kubernetes y LXD a través del túnel WireGuard.

## kubectl en DV0

### LXC Proxy Device (API Server)

El API Server de Kubernetes corre en `k8s-master-1` (192.168.1.21:6443). Como los contenedores usan macvlan, D1 no puede alcanzar directamente a su propio contenedor. Para exponer el API Server a través de la VPN WireGuard, se añadió un **LXC proxy device** en D1:

```bash
# En D1: reenviar puerto 6443 de la IP WireGuard al contenedor
lxc config device add k8s-master-1 proxy6443 proxy \
  connect=tcp:127.0.0.1:6443 listen=tcp:10.8.0.11:6443
```

Esto hace que D1 escuche en `10.8.0.11:6443` (su IP WireGuard) y reenvíe todo el tráfico a `k8s-master-1:6443`.

### Configurar kubeconfig en DV0

```bash
# Obtener el kubeconfig desde k8s-master-1 (vía D1)
ssh -p 9622 elarreglador@10.8.0.11 \
  "lxc exec k8s-master-1 -- cat /etc/kubernetes/admin.conf" \
  > ~/.kube/config

# Ajustar permisos
chmod 600 ~/.kube/config

# Cambiar el server para que apunte a la IP WireGuard de D1
kubectl config set-cluster kubernetes \
  --server=https://10.8.0.11:6443 \
  --insecure-skip-tls-verify=true
```

> **Nota**: Se usa `--insecure-skip-tls-verify` porque el certificado del API Server fue emitido para `192.168.1.21`, no para `10.8.0.11`.

### Verificación

```bash
kubectl get nodes
kubectl get pods -A
```

## LXC (lxd client) en DV0

DV0 tiene instalado el cliente LXD via snap, que permite gestionar el cluster LXD de D1/D2 de forma remota.

### Grupo LXD

El usuario `elarreglador` debe pertenecer al grupo `lxd`:

```bash
sudo usermod -aG lxd elarreglador
# Cerrar sesión y volver a entrar, o usar:
sg lxd -c "lxc version"
```

### Añadir Remote LXD

La API de LXD en D2 solo escuchaba en la IP LAN (`192.168.1.12:8443`). Se cambió para escuchar en todas las interfaces:

```bash
# En D2
lxc config set core.https_address [::]:8443
```

Desde DV0 se añade D2 como remote:

```bash
lxc remote add d2 10.8.0.12:8443 --password <CLAVE_SUDO> --accept-certificate
```

### Verificación

```bash
lxc list d2:
lxc exec d2:k8s-worker-1 -- kubectl get nodes
```

