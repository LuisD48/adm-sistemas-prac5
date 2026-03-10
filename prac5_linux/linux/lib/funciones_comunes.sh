#!/bin/bash
# =============================================================
#  lib/funciones_comunes.sh
#  Funciones utilitarias compartidas
#  Práctica 5 - Servidor FTP - OpenSUSE
# =============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
separador() { echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }
pausar()    { echo -ne "\nPresiona Enter para continuar..."; read -r; }

verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Ejecuta como root: sudo bash main.sh"
        exit 1
    fi
}

instalar_paquete() {
    local pkg="$1"
    if rpm -q "$pkg" &>/dev/null; then
        log_ok "Paquete '$pkg' ya instalado."
    else
        log_info "Instalando '$pkg'..."
        zypper --non-interactive install "$pkg" &>/dev/null
        [[ $? -eq 0 ]] && log_ok "'$pkg' instalado." || { log_error "Error instalando '$pkg'."; return 1; }
    fi
}

validar_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    (( o1<=255 && o2<=255 && o3<=255 && o4<=255 ))
}
