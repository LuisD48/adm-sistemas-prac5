#!/bin/bash
# =============================================================
#  lib/funciones_ftp.sh
#  Gestión completa de vsftpd en OpenSUSE
#  Práctica 5 - Servidor FTP
# =============================================================

source "$(dirname "$0")/lib/funciones_comunes.sh"

# ── Variables globales ────────────────────────────────────────
FTP_ROOT="/srv/ftp"
FTP_GENERAL="${FTP_ROOT}/general"
FTP_REPROBADOS="${FTP_ROOT}/reprobados"
FTP_RECURSADORES="${FTP_ROOT}/recursadores"
VSFTPD_CONF="/etc/vsftpd.conf"
GRUPOS=("reprobados" "recursadores")

# ── Opción 1: Instalación idempotente ────────────────────────
ftp_instalar() {
    separador
    log_info "Verificando instalación de vsftpd..."

    instalar_paquete "vsftpd" || return

    # Crear grupos si no existen
    for grupo in "${GRUPOS[@]}"; do
        if ! getent group "$grupo" &>/dev/null; then
            groupadd "$grupo"
            log_ok "Grupo '$grupo' creado."
        else
            log_ok "Grupo '$grupo' ya existe."
        fi
    done

    # Crear estructura de directorios
    log_info "Creando estructura de directorios FTP..."
    mkdir -p "$FTP_GENERAL" "$FTP_REPROBADOS" "$FTP_RECURSADORES"

    # Permisos base
    chown root:root "$FTP_ROOT"
    chmod 755 "$FTP_ROOT"

    # /general — todos pueden leer, usuarios autenticados escribir
    chown root:root "$FTP_GENERAL"
    chmod 777 "$FTP_GENERAL"

    # Carpetas de grupo
    chown root:reprobados "$FTP_REPROBADOS"
    chmod 775 "$FTP_REPROBADOS"
    chown root:recursadores "$FTP_RECURSADORES"
    chmod 775 "$FTP_RECURSADORES"

    log_ok "Estructura creada:"
    log_ok "  ${FTP_ROOT}/general      → lectura anónima + escritura autenticados"
    log_ok "  ${FTP_ROOT}/reprobados   → escritura grupo reprobados"
    log_ok "  ${FTP_ROOT}/recursadores → escritura grupo recursadores"

    # Generar vsftpd.conf
    ftp_configurar_vsftpd

    # Habilitar e iniciar
    systemctl enable vsftpd &>/dev/null
    systemctl restart vsftpd
    if systemctl is-active --quiet vsftpd; then
        log_ok "Servicio vsftpd activo."
    else
        log_error "Error al iniciar vsftpd."
        journalctl -u vsftpd --no-pager | tail -5
    fi

    # Firewall
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --add-service=ftp --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_ok "Puerto 21 abierto en firewall."
    fi
}

# ── Generar vsftpd.conf ───────────────────────────────────────
ftp_configurar_vsftpd() {
    log_info "Generando configuración vsftpd..."
    cat > "$VSFTPD_CONF" <<'EOF'
# =============================================================
#  vsftpd.conf — Práctica 5 Administración de Sistemas
# =============================================================

# ── Acceso anónimo (solo lectura a /general) ──────────────────
anonymous_enable=YES
anon_root=/srv/ftp
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# ── Usuarios locales ──────────────────────────────────────────
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES

# ── Configuración general ─────────────────────────────────────
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
xferlog_std_format=YES
listen=YES
listen_ipv6=NO

# ── Seguridad ─────────────────────────────────────────────────
ftpd_banner=Bienvenido al Servidor FTP - Administración de Sistemas
userlist_enable=NO
tcp_wrappers=NO

# ── Modo pasivo ───────────────────────────────────────────────
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
EOF
    log_ok "vsftpd.conf generado."
}

# ── Opción 2: Gestión de usuarios ────────────────────────────
ftp_gestionar_usuarios() {
    separador
    echo -e "${BOLD}── Gestión de Usuarios FTP ────────────────────────${NC}"

    echo -ne "¿Cuántos usuarios deseas crear? "; read -r N
    if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 1 )); then
        log_error "Número inválido."; return
    fi

    for (( i=1; i<=N; i++ )); do
        echo ""
        echo -e "${CYAN}── Usuario $i de $N ─────────────────────────────────${NC}"

        # Nombre de usuario
        local usuario
        while true; do
            echo -ne "   > Nombre de usuario: "; read -r usuario
            if [[ -z "$usuario" ]]; then
                log_error "El nombre no puede estar vacío."; continue
            fi
            if id "$usuario" &>/dev/null; then
                log_warn "Usuario '$usuario' ya existe. ¿Sobreescribir? (s/n)"
                read -r RESP
                [[ "$RESP" =~ ^[Ss]$ ]] && break || continue
            fi
            break
        done

        # Contraseña
        local pass
        while true; do
            echo -ne "   > Contraseña: "; read -rs pass; echo
            [[ -z "$pass" ]] && { log_error "La contraseña no puede estar vacía."; continue; }
            echo -ne "   > Confirmar contraseña: "; read -rs pass2; echo
            [[ "$pass" != "$pass2" ]] && { log_error "Las contraseñas no coinciden."; continue; }
            break
        done

        # Grupo
        local grupo
        while true; do
            echo -e "   > Grupo: ${BOLD}[1]${NC} reprobados  ${BOLD}[2]${NC} recursadores"
            echo -ne "   Selecciona [1-2]: "; read -r GSEL
            case $GSEL in
                1) grupo="reprobados"; break ;;
                2) grupo="recursadores"; break ;;
                *) log_error "Opción inválida." ;;
            esac
        done

        ftp_crear_usuario "$usuario" "$pass" "$grupo"
    done
}

# ── Crear usuario con estructura de carpetas ──────────────────
ftp_crear_usuario() {
    local usuario="$1"
    local pass="$2"
    local grupo="$3"

    # Crear usuario del sistema si no existe
    if ! id "$usuario" &>/dev/null; then
        useradd -M -s /bin/false -G "$grupo" "$usuario"
    else
        usermod -G "$grupo" "$usuario"
    fi

    # Establecer contraseña
    echo "${usuario}:${pass}" | chpasswd

    # Estructura de carpetas del usuario dentro de FTP_ROOT
    # Al hacer login verá: general/, reprobados/ o recursadores/, nombre_usuario/
    local USER_HOME="${FTP_ROOT}"

    # Crear carpeta personal del usuario
    local USER_DIR="${FTP_ROOT}/${usuario}"
    mkdir -p "$USER_DIR"
    chown "${usuario}:${grupo}" "$USER_DIR"
    chmod 700 "$USER_DIR"

    # Crear archivo de bienvenida
    echo "Carpeta personal de ${usuario} — grupo ${grupo}" > "${USER_DIR}/bienvenida.txt"
    chown "${usuario}:${grupo}" "${USER_DIR}/bienvenida.txt"

    log_ok "Usuario '${usuario}' creado → grupo: ${grupo}"
    log_ok "  Carpeta personal: ${USER_DIR}"
    log_ok "  Acceso a: /general, /${grupo}, /${usuario}"
}

# ── Opción 3: Cambiar grupo de usuario ───────────────────────
ftp_cambiar_grupo() {
    separador
    echo -e "${BOLD}── Cambiar Grupo de Usuario ───────────────────────${NC}"

    echo -ne "   > Nombre de usuario: "; read -r usuario
    if ! id "$usuario" &>/dev/null; then
        log_error "Usuario '$usuario' no existe."; return
    fi

    local grupo_actual
    grupo_actual=$(id -gn "$usuario")
    log_info "Grupo actual: ${grupo_actual}"

    local nuevo_grupo
    echo -e "   > Nuevo grupo: ${BOLD}[1]${NC} reprobados  ${BOLD}[2]${NC} recursadores"
    echo -ne "   Selecciona [1-2]: "; read -r GSEL
    case $GSEL in
        1) nuevo_grupo="reprobados" ;;
        2) nuevo_grupo="recursadores" ;;
        *) log_error "Opción inválida."; return ;;
    esac

    if [[ "$grupo_actual" == "$nuevo_grupo" ]]; then
        log_warn "El usuario ya pertenece a '$nuevo_grupo'."; return
    fi

    # Cambiar grupo
    usermod -g "$nuevo_grupo" -G "$nuevo_grupo" "$usuario"

    # Mover carpeta personal al nuevo grupo
    local USER_DIR="${FTP_ROOT}/${usuario}"
    if [[ -d "$USER_DIR" ]]; then
        chown -R "${usuario}:${nuevo_grupo}" "$USER_DIR"
    fi

    log_ok "Usuario '${usuario}' movido de '${grupo_actual}' a '${nuevo_grupo}'."
    log_ok "Ahora tiene acceso a: /general, /${nuevo_grupo}, /${usuario}"
}

# ── Opción 4: Listar usuarios y estructura ───────────────────
ftp_listar() {
    separador
    log_info "Usuarios FTP por grupo:"
    echo ""

    for grupo in "${GRUPOS[@]}"; do
        echo -e "${BOLD}  Grupo: ${grupo}${NC}"
        local miembros
        miembros=$(getent group "$grupo" | cut -d: -f4)
        if [[ -z "$miembros" ]]; then
            echo "    (Sin usuarios)"
        else
            IFS=',' read -ra USERS <<< "$miembros"
            for u in "${USERS[@]}"; do
                echo "    → ${u}"
            done
        fi
        echo ""
    done

    echo -e "${BOLD}  Estructura de directorios:${NC}"
    if command -v tree &>/dev/null; then
        tree "$FTP_ROOT" -L 2
    else
        ls -la "$FTP_ROOT"
        for dir in "$FTP_ROOT"/*/; do
            echo "  $(basename $dir)/:"
            ls "  $dir" 2>/dev/null | sed 's/^/    /'
        done
    fi
}

# ── Opción 5: Estado del servicio ────────────────────────────
ftp_estado() {
    separador
    log_info "Estado del servicio vsftpd:"
    systemctl status vsftpd --no-pager | head -12
    echo ""
    log_info "Puerto 21 en escucha:"
    ss -tlnp | grep ":21" || log_warn "Puerto 21 no detectado."
}

# ── Opción 6: Dar de baja ────────────────────────────────────
ftp_baja() {
    separador
    echo -ne "${YELLOW}¿Confirmas dar de baja el servidor FTP? (s/n): ${NC}"
    read -r C
    [[ ! "$C" =~ ^[Ss]$ ]] && { log_warn "Cancelado."; return; }

    systemctl stop vsftpd
    systemctl disable vsftpd &>/dev/null
    log_ok "Servicio vsftpd detenido."

    echo -ne "¿Eliminar usuarios FTP creados? (s/n): "; read -r DEL
    if [[ "$DEL" =~ ^[Ss]$ ]]; then
        for grupo in "${GRUPOS[@]}"; do
            local miembros
            miembros=$(getent group "$grupo" | cut -d: -f4)
            IFS=',' read -ra USERS <<< "$miembros"
            for u in "${USERS[@]}"; do
                userdel "$u" 2>/dev/null
                rm -rf "${FTP_ROOT}/${u}"
                log_ok "Usuario '$u' eliminado."
            done
        done
    fi

    echo -ne "¿Desinstalar vsftpd? (s/n): "; read -r UNI
    [[ "$UNI" =~ ^[Ss]$ ]] && zypper --non-interactive remove vsftpd &>/dev/null && log_ok "vsftpd desinstalado."
}

# ── Menú FTP ──────────────────────────────────────────────────
menu_ftp() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}"
        echo "╔══════════════════════════════════════════════╗"
        echo "║   Administrador FTP - vsftpd - OpenSUSE      ║"
        echo "╚══════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  ${BOLD}1)${NC} Instalación Idempotente"
        echo -e "  ${BOLD}2)${NC} Gestión de Usuarios y Grupos"
        echo -e "  ${BOLD}3)${NC} Cambiar Grupo de Usuario"
        echo -e "  ${BOLD}4)${NC} Listar Usuarios y Estructura"
        echo -e "  ${BOLD}5)${NC} Estado del Servicio"
        echo -e "  ${BOLD}6)${NC} Dar de Baja FTP"
        echo -e "  ${BOLD}0)${NC} Salir"
        echo ""
        echo -ne "Opción [0-6]: "; read -r OPT
        case $OPT in
            1) ftp_instalar ;;
            2) ftp_gestionar_usuarios ;;
            3) ftp_cambiar_grupo ;;
            4) ftp_listar ;;
            5) ftp_estado ;;
            6) ftp_baja ;;
            0) echo -e "\n${GREEN}Saliendo...${NC}\n"; exit 0 ;;
            *) log_warn "Opción inválida." ;;
        esac
        pausar
    done
}
