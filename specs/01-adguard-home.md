# SPEC 01 — AdGuard Home como DNS filtrante de la LAN

> **Estado:** Aprobado — **Implementado** y verificado `2026-10-11` (todos los pasos 1–10; cutover del router y de G9 ejecutado y comprobado).
> **Depende de:** — (primera spec; usa MetalLB, Ingress-NGINX, cert-manager y kube-prometheus-stack ya desplegados)
> **Fecha:** 2026-10-11
> **Objetivo:** Desplegar AdGuard Home como resolutor DNS filtrado de toda la LAN (`192.168.1.61`) y apuntar el router a él (DHCP en el router, IPv6 desactivado).

## Contexto del repositorio (léalo antes de empezar)

- Vault Obsidian de infraestructura K8s sobre LXC. **No hay build/test/lint/CI.** La documentación es el artefacto. Docs en español, identificadores/scripts en inglés.
- Ejecutar **siempre desde la raíz del repo**. Los scripts hacen `ssh "$KUBECTL_HOST"` (default `server`, override por env). **No se necesita `kubectl` local.**
- Patrones a imitar: `scripts/deploy-multimedia.sh` (idempotente), `files/multimedia/*.yaml`, `files/multimedia/certificate-*.yaml`, `files/nodered/networkpolicy.yaml`, `files/metallb/config-dlab.yaml`.
- Pool MetalLB `dlab-lan` = `192.168.1.50–192.168.1.64`. **Ocupadas `.50–.60`; libre `.61`.**
- Workers llevan label `eu.elarreglador/worker=true`. Los pods de servicio usan `nodeSelector` a worker y `externalTrafficPolicy: Local` (necesario para que las NetworkPolicies con `ipBlock: 192.168.1.0/24` surtan efecto).
- Secretos: **nunca en el repo**. Se crean por stdin (`kubectl apply -f -`) leyendo de `info_sensible/` (gitignored). Ver `AGENTS.md`.
- Gotcha a respetar: `kubectl apply --dry-run=server` es la única validación fiable (un parser YAML no detecta campos inválidos). **No usar `spec.timezone`.**

## Por qué esta spec

El router ZTE H3600P solo resuelve con Google DNS y no bloquea publicidad. Se quiere un DNS filtrado para toda la LAN. **Decisión de arquitectura clave:** el DNS es *unicast* y funciona perfectamente como pod detrás de MetalLB; el **DHCP es *broadcast* y NO funciona desde un pod de red overlay** (Flannel no ve el broadcast). Por tanto: AdGuard hace solo DNS; el router conserva el DHCP y solo se le cambia el DNS que anuncia.

**Contexto de riesgo operativo:** el agente (openCode) corre en **G9**, un portátil de la LAN. Si el cutover deja a G9 sin DNS, el agente pierde internet y se corta la sesión; por eso G9 se configura **en último lugar** y se deja un **runbook de rescate** (hotspot del móvil → `ssh server`). Además, el router anunciaba DNS por **IPv6** (RA/DHCPv6), que esquiva cualquier filtro IPv4: se desactiva.

## Alcance

**En:**

- **Crea el namespace y despliega AdGuard Home — `files/adguard/adguard.yaml` → cluster** — Deployment 1 réplica, `nodeSelector eu.elarreglador/worker=true`, imagen `adguard/adguardhome` con **tag fijo** (verificar el último estable), workdir sobre PVC.
- **Expone el DNS en IP fija de LAN — `files/adguard/service-dns.yaml` → `192.168.1.61`** — Service `LoadBalancer`, `loadBalancerIP: 192.168.1.61`, `externalTrafficPolicy: Local`, puertos `53/UDP` y `53/TCP`.
- **Expone el panel de administración — `files/adguard/service-web.yaml` + `files/adguard/ingress.yaml` → `https://adguard.elarreglador.eu`** — Service `ClusterIP:3000` + Ingress `ingressClassName: nginx` con TLS (`Certificate` cert-manager, patrón de `files/multimedia/certificate-jellyfin.yaml`).
- **Persiste la configuración — `files/adguard/pvc.yaml` + StorageClass `nfs-storage-v4` (existente) → PVC `adguard-data`** — config y estadísticas sobre NFS v4; **query log con retención corta (24 h) o desactivado** para evitar el I/O intensivo de SQLite sobre NFS.
- **Siembra la config inicial — Job `files/adguard/seed-config.yaml` → PVC** — escribe `AdGuardHome.yaml` (solo si no existe) con `http.address: 0.0.0.0:3000`, `dns.port: 53`, upstream `8.8.8.8`/`8.8.4.4`, listas por defecto de AdGuard y querylog 24 h. Idempotente, como `jellyfin-ensure-apikey`.
- **Restringe el tráfico — `files/adguard/networkpolicy.yaml`** — ingress 53/UDP+TCP desde `ipBlock 192.168.1.0/24` y 3000 desde `ingress-nginx`; egress a `8.8.8.8:53`, `8.8.4.4:53` y `443` (actualización de listas).
- **Avisa por Telegram si AdGuard cae — `files/adguard/alerts.yaml` (PrometheusRule) + matcher en `files/monitoring/alertmanager-config.yaml`** — regla `AdguardDown` (`kube_deployment_status_replicas_available{namespace="adguard",deployment="adguard"} == 0`, `for: 2m`, `severity: critical`) enrutada al receiver `telegram`; se añade `AdguardDown` al matcher prioritario de `alertmanager-config.yaml:25` y se re-ejecuta `scripts/patch-alertmanager.sh`.
- **Automatiza el despliegue — `scripts/deploy-adguard.sh`** — idempotente: valida con `--dry-run=server`, aplica manifests vía `cat ... | ssh "$KUBECTL_HOST" "kubectl apply -f -"`, crea el Secret del panel por stdin desde `info_sensible/adguard.env`.
- **Configura el router con asistencia del navegador — MCP `chrome-devtools` (o `playwright`) → `http://192.168.1.1/`** — guiar al usuario paso a paso para **(a) desactivar IPv6** (RA/DHCPv6; evita el bypass por IPv6) y **(b) poner DNS primario = `192.168.1.61`** con el **secundario vacío**, **manteniendo el DHCP activo**. Se accede **por IP** (sin depender de DNS). Fallo ruidoso: si AdGuard cae, la LAN deja de resolver y la alerta de Telegram avisa. No automatizar el login propietario; el usuario teclea credenciales.
- **Filtra también G9, pero en último lugar — `nmcli` en G9 → `192.168.1.61`** — `nmcli connection modify DIGIFIBRA-PLUS-eQeY ipv4.dns 192.168.1.61 ipv4.ignore-auto-dns yes` (+ `ipv6.method disabled`) y `nmcli connection up`; se ejecuta **después de validar todo**, porque desde ese momento el agente depende de AdGuard.
- **Deja un runbook de rescate — `04-Operaciones.md` → procedimiento probado** — dos vías para salir de un corte de DNS en G9: recuperar control por hotspot del móvil (`ssh server` para arreglar el cluster) y revertir G9 por `nmcli`. El router solo se toca desde la LAN.
- **Documenta el resultado** — `03-Aplicaciones.md` (inventario), `README-TECH.md` (fase) y `TODO.md` (checklist) — con verificaciones `(verificado YYYY-MM-DD)` y comando exacto.

**Fuera del alcance:**

- DHCP servido por AdGuard (`hostNetwork`), segunda réplica / HA, DoH/DoT, DNS de los nodos del cluster (CoreDNS se deja como está), DNS para clientes WireGuard.

## Modelo de datos

- **PVC `adguard-data`** en `nfs-storage-v4`: contiene `AdGuardHome.yaml`, `sessions.db`, `stats.db` (query log). Retención de log 24 h.
- **Secret `adguard-web`** (namespace `adguard`): usuario y hash bcrypt de la contraseña del panel. Origen `info_sensible/adguard.env` (gitignored).
- **Config inicial** (`AdGuardHome.yaml`): `http.address: 0.0.0.0:3000`; `dns.port: 53`; `upstream_dns: [8.8.8.8, 8.8.4.4]`; listas de bloqueo por defecto de AdGuard; `querylog.interval: 24h`; `statistics.interval: 24h`.

## Plan de implementación

1. Crear `files/adguard/` con `namespace.yaml`, `pvc.yaml` (`nfs-storage-v4`), `adguard.yaml` (Deployment) y `service-dns.yaml`. Verificar `--dry-run=server`.
2. Añadir `seed-config.yaml` (Job idempotente) y aplicarlo; comprobar que el PVC contiene `AdGuardHome.yaml`.
3. Añadir `service-web.yaml`, `ingress.yaml` y `certificate-adguard.yaml`; verificar TLS emitido.
4. Añadir `networkpolicy.yaml`; comprobar **desde G9 y por IP** (`dig @192.168.1.61 …`) que resuelve y bloquea, **sin tocar aún el router**.
5. Añadir `files/adguard/alerts.yaml` (`PrometheusRule AdguardDown`) y sumar `AdguardDown` al matcher prioritario de `files/monitoring/alertmanager-config.yaml`; re-ejecutar `scripts/patch-alertmanager.sh` y probar la alerta escalando el Deployment a 0 (con G9 todavía a salvo).
6. Escribir `scripts/deploy-adguard.sh` idempotente (incluye creación del Secret por stdin y los manifests de alerta) y ejecutarlo de principio a fin en un cluster limpio simulado (borrar namespace y re-desplegar).
7. **Probar el runbook de rescate antes de depender de él:** conectar G9 al hotspot del móvil y comprobar `ssh server "kubectl get nodes"`.
8. **Router (por IP, con la sesión abierta para revertir):** desactivar IPv6 y fijar el DNS del DHCP a `192.168.1.61` sin secundario. Verificar el DNS anunciado **desde un móvil** (no desde G9).
9. **Último — G9:** `nmcli connection modify DIGIFIBRA-PLUS-eQeY ipv4.dns 192.168.1.61 ipv4.ignore-auto-dns yes` (+ `ipv6.method disabled`) y `nmcli connection up`; confirmar resolución filtrada. Dejar documentado el comando de reversión.
10. Documentar en `03-Aplicaciones.md`, `README-TECH.md`, `TODO.md` y el runbook en `04-Operaciones.md` con verificaciones fechadas.

## Plan de contingencia — si G9 pierde la red

**Escenario:** tras los pasos 8 o 9, G9 se queda sin DNS (AdGuard caído o mal configurado). El agente (openCode) necesita DNS + internet, así que dejaría de responder. **Cambiar la WiFi de G9 lo hace el humano** (el agente no puede si está muerto).

**Vía A — recuperar el control (recomendada):**

1. Conectar G9 al **hotspot del móvil**. G9 pasa a usar el DNS del operador, `elarreglador.eu` vuelve a resolver y el agente recupera internet.
2. Arreglar el cluster por el camino público, que **no depende de la LAN ni de AdGuard**: `ssh server "kubectl -n adguard get pods"` (y `kubectl apply -f -` para reaplicar o revertir). `server` es DV0 (`elarreglador.eu`), y `kubectl` corre en DV0 contra el API Server vía WireGuard.
3. Verificado el arreglo, devolver G9 a la WiFi de casa.

**Vía B — revertir G9 a un DNS que no sea AdGuard:**

```bash
nmcli connection modify DIGIFIBRA-PLUS-eQeY ipv4.dns "8.8.8.8,1.1.1.1" ipv4.ignore-auto-dns no
nmcli connection up DIGIFIBRA-PLUS-eQeY
```

**Límites:**

- El **router** (`192.168.1.1`) **no** es alcanzable desde fuera de la LAN (ruteo asimétrico: el router desconoce `10.8.0.0/24`) ni desde el hotspot del móvil. Si el fallo fuese la config del router, haría falta un equipo en la LAN o el router físico.
- El MCP de navegador **no sirve para el router desde el hotspot** (no llega a su IP); sí para servicios por dominio.

**Prueba obligatoria:** ejecutar la Vía A (paso 7 del plan) **antes** del paso 9, para garantizar que el rescate funciona.

## Criterios de aceptación

- [x] `kubectl -n adguard get pods` muestra `1/1 Running` y el PVC `Bound`.
- [x] `dig @192.168.1.61 elarreglador.eu` responde; `dig @192.168.1.61 doubleclick.net` devuelve `0.0.0.0` o `NXDOMAIN` (bloqueado por lista).
- [x] `curl -sI https://adguard.elarreglador.eu` responde `200` o `302` con TLS válido.
- [x] El panel muestra consultas y el query log no supera la retención de 24 h (`querylog.interval: 1d`).
- [x] En un dispositivo que respete el DHCP (p. ej. el móvil) y tras renovar concesión, el DNS anunciado es `192.168.1.61`, **sin secundario** y **sin DNS IPv6**. `(verificado 2026-10-11`: tras reiniciar el router H3600P, los clientes renovaron y el querylog de AdGuard muestra 50/50 consultas de clientes LAN `.153/.156/.160` — solo alcanzan `.61` por DHCP, luego el servidor lo anunció sin secundario y con DHCPv6/RA desactivados`)
- [x] G9 (configurado en último lugar) resuelve por `192.168.1.61` y bloquea un dominio de prueba (`resolvectl query …`). `(verificado 2026-10-11`: `nmcli connection modify … ipv4.dns 192.168.1.61 ipv4.ignore-auto-dns yes ipv6.method disabled`; `resolvectl query elarreglador.eu` → `82.223.50.169` y `doubleclick.net` → `0.0.0.0`; sin IPv6 global en `wlo1`; DNS único `192.168.1.61`)
- [x] El runbook de rescate está probado: con G9 en el hotspot del móvil, `ssh server "kubectl get nodes"` responde **antes** del paso 9. `(verificado 2026-10-11` desde G9 en hotspot: 4 nodos `Ready` en ~4 s; internet y DNS del móvil OK`)
- [x] Existe y está documentado el rollback por IP (router) y por `nmcli` (G9).
- [x] Al escalar el Deployment a 0 (`kubectl -n adguard scale deploy/adguard --replicas=0`), llega `AdguardDown` (FIRING) a Telegram en ≤ 3 min; al restaurarlo, llega RESOLVED.
- [x] `./scripts/deploy-adguard.sh` re-ejecutado no produce cambios ni errores (idempotencia).
- [x] Ningún secreto aparece versionado (`git status` limpio salvo los ficheros previstos).

## Decisiones

- **Sí:** AdGuard solo DNS, pod normal tras MetalLB `.61`. El DHCP es broadcast y no funciona desde overlay; mantiene el diseño simple y permite añadir réplica en el futuro.
- **Sí:** el router conserva el DHCP y solo se le cambia el DNS anunciado. Cambio mínimo y reversible; no requiere `hostNetwork`. La contrapartida (caída total de DNS si AdGuard cae) es deliberada: fallo ruidoso + alerta.
- **Sí:** `nfs-storage-v4` (con locks) para SQLite, con query log de 24 h. Evita corrupción y reduce I/O.
- **Sí:** una sola réplica ahora. El doble escritor SQLite y el DHCP hacen inviable HA limpia; se pospone.
- **Sí:** alerta `AdguardDown` por Telegram vía `kube-state-metrics` (`replicas_available == 0`). Cubre la caída del pod sin tocar AdGuard ni añadir `blackbox_exporter`.
- **Sí:** toda la LAN filtrada, **incluido G9**, pero G9 se configura **en último lugar** para no perder la sesión del agente durante el despliegue.
- **Sí:** **IPv6 desactivado** en el router. Cierra el bypass por RA/DHCPv6 (G9 tenía DNS IPv6 del ISP: `2a0c:5a80:0:2::1`, `fe80::1`).
- **Sí:** runbook de rescate por hotspot del móvil + `ssh server`. La vía pública (G9 → `elarreglador.eu` → DV0 → WireGuard) no depende de la LAN ni de AdGuard, así que permite arreglar el cluster aunque el DNS doméstico haya caído.
- **No:** DNS secundario en el router. Fallo ruidoso deliberado: si AdGuard cae, la LAN deja de resolver y se nota; un `8.8.8.8` silencioso enmascararía la caída y saltaría el bloqueo.
- **No:** DHCP por AdGuard (`hostNetwork` anclado a un worker). Punto único de fallo y sin réplica posible.
- **No:** DoH/DoT. Se prioriza paridad con el DNS actual; se evaluará aparte.
- **No:** DNS de los nodos del cluster vía AdGuard. Ojo: cada host físico no alcanza las LB-IPs servidas por su propio LXC (ruteo asimétrico); CoreDNS sigue con su upstream propio.
- **Sí:** el panel de administración queda **público** en `https://adguard.elarreglador.eu` protegido por login (decisión del propietario, 2026-10-11). El DNS (`192.168.1.61:53`) sigue restringido a la LAN por NetworkPolicy. Candidatos de la extensión «AdGuard fuera de casa» (no en esta spec): **WireGuard móvil** con proxy DNS en DV0 (`10.8.0.1:53 → 192.168.1.61:53`) o **DoH/DoT** (`/dns-query`; DoT 853 para Android «DNS privado» requiere `tcp-services` en ingress-nginx).

## Riesgos

| Riesgo | Mitigación |
|---|---|
| AdGuard es punto único de fallo deliberado: si cae, la LAN deja de resolver | Alerta `AdguardDown` a Telegram (≤ 3 min) para actuar; **sin** DNS secundario, para que la caída no pase desapercibida. |
| El agente corre en G9: perder DNS corta la sesión y no puede reanimarse solo | G9 se configura **en último lugar** + runbook de rescate por hotspot del móvil (`ssh server`) **probado antes** del cutover + rollback `nmcli` para el humano. |
| El router (`192.168.1.1`) no es alcanzable desde fuera de la LAN | El router solo se toca desde la LAN; el rescate se hace del lado del cluster, no del router. |
| Dispositivos con DNS manual distinto de G9 quedan sin filtrar | Se documenta; se corrigen uno a uno si se detectan (el móvil de prueba usa DNS por DHCP). |
| NFS lento con SQLite | Query log a 24 h o desactivado; valorar `emptyDir` RAM para runtime si el I/O molesta. |
| El pod cambia de nodo | MetalLB re-ARP sobre `.61`; `externalTrafficPolicy: Local` para que funcionen las NetworkPolicy de LAN. |
| El firmware del router cambia su WebUI | Configuración guiada a mano por el navegador; no hay script propietario que mantener. |

## Lo que **no** está en esta especificación

- DHCP servido por AdGuard.
- Segunda réplica / alta disponibilidad.
- DNS secundario en el router (fallo ruidoso deliberado).
- Filtrar por IPv6 (se desactiva IPv6 en el router en vez de montar un segundo resolutor v6).
- Cifrado DoH/DoT del upstream.
- Filtrar el DNS interno de los nodos del cluster.

---

**Notas de ejecución para el agente:** valide cada manifiesto con `kubectl apply --dry-run=server`; no escriba claves en disco ni en el repo; para la fase del router, use el MCP de navegador para *abrir/observar* y guíe al usuario para que introduzca él las credenciales; cierre la parte web cuando el usuario confirme que el DNS quedó guardado. **Recuerde el orden:** G9 se toca en el último paso (paso 9); antes de ese paso, tenga probado el runbook de contingencia (paso 7).
