# Informe de Incidente: Jellyfin no detectaba la música descargada por aMule

**Fecha:** 2026-10-01
**Equipos Afectados:** `k8s-worker-1` (192.168.1.31), `k8s-master-1` (192.168.1.21), namespace `multimedia`
**Estado:** RESUELTO
**Severidad:** Media (funcionality ausente; ningún dato perdido — las descargas siguen en `/data/amule/incoming`)

## Descripción

Las canciones terminadas en aMule no aparecían nunca en Jellyfin. Los MP3
`Elvis Presley - Jailhouse Rock.mp3` (29-sep 13:15) y `The Beatles - Yesterday.mp3`
(29-sep 19:36) llevaban **dos días** en `/data/amule/incoming/` sin que ningún
proceso los moviera a la biblioteca.

El diseño previsto (documentado en el CronJob) era: aMule deja el fichero en
`/data/amule/incoming` → un script de crontab lo clasifica en `Artista/Álbum`
dentro de `/data/media/music` → Jellyfin indexa.

## Causa Raíz

Cuatro defectos independientes, **ninguno visible por separado**. Los tres
primeros bastaban por sí solos para romper la cadena.

### 1. El CronJob organizador no existía

`kubectl -n multimedia get cronjob` solo devolvía `jellyfin-auto-scan` y
`jellyfin-db-backup`. **No había ningún CronJob que moviera ficheros.**

Causa: `files/multimedia/amule-music-organizer.yaml` estaba **untracked** en git
(`??`) y el bloque que lo aplica en `scripts/deploy-multimedia.sh` estaba **sin
commitear**. Una sesión del 29-sep empezó el trabajo, añadió el manifiesto y el
`apply`, y no llegó a commitear ni desplegar. El repo afirmaba un estado que el
clúster no tenía.

### 2. `/data/media/music` no existía

`ls /data/media` devolvía solo `.trash`, `movies`, `tv`. El Job
`init-media-dirs` desplegado era la versión previa a añadir `music`; el diff que
lo añade estaba igualmente sin commitear.

### 3. Jellyfin no tenía ninguna librería de música

`GET /Library/VirtualFolders` devolvía exactamente tres entradas: `Collections`
(boxsets), `Películas` (`/data/media/movies`) y `Series` (`/data/media/tv`).
Ninguna de música. Aunque los ficheros se hubieran movido, Jellyfin no habría
tenido dónde indexarlos.

`files/multimedia/jellyfin-libraries.yaml`, el único manifiesto que declaraba la
librería, era un **no-op total** por tres motivos independientes:

- `deploy-multimedia.sh` **no lo aplicaba**.
- Escribía `/config/data/library.xml`, formato que Jellyfin ≥10.9 **ignora**
  (verificado 2026-10-01: no existen ni `library.xml` ni `library.db` en el
  config; las librerías viven en la DB y solo se exponen por API).
- Declaraba `movies`/`tv` sobre `/media/qbittorrent/*` y `/media/amule/*`, rutas
  que `jellyfin.yaml` **no monta** (el montaje real es `media-data` en `/data`).

### 4. `jellyfin-auto-scan` llevaba horas fallando con HTTP 401

Dos causas **independientes**:

- **Token desincronizado.** El token del Secret `jellyfin-apikey` (creado
  2026-08-31T10:03:49Z) no coincidía con la fila `jellyfin-auto-scan` de la tabla
  `ApiKeys` de `jellyfin.db` (2026-08-31 11:55, otro token). La BD conservaba el
  token antiguo de cuando la cadena aún usaba Jellyseerr.
- **Jellyfin 12.1.0 rechazó `X-Emby-Token`.** El script usaba esa cabecera en todo
  el flujo. Medido sobre el mismo token y el mismo endpoint:

  | Cabecera | Resultado |
  |---|---|
  | `X-Emby-Token: <key>` | `401` |
  | `X-Emby-Token: <key>` + `X-Emby-Client`/`Device`/`Version` | `401` |
  | `Authorization: MediaBrowser Token="<key>"` | `200` |
  | `Authorization: MediaBrowser Token="<key>", Client=..., Device=..., Version=...` | `200` |

  Es un cambio de Jellyfin 12, no un problema de permisos: la cabecera `X-Emby-*`
  dejó de aceptarse para API keys.

Además, el bucle de espera del script trataba el `401` como "API lista" (`if 200 or 401: break`), así que fallaba de inmediato con un diagnóstico engañoso, y `activeDeadlineSeconds: 3300` (55 min) dejaba Jobs colgados 59 min.

### 5. Bugs latentes en el CronJob (hubieran fallado aun desplegándolo)

- `readOnlyRootFilesystem: true` + `apk add --no-cache eyeD3` → `apk` falla con
  EROFS y el `|| true` de la misma línea **se lo tragaba en silencio**. `eyeD3`
  nunca se instalaba, luego `artist`/`album` salían siempre vacíos.
- Los MP3 **no traen ID3v2**: Elvis solo tiene ID3v1 al final y Beatles no tiene
  ningún tag. El metadato útil estaba **solo en el nombre del fichero**.
- `tr -cd '[:print:]'` con locale `C` de alpine **borra los acentos** de artistas y
  álbumes.
- `mv -n` devuelve `0` aunque no mueva nada → el log anunciaba `Moved` en ficheros
  que en realidad se saltaba.
- `delete job amule-music-organizer-cron` en `deploy-multimedia.sh:153` no
  coincidía con el nombre real (`amule-music-organizer`): no-op inofensivo.

### Hallazgo colateral: tercer token de CNI de Calico caducado

Al desplegar, el Job `jellyfin-ensure-apikey` se quedó en `ContainerCreating`:
`FailedCreatePodSandBox ... calico ... error getting ClusterInformation: connection is unauthorized`.
El token de `/etc/cni/net.d/calico-kubeconfig` había caducado en
**`k8s-worker-1` y `k8s-master-1`**; en esos dos nodos **no se podía crear ningún
pod nuevo**. `worker-2` y `master-2` iban bien. Tercera rotación de este token
(la segunda fue el 2026-08-29). Es el gotcha ya documentado en `03-Aplicaciones.md`.

## Solución Implementada

### Pipeline de música

1. **`files/multimedia/amule-music-organizer.yaml`** (reescrito) — script Python
   **solo de librería estándar** embebido en el manifiesto. Orden de resolución de
   metadatos: `ID3v2` → `ID3v1` → nombre del fichero `"Artista - Título"` →
   `Unknown Artist`/`Unknown Album`. Sin `apk` ni `pip` en tiempo de ejecución, de
   modo que conserva `readOnlyRootFilesystem: true` y funciona sin red. Saneado de
   nombres **preservando Unicode** (los acentos se respetan) y con
   sustitución de `/ \ : * ? " < > |` para impedir escapes de ruta. `os.walk` con
   `followlinks=False` ignora los enlaces `movies`/`tv` de `incoming`. Movimiento
   con `os.replace` (atómico, misma PVC) y reserva a `shutil.move`. Logging honesto
   de movido / ya existente / error, y salida `1` si hubo errores.
2. **`files/multimedia/jellyfin-libraries.yaml`** (reescrito) — Job idempotente
   que declara la librería por API: crea `/data/media/music`, espera la API con
   reintentos, y si no hay ninguna librería sobre esa ruta hace
   `POST /Library/VirtualFolders`. Si el token es inválido **falla en voz alta**
   en vez de ser un no-op.
3. **`files/multimedia/init-media-dirs.yaml`** — añade `/data/media/music` y el
   enlace `/data/torrents/music` (en línea con `movies`/`tv`).
4. **`scripts/deploy-multimedia.sh`** — aplica el CronJob organizador, aplica el
   Job de librerías **después** del rollout de Jellyfin y **después** de
   `jellyfin-ensure-apikey` (que es quien registra el token), y elimina el
   `delete job` con el nombre erróneo.

### Esaneo corregido

5. **`files/multimedia/jellyfin-auto-scan.yaml`** — cabecera
   `Authorization: MediaBrowser Token=…, Client=…, Device=…, Version=…`. El bucle
   de espera distingue `200` (listo) de `401/403` (token inválido → fallo rápido
   con mensaje accionable) en vez de tratar el `401` como "listo".
   `activeDeadlineSeconds` 3300 → 600. Imagen fijada a `curlimages/curl:8.6.0`.
6. **Token re-registrado** ejecutando el Job `jellyfin-ensure-apikey`, que inserta
   el token del Secret en la tabla `ApiKeys`.

### Calico

7. **Rotación del token del CNI** en `k8s-worker-1` y `k8s-master-1`: copia de
   seguridad `calico-kubeconfig.bak-<timestamp>`, sustitución del campo `token:`
   por el del Secret `calico-cni-plugin-token` y verificación por `sha256sum`
   (los cuatro nodos quedaron con el mismo hash). No hizo falta reiniciar nada:
   los pods en marcha no se ven afectados porque su sandbox ya existe.

## Verificación

* **`(verificado 2026-10-01)`** `kubectl -n multimedia get cronjob` → `amule-music-organizer */29 * * * *`, `jellyfin-auto-scan 0 * * * *`, `jellyfin-db-backup 0 3 * * 1,4`.
* **`(verificado 2026-10-01)`** `kubectl -n multimedia logs job/amule-music-organizer-manual-2` →
  `MOVIDO: Elvis Presley - Jailhouse Rock.mp3 -> Elvis Presley/Unknown Album [tags]` y
  `MOVIDO: The Beatles - Yesterday.mp3 -> The Beatles/Unknown Album [filename]`,
  `Resumen: 2 movidos, 0 ya existentes, 0 errores`, Job `Complete 1/1 5s`.
* **`(verificado 2026-10-01)`** `kubectl -n multimedia exec deploy/amule -- find /data/media/music` →
  `/data/media/music/Elvis Presley/Unknown Album/Elvis Presley - Jailhouse Rock.mp3` y
  `/data/media/music/The Beatles/Unknown Album/The Beatles - Yesterday.mp3`;
  `incoming` conserva solo los `.mkv`/`.avi` y los enlaces `movies`/`tv`.
* **`(verificado 2026-10-01)`** `GET /Library/VirtualFolders` → `Música (music) ['/data/media/music']`
  junto a `Películas`, `Series` y `Collections`. Segunda ejecución del Job →
  `La librería de música ya existe en /data/media/music -> nada que hacer` (idempotencia).
* **`(verificado 2026-10-01)`** `kubectl -n multimedia logs job/jellyfin-auto-scan-manual-1` →
  `API lista (intento 1/30)` + `Escaneo lanzado correctamente (HTTP 204)`, Job `Complete 1/1 4s`.
* **`(verificado 2026-10-01)`** `GET /Items?recursive=true&includeItemTypes=Audio,MusicAlbum,MusicArtist` →
  `6` ítems: `Audio "Jailhouse Rock"`, `Audio "The Beatles - Yesterday"`,
  `MusicArtist "The Beatles"`, `MusicArtist "Elvis Presley"` y dos `MusicAlbum "Unknown Album"`.
* **`(verificado 2026-10-01)`** **Disparos naturales programados** (no manuales): `jellyfin-auto-scan` a las
  `17:00:02 UTC` → `Escaneo lanzado correctamente (HTTP 204)`, Job `Complete 1/1 4s` (antes: `Failed 0/1` con
  59 min de duración a la hora). `amule-music-organizer` en sus tres disparos naturales
  (`29847869`, `29847898`, `29847900`) → `Complete 1/1` en `4-5s`, con
  `Resumen: 0 movidos, 0 ya existentes, 0 errores`, confirmando la idempotencia sobre el árbol ya organizado.
* **`(verificado 2026-10-01)`** Calico: `sha256sum /etc/cni/net.d/calico-kubeconfig` idéntico
  (`a5197bd6…`) en los cuatro nodos; `kubectl -n multimedia get job jellyfin-ensure-apikey` → `Complete 1/1`
  y `kubectl -n multimedia logs` → `OK ApiKeys verificado`; `/System/Info` con el token del
  Secret y cabecera `Authorization` → `200`.

## Lecciones Aprendidas

1. **`kubectl apply` que sale con `0` no significa que exista la configuración.**
   Un manifiesto no aplicado, o aplicado a un formato que la versión instalada
   ignora, falla en silencio. La única verificación fiable es consultar el
   **estado real por la API** (`GET /Library/VirtualFolders`), no el exit code.
2. **El repositorio puede afirmar un estado que el clúster no tiene.** Manifiesto
   `untracked` + bloque de despliegue sin commitear = operación documentada que no
   ocurre. Un CronJob que "debería existir" hay que verificarlo con `get cronjob`.
3. **Las actualizaciones mayores cambian contratos silenciosos.** Jellyfin 12
   dejó de honourar `X-Emby-Token` sin aviso: la petición falla con `401`, igual
   que un token malo. El `401` tenía dos causas distintas y solo una era el token.
4. **`readOnlyRootFilesystem: true` + instalador en runtime son incompatibles**, y
   un `|| true` alrededor del instalador convierte el error en silencio. Si el
   script necesita dependencias, deben venir en la imagen.
5. **El pipeline de música necesita *dos* pruebas**: mover el fichero **y** que
   la biblioteca exista. Aquí faltaban las dos.
6. **Validar los manifiestos contra el servidor, no solo con un parser YAML.**
   `yaml.safe_load` aceptó un `volumes` en el nivel equivocado y un manifiesto sin
   `volumeMounts`; `kubectl apply --dry-run=server` los detecta al instante.
7. **Los errores de CNI se camuflan como errores de la aplicación.** Un
   `ContainerCreating` Eternal no es un problema de PVC ni de imagen: hay que leer
   los eventos del pod antes de culpar al manifiesto.

## Recomendaciones

1. **Metadatos pobres**: los dos MP3 acabaron en `Unknown Album` porque los ficheros no
   traen etiquetas utilizables. El de Elvis conserva el título (`Jailhouse Rock`)
   desde ID3v1; el de Beatles solo tiene el nombre. Si se quiere álbum y portada,
   hace falta un *tagger* externo (beets/picard) o usar los proveedores de
   metadatos de Jellyfin vía la WebUI; el organizer solo clasifica, no etiqueta.
2. **Migrar el CNI a `TokenRequest` proyectado** con rotación automática, en lugar
   del Secret legacy `calico-cni-plugin-token`, que ya ha caducado dos veces
   (2026-08-29 y 2026-10-01) y dejó `worker-1` sin poder crear pods.
3. **Considerar un script de verificación** que compare lo declarado en el repo
   con lo real del clúster (CronJobs, librerías de Jellyfin, rutas de StorageClass)
   y avise de las divergencias.
4. **Revisar `activeDeadlineSeconds`** en el resto de CronJobs del stack: el
   `3300s` del escaneo era 5× lo necesario y solo servía para enmascarar fallos.

## Referencias

* `files/multimedia/amule-music-organizer.yaml`, `jellyfin-libraries.yaml`, `jellyfin-auto-scan.yaml`, `init-media-dirs.yaml`
* `scripts/deploy-multimedia.sh`
* `03-Aplicaciones.md` § Stack multimedia simplificado y § CNI Calico
* `AGENTS.md` § Gotchas operacionales