# D-Lab

## Arquitectura del Cluster:



## Mención del hardware

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
Integrada en el procesador

- Intel HD Graphics 630 (iGPU)

*Adaptador de red*
Integrado en placa base 10/100/1000

- RTL8111/8168/8211/8411 PCI Express Gigabit Etherne

## Tecnologías Utilizadas:

- LXC: Base de la virtualización.

- Kubernetes: K8S gestion de pods (contenedores).

## Redes/LoadBalancer
El hardware se conecta fisicamente desde el router del proveedor de internet, pasando por un switch hasta cada uno de los equipos via ethernet, evitando la conexion wifi.

## Ciber seguridad:



## Guía de Instalación:
- 00-Requisitos.md


## Roadmap / Estado Actual:

