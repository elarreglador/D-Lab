# TODO — D-Lab

## Features

- [x] Landing: sección «Acerca de ti» (live-fingerprinting del visitante) — `files/landing/acerca-de-ti.{js,css}`
- [x] Landing: rediseño ciberpunk/retrofuturista (paleta cian/magenta/marino/negro, tipografías auto-alojadas Orbitron/Exo 2/Share Tech Mono, rejilla + scanlines + glow) — `styles.css`, fuentes `.woff2` en `files/landing/`
- [x] Landing: cambio de estética a **dieselpunk** (latón/cobre/cuero/pergamino, Oswald + Roboto Slab + Special Elite, remaches y filetes de latón); el conmutador dark/light y su comportamiento se mantienen intactos
- [x] Landing: cambio de estética a **consola de operaciones** (minimal y profesional: azul marino + cian turquesa + rosa magenta, Space Grotesk + Inter + IBM Plex Mono, sin rejillas/scanlines/remaches); cache-busting `?v=YYYYMMDD` en `index.html` (nginx no envía `Cache-Control`); el conmutador dark/light y su comportamiento se mantienen intactos
- [x] Landing: retoques de estilo (estética GitHub): se elimina la barra bajo los títulos de sección y se normaliza el ritmo vertical (mismo hueco entre bloques: secciones 5rem, bloques hermanos internos 2.5rem, título→párrafo 1.4rem)
- [x] Landing: botones de contacto movidos a la barra inferior (footer como «barra» con fondo `--surface`); se elimina la sección «Contacto» y su enlace del menú; barras superior e inferior con `--border-bar: #7c8094` (mismo gris azulado en claro y oscuro)
- [x] Landing: barras mucho más oscuras — `--bar-bg: #161b22` en ambos modos (claro y oscuro), con `--bar-fg` (texto claro sobre la barra), `--bar-accent` (enlaces/hover azul claro) y botón de tema transparente sobre la barra; se mantiene `--border-bar: #7c8094`
- [x] Landing: cambio de estética a **«GitHub» (Primer)** — plana/neutra, paleta GitHub dark/light (azul `#2f81f7`/`#0969da`, verde `#3fb950`/`#1a7f37`), **tipografías de sistema** (se eliminan las fuentes auto-alojadas; ConfigMap 253→134 KB); el conmutador dark/light y su comportamiento se mantienen intactos
- [x] Landing: tema por defecto del sistema con conmutador manual claro/oscuro (persistencia en `localStorage` solo al pulsar el botón, `data-theme` + `meta color-scheme`, script anti-flash en `<head>`, fallback sin JS vía media query) — `index.html`, `styles.css`
- [x] `deploy-landing.sh`: guard por bandas frente al techo de etcd (~1,5 MiB) en lugar del aborto rígido de 1 MiB
- [ ] Vigilar tamaño de `acerca-de-ti.js`: si supera ~1 MiB raw, migrar la landing a imagen nginx custom (Dockerfile + import en nodos, ver README-TECH § Web pública)

## Fix

- [x] `signals.hw.netType.value` → `signals['hw.netType'].value` (acceso por clave punteada a un mapa de ids planos)
- [x] `recall()` colgada si un almacén (IndexedDB/Cache) no responde → guarda `Promise.race` con respaldo de primera visita
- [x] Versión de navegador limpia (sin client hints ruidosos "Not=A?Brand...")

## Tareas finalizadas

- [x] Despliegue y verificación de la landing con la nueva sección (2026-08-16): ConfigMap `landing-html` ~149 KB base64, pods Running, `/acerca-de-ti.js` 200 y md5 idéntico al local
- [x] Despliegue de la landing ciberpunk (2026-08-17): fuentes auto-alojadas (6 woff2, subset latin), ConfigMap ~296 KB base64, pods Running, curl 200 en `/`, `/styles.css` y fuentes con md5 idéntico al local. `deploy-landing.sh` migrado a `kubectl apply --server-side` (la anotación `last-applied` del client-side superaba su tope de 256 KiB con el ConfigMap engordado)
- [x] Documentación actualizada (README-TECH § Web pública, AGENTS.md)