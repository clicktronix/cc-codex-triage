# plugin cc-codex-triage

[English](README.md) · **Español** · [Русский](README.ru.md)

Hilos (threads) persistentes y con nombre de la CLI de Codex para triaje abierto entre agentes dentro de Claude Code.

## Qué te ofrece

- `/ask [--thread <name>] [--oneshot] <pregunta>` — preguntas informativas en un hilo persistente (sandbox de solo lectura por defecto). «Cómo funciona X aquí», «ya existe un Y». Por defecto usa el hilo `ask`, común a todo el repositorio; pasa `--thread <feature>` para que las preguntas de una funcionalidad queden junto al resto del contexto de Codex sobre ella.
- `/review [--required --base <ref> --spec <path>] [--lens <name>] [--thread <name>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] [--json] [--continue] <texto>` — crítica que **itera hasta APPROVE por defecto**. `--required` puede ser invocado por el modelo y cada llamada reclama una ronda foreground. Los hallazgos bloqueantes válidos vuelven al workflow propietario para fix/test/commit y un candidato nuevo; los refutados o diferidos explícitamente se revisan otra vez sobre el mismo candidato inmutable, sin cambios ficticios. La primera ronda required fija base/spec/cap hasta un reinicio explícito del hilo o el uso de otro hilo. Solo aprueba el base/spec explícito y el HEAD/tree/fingerprint exacto de un candidato limpio sin cambios. Cap o divergencia detienen el flujo sin aprobación; background/single-pass/JSON/Judge nunca satisfacen la verja obligatoria.
- `/plan [--lens <name>] [--thread <name>] [--once] [--oneshot] [--cap N] [--model <m>] [--effort <e>] [--background] <plan>` — somete un plan a prueba de estrés en un hilo de plan; **itera hasta APPROVE por defecto**. Lentes: stress-test (por defecto), pre-mortem, devils-advocate, alternatives, adr. Las lentes de plan ahora terminan en un veredicto legible por máquina (`APPROVE | REQUEST_CHANGES | COMMENT`). `--model`/`--effort` fijan el modelo/esfuerzo de razonamiento, aplicados solo en el envío inicial o en `--oneshot` (un resume mantiene estables el modelo/esfuerzo del hilo y avisa con WARN si los vuelves a pasar). `--background` envía en modo desacoplado (detached) y devuelve el turno sin esperar (implica una sola pasada, sin bucle; usa el flag `--detach` del driver — el envío corre en su propia sesión de procesos y sobrevive a la recolección de procesos del harness — más el watcher incluido `detach-watch.sh`, lanzado como tarea en segundo plano gestionada por Claude, que entrega la respuesta o el diagnóstico de fallo como notificación de finalización).
- `/reply [thread] <directiva>` — Claude Code responde de vuelta en un hilo activo (contestar una pregunta, ejecutar una acción de herramienta solicitada, rebatir un hallazgo).
- `/debate [--rounds N] [--thread <name>] <pregunta>` — desacuerdo estructurado de varias rondas entre Claude Code y Codex sobre una decisión, con cada intercambio visible para el usuario, que termina en una síntesis honesta (los desacuerdos residuales se exponen, no se disimulan).
- `/autoreview on|off|status` — al armarlo, si la rama ya tiene cambios los revisa de inmediato (sin `/review` manual); luego un hook Stop bloquea cualquier turno futuro cuyo código difiera del último estado que la verja liberó, hasta que un review de Codex alcance un APPROVE **que cubra ese estado**, o el tope de rondas. La unidad es un **ciclo**, no un armado: la huella es un hash del *contenido* del árbol de trabajo, así que una corrección sobrevive a su propio commit y la verja sigue activa, hacer commit de bytes ya aprobados no cuesta ninguna ronda, y un APPROVE libera un estado, no todo el armado. A prueba de descontrol: el tope de rondas por ciclo, validado numéricamente, es el terminador duro (un estado malformado falla en abierto), y solo una liberación real lo recarga. Las verjas armadas **caducan automáticamente a los 14 días** — una verja rancia en una rama ya fusionada se retira sola en vez de volver a dispararse cuando se reutiliza el nombre de la rama.
- `/autoplan on|off|status` — igual que `/autoreview` pero para documentos de plan: al armarlo, si `docs/plans/**` ya cambió los somete a prueba de inmediato; luego bloquea cualquier turno futuro cuyos documentos de plan difieran del último estado liberado, hasta que el hilo de plan haya visto un envío dentro del ciclo actual (la verja detecta crecimiento del log, no la identidad del comando). La huella incluye el contenido, también el de los archivos sin seguimiento, así que un plan reescrito tras una liberación vuelve a activar la verja. Misma semántica de tope y de caducidad automática a los 14 días.
- `/thread [--topic <text>] [--oneshot] <name> <mensaje>` — hilos con nombre arbitrario (paso directo, sin enmarcar). `--topic` registra una línea sobre qué contiene el hilo, fijada al crearlo.
- `/thread-list` — hilos activos + rondas, tamaño del log, última actividad.
- `/thread-new <name> [mensaje]` — fuerza el reinicio de un hilo (pierde la memoria).
- `/status` — vista de solo lectura: rama, árbol de trabajo, ruta de estado compartida, verjas armadas y su **estado de ciclo**, último veredicto por hilo, estado de la verja de revisión obligatoria (incluida una reclamación
  viva o caducada y una parada dura `CAP_REACHED`) y versión de Codex CLI.
- `/cleanup [--apply] [--older-than <days>]` — encuentra verjas armadas rancias/pre-0.5, logs de hilo huérfanos, diagnósticos last-error rancios y — con `--older-than <days>` — hilos dormidos enteros; por defecto en simulación (dry-run), `--apply` los **archiva** (nunca borra, reversible). Las barandillas protegen hilos con un arriendo vivo, un claim required-review reciente y coherente o una verja armada; los hilos genéricos `review`/`plan` solo se listan. Apply falla de forma cerrada si no puede descubrir la verja de algún worktree; la revalidación y los movimientos finales mantienen los mutex del dispatch/review y del escritor de verjas.
- `/review-dispute <id> <por qué>` / `/review-accept <id> --reason` / `/review-defer <id> --issue` — descarta un hallazgo de review registrado por su id (falso positivo / compromiso aceptado / diferido a un issue rastreado), de modo que abandona la lista de abiertos con un rastro auditable en vez de desaparecer en silencio.
- La skill `codex-triage` documenta el enrutamiento, el marco Judge-mode, las reglas anti-capitulación del debate, la validación de hallazgos entrantes de Codex (verifica antes de aplicar — no los selles solo para liberar la verja), la regla de arreglar-el-vecindario, cuándo el bucle de review es la herramienta equivocada, y el modificador `--oneshot`.
- `/review` puede ser invocado por el modelo para que un workflow propietario complete una revisión obligatoria hasta `APPROVE`. Los demás slash-commands siguen siendo solo para el usuario. La skill `codex-second-opinion` sigue siendo un único envío acotado para una bifurcación independiente y nunca toca hilos de verja.

Cada comando mantiene un hilo de Codex persistente por defecto; `--oneshot` convierte a cualquiera en desechable (`codex exec --ephemeral`, no guarda estado). **Una tarea = un hilo**: `/review` y `/plan` usan por defecto un hilo acotado a la rama (`review-<branch>` / `plan-<branch>`, p. ej. `review-main` en `main` — sin caso especial para main), así cada rama y su verja correspondiente quedan aisladas; pasa `--thread <topic>` para dividir más, o `--thread review` para uno compartido.

**Una funcionalidad = un hilo, a través de los comandos.** Esos valores por defecto son por *tipo de comando*, así que el contexto de una funcionalidad se reparte entre `ask`, `plan-<branch>` y `debate-<slug>`. Apunta `/ask`, `/plan` y `/debate` a un único `--thread <feature>` y deja `/review` en su hilo de rama (la verja lee los veredictos de ahí). El sandbox queda fijado al crear la sesión de Codex — `codex exec resume` acepta `-m` y `--output-schema` pero no `-s` — así que un hilo de funcionalidad elige solo-lectura o escritura una sola vez, en el primer envío. Y como cada resume vuelve a alimentar el historial, conviene dividir un hilo ya grande en lugar de reanudarlo indefinidamente; `/thread-list` muestra rondas y tamaño. Como calibración, no como umbral medido: los hilos de funcionalidad en producción llegan a ~130 KB en la ronda 9, y el más largo registrado (13 rondas) nunca convergió.

## En qué se diferencia de las alternativas

| | Este plugin | `hamelsmu/claude-review-loop` | `dementev-dev/adversarial-review` |
|---|---|---|---|
| Sesiones de Codex | **Persistentes vía `exec resume`** | Nuevas cada vez | Persistentes vía `exec resume` |
| Tope de rondas | **`--cap` por bucle de comando (5 por defecto), tope aparte por ciclo en las verjas** | 1 | 5 (approve/revise) |
| Propósito | **Diálogo iterativo de triaje + verja opcional de auto-verificación** | Review multi-agente de una pasada | Bucle de approve/revise |
| Salida | Stream Markdown, en bruto | Archivo Markdown consolidado | JSON + Markdown + literal VERDICT |

Úsalo cuando la conversación vaya a iterar. Usa `claude-review-loop` para un único review exhaustivo. Usa `adversarial-review` cuando quieras una verja dura de aprobado/fallo tras un número acotado de rondas.

## Requisitos previos

- CLI `codex` ≥ 0.137.0 (`npm install -g @openai/codex`) — la versión en la que se verificaron las semánticas de resume/`--ephemeral`; CLIs más antiguas pueden funcionar pero no están probadas.
- `/review --json` requiere `codex` ≥ 0.142 (soporte de `--output-schema`) y `jq`.
- `~/.codex/config.toml` con un modelo para el que estés autorizado. Sobrescribe por llamada con `CC_CODEX_FLAGS="-m gpt-5.5 -s read-only"`. Limitación: la cadena de flags se separa por espacios en blanco, así que los valores individuales de un flag no pueden contener espacios.
- Los envíos a un mismo hilo los serializa el driver: un segundo envío con otro en vuelo se rechaza (exit 10, lease de PID + mutex de adquisición) — no puede competir por los contadores/log. Usa una sesión de Claude Code propietaria de verjas por worktree y una tarea por hilo. Los worktrees separados tienen verjas armadas aisladas; las sesiones que reutilizan deliberadamente el mismo hilo siguen compartiendo su ledger y estado de review.

## Dónde vive el estado

- `<git-common-dir>/cc-codex-triage/threads/<name>.id` — UUID de sesión Codex compartido entre worktrees.
- `<git-common-dir>/cc-codex-triage/threads/<name>.log` — log de auditoría append-only.
- `<name>.candidate`, `<name>.review-state`, `<name>.review-loop`, `<name>.approved` — estado legible por máquina de la revisión obligatoria enlazado al candidato exacto.
- `<absolute-git-dir>/cc-codex-triage/gates/` — verjas armadas y caché de huella del worktree actual; no se comparten entre worktrees.
- `~/.codex/sessions/rollout-*.jsonl` — los propios archivos de rollout de Codex (gestionados por la CLI de Codex).

El plugin nunca borra los archivos de rollout de Codex. `/thread-new` limpia solo el puntero, contadores, metadatos de tarea y sidecars required-review de este repositorio.

## Primitivas de seguridad

- **Sin exec nuevo silencioso al fallar un resume.** Si `codex exec resume` falla, el driver sale con código 4 y te pide hacer `--new` de forma explícita. Tu suposición de «Codex recuerda esto» nunca se rompe en silencio.
- **Guardia de mutación de archivos versionados.** El driver toma una instantánea de `git status --porcelain` antes/después de cada envío a Codex y avisa si hay diferencias. Pon `CC_CODEX_TRIAGE_STRICT=1` para hacerlo fatal. Ejecuta con `CC_CODEX_FLAGS="-s read-only"` para hilos de solo review.
- **Sin `--last`.** Los hilos están anclados a su UUID guardado; si desaparece, la siguiente llamada empieza de cero, no con «lo que sea que se tocó más recientemente en `~/.codex/sessions/`».

### Permiso excesivo conocido: `allowed-tools: Bash`

Cada comando aquí declara un `allowed-tools: Bash` escueto. Ese campo es una **concesión previa de permisos, no una restricción**: durante el turno que invoca el comando, cualquier comando Bash se ejecuta sin pedir permiso, no solo el driver del plugin. Lo correcto sería acotarlo a la invocación del driver.

Aún no está acotado, y es deliberado. Las sustituciones documentadas dentro de las reglas Bash de `allowed-tools` son `${CLAUDE_SKILL_DIR}` y `${CLAUDE_PROJECT_DIR}`; `${CLAUDE_PLUGIN_ROOT}` — que es por donde todo esto se invoca — no está entre ellas. Una regla escrita con él probablemente quedaría como cadena literal, no coincidiría con nada, y convertiría cada envío en una petición de permiso. Cambiar un permiso excesivo acotado por un flujo roto es un mal trato, así que esto espera a confirmar que `${CLAUDE_PLUGIN_ROOT}` se expande ahí, o a reescribir las reglas con `${CLAUDE_SKILL_DIR}`.

La concesión dura solo el turno que invocó el comando y se limpia con tu siguiente mensaje.

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

## Fuera de alcance

**Una etapa de grooming / planificación previa** — los dos harnesses reuniendo
contexto y debatiendo una tarea *antes* de someter al usuario a un cuestionario
de requisitos — se consideró y se dejó fuera deliberadamente. Las piezas que
necesitaría ya existen aquí (`/ask` sobre un hilo de funcionalidad, `/debate`,
`/plan`), pero la etapa en sí vive por encima de este plugin, en aquello que
conduce la tarea: debe ser dueña del cuestionario y decidir qué queda por
preguntar. Construirla aquí significaría que el plugin invade un proceso del
que solo es participante.

## Alcance: unidireccional (Claude Code → CLI de Codex)

Este es un plugin de **Claude Code**. Sus slash commands invocan la CLI `codex`
mediante el driver incluido. A propósito no se empaqueta como plugin de Codex
(`.codex-plugin/`) — no hay nada que Codex ejecute; Codex es el invocado, no
el anfitrión. Si quieres que Codex *aloje* skills, eso es un artefacto distinto.

## Licencia

MIT.
