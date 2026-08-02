# D-Lab

Un pequeño centro de datos casero con dos ordenadores Dell OptiPlex, montado para aprender, experimentar y tener servicios propios funcionando 24/7.

Si busca detalles técnicos (cables, comandos, configuraciones), vaya a la [guía técnica](./README-TECH.md). Este documento es una vista general para curiosos.

---

## ¿Qué es D-Lab?

Son **dos mini-ordenadores** (de los que caben en un cajón) trabajando en equipo. Juntos forman un *cluster*: un grupo de máquinas que se coordinan para ejecutar programas de forma continuada, incluso si una de ellas falla.

El conjunto está gestionado por **Kubernetes**, un sistema de orquestación (el "director de orquesta") que decide dónde se ejecuta cada programa, lo reinicia si se cae y le da dirección de red para que el mundo exterior pueda acceder.

## ¿Para qué sirve?

D-Lab aloja los servicios personales que el propietario usa y vigila:

| Servicio | Qué es | Dirección |
|----------|--------|-----------|
| **Landing** | La página de bienvenida: quién es el propietario y qué proyectos tiene | [elarreglador.eu](https://elarreglador.eu) |
| **Grafana** | Paneles con gráficas: cómo está de salud el cluster y los equipos en tiempo real | [grafana.elarreglador.eu](https://grafana.elarreglador.eu) |
| **Node-RED** | Herramienta visual para conectar dispositivos y servicios (automatización y lógica) | [nodered.elarreglador.eu](https://nodered.elarreglador.eu) |

> Nota: Grafana y Node-RED piden usuario y contraseña. La landing, en cambio, es pública: cualquiera puede verla. Es una decisión deliberada: un salón abierto a la calle, pero los cuartos de máquinas con llave.

## ¿Cómo funciona por dentro?

A grandes rasgos:

```
Internet ───> Un pequeño servidor en la nube (DV0) ───> D-Lab (los dos OptiPlex)
                       │
                       └──── Red privada propia entre los ordenadores
```

1. **Dos ordenadores físicos (D1 y D2)** son la base. Cada uno hace dos papeles: *dirigir* (controlar el cluster) y *trabajar* (ejecutar los servicios).
2. **El director de orquesta (Kubernetes)** reparte las tareas, vigila que todo funcione y sustituye cualquier pieza que falle.
3. **Un servidor en la nube (DV0)** hace de portero y túnel seguro: recibe las peticiones de Internet y las pasa al cluster por una red privada cifrada (WireGuard). Así, los servicios de D-Lab no necesitan abrir puertos al exterior ni exponer la red de casa.
4. **Almacenamiento compartido**: los datos viven en ambos ordenadores a la vez (réplica). Si uno muere, el otro sigue con la copia.

## Puntos fuertes y elecciones de diseño

- **Alta disponibilidad**: hay dos ordenadores con funciones de control duplicadas. Si uno se cae, el cluster sigue.
- **Datos replicados**: el almacenamiento se copia en las dos máquinas (GlusterFS), con dirección virtual propia que salta automáticamente al nodo sano.
- **Acceso remoto seguro**: toda la gestión externa pasa por una VPN privada (WireGuard); no hay puertos abiertos de más en el router de casa.
- **Monitorización activa**: el propio cluster se vigila a sí mismo con Prometheus/Grafana y alertas (por ejemplo, si un equipo se apaga o un disco se llena).
- **Protección ante cortes de luz**: un SAI (Riello) mantiene el conjunto vivo ante micro-cortes o fluctuaciones.
- **Internet propio**: los servicios se publican bajo el dominio `elarreglador.eu` con certificados Let's Encrypt (candado HTTPS válido).

## ¿Qué puede hacer un visitante?

- **Ver** la página pública de la landing (sin contraseña).
- **Entrar** en Grafana si dispone de una cuenta (para ver los paneles de estado).
- Nada más, por diseño: el resto del cluster es interno y privado.

## Limitaciones honestas

- Es un laboratorio en casa: hardware modesto (dos i3 con 8 GB de RAM), no un centro de datos.
- El almacenamiento principal de métricas es **efímero**: si el equipo se apaga, se pierde el histórico de gráficas (se conserva, en cambio, la configuración).
- Un solo servidor en la nube hace de portero; si él falla, el cluster sigue vivo pero inaccesible desde Internet hasta que se recupere.

## Documentación

- **[README-TECH.md](./README-TECH.md)** — la guía técnica completa: arquitectura, hardware, instalación por fases, seguridad, monitorización y disaster recovery. **No incluye credenciales**; los secretos viven fuera del repositorio.
- **00-Requisitos.md / 01-Network.md / 02-vm.md / 03-Aplicaciones.md** — documentación por capas (requisitos, red, virtualización y aplicaciones desplegadas).

## Estado del proyecto

- Todos los servicios publicados están en producción y verificados (HTTPS 200).
- En marcha: ampliar a un tercer ordenador de control para reforzar la resiliencia del cluster.

---

*Un laboratorio casero, dos ordenadores pequeños y cero aburrimiento. Preguntas, ideas o pull requests: bienvenidos.*
