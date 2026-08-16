# TODO — D-Lab

## Features

- [x] Landing: sección «Acerca de ti» (live-fingerprinting del visitante) — `files/landing/acerca-de-ti.{js,css}`
- [x] `deploy-landing.sh`: guard por bandas frente al techo de etcd (~1,5 MiB) en lugar del aborto rígido de 1 MiB
- [ ] Vigilar tamaño de `acerca-de-ti.js`: si supera ~1 MiB raw, migrar la landing a imagen nginx custom (Dockerfile + import en nodos, ver README-TECH § Web pública)

## Fix

- [x] `signals.hw.netType.value` → `signals['hw.netType'].value` (acceso por clave punteada a un mapa de ids planos)
- [x] `recall()` colgada si un almacén (IndexedDB/Cache) no responde → guarda `Promise.race` con respaldo de primera visita
- [x] Versión de navegador limpia (sin client hints ruidosos "Not=A?Brand...")

## Tareas finalizadas

- [x] Despliegue y verificación de la landing con la nueva sección (2026-08-16): ConfigMap `landing-html` ~149 KB base64, pods Running, `/acerca-de-ti.js` 200 y md5 idéntico al local
- [x] Documentación actualizada (README-TECH § Web pública, AGENTS.md)