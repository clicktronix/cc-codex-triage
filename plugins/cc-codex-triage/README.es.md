# plugin cc-codex-triage

[English](README.md) · **Español** · [Русский](README.ru.md)

Hilos (threads) persistentes y con nombre de la CLI de Codex para triaje abierto entre agentes dentro de Claude Code.

## Qué te ofrece

- `/ask [--oneshot] <pregunta>` — preguntas informativas en el hilo persistente `ask` (sandbox de solo lectura). «Cómo funciona X aquí», «ya existe un Y».
- `/review [--lens <name>] [--thread <name>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] [--json] [--continue] <texto>` — crítica en un hilo de review; **itera hasta APPROVE por defecto** (envío → corregir → re-review hasta APPROVE o `--cap` rondas), `--once` para una sola pasada. Lentes (lenses): correctness (por defecto), security, performance, architecture, ux, quick. El hilo por defecto está acotado a la rama (`review-<branch>`). Un review de terceros pegado se envuelve automáticamente en Judge-mode como una única pasada de clasificación (sin bucle). `--model`/`--effort` fijan el modelo/esfuerzo de razonamiento, aplicados solo en el envío inicial o en `--oneshot` (un resume mantiene estables el modelo/esfuerzo del hilo y avisa con WARN si los vuelves a pasar). `--background` envía en modo desacoplado (detached) y devuelve el turno sin esperar (implica una sola pasada, sin bucle; usa el flag `--detach` del driver — el envío corre en su propia sesión de procesos y sobrevive a la recolección de procesos del harness, y la respuesta aterriza en el log del hilo). `--json` devuelve salida estructurada (`schemas/review-output.schema.json`, requiere `codex` ≥ 0.142 + `jq`) en lugar de prosa, se renderiza en una vista para humanos y se registra automáticamente en el ledger con una puntuación de confianza por hallazgo; no puede liberar la verja en modo texto de `/autoreview`. Los hallazgos se registran en un ledger legible por máquina y *fail-closed* (`<thread>.findings.jsonl`, requiere `jq` — un ledger corrupto es rechazado tanto por lectores como por escritores, nunca se muestra vacío ni se le añade nada); `--continue` reconstruye la siguiente ronda a partir de los hallazgos aún abiertos + el diff desde el último APPROVE.
- `/plan [--lens <name>] [--thread <name>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] <plan>` — somete un plan a prueba de estrés en un hilo de plan; **itera hasta APPROVE por defecto**. Lentes: stress-test (por defecto), pre-mortem, devils-advocate, alternatives, adr. Las lentes de plan ahora terminan en un veredicto legible por máquina (`APPROVE | REQUEST_CHANGES | COMMENT`). `--model`/`--effort` fijan el modelo/esfuerzo de razonamiento, aplicados solo en el envío inicial o en `--oneshot` (un resume mantiene estables el modelo/esfuerzo del hilo y avisa con WARN si los vuelves a pasar). `--background` envía en modo desacoplado (detached) y devuelve el turno sin esperar (implica una sola pasada, sin bucle; usa el flag `--detach` del driver — el envío corre en su propia sesión de procesos y sobrevive a la recolección de procesos del harness, y la respuesta aterriza en el log del hilo).
- `/reply [thread] <directiva>` — Claude Code responde de vuelta en un hilo activo (contestar una pregunta, ejecutar una acción de herramienta solicitada, rebatir un hallazgo).
- `/debate [--rounds N] [--thread <name>] <pregunta>` — desacuerdo estructurado de varias rondas entre Claude Code y Codex sobre una decisión, con cada intercambio visible para el usuario, que termina en una síntesis honesta (los desacuerdos residuales se exponen, no se disimulan).
- `/autoreview on|off|status` — al armarlo, si la rama ya tiene cambios los revisa de inmediato (sin `/review` manual); luego un hook Stop bloquea cualquier turno futuro con cambios de código sin verificar hasta que un review de Codex alcance un APPROVE **obtenido después de armar** (un APPROVE rancio de un armado anterior no cuenta), o el tope de rondas. A prueba de descontrol: el tope de rondas validado numéricamente es el terminador duro (un estado malformado falla en abierto), el APPROVE es la liberación por éxito, y el acotado por rama+árbol-sucio lo mantiene fuera de turnos no relacionados. Las verjas armadas **caducan automáticamente a los 14 días** — una verja rancia en una rama ya fusionada se retira sola en vez de volver a dispararse cuando se reutiliza el nombre de la rama.
- `/autoplan on|off|status` — igual que `/autoreview` pero para documentos de plan: al armarlo, si `docs/plans/**` ya cambió los somete a prueba de inmediato; luego bloquea cualquier turno futuro que cambie documentos de plan hasta que el hilo de plan haya visto un envío posterior al armado (normalmente tu prueba de estrés con `/plan`; la verja detecta crecimiento del log, no la identidad del comando). Misma semántica de tope y de caducidad automática a los 14 días.
- `/thread [--oneshot] <name> <mensaje>` — hilos con nombre arbitrarios (paso directo, sin enmarcar).
- `/thread-list` — hilos activos + rondas, tamaño del log, última actividad.
- `/thread-new <name> [mensaje]` — fuerza el reinicio de un hilo (pierde la memoria).
- `/status` — vista de una pantalla, de solo lectura: rama, árbol sucio, verjas armadas (con avisos de rama-rancia / pre-0.5 / objetivo-ausente), último veredicto por hilo, estado de gitignore, y la versión de la CLI de Codex frente al mínimo requerido.
- `/cleanup [--apply] [--older-than <days>]` — encuentra verjas armadas rancias/pre-0.5, logs de hilo huérfanos, diagnósticos last-error rancios y — con `--older-than <days>` — hilos dormidos enteros; por defecto en simulación (dry-run), `--apply` los **archiva** (nunca borra, reversible). Las barandillas de seguridad se aplican a cada clase: los hilos con un arriendo de envío vivo (`<thread>.active` nombrando un PID vivo) o apuntados por una verja armada nunca se tocan, y los hilos genéricos `review`/`plan` solo se listan, nunca se archivan automáticamente.
- `/review-dispute <id> <por qué>` / `/review-accept <id> --reason` / `/review-defer <id> --issue` — descarta un hallazgo de review registrado por su id (falso positivo / compromiso aceptado / diferido a un issue rastreado), de modo que abandona la lista de abiertos con un rastro auditable en vez de desaparecer en silencio.
- La skill `codex-triage` documenta el enrutamiento, el marco Judge-mode, las reglas anti-capitulación del debate, la validación de hallazgos entrantes de Codex (verifica antes de aplicar — no los selles solo para liberar la verja), la regla de arreglar-el-vecindario, y el modificador `--oneshot`.

Cada comando mantiene un hilo de Codex persistente por defecto; `--oneshot` convierte a cualquiera en desechable (`codex exec --ephemeral`, no guarda estado). **Una tarea = un hilo**: `/review` y `/plan` usan por defecto un hilo acotado a la rama (`review-<branch>` / `plan-<branch>`, p. ej. `review-main` en `main` — sin caso especial para main), así cada rama y su verja correspondiente quedan aisladas; pasa `--thread <topic>` para dividir más, o `--thread review` para uno compartido.

## En qué se diferencia de las alternativas

| | Este plugin | `hamelsmu/claude-review-loop` | `dementev-dev/adversarial-review` |
|---|---|---|---|
| Sesiones de Codex | **Persistentes vía `exec resume`** | Nuevas cada vez | Persistentes vía `exec resume` |
| Tope de rondas | **Abierto (acotado solo en las verjas `/autoreview`/`/autoplan`)** | 1 | 5 (approve/revise) |
| Propósito | **Diálogo iterativo de triaje + verja opcional de auto-verificación** | Review multi-agente de una pasada | Bucle de approve/revise |
| Salida | Stream Markdown, en bruto | Archivo Markdown consolidado | JSON + Markdown + literal VERDICT |

Úsalo cuando la conversación vaya a iterar. Usa `claude-review-loop` para un único review exhaustivo. Usa `adversarial-review` cuando quieras una verja dura de aprobado/fallo tras un número acotado de rondas.

## Requisitos previos

- CLI `codex` ≥ 0.137.0 (`npm install -g @openai/codex`) — la versión en la que se verificaron las semánticas de resume/`--ephemeral`; CLIs más antiguas pueden funcionar pero no están probadas.
- `/review --json` requiere `codex` ≥ 0.142 (soporte de `--output-schema`) y `jq`.
- `~/.codex/config.toml` con un modelo para el que estés autorizado. Sobrescribe por llamada con `CC_CODEX_FLAGS="-m gpt-5.5 -s read-only"`. Limitación: la cadena de flags se separa por espacios en blanco, así que los valores individuales de un flag no pueden contener espacios.
- Una sola sesión de Claude Code por repositorio a la vez: el estado de los hilos bajo `.claude/codex-threads/` no está bloqueado, así que dos sesiones concurrentes que envíen al mismo hilo pueden competir por los contadores/log (gana el último que escribe).

## Dónde vive el estado

- `.claude/codex-threads/<name>.id` — UUID de sesión de Codex guardado para el hilo.
- `.claude/codex-threads/<name>.log` — log de auditoría append-only de prompt/respuesta.
- `~/.codex/sessions/rollout-*.jsonl` — los propios archivos de rollout de Codex (gestionados por la CLI de Codex).

El plugin nunca borra los archivos de rollout de Codex. `/thread-new` solo limpia el puntero local.

## Primitivas de seguridad

- **Sin exec nuevo silencioso al fallar un resume.** Si `codex exec resume` falla, el driver sale con código 4 y te pide hacer `--new` de forma explícita. Tu suposición de «Codex recuerda esto» nunca se rompe en silencio.
- **Guardia de mutación de archivos versionados.** El driver toma una instantánea de `git status --porcelain` antes/después de cada envío a Codex y avisa si hay diferencias. Pon `CC_CODEX_TRIAGE_STRICT=1` para hacerlo fatal. Ejecuta con `CC_CODEX_FLAGS="-s read-only"` para hilos de solo review.
- **Sin `--last`.** Los hilos están anclados a su UUID guardado; si desaparece, la siguiente llamada empieza de cero, no con «lo que sea que se tocó más recientemente en `~/.codex/sessions/`».

## Marco Judge-mode

Cuando pegas los hallazgos de otro agente en `/review`, el comando envuelve el prompt como una evaluación de terceros en lugar de una refutación secuencial. Empíricamente (arXiv 2509.16533, EMNLP 2025 Findings) esto reduce las tasas de capitulación servil del 23,5–80,3 % en un factor de 1,5–2×.

## Instalación

```
/plugin marketplace add clicktronix/cc-codex-triage
/plugin install cc-codex-triage@cc-codex-triage
```

(El sufijo `@cc-codex-triage` es el nombre del marketplace — `plugin@marketplace`.)

Los comandos del plugin están **espaciados por nombre** (namespaced) bajo el plugin. Invócalos como
`/cc-codex-triage:review`, `/cc-codex-triage:ask`, etc. La forma corta `/<name>`
también funciona para nombres que no chocan con uno incorporado — pero `/review` y
`/plan` ya los usan los comandos propios de Claude Code, así que usa la forma con namespace para
esos dos.

## Alcance: unidireccional (Claude Code → CLI de Codex)

Este es un plugin de **Claude Code**. Sus slash commands invocan la CLI `codex`
mediante el driver incluido. A propósito no se empaqueta como plugin de Codex
(`.codex-plugin/`) — no hay nada que Codex ejecute; Codex es el invocado, no
el anfitrión. Si quieres que Codex *aloje* skills, eso es un artefacto distinto.

## Licencia

MIT.
