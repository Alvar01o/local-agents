#!/usr/bin/env bash
# setup-zram.sh — configura swap comprimida en RAM (zram) como red de
# seguridad ante picos de memoria (relevante acá porque vamos a correr LLMs
# locales, que son intensivos en RAM).
#
# Qué hace:
#   1. Instala el generador de zram (paquete distinto según distro).
#   2. Crea zram0: ~50% de la RAM total, comprimido con zstd, activado en
#      cada arranque vía systemd.
#   3. Busca particiones ya formateadas como swap pero no activas (ej. resto
#      de un dual-boot) y las reporta; opcionalmente las activa como
#      respaldo secundario de menor prioridad que zram.
#
# Uso:
#   bash setup-zram.sh
#   ACTIVATE_EXTRA_SWAP=1 bash setup-zram.sh   # además activa particiones swap inactivas encontradas
#
# Requiere sudo interactivo (no correr desde un entorno sin TTY).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib-common.sh"

FAMILY="$(detect_pkg_family)"
ZRAM_BACKEND=""   # "generator" (systemd-zram-generator) o "zram-tools"

echo "== 1/4: Instalando el generador de zram (distro detectada: ${FAMILY}) =="
case "$FAMILY" in
    arch)
        if pacman -Qs '^zram-generator$' >/dev/null; then
            echo "zram-generator ya está instalado, salteando."
        else
            sudo pacman -S --noconfirm zram-generator
        fi
        ZRAM_BACKEND="generator"
        ;;
    debian)
        sudo apt-get update
        if apt-cache show systemd-zram-generator >/dev/null 2>&1; then
            sudo apt-get install -y systemd-zram-generator
            ZRAM_BACKEND="generator"
        else
            echo "systemd-zram-generator no está en tus repos, usando zram-tools como alternativa."
            sudo apt-get install -y zram-tools
            ZRAM_BACKEND="zram-tools"
        fi
        ;;
    *)
        echo "Distro no soportada automáticamente (ni pacman ni apt-get)." >&2
        echo "Instalá 'zram-generator' (o 'zram-tools') manualmente y volvé a correr este script si querés la detección de particiones swap." >&2
        exit 1
        ;;
esac

echo "== 2/4: Configurando zram =="
if [ "$ZRAM_BACKEND" = "generator" ]; then
    sudo tee /etc/systemd/zram-generator.conf > /dev/null <<'EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
EOF
    sudo systemctl daemon-reload
    sudo systemctl start systemd-zram-setup@zram0.service
else
    sudo tee /etc/default/zramswap > /dev/null <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
    sudo systemctl enable --now zramswap.service
fi

echo "== 3/4: Buscando particiones swap existentes que no estén activas =="
# Caso general del que salió esto: puede haber una partición ya formateada
# como swap (resto de otra instalación / dual-boot) que nadie activó.
mapfile -t INACTIVE_SWAPS < <(
    blkid -t TYPE=swap -o device 2>/dev/null | while read -r dev; do
        if ! swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$dev"; then
            echo "$dev"
        fi
    done
)

if [ "${#INACTIVE_SWAPS[@]}" -gt 0 ]; then
    echo "Encontradas particiones swap sin activar:"
    printf '  - %s\n' "${INACTIVE_SWAPS[@]}"
    if [ "${ACTIVATE_EXTRA_SWAP:-0}" = "1" ]; then
        for dev in "${INACTIVE_SWAPS[@]}"; do
            echo "Activando $dev como swap secundario (prioridad 10, por debajo de zram)..."
            sudo swapon -p 10 "$dev"
            if ! grep -qs "^$dev" /etc/fstab; then
                echo "$dev none swap sw,pri=10 0 0" | sudo tee -a /etc/fstab > /dev/null
            fi
        done
    else
        echo "No se activan automáticamente (zram ya cubre el caso general)."
        echo "Para activarlas también como respaldo extra, volvé a correr:"
        echo "  ACTIVATE_EXTRA_SWAP=1 bash $DIR/setup-zram.sh"
    fi
else
    echo "No se encontraron particiones swap inactivas."
fi

echo "== 4/4: Verificación =="
echo "--- swapon --show ---"
swapon --show
echo "--- free -h ---"
free -h

echo
echo "Listo. El swap quedará activo automáticamente en cada arranque."
