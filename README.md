# D-Lab

Un pequeño centro de datos casero con dos ordenadores Dell OptiPlex, montado para aprender, experimentar y tener servicios propios funcionando 24/7.

Si busca detalles técnicos (cables, comandos, configuraciones), vaya a la [guía técnica](./README-TECH.md). Este documento es una vista general para curiosos.

---

## ¿Qué es D-Lab?

Son **dos mini-ordenadores** (de los que caben en un cajón) trabajando en equipo. Juntos forman un *cluster*: un grupo de máquinas que se coordinan para ejecutar programas de forma continuada, incluso si una de ellas falla.

El conjunto está gestionado por **Kubernetes**, un sistema de orquestación (el "director de orquesta") que decide dónde se ejecuta cada programa, lo reinicia si se cae y le da dirección de red para que el mundo exterior pueda acceder. Cada OptiPlex aloja dos contenedores LXC: uno dirige (`k8s-master`) y otro trabaja (`k8s-worker`).

## ¿Para qué sirve?

D-Lab aloja servicios personales que el propietario usa y vigila. Los siguientes son **ejemplos** — el cluster hospeda más aplicaciones y la lista evoluciona; el inventario completo y actualizado está en [03-Aplicaciones.md](./03-Aplicaciones.md):

| Servicio | Qué es | Acceso | Dirección |
|----------|--------|--------|-----------|
| **Landing** | Página de bienvenida: quién es el propietario y qué proyectos tiene | pública | [elarreglador.eu](https://elarreglador.eu) |
| **Grafana** | Paneles con gráficas: salud del cluster, hosts y DV0 en tiempo real | con login (Grafana) | [grafana.elarreglador.eu](https://grafana.elarreglador.eu) |
| **Node-RED** | Herramienta visual para conectar dispositivos y servicios | con login (Node-RED) | [nodered.elarreglador.eu](https://nodered.elarreglador.eu) |
| **SDR** | Radio definida por software (RTL-SDR v3 + Ham It Up, `rtl_tcp`) | pública, un cliente a la vez | `sdr.elarreglador.eu:1234` |
| **Multimedia** *(ej.)* | Jellyfin, Jellyseerr, qBittorrent, Sonarr, Radarr, Prowlarr, FlareSolverr | solo en casa (LAN) | `192.168.1.53` … `192.168.1.59` (MetalLB) |
| **IA local** *(ej.)* | Ollama con modelos qwen2.5-coder:3b y otros ≤3B | solo LAN/WireGuard | `192.168.1.31:31434` / `10.8.0.11:31434` |
| **Telegram bot** *(ej.)* | Notificaciones internas del cluster | interno (sin ingress) | `telegram-bot.pods.svc:8080` |
| **MariaDB** | Base de datos interna de los servicios | interna | sin acceso exterior |

> **Notas de acceso:** Grafana y Node-RED piden usuario y contraseña; la landing y la SDR son públicas por decisión deliberada — un salón abierto a la calle, pero los cuartos de máquinas con llave. Multimedia e IA local solo responden en la red de casa (o vía WireGuard en el caso de la IA) y MariaDB/Telegram bot solo dentro del propio cluster. Los ejemplos de la tabla no son exhaustivos: puede haber más aplicaciones desplegadas — consulte [03-Aplicaciones.md](./03-Aplicaciones.md) y [README-TECH.md](./README-TECH.md).

## ¿Cómo funciona por dentro?

A grandes rasgos:

```
Internet ──> DV0 (nube, 82.223.50.169, WireGuard 10.8.0.1, nginx stream)
                │  túnel WireGuard (10.8.0.0/24)
                ├── D1 (192.168.1.11) ── k8s-master-1 (.21) + k8s-worker-1 (.31)
                └── D2 (192.168.1.12) ── k8s-master-2 (.22) + k8s-worker-2 (.32)
                         almacenamiento GlusterFS replica 2 + VIP 192.168.1.30
                         red local MetalLB 192.168.1.50-.64
```

1. **Dos ordenadores físicos (D1 y D2)** son la base. Cada uno hace dos papeles: *dirigir* (control-plane) y *trabajar* (worker) en contenedores LXC separados.
2. **El director de orquesta (Kubernetes)** reparte las tareas, vigila que todo funcione y sustituye cualquier pieza que falle. Expone los servicios públicos con **ingress-nginx** y `cert-manager` (passthrough total desde DV0).
3. **Un servidor en la nube (DV0)** hace de portero y túnel seguro: recibe las peticiones de Internet y las pasa al cluster por WireGuard. Así, D-Lab no abre puertos en el router de casa.
4. **Almacenamiento compartido**: los datos viven en ambos ordenadores a la vez (GlusterFS replica 2 + NFS-Ganesha) con dirección virtual `192.168.1.30` que salta al nodo sano. En LAN, MetalLB asigna IPs fijas `192.168.1.50-.64`.

## Puntos fuertes y elecciones de diseño

- **Alta disponibilidad**: dos control-planes con etcd replicado (stacked). Si uno se cae, el otro mantiene los datos; con dos miembros se pierde quorum — de ahí el plan de tercer nodo.
- **Datos replicados**: GlusterFS replica 2 + VIP Keepalived. Si un disco u host falla, la copia sobrevive.
- **Acceso remoto seguro**: toda la gestión externa pasa por WireGuard; sin puertos extra en el router.
- **Red segmentada**: Calico `policy-only` junto a Flannel + NetworkPolicies y PodDisruptionBudgets.
- **Monitorización activa**: Prometheus/Grafana/AlertManager + node-exporter en los 4 nodos, hosts D1/D2 y DV0; alertas y backups etcd diarios redundantes.
- **Protección ante cortes de luz**: SAI Riello RPR 650 para micro-cortes.
- **Internet propio**: dominio `elarreglador.eu` con wildcard `*.elarreglador.eu` y certificados Let's Encrypt vía `cert-manager` (HTTP-01).

## ¿Qué puede hacer un visitante?

- **Ver** la landing pública (sin contraseña).
- **Sintonizar** la SDR en `sdr.elarreglador.eu:1234` con GQRX (un cliente a la vez, sin autenticación).
- **Entrar** en Grafana/Node-RED si dispone de cuenta.
- Nada más por diseño: multimedia, IA local, bases de datos y bots son internos o solo LAN.

## Limitaciones honestas

- Laboratorio en casa: hardware modesto (dos i3 con 8 GB de RAM), no un centro de datos.
- Métricas con almacenamiento **efímero** (`emptyDir`): al reiniciar se pierde el histórico (la configuración sí persiste en ConfigMaps/Secrets).
- etcd con 2 miembros necesita 2/2 para quorum; la caída de un master deja el API sin escritura hasta recuperar el peer. Tercer nodo pendiente.
- Un solo DV0 hace de portero; si él falla, el cluster sigue vivo pero inaccesible desde Internet hasta que se recupere. El SAI cubre solo micro-cortes.

## Documentación

- **[README-TECH.md](./README-TECH.md)** — guía técnica completa por fases: arquitectura, hardware, instalación, seguridad, monitorización y disaster recovery. **No incluye credenciales**; los secretos viven en `info_sensible/` (gitignored).
- **[03-Aplicaciones.md](./03-Aplicaciones.md)** — inventario autoritativo de aplicaciones, workloads, imágenes, almacenamiento y exposición. **Fuente de verdad** para la lista de servicios (los ejemplos de este README son un resumen).
- **[04-Operaciones.md](./04-Operaciones.md)** — apagado y arranque controlado (`scripts/D-lab_stop.sh` / `D-lab_start.sh`).
- **[Hardware.md](./Hardware.md)** — ficha técnica verificada del OptiPlex 3050 Micro.
- **[Benchmark-LLM.md](./Benchmark-LLM.md)** — comparativa de modelos Ollama ≤3B en el cluster.
- **00-Requisitos.md / 01-Network.md / 02-vm.md** — capas de red, virtualización y requisitos; 00 y 02 son parcialmente históricos (describen el cluster inicial de 2 contenedores).
- **[incidentes/](./incidentes/)**, **[files/](./files/)**, **[scripts/](./scripts/)** — postmortems, manifiestos K8s y scripts de despliegue.

## Estado del proyecto

- Servicios públicos verificados (HTTPS 200 / `RTL0` en SDR): landing, Grafana y Node-RED en producción; SDR operativa; multimedia e IA local en LAN operativas.
- Fases completadas hasta **Fase 14B** (telegram-bot interno y cluster-ai con polling + IA live Ollama `qwen2.5-coder:3b`); Fase 14C (RAG docs) en curso; 14D/E pendientes — ver [TODO.md](./TODO.md).
- En marcha: tercer ordenador de control (D3) para quorum etcd 2→3 y HA real.

---

*Un laboratorio casero, dos ordenadores pequeños y cero aburrimiento. Preguntas, ideas o pull requests: bienvenidos. Para el detalle técnico, consulte la [guía técnica](./README-TECH.md) y [03-Aplicaciones.md](./03-Aplicaciones.md).*
