#!/bin/bash
# =============================================================
#  lib/funciones_ftp.sh
#  Gestion completa de vsftpd en OpenSUSE
#  Practica 5 - Servidor FTP
# =============================================================

source "$(dirname "$0")/lib/funciones_comunes.sh"

# Variables globales
FTP_ROOT="/srv/ftp"
FTP_GENERAL="${FTP_ROOT}/_general"
FTP_REPROBADOS="${FTP_ROOT}/_reprobados"
FTP_RECURSADORES="${FTP_ROOT}/_recursadores"
VSFTPD_CONF="/etc/vsftpd.conf"
GRUPOS=("reprobados" "recursadores")

# ── Opcion 1: Instalacion idempotente ─────────────────────────
ftp_instalar() {
    separador
    log_info "Verificando instalacion de vsftpd..."
    instalar_paquete "vsftpd" || return

    # Crear grupos
    for grupo in "${GRUPOS[@]}"; do
        if ! getent group "$grupo" &>/dev/null; then
            groupadd "$grupo"
            log_ok "Grupo '$grupo' creado."
        else
            log_ok "Grupo '$grupo' ya existe."
        fi
    done

    # Crear carpetas compartidas base
    mkdir -p "$FTP_GENERAL" "$FTP_REPROBADOS" "$FTP_RECURSADORES"
    chown root:root "$FTP_GENERAL";        chmod 777 "$FTP_GENERAL"
    chown root:reprobados "$FTP_REPROBADOS";   chmod 775 "$FTP_REPROBADOS"
    chown root:recursadores "$FTP_RECURSADORES"; chmod 775 "$FTP_RECURSADORES"

    log_ok "Carpetas compartidas:"
    log_ok "  ${FTP_GENERAL}      -> lectura anonima + escritura autenticados"
    log_ok "  ${FTP_REPROBADOS}   -> escritura grupo reprobados"
    log_ok "  ${FTP_RECURSADORES} -> escritura grupo recursadores"

    # Agregar /bin/false a shells permitidas
    grep -q "^/bin/false$" /etc/shells || echo "/bin/false" >> /etc/shells
    log_ok "/bin/false agregado a /etc/shells"

    # Crear archivo PAM
    mkdir -p /etc/pam.d
    cat > /etc/pam.d/ftp << 'EOF'
auth required pam_unix.so
account required pam_unix.so
session required pam_unix.so
EOF
    log_ok "Archivo PAM /etc/pam.d/ftp creado."

    # Generar vsftpd.conf
    ftp_configurar_vsftpd

    # Habilitar e iniciar
    systemctl enable vsftpd &>/dev/null
    systemctl restart vsftpd
    systemctl is-active --quiet vsftpd && log_ok "Servicio vsftpd activo." || {
        log_error "Error al iniciar vsftpd."
        journalctl -u vsftpd --no-pager | tail -5
    }

    # Firewall
    command -v firewall-cmd &>/dev/null && {
        firewall-cmd --add-service=ftp --permanent &>/dev/null
        firewall-cmd --add-port=40000-50000/tcp --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_ok "Puerto 21 y pasivos abiertos en firewall."
    }
}

# ── Generar vsftpd.conf ───────────────────────────────────────
ftp_configurar_vsftpd() {
    log_info "Generando vsftpd.conf..."
    cat > "$VSFTPD_CONF" << 'EOF'
# Acceso anonimo (solo lectura a _general)
anonymous_enable=YES
anon_root=/srv/ftp/_general
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO

# Usuarios locales
local_enable=YES
write_enable=YES
local_umask=022

# Chroot - cada usuario ve solo su directorio home
chroot_local_user=YES
allow_writeable_chroot=NO
passwd_chroot_enable=YES

# General
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
listen=YES
listen_ipv6=NO
ftpd_banner=Bienvenido al Servidor FTP - Administracion de Sistemas
userlist_enable=NO
tcp_wrappers=NO

# Modo pasivo
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=50000
EOF
    log_ok "vsftpd.conf generado."
}

# ── Crear usuario con estructura chroot ───────────────────────
ftp_crear_usuario() {
    local usuario="$1"
    local pass="$2"
    local grupo="$3"

    # Crear usuario del sistema
    if ! id "$usuario" &>/dev/null; then
        useradd -M -s /bin/false "$usuario"
    fi

    # Asignar grupo
    usermod -g "$grupo" -G "$grupo" "$usuario"

    # Establecer contrasena
    echo "${usuario}:${pass}" | chpasswd

    # Estructura chroot:
    # /srv/ftp/<usuario>/           <- chroot root (root:root 755)
    # /srv/ftp/<usuario>/general/   <- enlace a _general
    # /srv/ftp/<usuario>/<grupo>/   <- enlace a _<grupo>
    # /srv/ftp/<usuario>/<usuario>/ <- carpeta personal

    local USER_CHROOT="${FTP_ROOT}/${usuario}"

    mkdir -p "${USER_CHROOT}/${usuario}"
    chown root:root "${USER_CHROOT}"
    chmod 755 "${USER_CHROOT}"

    # Crear carpetas y aplicar bind mount (vsftpd no sigue symlinks en chroot)
    mkdir -p "${USER_CHROOT}/general"
    mkdir -p "${USER_CHROOT}/${grupo}"

    # Montar bind si no esta ya montado
    if ! mountpoint -q "${USER_CHROOT}/general"; then
        mount --bind "${FTP_GENERAL}" "${USER_CHROOT}/general"
    fi
    if ! mountpoint -q "${USER_CHROOT}/${grupo}"; then
        mount --bind "${FTP_ROOT}/_${grupo}" "${USER_CHROOT}/${grupo}"
    fi

    # Hacer los mounts persistentes en fstab
    grep -q "${USER_CHROOT}/general" /etc/fstab || \
        echo "${FTP_GENERAL} ${USER_CHROOT}/general none bind 0 0" >> /etc/fstab
    grep -q "${USER_CHROOT}/${grupo}" /etc/fstab || \
        echo "${FTP_ROOT}/_${grupo} ${USER_CHROOT}/${grupo} none bind 0 0" >> /etc/fstab

    # Carpeta personal
    chown "${usuario}:${grupo}" "${USER_CHROOT}/${usuario}"
    chmod 700 "${USER_CHROOT}/${usuario}"
    echo "Bienvenido ${usuario} - grupo ${grupo}" > "${USER_CHROOT}/${usuario}/bienvenida.txt"
    chown "${usuario}:${grupo}" "${USER_CHROOT}/${usuario}/bienvenida.txt"

    # Cambiar home del usuario a su chroot
    usermod -d "${USER_CHROOT}" "$usuario"

    log_ok "Usuario '${usuario}' creado -> grupo: ${grupo}"
    log_ok "  Al conectarse vera: /general, /${grupo}, /${usuario}"
}

# ── Opcion 2: Gestion de usuarios ────────────────────────────
ftp_gestionar_usuarios() {
    separador
    echo -e "${BOLD}-- Gestion de Usuarios FTP --------------------------${NC}"
    echo -ne "Cuantos usuarios deseas crear? "; read -r N
    if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 1 )); then
        log_error "Numero invalido."; return
    fi

    for (( i=1; i<=N; i++ )); do
        echo ""
        echo -e "${CYAN}-- Usuario $i de $N --${NC}"

        local usuario
        while true; do
            echo -ne "   > Nombre de usuario: "; read -r usuario
            [[ -z "$usuario" ]] && { log_error "No puede estar vacio."; continue; }
            break
        done

        local pass pass2
        while true; do
            echo -ne "   > Contrasena: "; read -rs pass; echo
            [[ -z "$pass" ]] && { log_error "No puede estar vacia."; continue; }
            echo -ne "   > Confirmar contrasena: "; read -rs pass2; echo
            [[ "$pass" != "$pass2" ]] && { log_error "No coinciden."; continue; }
            break
        done

        local grupo
        while true; do
            echo -ne "   > Grupo (reprobados / recursadores): "; read -r grupo
            grupo=$(echo "$grupo" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
            [[ "$grupo" == "reprobados" || "$grupo" == "recursadores" ]] && break
            log_error "Grupo invalido. Escribe 'reprobados' o 'recursadores'."
        done

        ftp_crear_usuario "$usuario" "$pass" "$grupo"
    done
}

# ── Opcion 3: Cambiar grupo ───────────────────────────────────
ftp_cambiar_grupo() {
    separador
    echo -ne "   > Nombre de usuario: "; read -r usuario
    if ! id "$usuario" &>/dev/null; then
        log_error "Usuario '$usuario' no existe."; return
    fi

    local grupo_actual; grupo_actual=$(id -gn "$usuario")
    log_info "Grupo actual: ${grupo_actual}"

    local nuevo_grupo
    while true; do
        echo -ne "   > Nuevo grupo (reprobados / recursadores): "; read -r nuevo_grupo
        nuevo_grupo=$(echo "$nuevo_grupo" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        [[ "$nuevo_grupo" == "reprobados" || "$nuevo_grupo" == "recursadores" ]] && break
        log_error "Grupo invalido."
    done

    [[ "$grupo_actual" == "$nuevo_grupo" ]] && { log_warn "Ya pertenece a '$nuevo_grupo'."; return; }

    usermod -g "$nuevo_grupo" -G "$nuevo_grupo" "$usuario"

    local USER_CHROOT="${FTP_ROOT}/${usuario}"

    # Desmontar carpeta de grupo anterior
    if mountpoint -q "${USER_CHROOT}/${grupo_actual}"; then
        umount "${USER_CHROOT}/${grupo_actual}"
    fi
    rm -rf "${USER_CHROOT}/${grupo_actual}"

    # Montar nueva carpeta de grupo
    mkdir -p "${USER_CHROOT}/${nuevo_grupo}"
    mount --bind "${FTP_ROOT}/_${nuevo_grupo}" "${USER_CHROOT}/${nuevo_grupo}"

    # Actualizar fstab
    sed -i "\|${USER_CHROOT}/${grupo_actual}|d" /etc/fstab
    grep -q "${USER_CHROOT}/${nuevo_grupo}" /etc/fstab || \
        echo "${FTP_ROOT}/_${nuevo_grupo} ${USER_CHROOT}/${nuevo_grupo} none bind 0 0" >> /etc/fstab

    # Mover carpeta personal al nuevo grupo
    chown -R "${usuario}:${nuevo_grupo}" "${USER_CHROOT}/${usuario}" 2>/dev/null

    log_ok "Usuario '${usuario}' movido de '${grupo_actual}' a '${nuevo_grupo}'."
    log_ok "Ahora ve: /general, /${nuevo_grupo}, /${usuario}"
}

# ── Opcion 4: Listar ─────────────────────────────────────────
ftp_listar() {
    separador
    log_info "Usuarios FTP por grupo:"
    echo ""
    for grupo in "${GRUPOS[@]}"; do
        echo -e "${BOLD}  Grupo: ${grupo}${NC}"
        local miembros; miembros=$(getent group "$grupo" | cut -d: -f4)
        if [[ -z "$miembros" ]]; then
            echo "    (Sin usuarios)"
        else
            IFS=',' read -ra USERS <<< "$miembros"
            for u in "${USERS[@]}"; do echo "    -> ${u}"; done
        fi
        echo ""
    done

    log_info "Estructura de directorios:"
    ls -la "$FTP_ROOT"
}

# ── Opcion 5: Estado ─────────────────────────────────────────
ftp_estado() {
    separador
    log_info "Estado del servicio vsftpd:"
    systemctl status vsftpd --no-pager | head -12
    echo ""
    log_info "Puerto 21 en escucha:"
    ss -tlnp | grep ":21" || log_warn "Puerto 21 no detectado."
}

# ── Opcion 6: Baja ───────────────────────────────────────────
ftp_baja() {
    separador
    echo -ne "${YELLOW}Confirmas dar de baja el FTP? (s/n): ${NC}"; read -r C
    [[ ! "$C" =~ ^[Ss]$ ]] && { log_warn "Cancelado."; return; }
    systemctl stop vsftpd; systemctl disable vsftpd &>/dev/null
    log_ok "Servicio vsftpd detenido."

    echo -ne "Eliminar usuarios FTP? (s/n): "; read -r DEL
    if [[ "$DEL" =~ ^[Ss]$ ]]; then
        for grupo in "${GRUPOS[@]}"; do
            local miembros; miembros=$(getent group "$grupo" | cut -d: -f4)
            IFS=',' read -ra USERS <<< "$miembros"
            for u in "${USERS[@]}"; do
                [[ -z "$u" ]] && continue
                userdel "$u" 2>/dev/null
                rm -rf "${FTP_ROOT}/${u}"
                log_ok "Usuario '$u' eliminado."
            done
        done
    fi

    echo -ne "Desinstalar vsftpd? (s/n): "; read -r UNI
    [[ "$UNI" =~ ^[Ss]$ ]] && zypper --non-interactive remove vsftpd &>/dev/null && log_ok "vsftpd desinstalado."
}

# ── Menu FTP ─────────────────────────────────────────────────
menu_ftp() {
    while true; do
        clear
        echo -e "${CYAN}${BOLD}"
        echo "╔══════════════════════════════════════════════╗"
        echo "║   Administrador FTP - vsftpd - OpenSUSE      ║"
        echo "╚══════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo -e "  ${BOLD}1)${NC} Instalacion Idempotente"
        echo -e "  ${BOLD}2)${NC} Gestion de Usuarios y Grupos"
        echo -e "  ${BOLD}3)${NC} Cambiar Grupo de Usuario"
        echo -e "  ${BOLD}4)${NC} Listar Usuarios y Estructura"
        echo -e "  ${BOLD}5)${NC} Estado del Servicio"
        echo -e "  ${BOLD}6)${NC} Dar de Baja FTP"
        echo -e "  ${BOLD}0)${NC} Salir"
        echo ""
        echo -ne "Opcion [0-6]: "; read -r OPT
        case $OPT in
            1) ftp_instalar ;;
            2) ftp_gestionar_usuarios ;;
            3) ftp_cambiar_grupo ;;
            4) ftp_listar ;;
            5) ftp_estado ;;
            6) ftp_baja ;;
            0) echo -e "\n${GREEN}Saliendo...${NC}\n"; exit 0 ;;
            *) log_warn "Opcion invalida." ;;
        esac
        pausar
    done
}
