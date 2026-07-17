#!/usr/bin/env bash
# setup-llm-agents.sh — instala el stack de agentes de código local completo:
# Ollama (server de inferencia) + un par de modelos Qwen2.5-Coder (planner +
# coder) + Aider (orquestador, corriendo en modo --architect) + un lanzador
# 'aider-local' que ya queda armado con esos dos modelos.
#
# Selección de modelos (ver también --help):
#   - Interactivo sin argumentos: muestra un menú de presets.
#   - `--preset light|medium|heavy|max`: elige un preset sin menú.
#   - `PLANNER_MODEL=... CODER_MODEL=...` (env vars): modelos custom, ignora presets.
#   Si la RAM de la máquina es menor a la recomendada para el preset, avisa
#   (y pide confirmación si hay terminal interactiva).
#
# Requiere sudo interactivo (no correr desde un entorno sin TTY) y que el
# daemon de Ollama pueda levantar en 127.0.0.1:11434.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib-common.sh"

AIDER_PYTHON="3.11"   # aider-chat fija numpy==1.24.3, sin wheel para Python > 3.11
FAMILY="$(detect_pkg_family)"

# Presets de tamaño de modelos (familia Qwen2.5-Coder). El planner razona/
# descompone la tarea, el coder es el que efectivamente escribe/edita código.
# Ver la tabla completa y el porqué de cada preset en el README.
PRESET_ORDER=(light medium heavy max)
declare -A PRESET_PLANNER=(
    [light]="qwen2.5-coder:3b"
    [medium]="qwen2.5-coder:7b"
    [heavy]="qwen2.5-coder:14b"
    [max]="qwen2.5-coder:32b"
)
declare -A PRESET_CODER=(
    [light]="qwen2.5-coder:7b"
    [medium]="qwen2.5-coder:14b"
    [heavy]="qwen2.5-coder:32b"
    [max]="qwen2.5-coder:32b"
)
declare -A PRESET_RAM_GB=(
    [light]=16
    [medium]=32
    [heavy]=64
    [max]=48
)
declare -A PRESET_DESC=(
    [light]="Equipos chicos (~16GB RAM, GPU de 2-4GB VRAM o sin GPU). Ej: esta laptop."
    [medium]="Equipos medios (~32GB RAM, o GPU de 8GB+ VRAM)."
    [heavy]="Equipos potentes (~64GB RAM, o GPU de 24GB+ VRAM)."
    [max]="Mismo modelo grande (32b) en ambos roles: Ollama comparte los pesos entre los 2 slots concurrentes, así que pesa menos de lo que parece (~20GB), pero necesita CPU/GPU rápida para que ande a velocidad usable."
)

print_help() {
    cat <<EOF
Uso: $0 [--preset light|medium|heavy|max]

Sin argumentos: si hay una terminal interactiva, muestra un menú para elegir.
Si no hay terminal (ej. corrido desde otro script) y no se pasó --preset,
usa 'light' por defecto.

También podés fijar modelos custom a mano, lo que ignora los presets:
    PLANNER_MODEL=qwen2.5-coder:14b CODER_MODEL=qwen2.5-coder:32b $0

Presets disponibles:
EOF
    for name in "${PRESET_ORDER[@]}"; do
        printf "  %-8s planner=%-20s coder=%-20s (~%sGB RAM)\n" \
            "$name" "${PRESET_PLANNER[$name]}" "${PRESET_CODER[$name]}" "${PRESET_RAM_GB[$name]}"
        echo "           ${PRESET_DESC[$name]}"
    done
}

# Resolución de modelos, en orden de prioridad:
#   1. PLANNER_MODEL/CODER_MODEL ya seteados (env vars) -> se usan tal cual.
#   2. --preset pasado por flag -> se resuelve contra las tablas de arriba.
#   3. Terminal interactiva sin nada de lo anterior -> menú.
#   4. Sin terminal y sin nada de lo anterior -> 'light' por defecto.
PRESET=""
PLANNER_MODEL="${PLANNER_MODEL:-}"
CODER_MODEL="${CODER_MODEL:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset)
            PRESET="$2"; shift 2 ;;
        --preset=*)
            PRESET="${1#*=}"; shift ;;
        -h|--help)
            print_help; exit 0 ;;
        *)
            echo "Argumento desconocido: $1" >&2
            print_help
            exit 1
            ;;
    esac
done

if [[ -n "$PLANNER_MODEL" && -n "$CODER_MODEL" ]]; then
    echo "Usando modelos custom (variables de entorno): planner=$PLANNER_MODEL coder=$CODER_MODEL"
elif [[ -n "$PRESET" ]]; then
    if [[ -z "${PRESET_PLANNER[$PRESET]:-}" ]]; then
        echo "Preset desconocido: '$PRESET' (opciones: ${PRESET_ORDER[*]})" >&2
        exit 1
    fi
elif [[ -t 0 ]]; then
    echo "Elegí el tamaño de modelos a instalar:"
    for i in "${!PRESET_ORDER[@]}"; do
        name="${PRESET_ORDER[$i]}"
        echo "  $((i + 1))) $name — ${PRESET_DESC[$name]}"
        echo "      planner=${PRESET_PLANNER[$name]}  coder=${PRESET_CODER[$name]}  (recomendado ~${PRESET_RAM_GB[$name]}GB RAM)"
    done
    read -rp "Opción [1-${#PRESET_ORDER[@]}] (default 1=light): " choice
    choice="${choice:-1}"
    idx=$((choice - 1))
    PRESET="${PRESET_ORDER[$idx]:-light}"
else
    echo "Sin terminal interactiva y sin --preset: usando 'light' por defecto."
    PRESET="light"
fi

if [[ -n "$PRESET" ]]; then
    PLANNER_MODEL="${PRESET_PLANNER[$PRESET]}"
    CODER_MODEL="${PRESET_CODER[$PRESET]}"
    echo "Preset elegido: $PRESET (planner=$PLANNER_MODEL coder=$CODER_MODEL)"

    RAM_GB=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024))
    REQUIRED_RAM="${PRESET_RAM_GB[$PRESET]}"
    if ((RAM_GB < REQUIRED_RAM)); then
        echo "ADVERTENCIA: el preset '$PRESET' recomienda ~${REQUIRED_RAM}GB de RAM y esta máquina tiene ${RAM_GB}GB." >&2
        if [[ -t 0 ]]; then
            read -rp "¿Continuar de todos modos? [y/N] " confirm
            [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
        else
            echo "Continuando de todas formas (sin TTY para confirmar)." >&2
        fi
    fi
fi

echo "== 1/5: Instalando Ollama (distro detectada: ${FAMILY}) =="
if command -v ollama >/dev/null 2>&1; then
    echo "ollama ya está instalado, salteando."
else
    case "$FAMILY" in
        arch)
            sudo pacman -S --noconfirm ollama
            ;;
        debian)
            # Ubuntu/Debian no traen ollama en sus repos oficiales;
            # se usa el instalador oficial (configura también el servicio systemd).
            curl -fsSL https://ollama.com/install.sh | sh
            ;;
        *)
            echo "Distro no soportada automáticamente. Instalá Ollama manualmente: https://ollama.com/download" >&2
            exit 1
            ;;
    esac
fi

echo "== 2/5: Habilitando y arrancando el servicio de Ollama =="
sudo systemctl enable --now ollama

# Esperar a que el daemon responda antes de pedir modelos
for i in $(seq 1 15); do
    if curl -s -o /dev/null http://127.0.0.1:11434; then
        break
    fi
    sleep 1
done

echo "== 3/5: Descargando modelos (esto puede tardar según tu conexión) =="
ollama pull "$PLANNER_MODEL"
ollama pull "$CODER_MODEL"

echo "== 4/5: Instalando uv y Aider =="
# Se usa 'uv' en vez de pipx porque permite fijar la versión de Python del
# entorno aislado de Aider, sin depender del Python por defecto del sistema.
# Esto evita que la instalación falle intentando compilar numpy==1.24.3
# (dependencia fija de aider-chat, sin wheel para Python > 3.11) en distros
# con Python muy nuevo, como Manjaro rolling (trae 3.14).
if command -v uv >/dev/null 2>&1; then
    echo "uv ya está instalado, salteando."
else
    case "$FAMILY" in
        arch)
            sudo pacman -S --noconfirm uv
            ;;
        debian)
            sudo apt-get update
            if apt-cache show uv >/dev/null 2>&1; then
                sudo apt-get install -y uv
            else
                curl -LsSf https://astral.sh/uv/install.sh | sh
                export PATH="$HOME/.local/bin:$PATH"
            fi
            ;;
        *)
            curl -LsSf https://astral.sh/uv/install.sh | sh
            export PATH="$HOME/.local/bin:$PATH"
            ;;
    esac
fi

uv python install "$AIDER_PYTHON"
uv tool install aider-chat --python "$AIDER_PYTHON" --force
uv tool update-shell

echo "== 5/5: Creando lanzador aider-local =="
# Wrapper fino sobre 'aider': fija el endpoint de Ollama y los dos modelos
# (architect=planner, editor=coder) para no tener que repetir los flags
# cada vez. Queda escrito con los valores ya resueltos arriba (no relee
# variables de entorno en cada ejecución).
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/aider-local" <<EOF
#!/usr/bin/env bash
export OLLAMA_API_BASE="http://127.0.0.1:11434"
exec aider --architect \\
    --model "ollama/${PLANNER_MODEL}" \\
    --editor-model "ollama/${CODER_MODEL}" \\
    "\$@"
EOF
chmod +x "$HOME/.local/bin/aider-local"

echo
echo "Listo."
echo "Modelos instalados: ${PLANNER_MODEL} (planner) + ${CODER_MODEL} (coder)"
echo "Si '~/.local/bin' está en tu PATH, corré desde cualquier repo: aider-local"
echo "Si no, corré: ~/.local/bin/aider-local"
