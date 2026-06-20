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
