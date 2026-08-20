# 03-Aplicaciones — Aplicaciones del cluster: pods y configuración

**Objetivo**: documentar las aplicaciones desplegadas en el cluster Kubernetes de D-Lab: sus pods (workloads, imágenes, réplicas, recursos), su configuración específica y cómo se aplican los cambios. **Este documento es público (GitHub): no incluye credenciales ni secretos.** Las credenciales viven en `info_sensible/` (gitignored) o se pasan por variable de entorno a los scripts, nunca en este repo.

**Contexto**: ver [README-TECH.md](./README-TECH.md#fase-12--monitoreo-y-observabilidad) para el procedimiento de instalación. Manifiestos del repo en `files/`.

---

## Stack multimedia (Jellyseerr + *arr + Prowlarr + qBittorrent + Jellyfin)

Facade de peticiones (Jellyseerr) → organizadores (Sonarr/Radarr) → rastreo (Prowlarr + FlareSolverr) → descarga (qBittorrent) → servidor de medios (Jellyfin). Namespace `multimedia`.

### Resumen de workloads

| App | Workload | Imagen | Servicio | Puerto | IP LAN | Nodo (selector) |
|-----|----------|--------|----------|--------|--------|---------------------|
| qBittorrent | Deployment (1) | lscr.io/linuxserver/qbittorrent | `qbittorrent` | 8080 | `192.168.1.58` | worker (`eu.elarreglador/worker=true`) |
| qBittorrent (torrent) | idem | — | `qbittorrent-torrent` | 6881 T/U | `192.168.1.59` | idem |
| Sonarr | Deployment (1) | lscr.io/linuxserver/sonarr | `sonarr` | 8989 | `192.168.1.55` | k8s-worker-1 (`hostname`, config local) |
| Radarr | Deployment (1) | lscr.io/linuxserver/radarr | `radarr` | 7878 | `192.168.1.56` | k8s-worker-2 (`hostname`, config local) |
| Prowlarr | Deployment (1) | lscr.io/linuxserver/prowlarr | `prowlarr` | 9696 | `192.168.1.57` | k8s-worker-1 (`hostname`, config local) |
| FlareSolverr | Deployment (1) | ghcr.io/flaresolverr/flaresolverr | `flaresolverr` | 8191 | (sin IP LAN) | worker (sin selector) |
| Jellyfin | Deployment (1) | lscr.io/linuxserver/jellyfin | `jellyfin` | 8096 | `192.168.1.53` | worker (`eu.elarreglador/worker=true`) |
| Jellyseerr | Deployment (1) | fallenbagel/jellyseerr | `jellyseerr` | 5055 | `192.168.1.54` | worker (`eu.elarreglador/worker=true`) |

### Almacenamiento

- **`media-data`**: PVC 400Gi RWX sobre `nfs-storage-v4` (GlusterFS/NFS-Ganesha, VIP `192.168.1.30`), montado en `/data`. Subárboles: `/data/media/{tv,movies}` (biblioteca final) y `/data/torrents/{tv,movies}` (descargas). Owner `1000:1000` (`abc`).
- **Config de cada app (estado 2026-08-20, mixto)**: los **\*arr** (sonarr, radarr, prowlarr) usan PVC **local** `*-config-local` (StorageClass `local-static`, `nodeAffinity` → anclados a su worker): el SQLite necesita fsync rápido (~2,5 ms) y sobre NFS no es viable (ver gotcha abajo). **qBittorrent, Jellyfin y Jellyseerr** usan PVC NFS `*-config` sobre `nfs-storage-v4` (montado en `/config`, `/app/config` en jellyseerr) y corren en **cualquier worker** (`eu.elarreglador/worker=true`, movilidad verificada). El **2026-08-20** se migró todo a NFS y se revirtió parcialmente al detectarse el crash-loop de sonarr (detalles y diagnóstico en la nota "Gotcha SQLite sobre NFS").
- **Gotcha Jellyseerr**: la imagen `fallenbagel/jellyseerr` almacena su configuración en **`/app/config`**, no en `/config`. El Deployment monta el PVC en `mountPath: /app/config` y el backup lo contempla (ver Backups) (verificado 2026-08-15; antes montaba `/config` y toda la config vivía en el overlay efímero del pod, perdiéndose al recrearlo).
- **Permisos de `/data`** (`verificado 2026-08-15`): los archivos creados vía NFS/GlusterFS quedan con uid `4294967294` (squash) pero `chown 1000:1000` como root persiste correctamente (`abc:users`). El job `init-media-dirs` (aplicado por `deploy-media.sh`) hace `chown -R 1000:1000 /data/torrents /data/media` + `chmod 775` (dirs) / `664` (files) idempotente; reaplicar si se añade volumen o se pierden permisos.
- Los PVC/PV **locales** de qBittorrent, Jellyfin y Jellyseerr (`*-config-local` / `local-*-config`) se conservan **Bound/Retain sin consumidores** para rollback de estos 3 servicios a local-static.

### Bootstrap (vía API, sin navegador)

`source info_sensible/multimedia.env && ./scripts/multimedia-wizard.sh` — idempotente:
1. qBittorrent: login + `save_path`/`temp_path`.
2. Sonarr/Radarr: `authMethod=forms`, user `elarreglador`.
3. Rootfolders `/data/media/{tv,movies}` + download client qBittorrent (categorías `tv-sonarr`/`movies-radarr`).
4. Prowlarr: qBittorrent como DownloadClient, apps Sonarr/Radarr en `fullSync`, índice proxy **FlareSolverr** con tag `cloudflare`.
5. Indexadores públicos en castellano: **DivxTotal** (definición Cardigann custom), **Torrent9** y **LimeTorrents** (directos). Purga los anglófonos 1337x y Torrent Downloads. `TEST_INDEXERS=1` los testea.
6. Jellyfin: flujo Startup (Configuration → User → RemoteAccess → Complete) y librerías `Movies`/`TV Shows` (idempotente: salta si el admin y las librerías ya existen).
7. Jellyseerr: login con el admin de Jellyfin (primer arranque crea el admin; instalaciones existentes hacen re-login **sin** `hostname` para evitar el 500 "already configured"), marca `initialized` y activa las librerías Jellyfin y los servidores Sonarr/Radarr si faltan.

### Estado y notas

- **Auth de los *arr/Prowlarr**: `X-Api-Key` en el header (config.xml) **bypassa** la autenticación WebUI (`forms`) — es el mecanismo que usa el wizard. Las API keys viven en `info_sensible/multimedia.env`.
- **Jellyfin**: primer usuario `elarreglador` (admin) con librerías `Movies` (id `f137a2dd...`) → `/data/media/movies` y `TV Shows` (id `767bff...`) → `/data/media/tv`. El wizard de primera configuración quedó completado correctamente (_verificado 2026-08-15_).
- **Jellyseerr**: admin `elarreglador@d-lab.local` (integrado con el admin de Jellyfin), librerías `Movies`/`TV Shows` activas, Sonarr/Radarr como servidores de descarga (perfil `Any`, rootfolder correcto). La API key de Jellyfin registrada por Seerr se guarda en sus settings. **Interfaz en castellano** (`verificado 2026-08-17`): locale `es` aplicado por API (login Jellyfin con cookie, luego `POST /api/v1/settings/main` `{"locale":"es"}` para el locale por defecto y `POST /api/v1/user/1/settings/main` `{"locale":"es","permissions":2}` para el admin). Notas: `/api/v1/settings/public` es solo lectura (los cambios van por `/settings/main`, que hace merge); la lista `/api/v1/user` no expone `settings` (ver el `GET /api/v1/user/{id}` individual); el i18n va embebido en el build de Next.js, no hay fichero `/locales/es.json`.
- **Insignias de idioma en Jellyseerr (es-badge)** (`verificado 2026-08-17`): Jellyseerr/Seerr no conoce los idiomas de audio/subtítulos (son Next.js sin plugins). Para saber si un título está disponible en castellano, el pod `es-badge` **busca la disponibilidad en los indexadores antes de descargar** y la pinta sobre las tarjetas. Arquitectura de 2 contenedores en el Deployment `es-badge` (`files/multimedia/es-badge.yaml`): (1) **nginx** sirve el JS (`es-badge.js` en el ConfigMap `es-badge-js`) y proxya `/es-badge-api/` → `127.0.0.1:8080` y `/jf-api/` → `jellyfin:8096` (token Jellyfin server-side desde el Secret `es-badge-jf`, sin exponerlo al navegador; se conserva por compatibilidad); (2) **api** (node:20-alpine, `es-badge-api.js` en el ConfigMap `es-badge-api`) con endpoint `GET /es-badge-api/search?mediaType=movie|tv&tmdbId=<id>&q=<título>` que consulta Prowlarr por **keyword** (`/api/v1/search?type=movie|tvsearch&indexerIds=6&indexerIds=7&indexerIds=9`, clave desde el Secret `es-badge-jf`), **filtra los resultados por coincidencia de tokens del título** (evita ruido: p. ej. "Dune 2021" no contamina "Dune Prophecy"), **clasifica por nombre de release** y devuelve `{"ES":bool,"LAT":bool,"SUB":bool,"EN":bool,"total":n,"cached":bool}` con **caché** en emptyDir (`/cache/cache.json`, TTL 24 h) y **una búsqueda Prowlarr concurrente** (semáforo). El JS cliente (`es-badge.js`) observa `[data-testid="title-card"]` (MutationObserver + scroll con debounce) y encola las tarjetas visibles (cola FIFO + caché server-side). **Extracción del id/título por tarjeta**: la portada de Jellyseerr se renderiza en cliente (sin SSR) y el overlay con `href`/`title-card-title` **solo existe al hacer hover** (lo monta React), así que el script no puede depender solo de él: intercepta **`XMLHttpRequest` y `window.fetch`** (Jellyseerr usa axios → XHR, no `fetch`; sin la interceptación XHR el mapa de pósters nunca se llenaba en producción), captura las respuestas JSON de `/api/v1/discover` y `/api/v1/search` (mismo origen → mismas cookies) y construye un mapa `posterPath → {tmdbId, mediaType, title}` (TV usa `name`, movie `title`); cada tarjeta se resuelve por la URL de su `<img>` (póster de TMDB `image.tmdb.org/t/p/w300_and_h450_face/…`) con el overlay como fallback. Dedupe por `mediaType:tmdbId` (una consulta por película aunque aparezca en varios sliders) con caché `FLAGS[id]` y cola `WAITING[id]` para pintar los duplicados que llegan mientras la consulta está en vuelo. Debug: `?es-debug=1` activa logs y expone `window.__esBadge` (conteo de pósters capturados/consultas/pendientes/en espera). Muestra **todas las insignias que apliquen**: **ES** (audio castellano: `castellano|español|spanish|dual|multi|spa`), **LAT** (`latino|es-419|esp-lat`), **SUB** (subtítulos en castellano: `VOSE|VOS|subs spanish|subtitulado`), **EN** (audio inglés). El Ingress `jellyseerr` (`files/multimedia/ingress-jellyseerr.yaml`) añade `configuration-snippet` con `sub_filter` inyectando `<script src="/es-badge.js">` + `proxy_set_header Accept-Encoding ""` (evita respuestas gzip que romperían el filtrado) y las rutas `/es-badge.js`, `/es-badge-api/` y `/jf-api/` → service `es-badge`. **Requisito en ingress-nginx (v1.15.1+)**: el ConfigMap `ingress-nginx-controller` necesita `allow-snippet-annotations: "true"` **y** `annotations-risk-level: Critical` (desde v1.12 el webhook valida por nivel de riesgo y los snippets son `Critical`), y el controller se lanza con `--enable-annotation-validation=false`; sin esto el `kubectl apply` del Ingress falla con "risky annotation". Añade la NetworkPolicy `es-badge-ingress` (`files/multimedia/networkpolicy-es-badge.yaml`): `media-public` solo deja entrar al ingress-nginx en 5055/8096, no en el 80 de es-badge. Alcance: la inyección solo aplica al acceso **externo** (jellyseerr.elarreglador.eu); la IP LAN `192.168.1.54:5055` no la tiene (no pasa por el ingress). Detalles: los indexadores públicos **no soportan búsqueda por tmdbId/imdbId** (solo keyword), por eso el api usa el título de la tarjeta como query; 1337x queda excluido de la disponibilidad por su latencia (FlareSolverr, ~13 s vs ~2-4 s de los directos), a costa de perder su volumen; la clasificación es heurística por nombre (un `MULTI` francés sin español podría dar falso ES; un release con `VOSTFR` (francés) **no** marca SUB español). Regenerar ConfigMaps: `kubectl -n multimedia create configmap es-badge-js --from-file=es-badge.js=files/multimedia/es-badge.js --dry-run=client -o yaml | kubectl apply -f -` (idem `es-badge-api` desde `es-badge-api.js`). Verificado E2E: `/es-badge-api/search` devuelve insignias correctas para Dune Prophecy (ES+LAT+SUB+EN, total=106, 2ª llamada `cached:true`), caché persiste en emptyDir, sin fuga de `X-Api-Key`; tests unitarios del clasificador (10 casos), del filtrado de título y del backend (caché) y del JS cliente (18 checks de parseo de póster, dedupe e interceptación de fetch) todos en verde; `multimedia-verify.sh` 32/32. Regresión conocida (2026-08-17): la v1 extraía solo del overlay hover (sin SSR) → sin insignias en portada; resuelto con el mapa de pósters vía interceptación de `fetch`, verificado por curl (script servido idéntico al repo, `health` 200) — falta confirmación visual en navegador con `?es-debug=1`. **Fix v3 (2026-08-17)**: en el HTML real la barra de insignias se pintaba pero **no se veía sobre las tarjetas**: `div[data-testid="title-card"]` carece de `position`, así que el `position:absolute` de `.es-badge-bar` se anclaba al slider (`position:relative` del carrusel) y todas las insignias de un carrusel se apilaban en su esquina inferior-derecha. Además, el dedupe por `mediaType:tmdbId` hacía `return` antes de pintar, por lo que un mismo título en varios sliders solo recibía insignia en la primera tarjeta procesada (p. ej. el póster `tluwRNA…` tenía ES/SUB/EN en "Películas Populares" pero nada en "Tendencias"). Fix: (1) CSS inyectado `[data-testid="title-card"]{position:relative}` para anclar cada barra a su tarjeta (sin efecto colateral: el overlay interno ya es `relative`); (2) caché `FLAGS[id]` que se guarda al resolver cada consulta y, al encolar un duplicado con `DONE[id]`, pinta `badgeCard(card, FLAGS[id])` en vez de saltar (se mantiene 1 consulta por película y todas sus tarjetas reciben la insignia). Tests de unidad 24/24 en verde; ConfigMap `es-badge-js` regenerado e idéntico, script servido por curl idéntico, `health` 200, pod 2/2 Running. Pendiente: confirmación visual en navegador. **Fix v4 (2026-08-17)**: verificado en Chrome headless con sesión real que la app usa **XHR (axios), no `window.fetch`** — el mapa de pósters quedaba vacío y solo se pintaban insignias en tarjetas "hovereadas" (overlay). Se añade `interceptXhr()` (envuelve `XMLHttpRequest.prototype.open/send`, parsea `responseText` en `load`) además de `interceptFetch()`, y cola `WAITING[id]` para pintar duplicados en vuelo. Verificación real (login por API + Chrome headless, `?es-debug=1`): 171 pósters capturados del tráfico real, insignias ES/LAT/SUB/EN en 10 tarjetas; `offsetParent` de la barra === la tarjeta; geometría a 6px/6px de la esquina inferior-derecha de cada tarjeta; duplicados (p. ej. `tluwRNA…` en Tendencias + Películas Populares) pintados idénticos en todas sus instancias. Tests de unidad 28/28.
- **Torrent expuesto**: `TCP/UDP 6881` externo via DV0 → D1 → NodePort `31681` (ver [01-Network.md](./01-Network.md)). Cadena configurada por `scripts/multimedia-expose-torrent.sh` (stream nginx en DV0 + proxies LXC `proxytorrent`/`proxytorrentudp`). TCP+UDP **abiertos y verificados** `(verificado 2026-08-16)`: `nc -zv -w 5 82.223.50.169 6881` → connect succeeded; UDP confirmado con query DHT `find_node` → respuesta de 297 B; qBittorrent reporta `connection_status: connected` (DHT/PEX/pares entrantes activos).
- **Trackers**: la inyección de trackers se aplica por-torrent en tiempo de grab (qBittorrent no modifica torrents ya con announce).
- **Backups**: `files/backup-multimedia.sh` (SQLite + ajustes) desde `install-multimedia-backup.sh`, cron `0 2 * * *` en ambos masters → `/backup/multimedia/`. El script parametriza la ruta de config por app: `/config` salvo jellyseerr que usa `/app/config` (`verificado 2026-08-15`; antes asumía `/config` para todas y el backup de jellyseerr fallaba con `tar: can't change directory to '/config'`). Rotación de 30 por app, tar plano (no gzip) + copia al peer master por SSH.
- **Importación automática Radarr** (`verificado 2026-08-15`): fallaba con `System.ArgumentException: A path must be provided` (vía API `DownloadedMoviesScan` sin `Path`) o "No files found are eligible for import" cuando el `content_path` de qB no era accesible/legible. Arreglado en dos frentes: (1) permisos `1000:1000` en `/data` vía `init-media-dirs` (owner squash→`abc`); (2) el objetivo de import debe ser el `content_path` real del grab de qB, nunca un `DownloadedMoviesScan` a ciegas. E2E verificado de punta a punta: grab → descarga qB → import automático `downloadFolderImported` con cola a 0 y `hasFile:true`. Nota: si `DetectSample: Failed to get runtime from the file, make sure ffprobe is available`, el import queda `importBlocked` mientras la descarga cierra; el reintento del ciclo lo resuelve.
- **Política de idioma de descargas: castellano + fallback inglés** (`verificado 2026-08-17`): Sonarr v4 y Radarr v6 no tienen *language profiles*, así que el idioma se decide con Custom Formats. `scripts/multimedia-language.sh` (idempotente y declarativo: crea o actualiza los CFs y puntúa el perfil) configura en ambas apps 5 CFs: **"Español (Audio)"** (Language=Spanish/castellano, score 110), **"Audio dual"** (regex `dual|multi|es-en|castellano…inglés`, score 110), **"VOSE"** (regex de subtítulos, score 100), **"Inglés (con subs)"** (regex `eng.*subs|subs.*eng|\.eng\.(srt|sub|ass|ssa|vtt)`, score 50) y **"Inglés (sin subs)"** (regex `eng|english`, score 1). Aplica `minFormatScore=1` al perfil **"Any"** (id 1, el único que usa Jellyseerr vía `activeProfileId=1`). Jerarquía resultante (score por release, se elige el mayor; los CFs son aditivos): doblado+dual+subs **320** > doblado+dual **220** > doblado **110** > VOSE **100** > **Inglés+subs **51** (50+1 base) > **Inglés solo **1** > sin match **0** (rechazado). El CF "VOSE" no exige idioma a propósito: los releases `...-VOSE`/`SUBBED`/`VOS` se parsean a menudo como idioma "Unknown" y exigirlo los dejaría sin puntuar. Validado con `/api/v3/parse` (ej. `...-ENG.Subs` → 151; `...-ENG` → 1; `...-SPANISH` → 110). Limitaciones: detección por nombre de release; "Spanish (Latino)" excluido del CF de doblaje; Radarr no expone CFs en `/api/v3/parse` (mismo motor, verificado por config almacenada).
- **Indexadores torrent** (`verificado 2026-08-19`): las fuentes anglocéntricas (The Pirate Bay, YTS, EZTV, Nyaa.si) se sustituyeron primero por 4 públicas multilingüe y, tras evaluar candidatas en castellano, se dejó un set **3 en castellano**: **DivxTotal** (`https://divxtotal.foo/`, **definición Cardigann v11 custom** — el sitio no tiene soporte integrado en Prowlarr), **Torrent9** (`https://www6.torrent9.to/`) y **LimeTorrents** (`https://www.limetorrents.fun/`). Se purgaron **1337x** y **Torrent Downloads** (inglés, no aportaban). La definición de DivxTotal vive en `files/multimedia/prowlarr-defs/divxtotal.yml`, se entrega al cluster como ConfigMap `prowlarr-custom-defs` (`files/multimedia/prowlarr-custom-defs.yaml`) montado en `/config/Definitions/Custom` del pod (`prowlarr.yaml`), y la carga **deploy-multimedia.sh** (paso [3]) antes de reiniciar Prowlarr; los cambios en el ConfigMap requieren `kubectl rollout restart deploy/prowlarr`. Funcionamiento: búsqueda WordPress `/?s=<q>` (sin keywords devuelve 0), filas `table.table tbody tr` (título/categoría/fecha `dd-MM-yyyy`/tamaño, a menudo `N/A`→700 MB), categorías por slug de URL (`peliculas`→Movies/SD, `peliculas-hd`→Movies/HD, `peliculas-dvdr`→Movies/DVD, `series`→TV/SD, `programas`→PC, `otros`→Other/Misc) y **grab en 2 saltos** (bloque `download.selectors`): Prowlarr hace GET de la página de detalle y extrae el enlace real `download_tt.php` (películas: 1 enlace; series: primer capítulo). El dominio de DivxTotal rota con frecuencia (histórico: `.ms/.fi/.cat/.pl`): si cae, actualizar `baseUrl` del indexador y el `links` de la definición. Verificado E2E: `/api/v1/search?query=dune` → 15 resultados DivxTotal con categorías correctas; grab `/9/download?...` → `.torrent` bencoded válido (`d8:announce...`); `TEST_INDEXERS=1` → DivxTotal/LimeTorrents/Torrent9 OK. **Descartadas**: **DonTorrent** (doble anti-bot: challenge Anubis + PoW por descarga vía `api_validate_pow.php`, inasumible para Cardigann) y **EliteTorrent** (enlaces de descarga a través de acortador muerto `acortame-esto.com` → `google.com`). Detalles operativos previos: 1337x tardaba >60 s en resolverse (challenge Cloudflare, el proxy FlareSolverr usa `requestTimeout=120`); Torrent9 **no** usa proxy (sin tag `cloudflare`). Las apps Sonarr/Radarr reciben los 3 indexadores por `fullSync` (no modifican la puntuación por CFs de la política de idioma; ids Sonarr/Radarr: Torrent9=5, LimeTorrents=6, DivxTotal=8). Sigue vigente la limitación de que un título sin releases en castellano (p. ej. **Bluey**) no puntúa y no se descarga.
- **IPs propias en LAN vía MetalLB** (`verificado 2026-08-16`): se instaló MetalLB v0.14.9 (manifest nativo en `files/metallb/`, sin Helm) con pool L2 `dlab-lan` = `192.168.1.50–192.168.1.64`. Cada servicio expuesto pasó a `type: LoadBalancer` con `loadBalancerIP` fijo y `externalTrafficPolicy: Local`: `.50` landing, `.51` grafana, `.52` nodered, `.53` jellyfin, `.54` jellyseerr, `.55` sonarr, `.56` radarr, `.57` prowlarr, `.58` qB WebUI, `.59` qB-torrent (NodePort `31681` preservado), `.60` rtl-sdr (NodePort `31234` preservado). MariaDB y FlareSolverr siguen ClusterIP (sin IP LAN, por decisión). El acceso **externo no cambia** (DV0 → NodePorts/ingress intactos; verificado `curl` 200/302 y `nc 82.223.50.169:6881`).
- **Gotcha ruteo asimétrico + IPs LAN**: cada host físico **no alcanza las IP propias de sus propios LXC** (D1 no ve `.52`, `.55`, `.57`, `.58`, `.59`, `.60`; D2 no ve `.50`, `.51`, `.53`, `.54`, `.56`), mismo motivo documentado en `01-Network.md`. Desde cualquier otro equipo de la LAN todas responden (verificado con `curl`/`nc` cruzando D1↔D2). Las NetworkPolicies del stack se ampliaron con `ipBlock: 192.168.1.0/24` en `media-public`, `multimedia-internal`, landing y nodered para permitir el tráfico LAN.
- **Gotcha SQLite sobre NFS (diagnóstico definitivo 2026-08-20)**: las apps .NET de los *arr usan `busytimeout=100` (100 ms) y SQLite WAL `synchronous=FULL` (1 fsync por COMMIT). El volumen Gluster `vol-storage` es **Replicate 1×2 sobre discos mecánicos** (`192.168.1.31/32:/mnt/data/brick`, `performance.client-io-threads: off`), por lo que cada fsync tarda **~66 ms** (verificado: 150×4KB+fsync en 9,9 s; el disco local del nodo hace lo mismo en **~2,5 ms**). Con esa latencia, el RSS sync de Sonarr (decenas de commits) bloquea el servidor HTTP → las probes `/ping` (timeout 5 s) fallan → liveness reinicia el pod. **Experimentos descartados**: `local_lock=all` es **ignorado silenciosamente por el kernel en NFSv4** (monta en `local_lock=none`); con NFSv3 + `local_lock=all` el cuelgue **persiste** (el cuello de botella es el fsync I/O de la capa Ganesha→Gluster, no la negociación de locks). **Conclusión**: SQLite sobre este NFS **no es viable para los \*arr** → sus configs vuelven a `local-static` (el **2026-08-20** se migró todo a NFS, se verificó el crash-loop de sonarr y se **revirtió selectivamente**: \*arr a local, qB/Jellyfin/Jellyseerr permanecen en NFS con monitorización). Verificado tras el rollback: sonarr/radarr/prowlarr sobre PV local, `/ping` en **1-6 ms** (frente a 66 ms–7 s en NFS), RSS sync instantáneo, 0 reinicios.
- **Failover MetalLB verificado** (`verificado 2026-08-16`): `kubectl cordon k8s-worker-2; kubectl delete pod grafana` → el pod se re-schedulo a k8s-worker-1 manteniendo el service `.51` y respondiendo por LAN (`curl http://192.168.1.51/login` → 200, 0.04 s; re-ARP automático de MetalLB). Aplicable a cualquier servicio sin nodeSelector; hoy solo los anclados por hardware (rtl-sdr) siguen ligados a su nodo.
- **Movilidad parcial + masters blindados** (`verificado 2026-08-20`): `k8s-master-1` recibió label `node-role.kubernetes.io/control-plane` + taint `NoSchedule` (simétrico a `k8s-master-2`); se desalojaron de los masters landing, es-badge, **Prometheus** (TSDB efímero en emptyDir → se pierde al reiniciar, comportamiento documentado) y qBittorrent (que vivía en el master). El 2026-08-20 se eliminó el anclaje a nodo de los 6 servicios multimedia (nodeSelector → `eu.elarreglador/worker=true`) y de es-badge; **failover bidireccional real verificado**: `cordon k8s-worker-1; kubectl delete pod -l app=qbittorrent` → pod en k8s-worker-2, WebUI `.58:8080` 200 desde D1 y torrent externo `6881` OK; `cordon k8s-worker-2; kubectl delete pod -l app=radarr` → pod en k8s-worker-1, `.56:7878` 302 desde D2. MetalLB re-anuncia cada IP desde el nuevo nodo (re-ARP). **Reversión selectiva del mismo día**: sonarr/radarr/prowlarr volvieron a `nodeSelector kubernetes.io/hostname` + config local (SQLite sobre NFS inviable, ver gotcha arriba) → hoy la movilidad de pods se limita a **qBittorrent, Jellyfin, Jellyseerr** (config en NFS), además de landing/es-badge/Grafana/nodered (sin selector). Anclados permanentemente: **\*arr** (config local) y **rtl-sdr** (dongle USB, `eu.elarreglador/sdr=true`).

---

## Stack de monitorización: kube-prometheus-stack

- **Helm release**: `kube-prometheus-stack` (chart v88.0.1), namespace `monitoring`.
- **Prometheus operator**: v0.93.0.
- **Values**: el fichero `/root/values-monitoring.yaml` **ya no existe** en k8s-master-1 ni en k8s-master-2 (verificado 2026-08-18). Se usó en la instalación original para pasar el `adminPassword` de Grafana, pero hoy la password efectiva de admin es la del Secret `kube-prometheus-stack-grafana` en `monitoring` (efímero, ver abajo). El chart sigue gestionado por helm; si algún día se reinstala, habría que reconstruir el values con `grafana.grafana.ini` y `adminPassword`.
- **Actualizar config**: hoy la configuración viva vive en el ConfigMap `kube-prometheus-stack-grafana` (`grafana.ini`), el Secret `kube-prometheus-stack-grafana` (admin) y los ConfigMaps de dashboards/datasources (sidecar kiwigrid). Cambios puntuales se aplican con `kubectl`; el mecanismo completo de helm upgrade exigiría reconstruir `values-monitoring.yaml` (ya no existe, ver arriba).

### Resumen de workloads

| App | Workload | Réplicas | Imagen | Servicio (ClusterIP) | Puertos |
|-----|----------|----------|--------|-----------------------|---------|
| Grafana | Deployment `kube-prometheus-stack-grafana` | 1 | grafana/grafana:13.1.1 + 2× kiwigrid/k8s-sidecar:2.10.0 (dashboards y datasources) | `kube-prometheus-stack-grafana` | 80 |
| Prometheus | StatefulSet `prometheus-kube-prometheus-stack-prometheus` | 1 | quay.io/prometheus/prometheus:v3.13.2 + prometheus-config-reloader v0.93.0 | `kube-prometheus-stack-prometheus` (9090/8080) | 9090 |
| AlertManager | StatefulSet `alertmanager-kube-prometheus-stack-alertmanager` | 1 | quay.io/prometheus/alertmanager:v0.33.1 + config-reloader | `kube-prometheus-stack-alertmanager` (9093/8080) | 9093 |
| kube-state-metrics | Deployment `kube-prometheus-stack-kube-state-metrics` | 1 | registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.19.1 | `kube-prometheus-stack-kube-state-metrics` | 8080 |
| Prometheus operator | Deployment `kube-prometheus-stack-operator` | 1 | quay.io/prometheus-operator/prometheus-operator:v0.93.0 | `kube-prometheus-stack-operator` | 443 |
| node-exporter | DaemonSet `kube-prometheus-stack-prometheus-node-exporter` | 1 por nodo (4) | quay.io/prometheus/node-exporter:v1.12.1 | `kube-prometheus-stack-prometheus-node-exporter` | 9100 |

---

## Grafana

- **URL pública**: `https://grafana.elarreglador.eu` (Ingress `grafana` en `monitoring`).
- **Acceso**: solo login propio de Grafana. **Sin** basic-auth web ni anonymous. La página de login es pública. Usuarios (las credenciales concretas no van a este repo público):
  - `elarreglador` — uso diario, **rol Admin en la org 1 + Grafana Admin global**. Garantizado por `scripts/grafana-user.sh` (idempotente; passwords en `info_sensible/grafana-user.env`, gitignored).
  - `admin` — mantenimiento; password en el Secret `kube-prometheus-stack-grafana` (`admin-password`, base64). Al ser el storage efímero, si se pierde se resetea vía `kubectl` (patch del Secret + `rollout restart`) o con la CLI de Grafana.
- **Nota de automatización**: el endpoint `POST /api/login` de Grafana 13 espera JSON y aplica *rate limiting* por IP tras varios intentos fallidos (~10 min). En scripts es más fiable autenticar con **Basic Auth** (`curl -u user:pass .../api/user`) que con el login por form.
- **Ingress** (`files/monitoring/grafana-ingress.yaml`): TLS con cert-manager (secret `grafana-elarreglador-eu-tls`), `force-ssl-redirect: true`, sin anotaciones de auth.
- **grafana.ini** (vía `grafana.grafana.ini` en los values):
  - `server.root_url = https://grafana.elarreglador.eu/` + `server.domain = grafana.elarreglador.eu` — **obligatorio** detrás del proxy TLS; sin ellos el frontend recibe `appUrl=http://localhost:3000/` y la sesión se pierde al navegar (login en cada página).
  - `security.cookie_secure = true` + `security.cookie_samesite = lax` — cookie de sesión solo por HTTPS.
- **Almacenamiento**: efímero (`persistence.enabled: false`). Tras reiniciar el pod se pierden cambios de UI no provisionados **y los usuarios** (incluidos los **public dashboards**, ver más abajo). Para re-garantizar `elarreglador` tras una recreación: `./scripts/grafana-user.sh` (lee las credenciales de `info_sensible/grafana-user.env`).
- **Dashboard provisionado «Sistema D-Lab»** (`files/monitoring/grafana-dashboard-sistema-dlab.yaml`, ConfigMap `grafana-dashboard-sistema-dlab` en `monitoring` con label `grafana_dashboard: "1"`): 7 tarjetas stat de CPU%/RAM% en tiempo real — **DV0** (job `dv0-host`, label `host="dv0"`, ancho completo en la 1.ª fila), hosts físicos D1/D2 (job `host-node`, label `host`) y los 4 nodos K8s (job `node-exporter`, filtrados por `instance`). El sidecar kiwigrid lo importa; cambios al CM se reflejan al pulsar "Refresh" sin reiniciar.
- **Monitorización de hosts D1/D2** (fuente del job `host-node`): ServiceMonitor + Service/Endpoints versionados en `files/monitoring/host-node.yaml` (replica del objeto vivo en el cluster). D2 se scrapea directo en `192.168.1.12:9100`; D1 vía relay socat en `192.168.1.12:19100`. El relabeling añade `host="d1"`/`host="d2"`.
- **Monitorización de DV0** (`verificado 2026-08-18`): node_exporter v1.12.1 instalado en DV0 (binario en `/usr/local/bin`, unit systemd `node-exporter.service`) escuchando solo en la IP del túnel `10.8.0.1:9100` (sin firewall; no expuesto a internet). Al no estar DV0 en la LAN, se scrapea vía un segundo relay socat en D2 (`TCP4-LISTEN:19200 → TCP4:10.8.0.1:9100`, unit `node-exporter-relay-dv0`); Service + Endpoints + ServiceMonitor en `files/monitoring/dv0-host.yaml` con relabeling `host="dv0"`. D2 responde `ping 10.8.0.1` (túnel WG activo).
- **Public dashboard de la landing** (`verificado 2026-08-18`): el dashboard «Sistema D-Lab» se expone sin login para incrustarlo en la landing (sección *Monitorización en vivo*). En el grafana.ini se añadieron `security.allow_embedding = true` (sin `X-Frame-Options`) y el feature toggle `publicDashboards`. El registro del public dashboard es **efímero** (se pierde al recrear el pod): lo garantiza `scripts/ensure-public-dashboard.sh` (idempotente; guarda la URL en `info_sensible/public-dashboard.env`, gitignored). **Ojo Grafana 13**: la ruta pública usa **guion** — `https://grafana.elarreglador.eu/public-dashboards/<token>`; la variante con barra (`/public/dashboards/`) cae en el handler de assets y responde 302 a `/login`. **Gotcha ventana temporal**: el public dashboard se creó con `timeSelectionEnabled=false`, así que **ignora los `from`/`to` de la URL del iframe** y muestra el rango guardado del dashboard. Para cambiar la ventana (hoy `now-24h`), se edita `"time"` en `files/monitoring/grafana-dashboard-sistema-dlab.yaml` y se reaplica el ConfigMap (el sidecar re-provisiona; el registro público se conserva).
- **Recursos**: requests 100m/200Mi, limits 500m/512Mi.
- **Ojo Grafana 13**: el endpoint `POST /login` espera **JSON** (`Content-Type: application/json`, cuerpo `{"user":"...","password":"..."}`), no form-urlencoded. Afecta a la automatización con curl, no al navegador.
- **Datos de los paneles**: Grafana **consulta** a Prometheus y AlertManager (no al revés: Prometheus recolecta y almacena; Grafana hace las consultas cuando pinta un panel). Datasources definidos en el ConfigMap `kube-prometheus-stack-grafana-datasource` (montado por el sidecar kiwigrid):
  - `Prometheus` (default, `access: proxy`): `http://kube-prometheus-stack-prometheus.monitoring:9090/` — cada panel lanza queries PromQL.
  - `Alertmanager`: `http://kube-prometheus-stack-alertmanager.monitoring:9093/` — para visualizar alertas en paneles.
  - Ambas son ClusterIP internas (`:9090` y `:9093`), comunicación pod↔pod por la red del cluster; **no** necesitan dominio público.

## Prometheus

- **Retention**: 6 días (`prometheusSpec.retention`).
- **Almacenamiento TSDB**: efímero (`emptyDir`). No soporta reinicio de nodo: los datos históricos se pierden (decisión por la incidencia con el PVC NFS).
- **Recursos**: requests 500m/600Mi, limits 1 CPU/2Gi.
- **Servicios**: `kube-prometheus-stack-prometheus` (9090) y `prometheus-operated` (headless). **Sin ingress** → no expuesto públicamente; acceso interno vía port-forward.

## AlertManager

- **Servicios**: `kube-prometheus-stack-alertmanager` (9093/8080) y `alertmanager-operated` (headless). **Sin ingress**.
- **Recursos**: requests 100m/100Mi, limits 200m/256Mi.
- **Almacenamiento DB**: `emptyDir` en el StatefulSet actual, pese a que los values declaran `persistentVolume.enabled: true` (storageClass `nfs-storage`, 2Gi). Motivo: los `volumeClaimTemplates` de un StatefulSet son **inmutables**; el sts se creó sin PVC durante la incidencia NFS y un `helm upgrade` no lo añade. Para migrar a PVC habría que recrear el StatefulSet.

## Observabilidad auxiliar

- **node-exporter de hosts (D1/D2)**: Service headless `host-node` (9100/19100) + Endpoints manuales + ServiceMonitor `host-node`. D2 se scrapea directo (`:9100`); D1 vía relay socat en D2 (`TCP4-LISTEN:19100 → TCP4:192.168.1.11:9100`, servicio systemd `node-exporter-relay-d1`). Los containers LXD usan macvlan y no alcanzan a su propio host.
- **node-exporter de DV0**: relay socat en D2 (`TCP4-LISTEN:19200 → TCP4:10.8.0.1:9100`, servicio systemd `node-exporter-relay-dv0`) + Service/Endpoints/ServiceMonitor `dv0-host` (ver arriba).
- **ServiceMonitor cert-manager**: Service `cert-manager:9402` en namespace `cert-manager`.
- **PrometheusRule `alertas-personalizadas`** (grupo `host-alertas`): `HostDown`, `ClusterNodeNotReady`, `DiskPressureHost` (>85%), `CertificateExpiring` (<30 días).

## Node-RED

- **URL pública**: `https://nodered.elarreglador.eu` (Ingress `nodered` en namespace `pods`).
- **IP LAN** (`verificado 2026-08-16`): `192.168.1.52:1880` (LoadBalancer via MetalLB, `externalTrafficPolicy: Local`).
- **Imagen**: `nodered/node-red:5.0.4` (Node.js 24), puerto 1880. Deployment 1 réplica en `pods`.
- **Login propio de Node-RED** (usuario `elarreglador`): definido en `settings.js` (`adminAuth` con hash bcrypt) montado desde el Secret `nodered-settings` (Opaque, gitignored — se genera en despliegue). **Sin** basic-auth web ni anonymous.
- **Secretos**: el hash bcrypt y el `credentialSecret` (cifrado de credenciales de nodos) se generan en el despliegue y **no** se versionan. Ver `scripts/deploy-nodered.sh`.
- **Almacenamiento**: PVC `nodered-data` (5Gi, RWO, `nfs-storage`) montado en `/data` (flows, credenciales y contextos persistentes).
- **Ingress** (`files/nodered/ingress.yaml`): TLS con cert-manager (Certificate `nodered-elarreglador-eu` → secret `nodered-elarreglador-eu-tls`), `force-ssl-redirect: true`. Certificate versionado en `files/nodered/certificate.yaml`.
- **NetworkPolicy** (`files/nodered/networkpolicy.yaml`): permite tráfico desde ingress-nginx (1880), egress DNS y salida a Internet (para instalar nodos del palette).
- **Recursos**: requests 100m/256Mi, limits 500m/512Mi.
- **Despliegue**: `NODERED_PASSWORD=<clave> ./scripts/deploy-nodered.sh` (la clave solo en el entorno; el hash se genera con python3-bcrypt sin escribirla en disco).

## Radio SDR remota (rtl_tcp)

- **Acceso público**: `sdr.elarreglador.eu:1234` (TCP) — servidor `rtl_tcp` (verificado 2026-08-14: cabecera DongleInfo `RTL0` en el extremo público). **Sin autenticación**: cualquiera con el host:puerto puede sintonizar; **un solo cliente a la vez** (comportamiento nativo de rtl_tcp; el segundo queda a la espera hasta que el primero desconecte).
- **Hardware**: dongle RTL-SDR v3 (USB `0bda:2838`) + upconverter Nooelec Ham It Up (+125 MHz), conectados en D1. El upconverter permite un rango útil de ~25 MHz a 1700 MHz (con la conversión +125 MHz activa, la recepción HF efectiva es ~0,1–30 MHz).
- **Workload**: Deployment `rtl-sdr` (1 réplica, imagen `skl256/rtl_tcp`, namespace `pods`), **privilegiado** y anclado a **k8s-worker-1** con `nodeSelector` (`eu.elarreglador/sdr=true`). Monta por `hostPath` el directorio `/dev/bus/usb` del nodo (el dongle se pasa al contenedor LXC k8s-worker-1 con un device `usb` de LXD). Sin PVC (stateless).
- **Service**: `rtl-sdr`, NodePort `1234 → 31234/TCP`. Las probes son `exec` (`pgrep rtl_tcp`) a propósito: una probe `tcpSocket` al 1234 consumiría el slot del único cliente. Desde MetalLB añade además IP LAN `192.168.1.60:1234` (LoadBalancer, `externalTrafficPolicy: Local`; el NodePort se conserva para el tráfico externo).
- **Recursos**: requests 50m/64Mi, limits 250m/256Mi.
- **Cadena de acceso**:
  ```
  GQRX (RTL-SDR TCP) → sdr.elarreglador.eu:1234
    → nginx stream DV0 (listen 1234 → 10.8.0.11:1234)
    → LXC proxy device `proxyrtlsdr` en D1 (10.8.0.11:1234 → 127.0.0.1:31234)
    → Service NodePort `rtl-sdr` 31234 → pod rtl-sdr → dongle USB en k8s-worker-1
  ```
- **NetworkPolicy** (`files/sdr/networkpolicy.yaml`): `rtlsdr-allow` — ingress TCP/1234 desde cualquier origen (el tráfico NodePort entra DNAT desde el nodo; el retorno lo cubre conntrack) y egress solo DNS.
- **Despliegue**: `./scripts/deploy-sdr.sh` (etiqueta el nodo, aplica manifests y espera rollout). Los pasos de infraestructura en D1 (device `usb` + proxy LXC) se hacen una sola vez y están en [01-Network.md](./01-Network.md).
- **Instrucciones GQRX del cliente** (los mismos parámetros están publicados en la landing, sección Servicios D-Lab):

  | Parámetro | Valor |
  |-----------|-------|
  | Dispositivo | RTL-SDR TCP |
  | Host | `sdr.elarreglador.eu` |
  | Puerto | `1234` |
  | LNB LO (compensación upconverter Ham It Up +125 MHz) | **−125 MHz** |
  | Sample rate (input rate) | `960000` (valor publicado en la landing; el defecto de 2.4 MS/s ≈ 38 Mbps puede saturar el enlace de DV0) |
  | Clientes simultáneos | 1 |

  Device string alternativo en GQRX: `rtl_tcp=sdr.elarreglador.eu:1234`.
- **Notas operativas**: si el dongle se desenchufa, rtl_tcp muere y el pod se reinicia (se recupera al reenchufar). El pod no tiene PDB: al drenar o apagar k8s-worker-1 queda `Pending` hasta que el nodo vuelva.

## MariaDB

- **Acceso**: solo interno al cluster. Sin URL pública ni Ingress: se gestiona por terminal vía `kubectl exec` / `kubectl run` desde el namespace `pods`.
- **Workload**: Deployment `mariadb` (1 réplica, imagen `mariadb:11`, namespace `pods`), Service ClusterIP `mariadb:3306`. Recursos requests 250m/256Mi, limits 1 CPU/1Gi.
- **BD**: `dlab` (usuario `dlab`, password en el Secret `mariadb-secret`, Opaque, gitignored — se genera en despliegue; la password solo viaja en el entorno de `deploy-mariadb.sh`). BD y usuario dedicados para **Node-RED**: `nodered`/`nodered` (password en `info_sensible/nodered-mariadb.env`, gitignored; acceso solo a su propia BD). Args: `--innodb-buffer-pool-size=256M`, `--innodb-flush-log-at-trx-commit=2` (durabilidad reducida: acepta el fsync lento del NFS, riesgo de perder los últimos ~1 s de transacciones en corte de energía).
- **Almacenamiento**: PVC `mariadb-data` (10Gi, RWO) sobre el **StorageClass `nfs-storage-v4`** (NFSv4), montado en `/var/lib/mysql` con `fsGroup: 999`. El RWO permite que el pod migre de worker manteniendo los datos (verificado: k8s-worker-1 → k8s-worker-2).
- **NetworkPolicy** (`files/mariadb/networkpolicy.yaml`): `mariadb-allow-pods` — ingress solo TCP/3306 desde pods del namespace `pods`; egress solo DNS (CoreDNS + ClusterIP). **Sin acceso exterior**.
- **Backups** (`files/backup-mariadb.sh`): dump `mariadb-dump --all-databases` vía `kubectl exec` sobre el pod (sin depender de la red del pod) + copia redundante al peer master por SSH. Desplegado en k8s-master-1 y k8s-master-2, cron `0 3 * * *` en `/etc/cron.d/mariadb-backup` → `/backup/mariadb/mariadb-<fecha>.sql`, rotación de 30, log `/var/log/mariadb-backup.log`. La password se lee del Secret en runtime, nunca se versiona.
  - **Nota** `(verificado 2026-08-10)`: el cron debe vivir en `/etc/cron.d/mariadb-backup` con el campo de usuario `root`; si se mete en el crontab de usuario (`crontab -e`) el `root` se interpreta como comando y el backup falla cada noche (`/bin/sh: 1: root: not found`). Requiere `/root/.kube/config` en **ambos** masters (kubeconfig `admin.conf`) para que `kubectl` llegue al API Server.
- **Despliegue**: `MARIADB_ROOT_PASSWORD=<clave> MARIADB_PASSWORD=<clave> ./scripts/deploy-mariadb.sh` (las claves solo en el entorno; el Secret se genera por stdin).

## Modelo de lenguaje local (Ollama + qwen2.5-coder)

LLM de código abierto autoalojado para uso con opencode y Node-RED. Namespace `ia`.

- **Workload**: Deployment `ollama` (1 réplica, imagen `ollama/ollama:0.32.14`, pin fijo), **solo en los workers** vía `nodeSelector` (`eu.elarreglador/worker=true`). Modelo `qwen2.5-coder:3b` (Q4_K_M, 1.9 GB, contexto 32 768) descargado en el despliegue y persistente en el PVC.
- **Acceso** (sin autenticación a propósito; la protección es por aislamiento de red):
  - Interno (Node-RED): `http://ollama.ia.svc:11434`
  - LAN: `http://192.168.1.31:31434` (NodePort en cualquier nodo; `.32` también responde)
  - WireGuard: `http://10.8.0.11:31434` (LXC proxy device `proxyollama` en D1: `10.8.0.11:31434 → 127.0.0.1:31434`)
- **Ollama no autentica peticiones por defecto** (la `OLLAMA_API_KEY` solo aplica a ollama.com). Si algún día se necesita, la protección razonable es una capa previa (p. ej. nginx stream con Bearer en DV0), no esperar auth nativa.
- **Almacenamiento**: PVC `ollama-models` (20Gi, RWO, `nfs-storage`) montado en `/models` (`OLLAMA_MODELS=/models`).
- **Parámetros** (env del Deployment): `OLLAMA_HOST=0.0.0.0`, `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_KEEP_ALIVE=5m`, `HOME=/tmp` (el contenedor corre como uid 1000 con `readOnlyRootFilesystem`).
- **Recursos**: requests 500m/1Gi, limits 2 CPU/4Gi. **Tope por pod**: 2 CPU es lo que hay disponible de margen real en los workers (~20% libre sobre 7.1 GiB); para un modelo más grande (7B+) habría que subir el límite y evaluar que no ahogue al cluster. **Nota (2026-08-18)**: el límite de memoria subió de 3Gi a 4Gi durante el benchmark de tareas de programación — con 3Gi, cargar modelos de 2-3 GB junto con la KV cache (4096 ctx ≈ 1.28 GB) hacía que el **liveness probe (timeout 1 s)** matase el pod en cada carga (eventos `Liveness probe failed ... connection refused`); se subió el `timeoutSeconds` de las probes a 5 (startup/readiness/liveness, failureThreshold 5 en liveness).
- **Benchmark de modelos ≤3B (2026-08-18)**: se probaron 8 modelos en el pod con sus límites reales (2 CPU/3 Gi, CPU i3-7100T). Metodología: para cada modelo `ollama pull` → consulta fría (carga a RAM, descartada) → **consulta caliente** con el prompt *«Responde con una sola palabra: pong»* (`/api/chat`, `stream:true`), midiendo time-to-first-token (TTFT) y tiempo total con un pod helper `curl` (curlimages/curl, ns `ia`). Tras medir se ejecutó `ollama rm`.

  | Modelo | Tamaño | TTFT (s) | Total (s) | Resultado |
  |--------|--------|----------|-----------|-----------|
  | tinyllama:1.1b | 0.6 GB | 0.212 | **0.531** | ✓ dentro del corte |
  | qwen2.5-coder:1.5b | 1.0 GB | 0.427 | **0.586** | ✓ |
  | qwen2.5:1.5b | 1.0 GB | 0.431 | **0.623** | ✓ |
  | qwen2.5-coder:3b | 1.9 GB | 0.569 | **1.009** | ✓ elegido |
  | gemma2:2b | 1.6 GB | 0.802 | **1.216** | ✓ |
  | llama3.2:3b | 2.0 GB | 0.613 | 6.195 | ✗ supera 5 s (genera largo, ~5 tok/s) |
  | qwen3:4b | 2.5 GB | — | — | ✗ descartado (reiniciaba el pod) |
  | phi3:mini | 2.2 GB | — | — | ✗ descartado (reiniciaba el pod) |

  Criterio: tiempo de respuesta total ≤ 5 s. **qwen3:4b y phi3:mini se descartaron por inestabilidad**: al cargarlos (2.2-2.5 GB) el daemon tarda en responder y el **liveness probe (`timeoutSeconds: 1`)** mata el pod (`kubectl get events` → `Liveness probe failed ... connection refused`; `restartCount` sube). Los 5 que pasan el corte dan TTFT ≤ 0.8 s. La medición se hizo sobre el pod con sus límites reales, no sobre el host completo, para que los tiempos reflejen el entorno de uso (opencode/Node-RED).
- **Benchmark de tarea de programación (2026-08-18)**: a los 6 candidatos que pasaron/entraron en el corte anterior (qwen2.5-coder:3b, granite-code:3b, llama3.2:3b, yi-coder:1.5b, deepseek-coder:1.3b, smollm2:1.7b) se les pidió implementar, en cada lenguaje, un **evaluador de expresiones aritméticas** (enteros, `+ - * /` división entera, paréntesis, precedencia; leer de stdin, imprimir resultado). Prompt idéntico en castellano por lenguaje, sin mencionar prácticas/tests/seguridad. Proceso por lenguaje/modelo: `ollama pull` → warm-up (descartado, carga a RAM) → petición medida (`stream:false`, `keep_alive:0`, TTFT+total por `curl`) → **extracción del bloque de código y compilación/ejecución real en G9** (`dart`, `gcc`, `python3`, `bash`, `node`, `javac`/`java`), validando la salida contra un corpus fijo (p. ej. `2 + 3 * 4` → 14, `(2+3)*4` → 20, `10 / 4` → 2, `2*(3+4)/7` → 2, `8 / 2 * 2` → 8). Criterio **`Funciona?` = compila y produce el resultado esperado**; si no, las demás columnas quedan `-`. **Prompts, corpus y metodología completos en [`Benchmark-LLM.md`](Benchmark-LLM.md)**. Resultados preliminares **Dart** (ronda 1, con Rust fallido en paralelo — los dos lenguajes a la vez degradaban la calidad, así que se repitió solo Dart): **ningún modelo ≤3B generó Dart válido** (el más cercano, qwen2.5-coder:3b, con lógica de precedencia correcta pero `Stack` inexistente en la stdlib de Dart + nullability; el resto, APIs/sintaxis inventadas o esqueletos).

  | Modelo | Lenguaje | Funciona? | Estabilidad | CiberSeguridad | Buenas prácticas | Tests | Tiempo (s) |
  |--------|----------|-----------|-------------|----------------|-------------------|-------|------------|
  | qwen2.5-coder:3b | Dart | No | — | — | — | — | 67.8 |
  | granite-code:3b | Dart | No | — | — | — | — | 27.3 |
  | llama3.2:3b | Dart | No | — | — | — | — | 132.3 |
  | yi-coder:1.5b | Dart | No | — | — | — | — | 38.8 |
  | deepseek-coder:1.3b | Dart | No | — | — | — | — | 29.7 |
  | smollm2:1.7b | Dart | No | — | — | — | — | 92.6 |

  **Ronda completa (2026-08-19)** — C, Python, bash, JS y Java (misma tarea y corpus). En esta ronda el pod ollama ya tenía el límite de 4 GiB y las probes con timeout 5 s; cada petición se midió con `keep_alive:0`, así que el **tiempo incluye la carga del modelo** en cada una (TTFT ≈ TOTAL). Resultado: **un solo caso funcional de 30 — yi-coder:1.5b en JS, y usando `eval()`** (lee el stdin con `readFileSync('/dev/stdin')` y lo evalúa directamente): pasa el corpus 10/10, pero es una **RCE (ejecución de código arbitrario)** desde la entrada → valor CiberSeguridad 1/10. Ningún otro modelo+lenguaje produjo un evaluador correcto; fallos dominantes: código incompleto/fragmentado (granite, smollm2), `eval`/APIs inventadas (yi-coder, deepseek, smollm2), y precedencia o división entera mal resueltas en los que sí compilaban (qwen2.5-coder en C/Python, deepseek en Python con división real).

  | Modelo | Lenguaje | Funciona? | Estabilidad | CiberSeguridad | Buenas prácticas | Tests | Tiempo (s) |
  |--------|----------|-----------|-------------|----------------|-------------------|-------|------------|
  | qwen2.5-coder:3b | C | No | — | — | — | — | 92.8 |
  | qwen2.5-coder:3b | Python | No | — | — | — | — | 97.4 |
  | qwen2.5-coder:3b | bash | No | — | — | — | — | 33.0 |
  | qwen2.5-coder:3b | JS | No | — | — | — | — | 95.2 |
  | qwen2.5-coder:3b | Java | No | — | — | — | — | 108.2 |
  | granite-code:3b | C | No | — | — | — | — | 59.7 |
  | granite-code:3b | Python | No | — | — | — | — | 45.0 |
  | granite-code:3b | bash | No | — | — | — | — | 48.2 |
  | granite-code:3b | JS | No | — | — | — | — | 67.1 |
  | granite-code:3b | Java | No | — | — | — | — | 62.9 |
  | llama3.2:3b | C | No | — | — | — | — | 504.7 |
  | llama3.2:3b | Python | No | — | — | — | — | 92.3 |
  | llama3.2:3b | bash | No | — | — | — | — | 58.4 |
  | llama3.2:3b | JS | No | — | — | — | — | 133.2 |
  | llama3.2:3b | Java | No | — | — | — | — | 95.3 |
  | yi-coder:1.5b | C | No | — | — | — | — | 37.8 |
  | yi-coder:1.5b | Python | No | — | — | — | — | 58.2 |
  | yi-coder:1.5b | bash | No | — | — | — | — | 22.9 |
  | yi-coder:1.5b | **JS** | **Sí** | 10 | **1** (eval = RCE) | No | No | 24.9 |
  | yi-coder:1.5b | Java | No | — | — | — | — | 74.5 |
  | deepseek-coder:1.3b | C | No | — | — | — | — | 99.2 |
  | deepseek-coder:1.3b | Python | No | — | — | — | — | 32.6 |
  | deepseek-coder:1.3b | bash | No | — | — | — | — | 51.1 |
  | deepseek-coder:1.3b | JS | No | — | — | — | — | 33.8 |
  | deepseek-coder:1.3b | Java | No | — | — | — | — | 79.8 |
  | smollm2:1.7b | C | No | — | — | — | — | 91.3 |
  | smollm2:1.7b | Python | No | — | — | — | — | 63.5 |
  | smollm2:1.7b | bash | No | — | — | — | — | 46.1 |
  | smollm2:1.7b | JS | No | — | — | — | — | 75.3 |
  | smollm2:1.7b | Java | No | — | — | — | — | 104.0 |

  **Conclusión del benchmark de programación**: ningún modelo ≤ 3B es fiable para generar código de esa complejidad en 6 lenguajes; el único acierto (yi-coder JS) es además un antipatrón de seguridad. Para el uso real (opencode), **qwen2.5-coder:3b sigue siendo la mejor opción** por su calidad relativa de código y tiempos razonables — asumiendo que se **revisa siempre el código generado** (los fallos de precedencia en C/Python lo demuestran). Los tiempos aquí (30-500 s) no son comparables a los del ping (0.5-6 s): la tarea de programación genera 1-9 KB de tokens y en cada petición se recarga el modelo. **Los 6 modelos probados se conservan descargados en el PVC** (decisión 2026-08-19). Tablas, prompts y corpus completos en [`Benchmark-LLM.md`](Benchmark-LLM.md).
- **Hardening** (`files/ia/ollama.yaml`): `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, capabilities `drop: ALL`, seccomp `RuntimeDefault`. Namespace `ia` con PSS `baseline` (enforce) / `restricted` (warn).
- **NetworkPolicy** (`files/ia/networkpolicy.yaml`): `ollama-allow` — ingress TCP/11434 desde el namespace `pods` (ClusterIP, para Node-RED) **y** desde cualquier origen (el tráfico NodePort entra DNAT desde el nodo). Egress solo DNS + **TCP/443 a los rangos de Cloudflare** (`104.16.0.0/12`, `172.64.0.0/13`, `173.245.48.0/20`, `198.41.128.0/17`, `190.93.240.0/20`, `188.114.96.0/20`): necesarios para que `ollama pull` funcione — `registry.ollama.ai` (manifests) y `*.r2.cloudflarestorage.com` (blobs, Cloudflare R2). **Gotcha verificado 2026-08-18**: sin esa regla el pull muere con `dial tcp 172.64.x.x:443: i/o timeout` tras bajar el manifest.
- **Quota** (`files/ia/quota.yaml`): ResourceQuota `ia-quota` (requests 4 CPU/8Gi, limits 8 CPU/16Gi, 3 pods, 2 PVC) + LimitRange (default 100m/128Mi request, 500m/512Mi limit).
- **Probes**: startup/readiness/liveness con `httpGet /api/tags` (el endpoint responde 200 con el daemon listo; el modelo se carga bajo demanda en la primera petición).
- **Acceso LAN**: el Service es `NodePort 31434` (no MetalLB, a diferencia del stack multimedia). Motivo: el NodePort se reenvía por kube-proxy a cualquier worker y funciona desde cualquier nodo; verificado 200 desde `192.168.1.31` y `.32`.
- **Despliegue**: `./scripts/deploy-ollama.sh` (etiqueta los workers `eu.elarreglador/worker=true` idempotente, aplica `files/ia/`, espera rollout y descarga el modelo con `ollama pull`).
- **Problema de descarga del modelo por SSH**: `kubectl exec` corta el `ollama pull` si la sesión SSH muere (SIGHUP); si hay que relanzarlo, `nohup kubectl -n ia exec deploy/ollama -- ollama pull qwen2.5-coder:3b > /tmp/ollama-pull.log 2>&1 &`.
- **Seguridad**: Ollama tiene CVE conocidos (p. ej. CVE-2025-15063, RCE en el servidor MCP, CVSS 9.8). Mitigación: imagen pinnada a la última estable (`0.32.14`), hardening del pod, y **ninguna exposición pública** (solo LAN/WG). Antes de subir la imagen, revisar CVE en [GitHub Advisory DB](https://github.com/advisories?query=ollama).

### opencode en el portátil (G9)

Config global `~/.config/opencode/opencode.jsonc` con dos providers `@ai-sdk/openai-compatible`:

| Provider | baseURL | Cuándo |
|----------|---------|--------|
| `ollama-lan` | `http://192.168.1.31:31434/v1` | G9 en la LAN doméstica |
| `ollama-wg` | `http://10.8.0.11:31434/v1` | G9 fuera de casa (WireGuard) |

Modelos registrados con prefijo `D-Lab_` (5 en el PVC; `id` = nombre real en Ollama; `limit.context` = `context_length` verificado en el pod 2026-08-20). Reemplazos 2026-08-20: `deepseek-coder:1.3b` + `yi-coder:1.5b` → `qwen2.5-coder:1.5b`; `granite-code:3b` → `granite3.2:2b`:

| Modelo (clave opencode) | id en Ollama | context | tools (manifiesto) |
|---|---|---|---|
| `D-Lab_granite3.2:2b` | `granite3.2:2b` | 131072 | ✓ |
| `D-Lab_llama3.2:3b` | `llama3.2:3b` | 131072 | ✓ |
| `D-Lab_qwen2.5-coder:1.5b` | `qwen2.5-coder:1.5b` | 32768 | ✓ |
| `D-Lab_qwen2.5-coder:3b` | `qwen2.5-coder:3b` | 32768 | ✓ |
| `D-Lab_smollm2:1.7b` | `smollm2:1.7b` | 8192 | ✓ |

Uso: `opencode run "..." --model ollama-lan/D-Lab_qwen2.5-coder:3b` (o `ollama-wg/...` vía WG).

**Limitación real de tools (verificado 2026-08-20)**: aunque los 5 modelos declaran `tools` en el manifiesto de Ollama (aceptan el array `tools` en la petición), **ninguno ≤3B emite `tool_calls` nativos fiables** en el agente de opencode: en tareas que requieren herramientas responden con JSON en texto (p. ej. `{"name":"read","arguments":...}`) que opencode no ejecuta (mismo caso que [anomalyco/opencode#234](https://github.com/anomalyco/opencode/issues/234)). El agente `build` funciona para conversación y generación de código, pero las tareas que exigen leer/editar archivos no se ejecutan de forma fiable con ningún modelo de este catálogo.

**Gotchas del pod (2026-08-20)**:
- **OOM**: cargar varios modelos en la ventana `OLLAMA_KEEP_ALIVE` (5 m) supera los 4 GiB del límite → `OOMKilled` (confirmado: restart del pod). Usar un modelo a la vez y esperar a que descargue.
- **`granite3.2:2b` es un modelo "thinking"**: lento en el pod (2 CPU), respuestas de ~1-2 min en frío. Operativo pero no recomendado para uso interactivo.
- `granite3.1-dense:2b` se probó como alternativa y se **descartó** (error de servidor persistente al cargarlo en este pod).
- Los 3 modelos antiguos sin tools (`deepseek-coder:1.3b`, `yi-coder:1.5b`, `granite-code:3b`) se eliminaron del PVC.

## Exposición pública

| Host | App | Protección |
|------|-----|-----------|
| `elarreglador.eu` / `www.elarreglador.eu` | Landing (pública) | ninguna (200 sin credenciales) |
| `grafana.elarreglador.eu` | Grafana | login de Grafana |
| `nodered.elarreglador.eu` | Node-RED | login propio de Node-RED |
| `sdr.elarreglador.eu:1234` | Radio SDR (rtl_tcp, GQRX) | ninguna (recepción abierta; un cliente a la vez) |
| prometheus / alertmanager / **mariadb** / **ollama** | — | internos (sin ingress; ollama solo LAN/WG, sin auth) |
| `192.168.1.50` … `.60` | IPs LAN (MetalLB, pool `.50–.64`) | ver mapa de IPs en el stack multimedia y notas de cada app; solo LAN |

## PDBs y NetworkPolicies

- **PDBs** (manifiestos en `files/pdbs/`): `landing`, `coredns`, `ingress-nginx`, `calico-kube-controllers`, `calico-typha`, `grafana`, `prometheus`, `alertmanager`.
- **NetworkPolicies** (manifiestos en `files/networkpolicies/`, `files/mariadb/networkpolicy.yaml`, `files/nodered/networkpolicy.yaml`, `files/sdr/networkpolicy.yaml`, `files/ia/networkpolicy.yaml`, `files/multimedia/networkpolicy-*.yaml`): `landing-allow-ingress-nginx` (default, app=landing), `coredns-allow-dns` (kube-system), `mariadb-allow-pods`, `nodered-allow-ingress-nginx`, `rtlsdr-allow`, `ollama-allow`, `media-public` (Jellyfin/Jellyseerr, `ipBlock: 192.168.1.0/24`), `multimedia-internal` (Sonarr/Radarr/Prowlarr/qB WebUI, LAN `192.168.1.0/24`) y `es-badge-ingress` (ingress-nginx → es-badge:80). El resto del tráfico se rige por el modelo policy-only de Calico. Las de acceso LAN (`landing`, `nodered`, `media-public`, `multimedia-internal`) se ampliaron para permitir `192.168.1.0/24` y solo funcionan si el Service LoadBalancer usa `externalTrafficPolicy: Local` (si no, kube-proxy aplica SNAT y la IP origen vista es la del nodo).

## Notas operativas

- **Alertas firing por diseño**: `TargetDown`, `etcdMembersDown`, `etcdInsufficientMembers` (targets `kube-etcd`/`kube-scheduler`/`kube-controller-manager`/`kube-proxy` no exponen métricas en los puertos por defecto en LXC) y `Watchdog` (centinela). La cadena principal (kubelet, apiserver, coredns, node-exporter, hosts) está **up**.
- **Credenciales**: nunca en el repo. Grafana → usuario `elarreglador` (garantizado por `scripts/grafana-user.sh`; passwords en `info_sensible/grafana-user.env`, gitignored) y `admin` (Secret `kube-prometheus-stack-grafana`). Clave web / secretos → `info_sensible/` (gitignored).
- **sudo en DV0/D1/D2** (`verificado 2026-08-18`): el usuario `elarreglador` tiene `NOPASSWD: ALL` vía `/etc/sudoers.d/elarreglador-nopasswd` (antes solo `poweroff`/`systemctl`/`true` sin password). Se amplió para poder instalar/administrar agentes de monitoreo y gestionar unidades systemd remotas por SSH sin TTY. La password de sudo (no va al repo) sigue siendo la que define el señor en cada máquina.
- **CNI Calico — tokens de `calico-kubeconfig`**: el token del SA `calico-cni-plugin` usado por el plugin CNI en los 4 nodos (`/etc/cni/net.d/calico-kubeconfig`) **expira** (el emitido por kubeadm el 2026-08-01 caducó a las 24 h y todos los pods nuevos fallaban con `error getting ClusterInformation: ... Unauthorized`). Se fijó creando el Secret `calico-cni-plugin-token` (kube-system, anotación `kubernetes.io/service-account.name`) — sin expiración — y reescribiendo el `token:` de ese kubeconfig en los 4 nodos (`verificado 2026-08-15`; se renovó de nuevo con el static secret y el rollout de Radarr completó). Si vuelve a aparecer `FailedCreatePodSandBox` por Calico en pods nuevos, revisar la fecha de expiración de ese token: el proceso manual es copia de seguridad del kubeconfig, descarga del Secret de token estático y reescritura del campo `token` (`kubectl get secret calico-cni-plugin-token -n kube-system -o jsonpath='{.data.token}' | base64 -d`), en cada nodo.
- **Scripts útiles** (`scripts/`): `deploy-landing.sh` (despliegue de la landing), `deploy-nodered.sh` (despliegue de Node-RED; requiere `NODERED_PASSWORD` en el entorno), `deploy-mariadb.sh` (despliegue de MariaDB; requiere `MARIADB_ROOT_PASSWORD` y `MARIADB_PASSWORD` en el entorno), `deploy-sdr.sh` (despliegue del servidor rtl_tcp; etiqueta k8s-worker-1 y aplica `files/sdr/`), `deploy-ollama.sh` (despliegue del LLM local; etiqueta los workers y aplica `files/ia/`), `sync-web-auth.sh` (clave web; hoy **sin namespaces por defecto** — Grafana y Node-RED usan su propio login), `grafana-user.sh` (garantiza el usuario `elarreglador` de Grafana; lee las credenciales de `info_sensible/grafana-user.env`, gitignored), `ensure-public-dashboard.sh` (garantiza el public dashboard «Sistema D-Lab» tras recrear el pod; guarda la URL en `info_sensible/public-dashboard.env`), `computer_info.sh`.

## Referencias

- [README-TECH.md — Fase 12: Monitoreo y observabilidad](./README-TECH.md#fase-12--monitoreo-y-observabilidad)
- [README-TECH.md — Clave única de acceso web](./README-TECH.md#clave-única-de-acceso-web)
- [README-TECH.md — Web pública (landing)](./README-TECH.md#web-pública-landing)
- Manifiestos: `files/monitoring/grafana-ingress.yaml`, `files/nodered/`, `files/mariadb/`, `files/pdbs/`, `files/networkpolicies/`, `files/landing/`
