# Benchmark de modelos LLM (≤3B) — Ollama en el cluster D-Lab

Resultados de los benchmarks de generación de código realizados sobre el pod
Ollama del namespace `ia` (cluster K8s D-Lab). Documento de resultados; la
sección de la aplicación está en `03-Aplicaciones.md`.

- **Fecha**: 2026-08-18 (ping) y 2026-08-19 (tarea de programación).
- **Entorno**: pod `ollama/ollama:0.32.14`, 2 CPU / 4 GiB (límites), PVC
  `ollama-models` 20Gi (NFS). La carga y generación se midieron sobre el pod
  real, no sobre el host completo, para reflejar el uso real (opencode/Node-RED).
- **Modelos probados** (6): `qwen2.5-coder:3b`, `granite-code:3b`,
  `llama3.2:3b`, `yi-coder:1.5b`, `deepseek-coder:1.3b`, `smollm2:1.7b`.
- **Estado de los modelos**: los 6 se conservan descargados en el PVC
  (decisión del Señor, 2026-08-19).

---

## 1. Benchmark «ping» (tiempo de respuesta)

**Prueba**: dos consultas por modelo (fría descartada, caliente medida) con el
prompt «Responde con una sola palabra: pong». Criterio de corte: tiempo total
≤ 5 s. TTFT y total medidos con `curl -w` vía pod helper en el namespace `ia`.

**Resultados** (tiempo de respuesta total, consulta caliente):

| Modelo            | Tamaño | TTFT (s) | Total (s) | Veredicto            |
|-------------------|--------|----------|-----------|----------------------|
| tinyllama:1.1b    | 637 MB | —        | 0.531     | ✓ pasa corte         |
| qwen2.5-coder:1.5b| 986 MB | —        | 0.586     | ✓ pasa corte         |
| qwen2.5:1.5b      | 986 MB | —        | 0.623     | ✓ pasa corte         |
| qwen2.5-coder:3b  | 1.9 GB | —        | 1.009     | ✓ pasa corte         |
| gemma2:2b         | 1.6 GB | —        | 1.216     | ✓ pasa corte         |
| llama3.2:3b       | 2.0 GB | —        | 6.195     | ✗ supera 5 s         |
| qwen3:4b          | 2.5 GB | —        | —         | ✗ descartado (reiniciaba el pod) |
| phi3:mini         | 2.2 GB | —        | —         | ✗ descartado (reiniciaba el pod) |

**Conclusión**: qwen3:4b y phi3:mini se descartaron por inestabilidad — al
cargarlos el daemon tarda en responder y el liveness probe (timeout 1 s, por
aquel entonces) reiniciaba el pod. Modelo elegido en su momento:
`qwen2.5-coder:3b`.

---

## 2. Benchmark de tarea de programación

### 2.1 Prueba

A cada modelo se le pidió implementar, en cada lenguaje, un **evaluador de
expresiones aritméticas**: leer una línea de stdin con una expresión de enteros
y los operadores `+`, `-`, `*`, `/` (división entera) y paréntesis, evaluar
respetando la precedencia habitual y escribir el resultado como entero. Se
probaron 6 lenguajes: Dart, C, Python, bash, JS y Java.

**Proceso por lenguaje/modelo**:

1. `ollama pull <modelo>`.
2. Warm-up (consulta descartada: carga el modelo a RAM).
3. Petición medida al API `/api/chat` (`stream:false`, `keep_alive:0`): TTFT y
   total con `curl -w`.
4. Extracción del bloque de código de la respuesta.
5. **Compilación/ejecución real en G9** (`dart`, `gcc`, `python3`, `bash`,
   `node`, `javac`/`java`) y **validación contra un corpus fijo** de 10
   expresiones (ver 2.3).
6. Criterio `Funciona?` = **compila y produce el resultado esperado en todo el
   corpus**. Si no funciona, las demás columnas se puntúan `—`.

**Notas de medición**: en la ronda de 5 lenguajes el pod ya tenía el límite de
4 GiB y las probes con timeout 5 s. Cada petición se midió con `keep_alive:0`,
así que el **tiempo incluye la recarga del modelo** (TTFT ≈ TOTAL) — no es
comparable con el benchmark «ping», que medía consultas calientes de una
palabra.

### 2.2 Prompt de activación

Prompt idéntico en todos los modelos y lenguajes, salvo el nombre del lenguaje
(en mayúsculas para C/PYTHON/JS, capitalizado en el resto). Plantilla:

```
Escribe un programa en {LENGUAJE} que resuelva la siguiente tarea:

Lee una línea de la entrada estándar con una expresión aritmética formada por
números enteros y los operadores +, -, *, / (división entera) y paréntesis.
Evalúa la expresión respetando la precedencia habitual de operadores y escribe
en la salida estándar el resultado como número entero.

Devuelve un solo bloque de código en {LENGUAJE}. Sin explicaciones adicionales.
```

- Para Dart: «Escribe un programa en Dart que resuelva la siguiente tarea: …»
- Para C: «… en C …» / «… en C …» (mayúscula en la petición de bloque).
- Para Python: «… en PYTHON …» (nombre en mayúsculas).
- Para bash: «… en BASH …».
- Para JS: «… en JS …».
- Para Java: «… en Java …».

### 2.3 Corpus de validación

| Expresión           | Resultado esperado |
|---------------------|--------------------|
| `2 + 3 * 4`         | 14                 |
| `(2+3)*4`           | 20                 |
| `10 / 4`            | 2                  |
| `2*(3+4)/7`         | 2                  |
| `8 / 2 * 2`         | 8                  |
| `7 - 3 + 1`         | 5                  |
| `20/3`              | 6                  |
| `100/7/2`           | 7                  |
| `3 + 5 * ( 2 - 8 )` | −27                |
| `( 8 + 2 ) / 5`     | 2                  |

### 2.4 Resultados — Dart

Ronda preliminar (2026-08-18). Ningún modelo ≤ 3B generó Dart válido; el más
cercano, qwen2.5-coder:3b, con lógica de precedencia correcta pero `Stack`
inexistente en la stdlib de Dart + nullability; el resto, APIs/sintaxis
inventadas o esqueletos.

| Modelo            | Lenguaje | Funciona? | Tiempo (s) |
|-------------------|----------|-----------|------------|
| qwen2.5-coder:3b  | Dart     | No        | 67.8       |
| granite-code:3b   | Dart     | No        | 27.3       |
| llama3.2:3b       | Dart     | No        | 132.3      |
| yi-coder:1.5b     | Dart     | No        | 38.8       |
| deepseek-coder:1.3b| Dart    | No        | 29.7       |
| smollm2:1.7b      | Dart     | No        | 92.6       |

### 2.5 Resultados — C, Python, bash, JS, Java

Ronda completa (2026-08-19), misma tarea y corpus.

| Modelo            | Lenguaje | Funciona? | Estabilidad | CiberSeguridad   | Buenas prácticas | Tests | Tiempo (s) |
|-------------------|----------|-----------|-------------|------------------|------------------|-------|------------|
| qwen2.5-coder:3b  | C        | No        | —           | —                | —                | —     | 92.8       |
| qwen2.5-coder:3b  | Python   | No        | —           | —                | —                | —     | 97.4       |
| qwen2.5-coder:3b  | bash     | No        | —           | —                | —                | —     | 33.0       |
| qwen2.5-coder:3b  | JS       | No        | —           | —                | —                | —     | 95.2       |
| qwen2.5-coder:3b  | Java     | No        | —           | —                | —                | —     | 108.2      |
| granite-code:3b   | C        | No        | —           | —                | —                | —     | 59.7       |
| granite-code:3b   | Python   | No        | —           | —                | —                | —     | 45.0       |
| granite-code:3b   | bash     | No        | —           | —                | —                | —     | 48.2       |
| granite-code:3b   | JS       | No        | —           | —                | —                | —     | 67.1       |
| granite-code:3b   | Java     | No        | —           | —                | —                | —     | 62.9       |
| llama3.2:3b       | C        | No        | —           | —                | —                | —     | 504.7      |
| llama3.2:3b       | Python   | No        | —           | —                | —                | —     | 92.3       |
| llama3.2:3b       | bash     | No        | —           | —                | —                | —     | 58.4       |
| llama3.2:3b       | JS       | No        | —           | —                | —                | —     | 133.2      |
| llama3.2:3b       | Java     | No        | —           | —                | —                | —     | 95.3       |
| **yi-coder:1.5b** | **JS**   | **Sí**    | **10**      | **1** (eval RCE) | No               | No    | 24.9       |
| yi-coder:1.5b     | C        | No        | —           | —                | —                | —     | 37.8       |
| yi-coder:1.5b     | Python   | No        | —           | —                | —                | —     | 58.2       |
| yi-coder:1.5b     | bash     | No        | —           | —                | —                | —     | 22.9       |
| yi-coder:1.5b     | Java     | No        | —           | —                | —                | —     | 74.5       |
| deepseek-coder:1.3b| C       | No        | —           | —                | —                | —     | 99.2       |
| deepseek-coder:1.3b| Python  | No        | —           | —                | —                | —     | 32.6       |
| deepseek-coder:1.3b| bash    | No        | —           | —                | —                | —     | 51.1       |
| deepseek-coder:1.3b| JS      | No        | —           | —                | —                | —     | 33.8       |
| deepseek-coder:1.3b| Java    | No        | —           | —                | —                | —     | 79.8       |
| smollm2:1.7b      | C        | No        | —           | —                | —                | —     | 91.3       |
| smollm2:1.7b      | Python   | No        | —           | —                | —                | —     | 63.5       |
| smollm2:1.7b      | bash     | No        | —           | —                | —                | —     | 46.1       |
| smollm2:1.7b      | JS       | No        | —           | —                | —                | —     | 75.3       |
| smollm2:1.7b      | Java     | No        | —           | —                | —                | —     | 104.0      |

**El único caso funcional** (yi-coder:1.5b en JS) usa `eval()` sobre el
contenido de `/dev/stdin` (`fs.readFileSync`), lo que constituye una **RCE
(ejecución de código arbitrario)** desde la entrada; por eso su
CiberSeguridad es 1/10 y no es apto para uso real.

### 2.6 Resumen de fallos por modelo

| Modelo              | Patrón de fallo dominante                                                                 |
|---------------------|-------------------------------------------------------------------------------------------|
| qwen2.5-coder:3b    | Código casi correcto en C/Python pero **precedencia mal resuelta** (`2+3*4`→20); JS con `readline` sin import; bash vacío; Java no compila |
| granite-code:3b     | Respuestas **fragmentadas/incompletas** (esqueletos); nada compila/evalúa correctamente  |
| llama3.2:3b         | C no compila; Python devuelve `0`; bash requiere paréntesis; JS produce NaN; Java compila pero exige paréntesis obligatorios |
| yi-coder:1.5b       | JS usa **`eval()` (RCE)** y pasa el corpus; en C intenta entrada interactiva; Python con sintaxis rota; bash `bc` roto |
| deepseek-coder:1.3b | Python con **división real** (`10/4`→`2.0`) y `NaN` en JS; Java excepción de pila (Stack.pop) |
| smollm2:1.7b        | C/Java no compilan; Python/bash/JS con **errores de sintaxis** o salidas vacías            |

### 2.7 Conclusión

Ningún modelo ≤ 3B es fiable para generar código de esa complejidad en 6
lenguajes; el único acierto (yi-coder JS) es además un antipatrón de
seguridad. Para el uso real (opencode) **qwen2.5-coder:3b sigue siendo la
mejor opción** por su calidad relativa de código y tiempos razonables,
asumiendo que **el código generado siempre se revisa** (los fallos de
precedencia en C/Python lo demuestran). Los tiempos de esta sección (30-500 s)
no son comparables a los del ping (0.5-6 s): la tarea de programación genera
1-9 KB de tokens y cada petición recarga el modelo.
