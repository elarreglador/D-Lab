# Informe de Incidente: reproducción de vídeo 4K que se detiene y reanuda cada pocos minutos — transcodificación por software sin GPU

**Fecha:** 2026-10-15

**Equipos afectados:** `k8s-worker-1` (192.168.1.31) / `k8s-worker-2` (192.168.1.32), hosts D1 / D2, Jellyfin `jellyfin.elarreglador.eu` (192.168.1.53:8096), firestick cliente (Jellyfin Android TV 0.19.10)

**Estado:** RESUELTO (con dos avisos abiertos, ver Lecciones)

**Severidad:** Media — degradación de UX en un único archivo, sin pérdida de datos ni de biblioteca

## Descripción

Un archivo concreto de la biblioteca se detenía y reanudaba la reproducción cada pocos minutos en el firestick, mientras el resto del catálogo reproducía con normalidad. El síntoma —pausa, relleno de búfer, reproducción, nuevo vaciado— es el patrón clásico de un cliente que consume más deprisa de lo que el servidor produce, no de un error de red ni de un archivo corrupto.

El estudio de los 129 archivos de la biblioteca mostró que solo hay **dos archivos 4K**, y eso dio una prueba controlada natural:

| Archivo | Codec | Resolución | `pix_fmt` | Resultado |
|---|---|---|---|---|
| El que funcionaba | hevc | 3840×1600 | **`yuv420p`** (8-bit, SDR) | Direct Play, sin problemas |
| El que fallaba | hevc | 3840×2072 | **`yuv420p10le`** (10-bit) | Transcodificación completa, se corta |

El archivo que falla es el **único** de la biblioteca en 10-bit con Dolby Vision P8.1 + HDR10. La causa quedó descartada para la red (el archivo va a 3 663 kbps, una cifra irrelevante), para el almacenamiento y para el audio.

## Causa raíz

El cliente no puede decodificar el archivo en nativo (el firestick no soporta Dolby Vision P8.1), así que Jellyfin intenta una **transcodificación completa**: decodificar HEVC Main10 + escalar 4K→1080p + mapear tono HDR→SDR (`tonemapx=bt2390`) + re-codificar con `libx264 -preset veryfast` + empaquetar HLS.

Y la ejecuta **íntegramente por software**, porque la GPU integrada del procesador no estaba disponible para el contenedor:

```
PCI_ID=8086:5912                  → Intel HD Graphics 630 (integrada en el i3-7100T)
DRIVER=i915
D1 (host):    /dev/dri/renderD128 existe
worker (LXC): /dev/dri NO existe   → vainfo falla con "failed to initialize display"
```

Los workers son `i3-7100T` (2 núcleos / 4 hilos). Medido con la misma cadena de filtros que usa Jellyfin, dentro del propio pod:

| Medición | Resultado |
|---|---|
| Decodificar + escalar + tonemap + codificar (software) | **`speed=0.211x`** — 288 fotogramas en 56,46 s |
| Solo decodificar | ~`0.52x` |
| Necesario para reproducir | `1.00x` |

El servidor necesita **4,7 s de CPU por cada 1 s de vídeo**. El búfer del cliente se vacía de inmediato, de ahí el corte continuo. En los logs se veía el transcodificador muriendo y reiniciando tres veces en 90 segundos, y el testigo final que confirma el diagnóstico:

```
[WRN] DynamicHlsController: cannot serve ...50.ts as it doesn't exist and no transcode is running
```

El propio postmortem `incidentes/20260906_jellyfin-lentitud.md` ya avisaba de vigilar el rendimiento «tras transcodes 4K→1080p», pero la alerta se quedó en prosa.

**Agravante no relacionado y encontrado durante el trabajo:** el token legacy del CNI de Calico caducó por tercera vez (a las 10:06 del mismo día), con `Unauthorized` en `destroy network for sandbox`, lo que impedía eliminar cualquier pod. Bloqueaba el propio despliegue. La causa real es que las rotaciones anteriores se hicieron con tokens generados a 24 h, en lugar de usar el del Secret, que no tiene fecha de expiración.

## Solución implementada

Objetivo: que el transcodificado se ejecute en la GPU integrada, **sin** dar privilegios al contenedor de Jellyfin (que está expuesto a Internet).

### 1. Conectar la GPU a los contenedores LXC de los workers

```bash
ssh D1 "lxc config device add k8s-worker-1 gpu gpu gid=44"
ssh D1 "lxc config device add k8s-worker-2 gpu gpu gid=44"
```

El cluster LXD está en Raft (D1 leader, D2 standby), así que se aplica desde cualquier miembro y cada uno resuelve el dispositivo localmente. `worker-1` corre en D1 y `worker-2` en D2. Se usa `gid=44` (grupo `video`) porque es el único id que **coincide en host y contenedor**; el grupo `render` tiene gid 991 en el host y 110 en el contenedor, y apoyarse en él habría funcionado hoy para romperse con el siguiente cambio de ids.

### 2. Montar el sysfs de GPU (necesario para el device plugin)

```bash
ssh D1 "lxc config device add k8s-worker-1 sysdrm disk source=/sys/class/drm path=/sys/class/drm readonly=true"
ssh D1 "lxc config device add k8s-worker-2 sysdrm disk source=/sys/class/drm path=/sys/class/drm readonly=true"
```

Ojo con un detalle tramposo de este entorno: el `hostfs` del snap LXD en D1 **no ve `/tmp`** (`open /var/lib/snapd/hostfs/tmp/...: no such file or directory`), por lo que `lxc file push` desde rutas temporales falla en silencio. Para pasar datos a los contenedores hay que usar stdin (`tee`) o `lxc exec` directo.

### 3. Exponer la GPU al cluster con un device plugin

`files/multimedia/intel-gpu-plugin.yaml`: DaemonSet `intel/intel-gpu-plugin:0.37.1` (imagen **pineada**) en `kube-system`, con `nodeSelector` a los workers. Publica el recurso `gpu.intel.com/i915`.

**Por qué un device plugin y no un `hostPath` en el pod** — dos razones medidas:

1. El namespace `multimedia` está en PodSecurity `baseline`, que **prohíbe `hostPath`**. Se comprobó en los eventos reales: `Error creating: pods ... is forbidden: violates PodSecurity "baseline:latest": hostPath volumes`.
2. Aunque se subiera el namespace a `privileged`, **runc deniega la apertura** del dispositivo: `cannot create /dev/dri/renderD128: Operation not permitted`. Eso habría obligado a `securityContext.privileged: true` en Jellyfin, dando a un servicio expuesto a Internet acceso a `/dev/mapper/control` y al disco de GlusterFS del contenedor LXC.

Con el plugin, el privilegio queda confinado a un DaemonSet interno de `kube-system`, y el namespace `multimedia` pudo **devolverse a `baseline`**.

### 4. Reservar la GPU en el pod de Jellyfin

`files/multimedia/jellyfin.yaml`:
- `resources.limits: gpu.intel.com/i915: 1` (sin `hostPath`, sin `privileged`)
- `securityContext: supplementalGroups: [44]`
- `emptyDir` de `/config/cache`: de `1Gi` a `10Gi`. Un HLS completo de 1 h 41 min a 9 Mbps son ~7 GiB; con 1 GiB kubelet desalojaba el pod a mitad de película. Latente, no era la causa de hoy.

### 5. Activar VAAPI dentro de Jellyfin

`files/multimedia/jellyfin-vaapi.yaml`: Job idempotente que escribe `EncodingOptions` por API. Dos detalles que costaron hora y media de diagnóstico y que están documentados en la spec:

- **La API key de Jellyfin no identifica a ningún usuario**: da `401` en `/Users/Me`, `/System/Info` y `/Library/Refresh`. El Job se autentica como administrador (`Secret jellyfin-admin`, origen `info_sensible/jellyfin-admin.env`, gitignored, `600`).
- **Para autenticarse, el cliente va en `Authorization: MediaBrowser ...`, no en `X-Emby-Authorization`**. Con este último, Jellyfin 12.2.0 lanza `ArgumentNullException (Parameter 'request.App')` → HTTP 400.
- **La verificación se hace contra `/config/encoding.xml`**, no contra el `GET /System/Configuration`: en Jellyfin 12.2.0 ese endpoint **no devuelve la sección `EncodingOptions`** (54 claves, ninguna de encoding), aunque el POST la acepte sin problema.

### 6. Automatizar todo junto

`scripts/jellyfin-gpu-passthrough.sh` (idempotente, verificado ejecutándolo dos veces) y la integración en `scripts/deploy-multimedia.sh` paso 5.

### 7. Reparar el token del CNI de Calico

Rotado en los 4 nodos con el token del Secret `calico-cni-plugin-token` (que no tiene `exp`), con backup previo `calico-kubeconfig.bak-20261015` y verificación por `sha256sum` idéntico en los cuatro. Esto no reanuda `calico-node` ni afecta a los pods en marcha.

## Verificación

`verificado 2026-10-15`:

- Dentro del pod de Jellyfin, `vainfo` carga el driver iHD 26.3.5 y declara **`VAProfileHEVCMain10 : VAEntrypointVLD`** (decodificado HEVC 10-bit) y `VAProfileH264High : VAEntrypointEncSlice` (codificado H.264).
- Benchmark con la misma cadena que medía `0,211x`: **`speed=3.96x`** usando `scale_vaapi` + `tonemap_vaapi` + `h264_vaapi`. Salida: `frame=288 fps=95 ... speed=3.96x elapsed=0:03.01`.
- Los dos workers anuncian el recurso: `kubectl get nodes -o custom-columns=NAME:.metadata.name,'GPU:.status.allocatable.gpu\.intel\.com/i915'` → `1` en ambos.
- `/config/encoding.xml`: `HardwareAccelerationType=vaapi`, `VaapiDevice=/dev/dri/renderD128`, `EnableHardwareEncoding=true`, `TonemappingAlgorithm=bt2390`.
- El pod queda `1/1 Running` **sin `privileged` y sin `hostPath`**, y el namespace `multimedia` devuelto a PodSecurity `baseline`.
- El Job es idempotente: reejecutado devuelve `unchanged` + `condition met`.
- Token de Calico: `sha256sum` idéntico en los 4 nodos y los 4 nodos `Ready`.
- `scripts/jellyfin-gpu-passthrough.sh` ejecutado dos veces seguidas sin errores ni duplicados.

**No verificado:** que la reproducción real del archivo con Dolby Vision deje de cortarse. No se pudo forzar el transcodificado por API —sin perfil de cliente declarado, Jellyfin hace Direct Play y no lanza ffmpeg—, así que la prueba definitiva es reproducir y confirmar en los logs que el comando lleva `h264_vaapi`.

## Lecciones aprendidas

1. **La GPU estaba ahí todo el tiempo, ociosa, mientras la CPU se ahogaba.** Diagnosticar "va lento" sin comprobar primero si el trabajo está en el circuito equivocado lleva a soluciones equivocadas. La medición decisiva fue el benchmark con la misma cadena de filtros que usa el servidor, no el uso de CPU.
2. **`kubectl top` no sirve en este cluster** (`error: Metrics API not available`). El benchmark de ffmpeg dentro del pod es una medida más informativa y no depende de métricas.
3. **Un `HTTP 204` no significa que el servidor haya aplicado lo que le enviaste.** Jellyfin aceptó el POST y devolvió `204` mientras descartaba en silencio tres campos. La única prueba fiable fue leer el fichero resultante.
4. **`X-Emby-Token` no es un atajo universal.** Ya estaba documentado que daba `401`; al añadir autenticación por contraseña apareció un fallo distinto (`request.App` nulo → 400) que solo se vio leyendo la traza del servidor. Los errores de autenticación de este servidor son poco informativos por diseño.
5. **El `hostfs` del snap LXD en D1 no ve `/tmp`.** `lxc file push` desde rutas temporales falla en silencio. En la rotación del token de Calico, el push falló y el `sed` dejó los 4 kubeconfig con el token vacío; se detectó porque los 4 `sha256` coincidían entre sí pero no con el backup. **Verificación que no distinga "todo falló igual" de "todo salió bien" no es verificación.**
6. **PodSecurity `baseline` prohíbe `hostPath`.** Lo di por supuesto dos veces y las dos me equivoqué (también supuse que había exenciones por namespace; no existen, solo en la configuración del API server). Los eventos reales del cluster desmintieron ambas suposiciones.
7. **El token del CNI sigue siendo una deuda.** Ha caducado tres veces; la causa de todas es usar tokens de 24 h en lugar del del Secret, que no expira. La migración a `TokenRequest` proyectado sigue pendiente en `TODO.md`.
8. **El auto-scan de Jellyfin falla de forma intermitente** (`HTTP 000` / `401`) porque su API key no identifica a usuario. Queda anotado para revisarlo aparte; el trabajo de hoy no lo ha empeorado.

## Recomendaciones

1. Cuando se toque `EncodingOptions` otra vez, **leer siempre `/config/encoding.xml`** para confirmar, no fiarse del código de respuesta.
2. Considerar escribir `hevc` a mano en `HardwareDecodingCodecs` (Jellyfin lo rechaza por API). Con ello, el HEVC 10-bit también se decodificaría por hardware y el rendimiento pasaría de ~`1x` estimado a ~`4x`. Requiere reiniciar el pod.
3. Reescribir el `media-compress` para que emita **8-bit SDR con tonemap**: hoy produciría HEVC 10-bit HDR, que el firestick tampoco reproduce en nativo. Con la GPU disponible, el coste de esa conversión baja de horas a minutos.
4. Completar la verificación con una reproducción real de al menos 10 minutos y comprobación de logs.
5. Migrar el CNI de Calico a `TokenRequest` proyectado con rotación automática para que no vuelva a ocurrir lo del token.
6. Revisar `jellyfin-auto-scan`: su API key necesita permisos de usuario, no de aplicación.

## Referencias

- `specs/02-vaapi-jellyfin-gpu.md` — especificación completa, con «Estado de la verificación», decisiones y riesgos
- `incidentes/20260906_jellyfin-lentitud.md` — postmortem previo que ya avisaba del transcodificado 4K→1080p
- `files/multimedia/intel-gpu-plugin.yaml`, `files/multimedia/jellyfin-vaapi.yaml`, `files/multimedia/jellyfin.yaml`
- `scripts/jellyfin-gpu-passthrough.sh`, `scripts/deploy-multimedia.sh`
- `03-Aplicaciones.md` § Stack multimedia simplificado (sección «Jellyfin con aceleración por hardware VAAPI»)
- `TODO.md` § Features
