# D-Lab

## Arquitectura del Cluster:



## Hardware

### SAI

Riello UPS RPR 650 230VAC (aprox. 360 W).

Es un sistema de alimentación ininterrumpida compacto diseñado para proteger computadoras personales, periféricos y equipos de oficina, frente a cortes de energía, sobretensiones y fluctuaciones de voltaje.

Este equipo es una solución de nivel básico, con de dos salidas tipo schuko

### Switch

Mercusys MS105G

switch Gigabit de escritorio diseñado para redes domésticas o pequeñas oficinas donde se requiere una transmisión de datos rápida y eficiente.

- Puertos: 5 puertos RJ45 de 10/100/1000 Mbps con auto-negociación.

- Capacidad de Conmutación: 10 Gbps (Backplane).

- Dimensiones: 105 x 70 x 24.9 mm.

### Perifericos

Nooelec Ham It Up - Un Nooelec Ham It Up sirve para sintonizar frecuencias bajas de onda corta (HF) utilizando un dongle USB RTL-SDR normal, sumándoles 125 MHz para que el receptor pueda leerlas sin problemas.

### Equipos

El cluster se compone de dos Dell OptiPlex 3050 Micro con las siguientes especificaciones tecnicas a partir del comando 'sudo lshw'

*Modelo*

Dell OptiPlex 3050 Micro

*CPU* 

Intel(R) Core(TM) i3-7100T CPU @ 3.40GHz, (2 núcleos, 4 hilos a 3.40GHz), procesador de bajo consumo (la "T" indica bajo TDP).

*Memoria*

Actualmente 4 GB es insuficiente para un entorno de escritorio o ejecutar contenedores o herramientas de virtualización por lo que se pretende una ampliacion en breve.

```
RAM:           3,2G Micron Technology 2400MHz
Swap:          4,0G
```

*Almacenamiento*

El equipo dispone de un disco mecanico Seagate ST500LM021-1KJ15 de 500Gb y un NVMe M.2 Sandisk SN520 de 256Gb

```
NAME        MAJ:MIN RM   SIZE RO TYPE FORMAT

sda           8:0    0 465,8G  0 disk 
└─sda1        8:1    0 465,8G  0 part Sin formato

nvme0n1     259:0    0 238,5G  0 disk 
├─nvme0n1p1 259:1    0     1G  0 part fat32 (/boot/efi)
├─nvme0n1p2 259:2    0     4G  0 part SWAP
├─nvme0n1p3 259:3    0   100G  0 part ext4 (/)
└─nvme0n1p4 259:4    0 133,4G  0 part Sin formato
```

*Grafica*

- Intel HD Graphics 630 (iGPU)

*Adaptador de red*

- RTL8111/8168/8211/8411 PCI Express Gigabit Etherne integrado en placa base

## Tecnologías Utilizadas:

- LXC: Base de la virtualización.

- Kubernetes: K8S gestion de pods (contenedores).

## Redes/LoadBalancer

El hardware se conecta fisicamente desde el router del proveedor de internet, pasando por un switch hasta cada uno de los equipos via ethernet, evitando la conexion wifi.

## Ciber seguridad:

- [ ] Cambiar puerto ssh
- [ ] Implementar fail2ban


## Guía de Instalación:

- [00-Requisitos.md](./00-Requisitos.md)


## Roadmap:

### Hardware

- [ ] Agregar un tercer equipo fisico
- [ ] Ampliación de memoria RAM a 8GB/16GB por nodo.

### Software

