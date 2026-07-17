#!/usr/bin/env bash
# lib-common.sh — utilidades compartidas por los demás scripts de setup/.
# Se sourcea (`source "$DIR/lib-common.sh"`), no se ejecuta directo.

# Detecta la familia de gestor de paquetes del sistema actual.
# Salida: "arch" | "debian" | "unknown"
detect_pkg_family() {
    if command -v pacman >/dev/null 2>&1; then
        echo "arch"
    elif command -v apt-get >/dev/null 2>&1; then
        echo "debian"
    else
        echo "unknown"
    fi
}
