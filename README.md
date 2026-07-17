# local-agents

Setup de agentes de código LLM 100% locales: dos "roles" (**planner** y **coder**) corriendo sobre modelos Qwen2.5-Coder servidos por [Ollama](https://ollama.com), orquestados con [Aider](https://aider.chat) en su modo `--architect`, todo manejable desde una terminal.

## Por qué esta arquitectura

- **Planner + Coder en vez de un solo modelo**: un modelo más chico y rápido (*planner*) descompone la tarea, y otro más grande (*coder*) genera los diffs/edita el código. Es el modo `--architect`/`--editor-model` que Aider ya trae resuelto, así que no hace falta un orquestador propio.
- **Ollama en vez de Docker/vLLM**: instalación simple por gestor de paquetes, API compatible con OpenAI, y en equipos con poca VRAM corre bien en CPU. Docker está disponible en el sistema pero no se usa acá — sumaría overhead innecesario para lo que hacemos.
- **`uv` en vez de `pipx` para instalar Aider**: `aider-chat` fija `numpy==1.24.3` en sus dependencias, versión sin wheel precompilado para Python > 3.11. En distros con Python muy nuevo (ej. Manjaro rolling, que ya trae 3.14) instalarlo con `pipx` falla intentando compilar numpy desde cero. `uv` permite fijar Python 3.11 solo para el entorno aislado de Aider, sin tocar el Python del sistema.
- **Presets de tamaño de modelo**: el hardware donde se corre esto varía mucho (desde una laptop con 2GB de VRAM hasta una workstation con GPU grande), así que los modelos a usar son configurables en vez de estar hardcodeados.

## Requisitos

- Linux con `systemd`, arquitectura basada en `pacman` (Arch/Manjaro) o `apt` (Ubuntu/Debian). Otras distros no están soportadas automáticamente por los scripts, pero se puede instalar todo a mano siguiendo los mismos pasos.
- Acceso `sudo`.
- Conexión a internet para descargar los modelos (varios GB según el preset elegido).

## Estructura

```
setup/
  lib-common.sh        # detección de distro (pacman vs apt), sourceado por los otros scripts
  setup-zram.sh         # configura swap comprimida (zram) como red de seguridad de memoria
  setup-llm-agents.sh   # instala Ollama + modelos + Aider, y crea el lanzador aider-local
```

## Uso

### 1. Swap (recomendado, una sola vez)

Antes de correr modelos locales conviene tener algo de swap como colchón ante picos de memoria, sobre todo si la RAM es justa para el preset elegido.

```bash
bash setup/setup-zram.sh
```

Instala `zram-generator` (o `zram-tools` como alternativa en Debian/Ubuntu si el primero no está disponible) y configura ~50% de la RAM como swap comprimida con zstd. También detecta particiones swap ya existentes pero no activadas (por ejemplo, restos de una instalación anterior/dual-boot) y las reporta; para activarlas también como respaldo extra:

```bash
ACTIVATE_EXTRA_SWAP=1 bash setup/setup-zram.sh
```

### 2. Ollama + modelos + Aider

```bash
bash setup/setup-llm-agents.sh
```

Si se corre en una terminal interactiva sin argumentos, muestra un menú para elegir el tamaño de los modelos. También se puede elegir sin menú:

```bash
bash setup/setup-llm-agents.sh --preset light
```

#### Presets disponibles

| Preset   | Planner              | Coder                 | RAM recomendada | Perfil de equipo |
|----------|----------------------|------------------------|------------------|-------------------|
| `light`  | qwen2.5-coder:3b      | qwen2.5-coder:7b       | ~16GB            | Laptop chica, GPU de 2-4GB VRAM o sin GPU |
| `medium` | qwen2.5-coder:7b      | qwen2.5-coder:14b      | ~32GB            | Equipo medio, GPU de 8GB+ VRAM |
| `heavy`  | qwen2.5-coder:14b     | qwen2.5-coder:32b      | ~64GB            | Equipo potente, GPU de 24GB+ VRAM |
| `max`    | qwen2.5-coder:32b     | qwen2.5-coder:32b      | ~48GB            | Mismo modelo en ambos roles: Ollama comparte los pesos entre los 2 slots concurrentes, pesa menos de lo que parece (~20GB), pero necesita CPU/GPU rápida |

Si la RAM detectada es menor a la recomendada para el preset elegido, el script avisa y pide confirmación antes de seguir (o solo avisa y continúa si no hay terminal interactiva).

También se pueden fijar modelos puntuales, ignorando los presets:

```bash
PLANNER_MODEL=qwen2.5-coder:14b CODER_MODEL=qwen2.5-coder:32b bash setup/setup-llm-agents.sh
```

Ver todas las opciones: `bash setup/setup-llm-agents.sh --help`

### 3. Usar los agentes

El script deja instalado un lanzador en `~/.local/bin/aider-local`. Parado en cualquier repo de código:

```bash
aider-local
```

Esto abre el chat de Aider en modo architect: el modelo *planner* razona el approach y el modelo *coder* genera los diffs que se aplican al código. Si `~/.local/bin` no está en el `PATH`, correr `~/.local/bin/aider-local` con la ruta completa, o agregar `export PATH="$HOME/.local/bin:$PATH"` al `.zshrc`/`.bashrc`.

## Troubleshooting

- **`pip` falla compilando `numpy` al instalar Aider**: sería el problema de Python > 3.11 descripto arriba. `setup-llm-agents.sh` ya lo evita usando `uv` con Python 3.11 fijo; si aparece igual, correr `uv python install 3.11 && uv tool install aider-chat --python 3.11 --force` a mano.
- **`sudo` pide contraseña y no la tenés / no arranca sesión**: si el sistema hace autologin y nunca la usaste, puede que directamente no la recuerdes. Se resetea reiniciando, editando la entrada de GRUB (`e`) para agregar `init=/bin/bash` al final de la línea `linux`, y una vez dentro: `mount -o remount,rw /`, `passwd <tu_usuario>`, `exec /sbin/init`. Es una edición de arranque temporal, no persiste.
- **Los scripts piden contraseña y quedan colgados**: no correrlos a través de un agente/herramienta sin terminal interactiva (`sudo` necesita TTY para leer la contraseña). Correrlos directo en una terminal normal.
