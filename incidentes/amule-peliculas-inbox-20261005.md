# Informe de Incidente: Jellyfin no detectaba las películas descargadas por aMule

**Fecha:** 2026-10-05
**Equipos Afectados:** `k8s-worker-2` (192.168.1.32, aMule), `k8s-worker-1` (192.168.1.31, Jellyfin), namespace `multimedia`
**Estado:** RESUELTO
**Severidad:** Media (funcionality ausente; ningún dato perdido — las descargas seguían en `/data/amule/incoming`)

## Descripción

Seis películas terminadas en aMule entre el 30-sep y el 2-oct no aparecían nunca en
Jellyfin. Ocupaban **≈ 13,9 GiB** (`ls -la` → `total 14550486` KiB) en la **raíz**
de `/data/amule/incoming/`, no en la subcarpeta `movies`.

El síntoma reportado era «el proceso de agregado automático a Jellyfin ha fallado».
**Falso positivo.** El proceso de agregado (`jellyfin-auto-scan`) funcionaba
correctamente: completaba cada hora con `HTTP 204`. Lo que no existía era el paso
*anterior* — el enrutado del fichero desde el inbox hasta la biblioteca.

## Causa Raíz

Un solo defecto conceptual, expresado en tres piezas del sistema.

### 1. La WebUI de aMule deposita en `IncomingDir` por defecto

`amule.yaml:48-51` fija `INCOMING_DIR=/data/amule/incoming` y `TEMP_DIR=/data/amule/temp`,
y el `postStart` los escribe en `amule.conf`. aMule deja el fichero terminado en
`IncomingDir` **con el nombre de la release**, sin subcarpeta. La WebUI tiene un
desplegable *«Carpeta de destino»* cuyo valor por defecto es precisamente `IncomingDir`.

El repo **asumía** que ese desplegable se usaría para elegir `movies`:

- `init-media-dirs.yaml:48-62` crea `incoming/movies → /data/media/movies`.
- `03-Aplicaciones.md:47-51` describía la cadena como si aMule escribiera ahí.

Ese supuesto solo constaba en un diagrama. Nada en el flujo lo requería, nada lo
verificaba y nada avisaba cuando no se cumplía. `ls -la /data/amule/incoming/`
muestra el symlink `movies`, lo que refuerza la ilusión de que es la ruta usada.

### 2. No existía el equivalente del `amule-music-organizer` para vídeo

La cadena de música **sí** tenía su paso de movimiento: `amule-music-organizer`
(`*/29 * * * *`) recoge el audio suelto de la raíz de `incoming` y lo clasifica en
`Artista/Álbum` dentro de `/data/media/music`. Ese CronJob nació del incidente
`jellyfin-musica-aMule-20261001` (2026-10-01).

Para vídeo no había nada equivalente. Ningún `kubectl apply`, ningún script, ningún
manifiesto movía ficheros de la raíz. La única operación era `/Library/Refresh`,
que reindexa `/data/media/movies` — donde no había llegado nada.

### 3. El escaneo automático era correcto y aun así inútil

`jellyfin-auto-scan` (`0 * * * *`) hacía exactamente lo que debía: `POST /Library/Refresh`
con `HTTP 204` cada hora. La librería `Películas` (`GET /Library/VirtualFolders` →
`["/data/media/movies"]`) se reindexaba sin encontrar nada nuevo.

**El escaneo no puede fallar: no tiene forma de saber que le falta un fichero que nunca
llegó a su ruta.** La avería era invisible para cualquier monitorización de este
proceso, porque el proceso estaba sano.

### Estado de apoyo verificado

Los seis ficheros eran propiedad de `4294967294` (`nobody`), no de `1000:1000` como el
resto de la biblioteca: se escribieron después del último `init-media-dirs` (hace 3d14h
en el momento del diagnóstico). Irrelevante para el fallo, pero condicionaba el diseño
del arreglo (ver *Solución*, punto 3).

## Solución

Nuevo CronJob **`amule-inbox-router`** (`files/multimedia/amule-inbox-router.yaml`),
desplegado y aplicado en `scripts/deploy-multimedia.sh`:

```bash
cat files/multimedia/amule-inbox-router.yaml | ssh server "kubectl apply -f -"
```

1. **Cada 10 minutos** (`*/10 * * * *`, `concurrencyPolicy: Forbid`,
   `activeDeadlineSeconds: 600`, `backoffLimit: 0`, `ttlSecondsAfterFinished: 3600`)
   recorre la raíz del inbox con `os.walk(followlinks=False)` — por lo que ignora los
   symlinks `movies` y `tv` — y mueve a `/data/media/movies` **todo fichero de vídeo**
   que encuentre suelto.
2. **Renombra a `Título (Año).ext`**. Parser propio, solo librería estándar: el año se
   busca primero entre paréntesis (`… (AAAA) …`) y solo si no lo hay se busca suelto
   — orden que importa cuando el título es un número de cuatro cifras y hay otro año
   entre paréntesis: el año es el de los paréntesis y el número es el título.
   El recorte del nombre se hace en el primer paréntesis con prefijo y luego token a
   token contra una lista de ~150 términos técnicos (`bdrip`, `1080p`, `x265`, `ita`,
   `by`, …). Los números de 1-2 dígitos **se conservan**, porque hay sagas cuyo título
   acaba en número; los de 3+ solo se aceptan si aún no hay palabras, para no perder
   títulos numéricos puros.
3. **Sin root.** `runAsNonRoot: true` / `1000:1000` / `fsGroup: 1000`, igual que el
   organizador de música. Verificado antes de elegir esto: `test -w` como UID 1000 da
   `W` en los tres directorios. `/data/media/movies` es `775 nobody:nobody` y sin ACL
   visible, así que un UID 1000 caería en «others» (`r-x`); funciona por una **ACL por
   defecto** que `stat` no muestra. `test -w` con el UID real sí la detecta.
4. **Idempotente y sin sobrescribir.** `os.replace` (rename dentro del mismo NFS:
   instantáneo, no copia 13,9 GiB). Si el destino existe con el **mismo tamaño** se
   salta; si difiere, sufije `-2`, `-3`, … y lo registra. Nombre no interpretable →
   se conserva tal cual, nunca se pierde un fichero. Cero bytes → se salta.
5. **No pisa al organizador de música**: cada CronJob filtra por extensión, así que
   audio y vídeo se reparten sin solaparse.

El aMule sigue funcionando igual: **no hay que cambiar nada en la WebUI**. El
router normaliza cualquier destino que se elija, incluido el valor por defecto. Si en
el futuro se elige `movies` a mano, el `followlinks=False` hace que no toque nada.

### Rechazo de la alternativa

Añadir `/data/amule/incoming` como segunda ubicación de la librería `Películas` era una
solución de una línea, pero deja el directorio de descargas dentro de la biblioteca
permanentemente: si se borra un fichero y aMule no lo re-descarga, la entrada queda
colgada o duplicada, y el organizador de música seguiría moviendo audio desde una ruta
que ahora sería de biblioteca. El router mantiene una frontera limpia entre *inbox* y
*biblioteca*.

## Verificación

* **`(verificado 2026-10-05)`** `kubectl -n multimedia logs job/amule-inbox-router-manual-1` →
  Job `Complete 1/1 4s`. Los nombres concretos se omiten por privacidad; la forma de la
  línea es `MOVIDO: <release de eDonKey> -> Título (Año).ext`:
  ```
  Enrutando video de /data/amule/incoming hacia /data/media/movies
    MOVIDO: <AAAA> <titulo>-<director> <codigo-idioma>.avi -> <Titulo> <Director> (AAAA).avi
    MOVIDO: <Titulo>.<N>.(AAAA).(Spanish.English.Subs).BDrip.<res>.x264-<audio>.by.<grupo>.mkv -> <Titulo> <N> (AAAA).mkv
    MOVIDO: <Titulo>.<N>.(Spanish.English.Subs).<calidad>.<res>.<codec>.<audio>.mkv -> <Titulo> <N>.mkv
    MOVIDO: <Titulo>.<N>.(AAAA).(Spanish.English.Subs).<res>.<hdr>.<codec>.<audio>.by.<grupo>.<dominio>.mkv -> <Titulo> <N> (AAAA).mkv
    MOVIDO: <Titulo>.<subtitulo>.(Spanish.English).HDrip.<codec>-<audio>.by.<grupo>.avi -> <Titulo> <Subtitulo>.avi
    MOVIDO: <titulo>.<N>.(AAAA).(Spanish.English.Subs).BDrip.<res>.<codec>-<audio>.by.<grupo>.mkv -> <Titulo> <N> (AAAA).mkv
  Resumen: 6 movidos, 0 saltados, 0 errores
  ```
  Cobertura de los seis casos: un año suelto al principio del nombre, un año entre
  paréntesis con saga numerada, una release **sin año**, un subgrupo de saga con año,
  un AVI con subtítulo, y una variante con el título en distinta capitalización. Dos de
  los seis nombres de origen no traían el año y uno arrastraba el nombre del director.
  **Ninguna película se movió a mano**: el trabajo lo hizo el script, que es lo que había que validar.
* **`(verificado 2026-10-05)`** `kubectl -n multimedia exec deploy/amule -- ls -la /data/amule/incoming/` →
  solo los dos symlinks `movies → /data/media/movies` y `tv → /data/media/tv`;
  `du -sh /data/amule/incoming` → `5.0K` (antes 14G).
* **`(verificado 2026-10-05)`** `kubectl -n multimedia exec deploy/jellyfin -- ls -la /data/media/movies/` →
  las seis presentes con el nombre limpio, y `setpriv --reuid=1000 … test -r <uno de ellos>` →
  `Jellyfin(uid 1000) PUEDE leer las peliculas`.
* **`(verificado 2026-10-05)`** `kubectl -n multimedia logs job/jellyfin-auto-scan-manual-1` →
  `API lista (intento 1/30)` + `Escaneo lanzado correctamente (HTTP 204)`.
* **`(verificado 2026-10-05)`** `GET /Items?Recursive=true&Fields=Path&IncludeItemTypes=Movie` →
  las seis catalogadas y **con metadatos de TMDB**, no como «sin título»: cada una tiene
  póster, backdrop, logo y ficha con año, y su `Path` cuelga de `/data/media/movies`.
  Los títulos mostrados por Jellyfin difieren del nombre del fichero en los casos en que
  el release estaba incompleto, que es precisamente el objetivo del renombrado.
  `GET /Library/VirtualFolders` → las cuatro librerías en `RefreshStatus: Idle`.
* **`(verificado 2026-10-05)`** Pruebas del script **fuera del clúster**, contra un árbol
  local con la misma variety de nombres más ruido (MP3, `.srt`, `.part`, oculto, symlink,
  0 bytes): 6 movidos y renombrados como arriba, resto intacto; segunda ejecución
  `Resumen: 0 movidos, 1 saltados, 0 errores` (idempotencia); colisión con tamaño distinto →
  `Título (AAAA)-2.mkv` **sin pisar** el original; nombre ininterpretable → movido, no perdido.
* **`(verificado 2026-10-05)`** **Disparo natural programado** (no manual):
  `kubectl -n multimedia get cronjob amule-inbox-router` → `LAST 2026-10-05T07:20:00Z`;
  `get job` → `amule-inbox-router-29853080 Complete 1/1 4s`, con
  `Resumen: 0 movidos, 0 saltados, 0 errores`. Es la idempotencia real sobre el árbol
  ya enrutado: el CronJob corre cada 10 minutos y no vuelve a tocar nada.
* **`(verificado 2026-10-05)`** `kubectl apply --dry-run=server` →
  `cronjob.batch/amule-inbox-router created (server dry run)`. Sin `--dry-run=server` el
  campo `spec.timezone` pasaba el `yaml.safe_load` local y el API server lo rechazaba con
  `strict decoding error: unknown field "spec.timezone"`.

## Lecciones Aprendidas

1. **Un contrato implícito en un diagrama no es un requisito.** «Recuerda elegir
   `movies` en la WebUI» es exactamente el tipo de instrucción que se olvida. El diseño
   correcto no lo exige: lo normaliza. La zona de entrada debe ser *autodescubrible*.
2. **Un escaneo correcto no es un pipeline correcto.** El `HTTP 204` del `auto-scan`
   era verdad y a la vez irrelevante. Un disparador que reindexa no puede detectar que
   le falta un fichero que nunca llegó a su ruta: la ausencia no se manifiesta como
   error, sino como nada. Hay que verificar el **dato en destino** (`GET /Items`), no el
   código de salida del proceso que dispara.
3. **Enrutamiento por normalización > enrutamiento por configuración.** La decisión de
   dónde acaba el fichero debe tomarla el router, no el cliente que lo deja. Si el
   destino es un valor por defecto correcto, todo lo que se escriba en el inbox acaba
   bien por constructo.
4. **Los guiones implícitos en el estado vacío son un invariante de salud.** `du -sh
   /data/amule/incoming` → `5.0K` es la señal. Si vuelve a crecer, el router ha dejado
   de funcionar, aunque `jellyfin-auto-scan` siga devolviendo `204`.
5. **Hay que probar los permisos con el UID que va a usar el proceso, no con root.**
   Root escribía en `/data/media/movies` (`nobody:nobody 775`), y aun así la
   comprobación relevante era `test -w` como UID 1000 — que sale `W` por una ACL por
   defecto que `stat` no muestra. Comprobar como root y asumir que el resto funciona
   habría producido un CronJob que se ejecutaría pero no movería nada.
6. **El clúster es viejo y hay que dejar que lo diga.** `spec.timezone` requiere el
   feature gate `CronJobTimeZone` (K8s ≥ 1.27) y aquí el API server responde
   `strict decoding error`. `kubectl apply --dry-run=server` lo detecta al instante;
   `yaml.safe_load` y `bash -n` pasan todo lo que les des.

## Limitaciones conocidas

- **Los nombres de director se cuelan en el título.** Una de las seis releases traía el
  año suelto al principio y el nombre del director pegado al título con un guion, así que
  el resultado fue `Título Director (AAAA).avi`. TMDB lo matchea bien (verificado: la
  entrada existe y es la película correcta), pero el nombre es más largo de lo debido.
  Arreglarlo exigiría una lista de directores, que es una base de datos, no una regla.
- **Sin año en el nombre, sin año en el fichero.** Una de las seis releases no traía año,
  de modo que quedó `Título N.mkv` sin el sufijo. Jellyfin lo indexa bien por título
  (verificado con metadatos de TMDB), pero el fichero no queda ordenado como sus hermanos.
- **Todo el vídeo suelto va a `Películas`.** No hay heurística de episodio, así que
  una serie descargada por aMule acabaría en la librería de películas.
- **Ficheros movidos con propietario `nobody`.** `os.replace` conserva el inode y su
  propietario, y un proceso UID 1000 no puede hacer `chown` sobre un fichero ajeno. Son
  `-rw-rw-r--` y Jellyfin los lee con normalidad. `init-media-dirs` los normaliza a
  `1000:1000` en el próximo despliegue.

## Recomendaciones

1. **Alertar sobre el tamaño del inbox**, no sobre el estado de los CronJobs:
   `du -s /data/amule/incoming` por encima de unos cientos de MB significa que hay
   descargas sin enrutar. Es la única señal que habría detectado este incidente.
2. **Script de verificación repo↔clúster** (ya pendiente en `TODO.md`): comparar
   CronJobs declarados frente a `get cronjob`, librerías frente a
   `GET /Library/VirtualFolders` y rutas de `media-data`.
3. **Títulos y años de verdad**: consultar TMDB en el router resolvería de una vez el
   director, el año ausente y el renombrado. Requiere una API key en un Secret y, en el
   Finder, `networkPolicy` hacia internet — solo con que el egress lo permita.
4. **Unificar `amule-inbox-router` y `amule-music-organizer`** cuando el router sepa
   distinguir el destino por tipo de contenido. Ahora comparten montaje, permisos y
   convenciones; son dos Jobs que podrían ser uno.

## Referencias

* `files/multimedia/amule-inbox-router.yaml` (nuevo), `amule-music-organizer.yaml`,
  `amule.yaml`, `init-media-dirs.yaml`, `jellyfin-auto-scan.yaml`, `networkpolicy-multimedia.yaml`
* `scripts/deploy-multimedia.sh`
* `03-Aplicaciones.md` § Flujo automático descarga → catálogo
* `incidentes/jellyfin-musica-aMule-20261001.md` (el mismo hueco, del lado del audio)