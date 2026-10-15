# SPEC 02 — Aceleración por hardware VAAPI para Jellyfin

> **Estado:** Implementado — ver «Estado de la verificación» (núcleo VAAPI aplicado y verificado; queda pendiente la reproducción real desde el Fire Stick)
> **Depende de:** SPEC 01 (convenciones de repo y de despliegue). Usa el cluster LXC + K8s ya desplegados; no depende funcionalmente de AdGuard Home.
> **Fecha:** 2026-10-15
> **Objetivo:** Dar al pod de Jellyfin acceso, mediante VAAPI, a la GPU Intel HD Graphics 630 integrada de ambos workers, para que transcodifique 4K HEVC 10-bit HDR sin saturar la CPU del `i3-7100T`.

## Contexto del repositorio (léalo antes de empezar)

- Vault Obsidian de infraestructura K8s sobre LXC. **No hay build/test/lint/CI.** La documentación es el artefacto. Docs en español, identificadores/scripts en inglés.
- Ejecutar **siempre desde la raíz del repo**. Los scripts hacen `ssh "$KUBECTL_HOST"` (default `server` = DV0, override por env). **No se necesita `kubectl` local.**
- El cluster **LXD está en cluster Raft**: `D1` (database-leader) y `D2` (database-standby), LXD 6.9 en ambos. `lxc list -c nsL` desde D1 muestra los 4 contenedores con su ubicación: `k8s-master-1` y `k8s-worker-1` en **D1**; `k8s-master-2` y `k8s-worker-2` en **D2**. Los comandos `lxc` se lanzan contra cualquier miembro y LXD propaga la configuración; los dispositivos se resuelven **localmente** en el nodo que aloja el contenedor.
- Alias SSH: `D1` → `10.8.0.11`, `D2` → `10.8.0.12` (puerto 9622, ProxyJump DV0); `server` → DV0.
- Patrones a imitar: `scripts/deploy-multimedia.sh` (idempotente), `files/multimedia/jellyfin.yaml`, el Job `jellyfin-ensure-apikey` (Python/shell embebido + sqlite sobre `jellyfin-config-local`) y `jellyfin-libraries.yaml` (Job que habla con la API de Jellyfin).
- Gotcha a respetar: `kubectl apply --dry-run=server` es la única validación fiable. `kubectl top` **no funciona** en este cluster (`error: Metrics API not available`).

## Por qué esta spec

El 2026-10-15 se detectó que `el archivo detectado` se detenía y reanudaba cada pocos minutos en el Fire Stick, mientras el resto de la biblioteca reproducía bien. Diagnóstico medido, no supuesto:

| Medida | Resultado |
|---|---|
| Cliente | `Jellyfin Android TV 0.19.10` |
| Modo de reproducción | **transcodificación completa** (no Direct Play) |
| Pipeline real de Jellyfin | decode HEVC Main10 + `scale` 3840×2072→1920 + `tonemapx=bt2390` (HDR→SDR) + `libx264 -preset veryfast` + HLS |
| Velocidad medida del pipeline | **`speed=0.211x`** (288 fotogramas en 56,46 s) |
| Velocidad midiendo solo el decodificador | ~`0.52x` |
| Necesario para reproducir | `1.00x` |

**Prueba controlada:** la biblioteca tiene exactamente dos archivos 4K. El que funcionaba es `hevc 3840×1600` con `pix_fmt=yuv420p` (**8-bit, sin HDR**): el Fire Stick hace **Direct Play** y reproduce sin problemas. El que falla es `hevc 3840×2072` con `pix_fmt=yuv420p10le` (**10-bit, Dolby Vision P8.1 + HDR10**) y es el único archivo así de los 129 analizados. La causa no es la red (el archivo va a 3 663 kbps), ni el almacenamiento, ni el audio: es que el cliente no puede decodificar el archivo y el servidor no puede transcodificarlo.

Y no puede porque **no usa la GPU que ya tiene**. El host D1 expone:

```
PCI_ID=8086:5912  DRIVER=i915        → Intel HD Graphics 630 (integrada en el i3-7100T)
/dev/dri/card0         226,0   grupo video (gid 44)
/dev/dri/renderD128                grupo render (host gid 991 / contenedor gid 110)
```

mientras que dentro del contenedor `k8s-worker-1` **no existe `/dev/dri`** (`ls: cannot access '/dev/dri'`), y `vainfo` falla con `failed to initialize display`. La imagen `lscr.io/linuxserver/jellyfin` trae ya todo el software necesario —`h264_vaapi`, `hevc_vaapi`, `scale_vaapi`, **`tonemap_vaapi`**, `libva 2.2400.0`, los drivers Intel `i965` e `iHD`— y solo le falta el dispositivo.

## Alcance

**En:**

- **Conecta la GPU del procesador al contenedor `k8s-worker-1` — LXD, desde cualquier miembro del cluster — `/dev/dri/renderD128` pasa a existir dentro del contenedor**
  - Dispositivo LXD `gpu` con `gid: 44`; LXD crea `/dev/dri` y los nodos `card0`/`renderD128` con los major/minor reales.
  - Se resuelve en D1, que es donde corre el contenedor.
- **Conecta la GPU del procesador al contenedor `k8s-worker-2` — LXD, desde cualquier miembro del cluster — `/dev/dri/renderD128` pasa a existir dentro del contenedor**
  - Mismo dispositivo `gpu gid=44`; se resuelve en D2. Necesario para no degradar la **movilidad** de Jellyfin, que es requisito documentado.
- **Expone la GPU como recurso del cluster — `files/multimedia/intel-gpu-plugin.yaml` → `kube-system`** — DaemonSet Intel device plugin (`intel/intel-gpu-plugin:0.37.1`), `nodeSelector` a workers, sin `privileged`.
  - Anuncia `gpu.intel.com/i915: 1` en `k8s-worker-1` y `k8s-worker-2`.
  - Monta `/dev/dri`, `/sys/class/drm`, `/var/lib/kubelet/device-plugins` y `/var/run/cdi` por `hostPath` desde `kube-system` (namespace ya `privileged`, no expuesto a Internet).
- **Conecta el sysfs de GPU a los contenedores — LXD, desde cualquier miembro del cluster — `/sys/class/drm` pasa a existir dentro del contenedor**
  - Dispositivo LXD `disk` (`source=/sys/class/drm`, `path=/sys/class/drm`, `readonly=true`). El plugin lo necesita para detectar la GPU; sin él falla la detección.
- **Reserva la GPU en el pod de Jellyfin — `files/multimedia/jellyfin.yaml` — `resources.limits: gpu.intel.com/i915: 1` y grupo vídeo 44**
  - El device node lo inyecta el plugin: el pod **no lleva `hostPath` ni `privileged`**.
  - `securityContext: supplementalGroups: [44]`; verificado que el proceso `abc` (uid 1000) puede abrir el nodo porque este queda `root:root` con los grupos `0,100,1000`.
- **Amplía el disco para transcodificados — `files/multimedia/jellyfin.yaml` — `emptyDir` de `/config/cache` sube de `1Gi` a `10Gi`**
  - Un HLS completo de 1 h 41 min a 9 Mbps son ~7 GiB; con `1Gi` kubelet desalojaría el pod a mitad de película.
- **Activa VAAPI dentro de Jellyfin — Job `files/multimedia/jellyfin-vaapi.yaml` — escribe `EncodingOptions` en `jellyfin.db` por API**
  - `HardwareAccelerationType: vaapi`, `VaapiDevice: /dev/dri/renderD128`, encode por hardware activo, tonemap `bt2390`.
  - `HardwareDecodingCodecs` con `hevc` (lo reintenta; Jellyfin lo rechaza en silencio, ver verificación).
  - Idempotente: lee la configuración, parchea y vuelve a escribir; reaplicable sin efectos secundarios.
  - **Autentica como administrador** (`Secret jellyfin-admin`, desde `info_sensible/jellyfin-admin.env`): una API key de Jellyfin da `401` en todo lo que requiere usuario.
  - **Verifica contra `/config/encoding.xml`**, no contra el GET: en Jellyfin 12.2.0 `/System/Configuration` **no devuelve `EncodingOptions`**.
- **Automatiza el paso de la GPU — `scripts/jellyfin-gpu-passthrough.sh` — añade el dispositivo a ambos workers y aplica el manifiesto**
  - Idempotente (no falla si el dispositivo ya existe) y verificable con `ls -l /dev/dri` dentro de cada contenedor.
- **Integra el paso en el despliegue — `scripts/deploy-multimedia.sh` — aplica `jellyfin-vaapi.yaml` tras el rollout de Jellyfin**
  - Mismo patrón que `jellyfin-libraries.yaml` en el paso 5.
- **Documenta el resultado** — `03-Aplicaciones.md`, `README-TECH.md`, `TODO.md` e `incidentes/` — con verificaciones `(verificado YYYY-MM-DD)` y comando exacto.

**Fuera del alcance:**

- **Recodificar `el archivo detectado` ni ninguna película concreta.** Decisión explícita del propietario (2026-10-15). El `media-compress` del `TODO.md` se deja como está y se reevaluará aparte.
- Corregir el `media-compress` para que emita 8-bit SDR (hoy produciría HEVC 10-bit HDR, que el Fire Stick tampoco reproduce en nativo).
- Acelerar por hardware el resto de workloads multimedia (qBittorrent y aMule no transcodifican).
- Fijar el tag de la imagen `lscr.io/linuxserver/jellyfin:latest`.
- Cambiar los límites de CPU del pod (`1500m`): con VAAPI deberían sobrar, pero no se tocan en esta spec.
- Elegir el modelo de Fire Stick ni pedir HDR10 en lugar de SDR: la salida será SDR, segura para todos.

## Modelo de datos

**1. Dispositivo LXD (en ambos workers)**

```yaml
name: gpu
type: gpu
gid: 44          # grupo video; estable en host y en contenedor
```

No es un fichero del repo: se aplica con `lxc config device add k8s-worker-N gpu gpu gid=44` desde cualquier miembro del cluster. `scripts/jellyfin-gpu-passthrough.sh` es su fuente de verdad.

**2. Fragmento de `files/multimedia/jellyfin.yaml`**

```yaml
      securityContext:
        fsGroup: 1000
        supplementalGroups: [44]
      containers:
        - name: jellyfin
          volumeMounts:
            - name: dri
              mountPath: /dev/dri
      volumes:
        - name: dri
          hostPath:
            path: /dev/dri
            type: Directory
        - name: cache
          emptyDir:
            sizeLimit: 10Gi      # era 1Gi
```

**3. `EncodingOptions` persistido en `jellyfin.db`** (no es un manifiesto; se escribe por API)

```jsonc
{
  "EnableThreading": true,
  "EnableHardwareEncoding": true,
  "HardwareAccelerationType": "vaapi",
  "VaapiDevice": "/dev/dri/renderD128",
  "EnableTonemapping": true,
  "TonemappingAlgorithm": "bt2390",
  "TonemappingMode": "auto",
  "TonemappingRange": "auto",
  "EnableHardwareDecodingFor": ["h264","hevc","mpeg1video","mpeg2video","vc1","vp8","vp9"]
}
```

Convenciones:

- Todos los valores de `EncodingOptions` son los que ya usa Jellyfin por defecto, salvo los seis modificados arriba. El Job lee, parchea y reescribe; no construye el objeto de cero.
- No se introduce ninguna PVC, Secret ni PVC nueva. Se reutiliza `jellyfin-apikey` (existente, gitignored).
- Los transcodificados siguen en disco local del worker (`emptyDir`), nunca en NFS.

## Plan de implementación

1. Añadir el dispositivo GPU a `k8s-worker-1` desde D1 y verificar `ls -l /dev/dri` dentro del contenedor (aparecen `card0` y `renderD128`, grupo `video`/gid 44).
2. Añadir el dispositivo GPU a `k8s-worker-2` y verificar igual. Comprobar que `vainfo` ya responde dentro de ambos contenedores.
3. Editar `files/multimedia/jellyfin.yaml`: `supplementalGroups`, volumen `dri` + montaje, y `sizeLimit: 10Gi`. Validar con `kubectl apply --dry-run=server`.
4. Aplicar el manifiesto y esperar `rollout status deploy/jellyfin`. Verificar dentro del **pod** que `/dev/dri/renderD128` existe y que su grupo es 44.
5. Ejecutar `vainfo` dentro del pod y comprobar que declara `VAProfileHEVCMain10`, `VAProfileH264High` y el encoder `h264_vaapi`.
6. Escribir `scripts/jellyfin-gpu-passthrough.sh` (pasos 1-4 automatizados e idempotentes) y ejecutarlo de nuevo de punta a punta para confirmar idempotencia.
7. Crear `files/multimedia/jellyfin-vaapi.yaml`: Job que espera la API de Jellyfin, lee `EncodingOptions`, parchea los campos del Modelo de datos, los reescribe y verifica con un `GET` posterior. Validar con `--dry-run=server`.
8. Aplicar el Job y comprobar en sus logs que `EncodingOptions` quedó con `vaapi` y `/dev/dri/renderD128`.
9. Integrar en `scripts/deploy-multimedia.sh`: aplicar `jellyfin-vaapi.yaml` en el paso 5, tras `jellyfin-init-libraries`.
10. **Benchmark comparativo:** repetir en el pod la misma cadena de decodificación/tonemap/codificado que midió 0,211x y dejar la cifra nueva registrada.
11. **Verificación funcional:** reproducir `el archivo detectado` desde el Fire Stick y confirmar en los logs de Jellyfin que el comando ffmpeg usa `h264_vaapi`, que no aparecen `[WRN] cannot serve ... no transcode is running`, y que la reproducción llega a los 10 minutos sin cortes.
12. Documentar en `03-Aplicaciones.md`, `README-TECH.md`, `TODO.md` y escribir el postmortem en `incidentes/20261015_jellyfin-4k-dv-firestick.md`.

## Plan de contingencia

**Escenario A — el pod no arranca tras montar `/dev/dri`** (el `hostPath` no existe en el nodo donde cayó):

```bash
ssh server "kubectl -n multimedia get pods -l app=jellyfin -o wide"
ssh server "kubectl -n multimedia describe pod -l app=jellyfin | tail -20"
```

Reversión: revertir `files/multimedia/jellyfin.yaml` (`git checkout` del fichero) y reaplicar. El pod vuelve al estado anterior en ~60 s sin pérdida de datos: el PVC `jellyfin-config-local` no se toca.

**Escenario B — VAAPI disponible pero la reproducción sigue cortándose:** quitar la decodificación por hardware de la lista (`EnableHardwareDecodingFor: []`) dejando solo el **encode** por hardware. Es el caso más barato de todos y queda como opción intermedia.

**Escenario C — volver al estado previo por completo:**

```bash
ssh D1 "lxc config device remove k8s-worker-1 gpu"
ssh D1 "lxc config device remove k8s-worker-2 gpu"
git checkout files/multimedia/jellyfin.yaml
./scripts/jellyfin-gpu-passthrough.sh   # ya no añade nada; solo reaplica el manifiesto
```

## Criterios de aceptación

- [ ] Dentro de `k8s-worker-1` y `k8s-worker-2` existen `/dev/dri/renderD128` y `/dev/dri/card0`, con grupo `video` (gid 44).
- [ ] `vainfo` dentro del pod de Jellyfin lista `VAProfileHEVCMain10` y el encoder `h264_vaapi`.
- [ ] El pod de Jellyfin queda `1/1 Running` tras el rollout y `/dev/dri` es accesible por el proceso con PUID 1000.
- [ ] `GET /System/Configuration` devuelve `HardwareAccelerationType: "vaapi"`, `VaapiDevice: "/dev/dri/renderD128"`, `EnableHardwareEncoding: true` y `TonemappingAlgorithm: "bt2390"`.
- [ ] El benchmark con la misma cadena que medía `0.211x` supera `1.0x` en el pod.
- [ ] Reproducir `el archivo detectado` durante 10 minutos no produce `[WRN] cannot serve ...` ni `Stopping ffmpeg process` en los logs de Jellyfin, y el comando ffmpeg contiene `h264_vaapi`.
- [ ] `el otro archivo 4K` (el 4K 8-bit SDR) **sigue en Direct Play**: no aparece comando ffmpeg al reproducirlo.
- [ ] El `emptyDir` de `/config/cache` declara `10Gi` y la reproducción de 1 h 41 min no desaloja el pod (`RESTARTS` no aumenta).
- [ ] Si se borra el pod, se re programa en el otro worker y arranca `1/1 Running` sin intervención manual.
- [ ] `./scripts/jellyfin-gpu-passthrough.sh` ejecutado dos veces seguidas no produce errores ni duplica el dispositivo.
- [ ] `git status` no muestra secretos versionados.

## Decisiones

- **Sí: los dos workers, no solo `worker-1`.** El PVC `jellyfin-config-local` está `Bound` a `worker-1`, pero la movilidad es requisito documentado (`03-Aplicaciones.md`). Con el dispositivo en un solo worker, un failover deja el pod en `ContainerCreating` porque el `hostPath` no existe en el otro nodo. Añadirlo a los dos cuesta lo mismo y elimina el fallo.
- **Sí: VAAPI, no Quick Sync (QSV).** Los dos están disponibles en la imagen, pero VAAPI es la ruta verificada pieza por pieza aquí (`tonemap_vaapi`, drivers `i965`/`iHD`, `libva`). QSV añade la capa libmfx sin ventaja demostrada en Gen9.
- **Sí: `hostPath` + `supplementalGroups`, no `privileged` ni `nodeSelector`.** Es el cambio mínimo que da acceso al nodo de render. Un contenedor privilegiado en este cluster sería una regresión de seguridad injustificada, y un `nodeSelector` rompería la movilidad.
- **Sí: `sizeLimit: 10Gi`, no `hostPath` para los transcodificados.** Un `hostPath` obligaría a `nodeAffinity` y mataría la movilidad; 10 GiB en disco local del worker (NVMe de 238 G) es margen suficiente para 1 h 41 min a 9 Mbps con holgura.
- **Sí: `gid: 44` en el dispositivo LXD.** Es el único grupo cuyo id coincide en host y contenedor. `render` tiene gid 991 en el host y 110 en el contenedor: apoyarse en él habría funcionado hoy y roto con el siguiente cambio de ids.
- **Sí: `av1` fuera de la decodificación por hardware.** La HD Graphics 630 (Gen9, 2017) no decodifica AV1. Dejarlo en la lista haría que ffmpeg intentara subir a la GPU algo que no puede. `un archivo AV1 de la biblioteca` es AV1 y se queda con decodificado por software y codificado por hardware.
- **Sí: salida SDR, no HDR10.** No se conoce el modelo de Fire Stick. SDR funciona en todos; HDR10 habría que activarlo por perfil de cliente y abriría otra decisión.
- **No: subir el límite de CPU de 1500 m.** Con el transcodificado fuera de la CPU debería sobrar. Se mide antes de tocar recursos.
- **No: recodificar películas.** Queda fuera por decisión del propietario. Esta spec arregla la *capacidad de transcodificar*, que es el problema de fondo.
- **No: fijar el tag de la imagen.** Se anota como deuda; cambiar `latest` por una versión concreta puede romper el pin de ffmpeg que da `tonemap_vaapi` y merece su propia spec.
- **Sí: automatizar la configuración de Jellyfin con un Job, no por la interfaz.** La convención del repo es despliegue reproducible (`jellyfin-ensure-apikey`, `jellyfin-init-libraries`). Un ajuste hecho a mano en la WebUI no sobrevive a una restauración desde backup.

Decisiones tomadas **durante la implementación**, que son las que más valor tienen:

- **Sí: device plugin Intel, no `hostPath` en el pod.** Dos razones medidas: `multimedia` está en PodSecurity `baseline`, que prohíbe `hostPath`; y aunque se subiera a `privileged`, **runc deniega la apertura** del char device con `Operation not permitted`, lo que habría obligado a `securityContext.privileged: true` en el contenedor de Jellyfin. Eso habría dado a un servicio **expuesto a Internet** acceso a `/dev/mapper/control` y al disco de GlusterFS del contenedor LXC. Con el plugin, el privilegio queda confinado a un DaemonSet interno de `kube-system`.
- **Sí: montar `/sys/class/drm` (readonly) en los contenedores LXC.** El plugin lo necesita para detectar la GPU; sin él no anuncia ningún recurso.
- **Sí: `Authorization: MediaBrowser ...`, no `X-Emby-Authorization`, para autenticarse.** Con el segundo, Jellyfin 12.2.0 lanza `ArgumentNullException (Parameter 'request.App')` → HTTP 400. Dos horas de diagnóstico hasta ver la traza en los logs.
- **Sí: verificar contra `/config/encoding.xml`, no contra el GET.** En Jellyfin 12.2.0 `/System/Configuration` **no devuelve `EncodingOptions`** (54 claves, ninguna de encoding), aunque el POST lo acepte sin problema.
- **Sí: tonemapping y `hevc` como AVISO, no como fallo del Job.** Jellyfin los rechaza en silencio devolviendo `204`; hacerlos obligatorios habría dejado el Job permanentemente en `Failed`.
- **No: fiarse del código `204`.** Comprobado tres veces: `POST /System/Configuration` devuelve `204` incluso cuando descarta campos. La única prueba fiable es leer el fichero resultante.
- **No: usar `kubectl top` para medir rendimiento.** El cluster responde `Metrics API not available`; el benchmark de ffmpeg con la misma cadena de filtros es más informativo.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| **La GPU solo acelera el codificador**: Jellyfin rechaza `hevc` en `HardwareDecodingCodecs`, así que el HEVC 10-bit se decodificaría por software (~`0,52x`) | Medido y documentado como AVISO en el Job. Pendiente de confirmar en una reproducción real. Si hace falta, escribir `hevc` a mano en `encoding.xml` y reiniciar el pod (no cubierto por esta spec) |
| **Sin tonemapping VPP, el contenido HDR/Dolby Vision puede seguir sin transcodificar** | Jellyfin deja `EnableTonemapping=false` porque `vainfo` no lista `VAProcFilter`. Afecta solo a HDR/DV; el SDR transcodifica por hardware sin problemas |
| El device plugin es una dependencia externa más que mantener | Imagen **pineada** a `0.37.1`; vive en `kube-system`, fuera de la superficie expuesta |
| La imagen de Jellyfin es `latest`: un cambio podría romper el pin de ffmpeg que da `tonemap_vaapi` | Se anota como deuda; fijar el tag merece su propia spec |
| El `Secret jellyfin-admin` guarda credenciales dentro del cluster | Origen `info_sensible/jellyfin-admin.env` (gitignored, `600`); se transmite por stdin y nunca aparece en logs ni en el repo |
| El pod puede cambiar de worker | El dispositivo GPU y el sysfs están en **ambos** workers, y el DaemonSet también; `allocatable` verificado en los dos |
| kubelet desaloja el pod al llenarse el `emptyDir` | `sizeLimit: 10Gi` y comprobación de que `RESTARTS` no aumenta tras una reproducción completa |
| Añadir el dispositivo LXD en caliente afecta a otros pods del nodo | Solo crea nodos en `/dev/dri` y `/sys/class/drm`; quien los usa es únicamente el pod de Jellyfin. Verificado `get pods -A` tras el cambio |
| El Job deja de completar si cambia el nombre de los campos | La verificación es sobre `encoding.xml`, que es el fichero estable de Jellyfin; falla **en voz alta** si algo no cuadra |

## Estado de la verificación (2026-10-15)

**Verificado con evidencia:**

| Comprobación | Resultado |
|---|---|
| `vainfo` dentro del pod | VA-API 1.24, driver `iHD 26.3.5`, **`VAProfileHEVCMain10 : VAEntrypointVLD`** (decode HEVC 10-bit), `VAProfileH264High : VAEntrypointEncSlice` (encode H.264) |
| Benchmark con la misma cadena que medía `0,211x` | **`3,96x`** con `scale_vaapi` + `tonemap_vaapi` + `h264_vaapi` |
| `allocatable` de los nodos | `k8s-worker-1` y `k8s-worker-2`: **`gpu.intel.com/i915: 1`** |
| `/config/encoding.xml` | `HardwareAccelerationType=vaapi`, `VaapiDevice=/dev/dri/renderD128`, `EnableHardwareEncoding=true`, `TonemappingAlgorithm=bt2390` |
| Pod de Jellyfin | `1/1 Running`, **sin `privileged` y sin `hostPath`**, namespace `multimedia` devuelto a PodSecurity `baseline` |
| Idempotencia | `jellyfin-vaapi` reejecutado: `condition met`, sin cambios |

**Avisos reales — Jellyfin rechaza estos campos en silencio, devolviendo `204` igual:**

- `EnableTonemapping` / `EnableVppTonemapping` → se quedan en `false`. Causa: `vainfo` **no lista `VAProcFilter`** (0 coincidencias), así que Jellyfin no detecta tonemapping VPP, aunque `tonemap_vaapi` sí funcione en ffmpeg puro.
- `HardwareDecodingCodecs` → se queda en `h264, vc1`; **no acepta `hevc`**.
- `TonemappingMode` → vuelve siempre a `auto`.

**Consecuencia práctica (estimada, no confirmada):** sin `hevc` en la lista, Jellyfin decodificaría el HEVC 10-bit por software (~`0,52x` medido) y codificaría por hardware. Estimación ~`1x`: debería mantener la reproducción, pero sin holgura. **No es un hecho verificado**: la prueba real es reproducir y confirmar que el comando ffmpeg contiene `h264_vaapi`.

**Pendiente:** reproducir `el archivo detectado` desde el Fire Stick y comprobar los logs.

## Lo que **no** está en esta especificación

- Recodificar `el archivo detectado` ni ninguna otra película.
- Arreglar `media-compress` para que emita 8-bit SDR.
- Acelerar por hardware qBittorrent o aMule.
- Fijar el tag de la imagen de Jellyfin.
- Subir los límites de CPU del pod.
- Determinar el modelo de Fire Stick ni servir HDR10.

Cada uno de ellos, si aterriza, irá en su propia especificación.
