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
PostUp = ip route add 192.168.1.0/24 dev wg0
PostDown = iptables -D INPUT -p udp --dport 51820 -j ACCEPT
PostDown = iptables -D FORWARD -i ens6 -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ens6 -j MASQUERADE
PostDown = ip route del 192.168.1.0/24 dev wg0
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
AllowedIPs = 10.8.0.0/24, fd42:42:42::/64
PersistentKeepalive = 25
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
AllowedIPs = 10.8.0.0/24, fd42:42:42::/64
PersistentKeepalive = 25
```

#### G9 portátil (`files/wg0-client-g9.conf`)

```ini
[Interface]
PrivateKey = <PRIVATE_KEY_G9>
Address = 10.8.0.100/24, fd42:42:42::100/128

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY_G9>
Endpoint = elarreglador.eu:51820
AllowedIPs = 10.8.0.1/32, 10.8.0.11/32, 10.8.0.12/32
PersistentKeepalive = 25
```

> **Nota (actualizada 2026-08-18)**: `AllowedIPs` en **D1/D2** pasó de `10.8.0.1/32` a `10.8.0.0/24, fd42:42:42::/64` (en **servidor y clientes**). Motivo: habilitar **hub-and-spoke** — G9 (10.8.0.100) y otros peers de la VPN deben poder hablar entre sí *a través de DV0*. Con el valor antiguo, D1/D2 solo aceptaban tráfico cuyo origen fuera `10.8.0.1` y no tenían ruta de vuelta, así que los paquetes de G9 reenviados por el servidor se descartaban (handshake ok, pero timeout al conectar). La corrección se aplicó con `sed` sobre `/etc/wireguard/wg0.conf` de D1/D2 **y** la ruta se añadió a mano (`ip route add 10.8.0.0/24 dev wg0`) — ojo: `wg syncconf` **no** toca la tabla de rutas; `wg-quick up` (reinicio) sí la regeneraría. El cambio es seguro: la subred 10.8.0.0/24 es privada del túnel y D1/D2 siguen con **split-tunnel** (su default route queda intacta; solo lo 10.8.0.0/24 entra por wg0). G9 usa split-tunnel estricto (`AllowedIPs` solo las IPs de la VPN que necesita, sin DNS) para no interferir con la LAN doméstica. Ver [WireGuard: Estabilidad y Split-Tunnel](#wireguard-estabilidad-y-split-tunnel).

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

# Ancho de banda y límites P2P para priorizar multimedia (`verificado 2026-09-01`)

**Línea DIGI** FIBRA `AS57269 DIGI SPAIN TELECOM` (verificado con `curl https://ipinfo.io/ip` y `curl https://ifconfig.me`).

Medición cableada desde D1/D2 (no G9 WiFi, limitado a ~228 Mbit/s):
```bash
lxc exec k8s-master-1 -- kubectl -n multimedia exec deploy/qbittorrent -- curl -s http://localhost:8080/api/v2/transfer/info | tr ',' '\n' | grep rate_limit
curl -o /dev/null -w '%{speed_download} B/s' http://cachefly.cachefly.net/100mb.test   # D1 74.733.338 B/s = 597 Mbit/s, D2 70.722.190 B/s = 565 Mbit/s, G9 28.502.672 B/s WiFi
curl -X POST --data-binary @/tmp/50M.test -o /dev/null -w '%{speed_upload} B/s' http://speedtest2.digimobil.es:8080/speedtest/upload.php  # 95.809.013 B/s = 766 Mbit/s
ping 1.1.1.1  # 6.1 ms avg, 8.8.8.8 14.2 ms
```
Resultado efectivo **~550-600 Mbit/s simétricos** (capacidad real medida; coherente con tarifa DIGI 600 Mb). Se toma **600 Mbit/s = 75 MB/s** como base redonda.

**Política aplicada (1/3 del ancho para P2P, 2/3 libres para Jellyfin `192.168.1.53:8096`):** deja **400 Mbit/s libres** → 11×4K (35 Mbit/s) o 33×1080p (12 Mbit/s) sin bufferbloat en el ZTE H3600P.

| App | Límite down | Límite up | Config viva |
|-----|-------------|-----------|-------------|
| qBittorrent | `19500 KiB/s` (160 Mbit/s) | `19500 KiB/s` (160 Mbit/s) | `lxc exec k8s-master-1 -- kubectl -n multimedia exec deploy/qbittorrent -- curl -s http://localhost:8080/api/v2/transfer/info` → `dl_rate_limit 19968000 / up_rate_limit 19968000 / speedLimitsMode 0` y `qBittorrent.conf: Session\GlobalDLSpeedLimit=19500 / GlobalUPSpeedLimit=19500 / AlternativeGlobalDLSpeedLimit=19500 / UseAlternativeGlobalSpeedLimit=false` (antes `100/100/5` modo 1 = 5 KiB/s cerrado) |
| aMule | `4880 KiB/s` (40 Mbit/s) | `4880 KiB/s` (40 Mbit/s) | `lxc exec k8s-master-1 -- kubectl -n multimedia exec deploy/amule -- grep -E '^MaxDownload\|^MaxUpload' /home/amule/.aMule/amule.conf` → `4880` (antes `0` ilimitado), `MaxConnections 500 / SlotAllocation 20` |

Total P2P `200 Mbit/s` = 33% del total. Ajustado vía `curl -s http://localhost:8080/api/v2/transfer/setDownloadLimit -d 'limit=19968000'` y `setUploadLimit` + `setSpeedLimitsMode 0` para qB y `sed -i 's/^MaxDownload=.*/MaxDownload=4880/'` + `sed -i 's/^MaxUpload=.*/MaxUpload=4880/'` + `rollout restart deploy/amule` para aMule. Verificado `jellyfin:8096` → `302 0.014s` desde el pod qB.

ASCII horizontal (600 Mbit/s base):
```
BAJADA 600                    |██████████████████████████████████████████████████|
 qB 160                      |█████████████▎                                    |
 aMule 40                    |███▎                                              |
 Libre Jellyfin 400          |█████████████████████████████████▋                | 66% libre
```

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

### Radio SDR remota (rtl_tcp) — LXC proxy device

Cadena de acceso público para el servidor de radio (servicio `rtl-sdr`, ver [03-Aplicaciones.md#radio-sdr-remota-rtl_tcp](./03-Aplicaciones.md#radio-sdr-remota-rtl_tcp)):

```
GQRX (RTL-SDR TCP) → sdr.elarreglador.eu:1234
  → nginx stream DV0 (listen 1234 → 10.8.0.11:1234)        [en DV0]
  → LXC proxy device `proxyrtlsdr` (10.8.0.11:1234)          [en D1]
  → 127.0.0.1:31234 (NodePort `rtl-sdr`, k8s-worker-1)
  → pod rtl-sdr (privilegiado, /dev/bus/usb) → dongle USB
```

**1. Passthrough del dongle al contenedor k8s-worker-1** (device `usb` de LXD; aplica en caliente sin reiniciar el contenedor):

```bash
# En D1 (los drivers DVB se desenganchan solos: librtlsdr usa libusb con DETACH_KERNEL_DRIVER)
lxc config device add k8s-worker-1 rtlsdr usb vendorid=0bda productid=2838
# Verificar dentro del contenedor: debe aparecer /dev/bus/usb/<bus>/<dev>
lxc exec k8s-worker-1 -- ls -l /dev/bus/usb/
```

**2. Proxy LXC hacia el NodePort** (escucha en la IP WireGuard de D1, igual que `proxy6443`):

```bash
# En D1
lxc config device add k8s-worker-1 proxyrtlsdr proxy \
  listen=tcp:10.8.0.11:1234 connect=tcp:127.0.0.1:31234
```

El `connect=tcp:127.0.0.1:31234` se resuelve **dentro del namespace del contenedor** k8s-worker-1, donde kube-proxy DNATea el NodePort `rtl-sdr` hacia el pod.

**3. nginx stream en DV0** (`/etc/nginx/stream.conf.d/sdr.conf`, requiere sudo en DV0):

```nginx
upstream sdr_rtltcp {
    server 10.8.0.11:1234;
}
server {
    listen 1234;
    proxy_pass sdr_rtltcp;
    proxy_timeout 300s;
}
```

```bash
# En DV0
sudo nginx -t && sudo systemctl reload nginx
```

**4. DNS**: `sdr.elarreglador.eu` resuelve vía el wildcard `*.elarreglador.eu → 82.223.50.169` (no requiere registro nuevo).

**Endurecimiento opcional** (D1, requiere sudo; no imprescindible porque librtlsdr desconecta el driver del kernel en runtime): blacklist de drivers DVB en `/etc/modprobe.d/rtlsdr-blacklist.conf`:

```
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2832_sdr
```

**Verificación**: la cabecera DongleInfo de 12 bytes (magic `RTL0`) se recibe al conectar a `10.8.0.11:1234` (desde hosts con acceso a la WG) y al extremo público `sdr.elarreglador.eu:1234` (verificado 2026-08-14).

## LXC (lxd client) en DV0

DV0 gestiona el cluster LXD de forma remota usando el binario real de LXC directamente (bypasseando snapd, que es inestable con 394MiB RAM).

### Problema: snapd inestable

DV0 tiene solo 394MiB de RAM. El snap de LXD se bloquea al leer binarios desde squashfs (`submit_bio_wait` / `squashfs_bio_read`). El wrapper `/usr/sbin/lxc` (del paquete `lxd-installer`) cuelga al ejecutar `snap list lxd`.

### Solución: binario real + remote por defecto

1. **Copiar la configuración** desde el directorio snap a `~/.config/lxc/`:
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
   remotes:
     d2:
       addr: https://10.8.0.12:8443
       auth_type: tls
       project: default
       protocol: lxd
       public: false
     local:
       addr: unix://
       public: false
   ```

3. **Crear wrapper** en `~/.local/bin/lxc` que llame al binario real:
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

### Verificación

```bash
lxc cluster list    # lista los miembros del cluster
lxc list            # lista contenedores del cluster
lxc info            # información del cluster vía D2
```

### Configuración previa: Remote LXD en D2

Para que DV0 pueda conectar, la API de LXD en D2 debe escuchar en todas las interfaces:

```bash
# En D2 (ejecutado una vez)
lxc config set core.https_address [::]:8443
```

El remote `d2` se añadió originalmente con:

```bash
lxc remote add d2 10.8.0.12:8443 --password <CLAVE_SUDO> --accept-certificate
```

### Ruta a LAN por WireGuard desde DV0

Para que DV0 pueda alcanzar D1/D2 en sus IPs LAN (`192.168.1.x`) a través del túnel WireGuard —necesario para la comunicación con el cluster LXD y Kubernetes— se añaden las IPs LAN a los `AllowedIPs` de cada peer en el servidor:

```ini
### Client D1
[Peer]
PublicKey = <PUBKEY_D1>
AllowedIPs = 10.8.0.11/32, fd42:42:42::11/128, 192.168.1.11/32, 192.168.1.21/32, 192.168.1.30/32, 192.168.1.31/32

### Client D2
[Peer]
PublicKey = <PUBKEY_D2>
AllowedIPs = 10.8.0.12/32, fd42:42:42::12/128, 192.168.1.12/32, 192.168.1.22/32, 192.168.1.32/32

### Client G9 (portátil)
[Peer]
PublicKey = <PUBKEY_G9>
PresharedKey = <PRESHARED_KEY_G9>
AllowedIPs = 10.8.0.100/32, fd42:42:42::100/128
```

Las IPs `.21/.22` (masters) y `.30/.31/.32` (VIP + workers) se anuncian en el peer correspondiente (D1 o D2) para que DV0 las alcance a través del túnel. G9 se registró el 2026-08-18 (peer nuevo, sin IPs LAN: G9 solo necesita las IPs de la VPN).

Además, se añade una ruta estática en DV0 (con `replace` para que sea idempotente en el `PostUp`):

```bash
ip route replace 192.168.1.0/24 dev wg0
```

Aplicar en caliente:

```bash
wg set wg0 peer <PUBKEY_D1> allowed-ips 10.8.0.11/32,fd42:42:42::11/128,192.168.1.11/32,192.168.1.21/32,192.168.1.30/32,192.168.1.31/32
wg set wg0 peer <PUBKEY_D2> allowed-ips 10.8.0.12/32,fd42:42:42::12/128,192.168.1.12/32,192.168.1.22/32,192.168.1.32/32
wg set wg0 peer <PUBKEY_G9> allowed-ips 10.8.0.100/32,fd42:42:42::100/128
ip route replace 192.168.1.0/24 dev wg0
```

---

## WireGuard: Estabilidad de Conexión

### Problema: Conectividad Intermitente

Se observó que desde DV0 a veces no se podía alcanzar D1/D2 via WireGuard (ping, kubectl, SSH), aunque los handshakes estaban activos. El tráfico desde los clientes a DVO siempre funcionaba.

### Causa Raíz

Los clientes (`D1`, `D2`) están detrás de un router NAT doméstico. Sin tráfico activo, el mapeo NAT UDP expira (en ~30s por defecto), y al iniciar tráfico desde DV0, WireGuard debía re-hacer el handshake.

### Solución: PersistentKeepalive

Se añadió `PersistentKeepalive = 25` en la sección `[Peer]` de ambas configuraciones cliente:

```ini
[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
PresharedKey = <PRESHARED_KEY>
Endpoint = 82.223.50.169:51820
AllowedIPs = 10.8.0.1/32
PersistentKeepalive = 25   # <-- añadido
```

Esto envía un keepalive cada 25 segundos, manteniendo el mapeo NAT activo.

### Aplicación en caliente (sin cortar conexión)

```bash
wg set wg0 peer <PUBLIC_KEY_DEL_SERVIDOR> persistent-keepalive 25
```

Editar también `/etc/wireguard/wg0.conf` para que persista tras reinicio.

---

## WireGuard: Estabilidad y Split-Tunnel

### Problema: Pérdida total de conectividad DV0 → D1/D2

El 31-jul-2026, tras un cambio de red local, DV0 perdió toda conectividad con D1 y D2 a través de WireGuard. El diagnóstico reveló dos fallos independientes, ambos provocados por **manipulación manual de las reglas de ruteo** (`ip rule`/`ip route`) en sesiones anteriores, dejando el estado de red inconsistente con la configuración de `wg-quick`.

### Diagnóstico

| Nodo | Síntoma | Causa raíz |
|------|---------|------------|
| **D1** | Handshake muerto (16h). Ping a 10.8.0.1 sin respuesta | Regla manual `ip rule add fwmark 0xca6c lookup 51820` (resto de sesión previa) + ruta residual `default dev wg0` en tabla 51820 (del antiguo full-tunnel). Los paquetes del socket WG (marcados con fwmark) caían en esa regla, se reinyectaban en `wg0` → **bucle de ruteo** → nunca salían por la LAN. |
| **D2** | Handshake activo pero tráfico interior sin respuesta | Config seguía en full-tunnel (`AllowedIPs = 0.0.0.0/0`) y sin reglas de wg-quick aplicadas (tabla 51820 huérfana). `ip route get 10.8.0.1` resolvía a `via 192.168.1.1` (router LAN) en vez de `dev wg0` → el tráfico se descartaba en el router doméstico. |
| **DV0** | OK | Config y `PostUp` correctos. (El `ping 82.223.50.169` falla desde los clientes porque IONOS bloquea ICMP; no es síntoma.) |

**Causa raíz común**: gestionar el ruteo de WG a mano en vez de dejar que `wg-quick` lo genere automáticamente desde `/etc/wireguard/wg0.conf`. Cualquier cambio manual se pierde o queda a medias, y `wg-quick` no vuelve a regenerarlo mientras la interfaz siga arriba.

### Solución aplicada

**1. D1 — Reinicio limpio de wg-quick** (regenera las reglas desde la config, eliminando el bucle):

```bash
sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
sudo wg-quick down wg0
sudo wg-quick up wg0
```

**2. D2 — Migración a split-tunnel + reinicio limpio:**

```bash
sudo cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak
# Cambiar en /etc/wireguard/wg0.conf:
#   AllowedIPs = 0.0.0.0/0,::/0   →   AllowedIPs = 10.8.0.1/32
sudo wg-quick down wg0
sudo wg-quick up wg0
```

**3. Reenvío IP persistente** en D1 y D2 (para permitir tráfico LAN↔WG en el host):

```bash
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -w net.ipv4.ip_forward=1   # en caliente (D2)
```

**4. nginx en DV0** — se eliminó el túnel SSH reverso que servía de muleta y el proxy apunta directamente a la IP WG de D1 vía LXD proxy device:

```bash
# En /etc/nginx/sites-available/k8s
proxy_pass http://10.8.0.11:31113;   # en vez de http://127.0.0.1:31113
sudo nginx -t && sudo systemctl reload nginx
# En D1: matar el proceso del túnel SSH reverso
```

**5. Endurecer PostUp en DV0** (evita fallo de restart si la ruta ya existe):

```bash
# En /etc/wireguard/wg0.conf
PostUp = ip route replace 192.168.1.0/24 dev wg0
```

### Por qué split-tunnel

| Modo | AllowedIPs | Consecuencia |
|------|-----------|--------------|
| **Full-tunnel** (antes) | `0.0.0.0/0,::/0` | Todo el tráfico de D1/D2 pasa por WG. Si WG cae, pierden internet; si el ruteo se rompe, hay bucles. |
| **Split-tunnel** (ahora) | `10.8.0.1/32` | Solo el tráfico hacia DV0 (y redes anunciadas por el peer) entra al túnel. D1/D2 mantienen su gateway LAN normal. Más estable y sin riesgo de bucle. |

### Verificación final

```bash
# En DV0
ping 10.8.0.11   # ✓ responde (~16ms)
ping 10.8.0.12   # ✓ responde (~16ms)
curl http://10.8.0.11:31113   # ✓ 200 (nginx welcome)
curl https://www.elarreglador.eu   # ✓ 200
```

Ambos `wg-quick@wg0` están `enabled` y el estado de ruteo se regenera solo en cada boot.

### Nota: acceso a IPs LAN de los containers

DV0 **no puede hacer ping** a las IPs LAN de los containers LXC (`192.168.1.21/.22/.31/.32`): sus rutas por defecto apuntan al router doméstico (`via 192.168.1.1`), que no conoce la red `10.8.0.0/24` → la respuesta se pierde (ruteo asimétrico). **No es un problema**: los servicios se exponen a través de la IP WG del host D1 (`10.8.0.11`) con LXC proxy devices, cuyo retorno sí es simétrico. Para alcanzar los containers directamente habría que añadir una ruta estática en el router o rutas dentro de cada container — innecesario hoy.

