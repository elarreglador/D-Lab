# Informe de Incidente: Conflicto entre ssh.socket y ssh.service

**Fecha del Incidente:** 20 de junio de 2026  
**Equipos Afectados:** D1, D2  
**Estado:** RESUELTO  

## Descripción del Problema

El servicio SSH no estaba disponible tras los reinicios de los equipos D1 y D2. Al ejecutar `systemctl status ssh`, el servicio mostraba estado `inactive (dead)`. La causa raíz fue la interferencia entre dos unidades de systemd que competían por el puerto SSH (puerto 22):

- **ssh.socket**: Unidad socket que escucha en el puerto 22
- **ssh.service**: Servicio SSH tradicional

Ambas unidades intentaban escuchar en el mismo puerto, causando conflictos que dejaban SSH inoperable tras el reinicio.

## Análisis de Logs

### Timeline del Incidente

Los logs de journalctl revelan el siguiente patrón:

1. **Antes de la solución (13-14 de junio):** ssh.socket estaba activo pero recibía desactivaciones periódicas mientras ssh.service intentaba iniciar.

2. **Comando de remediación ejecutado:**
   ```bash
   sudo systemctl disable --now ssh.socket
   sudo systemctl enable ssh
   ```

3. **Estado actual verificado (24 de junio):**
   ```
   UNIT FILE   STATE    PRESET 
   ssh.service enabled  enabled
   ssh.socket  disabled enabled
   ```

### Evidencia en Logs

**Incidentes de conflicto documentados:**
- 20 de junio, 10:57:17 - 11:14:45: Múltiples ciclos de parada/inicio de ambas unidades
- Evento crítico: A las 11:14:45 se ejecutó la desactivación de ssh.socket
- A las 11:14:45, ssh.service se reinició escuchando en puerto 9622 (cambio de configuración detectado)

**Resolución confirmada:**
- 24 de junio, 09:37:51: Último reinicio muestra ssh.service iniciando correctamente
- 24 de junio, 10:01:40 en adelante: Sesiones SSH exitosas con autenticación correcta

### Conexiones SSH Exitosas Post-Resolución

Los logs muestran múltiples sesiones autenticadas correctas:
- 24 de junio, 10:01:40: desde 192.168.1.102
- 24 de junio, 10:07:05: desde 192.168.1.11
- 24 de junio, 10:08:26: desde 192.168.1.102

## Solución Implementada

1. **Deshabilitación de ssh.socket:**
   ```bash
   sudo systemctl disable --now ssh.socket
   ```
   - Detiene inmediatamente la unidad socket
   - Desactiva su inicio automático en futuros reinicios

2. **Habilitación de ssh.service:**
   ```bash
   sudo systemctl enable ssh
   ```
   - Asegura que ssh.service se inicia automáticamente en reinicios

## Verificación Post-Remediación

**Estado de las unidades:** ssh.service habilitado, ssh.socket deshabilitado

**Comportamiento observado:**
- SSH disponible y respondiendo correctamente a intentos de acceso
- Autenticación funcionando sin errores
- Servicio se reinicia automáticamente tras reinicios del sistema

## Recomendaciones

1. **Monitoreo:** Configurar alertas para cambios no autorizados en el estado de servicios SSH críticos
2. **Documentación:** Mantener registro de cambios en la configuración de servicios del sistema
3. **Prevención:** Considerar remover ssh.socket del sistema si solo se requiere ssh.service, o implementar mecanismos de exclusión mutua más robustos en la configuración de systemd

## Conclusión

El incidente fue causado por la coexistencia conflictiva de dos unidades de systemd. La solución de deshabilitar ssh.socket a favor de ssh.service fue efectiva y ha mantenido SSH operacional desde su implementación.
