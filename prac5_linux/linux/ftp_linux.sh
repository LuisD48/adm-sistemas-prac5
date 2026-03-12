#!/bin/bash
# =================================================================
#  ftp_linux.sh - Gestion FTP - OpenSUSE Leap - vsftpd
#  Alumno: Laurean Acosta Luis Donaldo
#  Practica 5 - Administracion de Sistemas
#
#  USO: sudo bash ftp_linux.sh
# =================================================================

[ "$EUID" -ne 0 ] && echo "Ejecute como root: sudo bash ftp_linux.sh" && exit 1

# --- RUTAS Y VARIABLES GLOBALES ---
FTP_ROOT="/srv/ftp"
USERS_HOME="/home/ftp_users"
GRUPOS=("reprobados" "recursadores")

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
pausar()    { echo -ne "\nPresiona Enter para continuar..."; read -r; }

# =================================================================
# 1. INSTALAR Y CONFIGURAR VSFTPD (idempotente)
# =================================================================
instalar_configurar() {
    echo ""
    echo -e "${CYAN}${BOLD}=== Instalando y configurando vsftpd ===${NC}"

    # Instalacion idempotente
    if rpm -q vsftpd &>/dev/null; then
        log_ok "vsftpd ya instalado."
    else
        log_info "Instalando vsftpd..."
        zypper install -y vsftpd &>/dev/null && log_ok "vsftpd instalado." || {
            log_error "Error instalando vsftpd."; return 1
        }
    fi

    # Crear grupo ftp si no existe
    getent group ftp &>/dev/null || groupadd ftp

    # Crear grupos reprobados / recursadores
    for g in "${GRUPOS[@]}"; do
        if getent group "$g" &>/dev/null; then
            log_ok "Grupo '$g' ya existe."
        else
            groupadd "$g"
            log_ok "Grupo '$g' creado."
        fi
    done

    # -------------------------------------------------------
    # CARPETAS MAESTRAS (almacen real de datos)
    # -------------------------------------------------------
    mkdir -p "$FTP_ROOT/general"
    mkdir -p "$FTP_ROOT/reprobados"
    mkdir -p "$FTP_ROOT/recursadores"
    mkdir -p "$USERS_HOME"

    # /general: grupo ftp, todos los autenticados escriben (SGID)
    chown root:ftp "$FTP_ROOT/general"
    chmod 2775 "$FTP_ROOT/general"

    # /reprobados y /recursadores: solo su grupo escribe (SGID)
    chown root:reprobados "$FTP_ROOT/reprobados"
    chmod 2770 "$FTP_ROOT/reprobados"
    chown root:recursadores "$FTP_ROOT/recursadores"
    chmod 2770 "$FTP_ROOT/recursadores"

    # Carpeta raiz para anonimo (ve /general como carpeta, no como raiz)
    mkdir -p "$FTP_ROOT/anonimo/general"
    chown root:root "$FTP_ROOT/anonimo"
    chmod 755 "$FTP_ROOT/anonimo"

    # Bind mount: anonimo/general apunta a la misma carpeta real
    mountpoint -q "$FTP_ROOT/anonimo/general" || \
        mount --bind "$FTP_ROOT/general" "$FTP_ROOT/anonimo/general"
    grep -q "$FTP_ROOT/anonimo/general" /etc/fstab || \
        echo "$FTP_ROOT/general $FTP_ROOT/anonimo/general none bind 0 0" >> /etc/fstab

    log_ok "Carpetas maestras creadas en $FTP_ROOT"
    log_ok "Anonimo vera solo: /general (mismo contenido que usuarios autenticados)"

    # Shell de nologin permitida
    grep -q "^/sbin/nologin$" /etc/shells || echo "/sbin/nologin" >> /etc/shells

    # -------------------------------------------------------
    # CONFIGURACION VSFTPD.CONF
    # -------------------------------------------------------
    cat > /etc/vsftpd.conf <<EOF
# --- Modo de escucha ---
listen=YES
listen_ipv6=NO

# --- Acceso anonimo (ve carpeta /general) ---
anonymous_enable=YES
anon_root=$FTP_ROOT/anonimo
no_anon_password=YES
anon_upload_enable=NO
anon_mkdir_write_enable=NO

# --- Usuarios locales autenticados ---
local_enable=YES
write_enable=YES
local_umask=002
file_open_mode=0664

# --- Chroot: cada usuario ve solo su HOME ---
chroot_local_user=YES
allow_writeable_chroot=YES

# --- Seguridad y logs ---
dirmessage_enable=YES
use_localtime=YES
xferlog_enable=YES
connect_from_port_20=YES
pam_service_name=vsftpd
seccomp_sandbox=NO

# --- Modo pasivo (para FileZilla) ---
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
EOF

    log_ok "vsftpd.conf generado."

    # Firewall
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-service=ftp &>/dev/null
        firewall-cmd --permanent --add-port=40000-40100/tcp &>/dev/null
        firewall-cmd --reload &>/dev/null
        log_ok "Firewall configurado (puerto 21 + pasivos)."
    fi

    systemctl enable vsftpd &>/dev/null
    systemctl restart vsftpd

    if systemctl is-active --quiet vsftpd; then
        log_ok "Servicio vsftpd activo y corriendo."
    else
        log_error "vsftpd no inicio. Revisa: journalctl -u vsftpd"
    fi

    echo ""
    log_ok "Instalacion completada."
    log_ok "Anonimo ve: $FTP_ROOT/general (solo lectura)"
    log_ok "Autenticados ven: general/, su_grupo/, su_nombre/"
}

# =================================================================
# 2. CREAR USUARIOS
# Estructura visible por FTP al hacer login:
#   /general
#   /reprobados  o  /recursadores
#   /nombre_usuario
# =================================================================
crear_usuarios() {
    echo ""
    echo -e "${CYAN}${BOLD}=== Gestion de Usuarios FTP ===${NC}"

    echo -ne "Numero de usuarios a crear: "; read -r n
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 )); then
        log_error "Numero invalido."; return
    fi

    for (( i=1; i<=n; i++ )); do
        echo ""
        echo -e "${CYAN}--- Usuario $i de $n ---${NC}"

        # Nombre
        while true; do
            echo -ne "   > Nombre de usuario: "; read -r username
            [[ -z "$username" ]] && { log_error "No puede estar vacio."; continue; }
            break
        done

        # Contrasena
        while true; do
            echo -ne "   > Contrasena: "; read -rs password; echo
            [[ -z "$password" ]] && { log_error "No puede estar vacia."; continue; }
            echo -ne "   > Confirmar contrasena: "; read -rs password2; echo
            [[ "$password" != "$password2" ]] && { log_error "No coinciden."; continue; }
            break
        done

        # Grupo
        while true; do
            echo -ne "   > Grupo (reprobados / recursadores): "; read -r grupo
            grupo=$(echo "$grupo" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
            [[ "$grupo" == "reprobados" || "$grupo" == "recursadores" ]] && break
            log_error "Grupo invalido. Escribe 'reprobados' o 'recursadores'."
        done

        user_home="$USERS_HOME/$username"

        # Crear usuario del sistema
        if ! id "$username" &>/dev/null; then
            useradd -m -d "$user_home" \
                    -g "$grupo"        \
                    -G ftp             \
                    -s /sbin/nologin   \
                    "$username"
            log_ok "Usuario '$username' creado."
        else
            usermod -g "$grupo" -G ftp "$username"
            log_warn "Usuario '$username' ya existia. Grupos actualizados."
        fi
        echo "${username}:${password}" | chpasswd

        # Crear estructura de carpetas (puntos de montaje)
        mkdir -p "$user_home/general"
        mkdir -p "$user_home/$grupo"
        mkdir -p "$user_home/$username"

        # BIND MOUNTS: conectar vistas con almacen real
        mountpoint -q "$user_home/general" || \
            mount --bind "$FTP_ROOT/general" "$user_home/general"
        mountpoint -q "$user_home/$grupo" || \
            mount --bind "$FTP_ROOT/$grupo" "$user_home/$grupo"

        # Persistencia en fstab
        grep -q "$user_home/general" /etc/fstab || \
            echo "$FTP_ROOT/general $user_home/general none bind 0 0" >> /etc/fstab
        grep -q "$user_home/$grupo" /etc/fstab || \
            echo "$FTP_ROOT/$grupo $user_home/$grupo none bind 0 0" >> /etc/fstab

        # Permisos
        chown root:ftp "$user_home/general";       chmod 2775 "$user_home/general"
        chown root:"$grupo" "$user_home/$grupo";   chmod 2770 "$user_home/$grupo"
        chown "$username:$grupo" "$user_home/$username"; chmod 770 "$user_home/$username"

        # HOME raiz: root y no escribible (requisito chroot vsftpd)
        chown root:root "$user_home"
        chmod 755 "$user_home"

        log_ok "Usuario '$username' listo → grupo: $grupo"
        log_ok "  Vera al conectarse: /general, /$grupo, /$username"
    done
}

# =================================================================
# 3. CAMBIAR GRUPO DE USUARIO
# =================================================================
cambiar_grupo() {
    echo ""
    echo -e "${CYAN}${BOLD}=== Cambiar Grupo de Usuario ===${NC}"

    echo -ne "   > Nombre del usuario: "; read -r username
    if ! id "$username" &>/dev/null; then
        log_error "Usuario '$username' no existe."; return
    fi

    viejo_grupo=$(id -gn "$username")
    if [[ "$viejo_grupo" != "reprobados" && "$viejo_grupo" != "recursadores" ]]; then
        log_error "El usuario no pertenece a reprobados ni recursadores."; return
    fi

    log_info "Grupo actual: $viejo_grupo"

    while true; do
        echo -ne "   > Nuevo grupo (reprobados / recursadores): "; read -r nuevo_grupo
        nuevo_grupo=$(echo "$nuevo_grupo" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        [[ "$nuevo_grupo" == "reprobados" || "$nuevo_grupo" == "recursadores" ]] && break
        log_error "Grupo invalido."
    done

    if [[ "$nuevo_grupo" == "$viejo_grupo" ]]; then
        log_warn "Ya pertenece a '$nuevo_grupo'."; return
    fi

    user_home="$USERS_HOME/$username"

    # 1. Desmontar carpeta del grupo viejo
    log_info "Desvinculando '$viejo_grupo'..."
    fuser -km "$user_home/$viejo_grupo" 2>/dev/null
    sleep 1
    umount "$user_home/$viejo_grupo" 2>/dev/null || \
        umount -f "$user_home/$viejo_grupo" 2>/dev/null

    if mountpoint -q "$user_home/$viejo_grupo"; then
        log_error "No se pudo desmontar '$viejo_grupo'. Cierra la sesion FTP activa."
        return 1
    fi

    sed -i "\|$user_home/$viejo_grupo|d" /etc/fstab
    rm -rf "$user_home/$viejo_grupo"

    # 2. Cambiar grupo primario
    usermod -g "$nuevo_grupo" -G ftp "$username"

    # 3. Crear y montar nuevo grupo
    mkdir -p "$user_home/$nuevo_grupo"
    mount --bind "$FTP_ROOT/$nuevo_grupo" "$user_home/$nuevo_grupo"

    if ! mountpoint -q "$user_home/$nuevo_grupo"; then
        log_error "No se pudo montar '$nuevo_grupo'."; return 1
    fi

    echo "$FTP_ROOT/$nuevo_grupo $user_home/$nuevo_grupo none bind 0 0" >> /etc/fstab

    # 4. Permisos
    chown root:"$nuevo_grupo" "$user_home/$nuevo_grupo"
    chmod 2770 "$user_home/$nuevo_grupo"
    chown "$username:$nuevo_grupo" "$user_home/$username"

    log_ok "'$username' movido de '$viejo_grupo' a '$nuevo_grupo'."
    log_ok "Ahora vera: /general, /$nuevo_grupo, /$username"
}

# =================================================================
# 4. LISTAR USUARIOS
# =================================================================
listar_usuarios() {
    echo ""
    echo -e "${CYAN}${BOLD}=== Usuarios FTP ===${NC}"
    echo ""
    printf "${BOLD}%-15s %-15s %-12s${NC}\n" "USUARIO" "GRUPO" "MONTAJE"
    echo "-------------------------------------------"

    getent passwd | awk -F: -v home="$USERS_HOME" '$6 ~ home {print $1}' | \
    while read -r user; do
        grp=$(id -gn "$user" 2>/dev/null)
        if [[ "$grp" == "reprobados" || "$grp" == "recursadores" ]]; then
            mnt=$(mountpoint -q "$USERS_HOME/$user/$grp" \
                && echo -e "${GREEN}ACTIVO${NC}" \
                || echo -e "${RED}INACTIVO${NC}")
            printf "%-15s %-15s %-12s\n" "$user" "$grp" "$mnt"
        fi
    done

    echo ""
    log_info "Estructura de directorios en $USERS_HOME:"
    ls -la "$USERS_HOME" 2>/dev/null || log_warn "Directorio vacio."
}

# =================================================================
# 5. ESTADO DEL SERVICIO
# =================================================================
estado_servicio() {
    echo ""
    echo -e "${CYAN}${BOLD}=== Estado del Servicio FTP ===${NC}"
    systemctl status vsftpd --no-pager | head -12
    echo ""
    log_info "Puerto 21 en escucha:"
    ss -tlnp | grep ":21" || log_warn "Puerto 21 no detectado."
}

# =================================================================
# 6. BORRAR TODO
# =================================================================
borrar_todo() {
    echo ""
    echo -e "${RED}${BOLD}=== Borrar Todo ===${NC}"
    echo -ne "${YELLOW}Confirma borrado total? (s/N): ${NC}"; read -r confirm
    [[ "$confirm" != "s" && "$confirm" != "S" ]] && { log_warn "Cancelado."; return; }

    systemctl stop vsftpd

    # Desmontar todos los bind mounts
    mount | grep "$USERS_HOME" | awk '{print $3}' | \
        xargs -I{} umount -l {} 2>/dev/null

    # Limpiar fstab
    sed -i "\|$USERS_HOME|d" /etc/fstab

    # Eliminar usuarios FTP
    getent passwd | awk -F: -v home="$USERS_HOME" '$6 ~ home {print $1}' | \
    while read -r user; do
        grp=$(id -gn "$user" 2>/dev/null)
        if [[ "$grp" == "reprobados" || "$grp" == "recursadores" ]]; then
            userdel -r "$user" 2>/dev/null
            log_ok "Usuario '$user' eliminado."
        fi
    done

    # Eliminar directorios y grupos
    rm -rf "$USERS_HOME" "$FTP_ROOT"
    groupdel reprobados   2>/dev/null
    groupdel recursadores 2>/dev/null
    groupdel ftp          2>/dev/null

    log_ok "Limpieza completa."
}

# =================================================================
# MENU PRINCIPAL
# =================================================================
while true; do
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════╗"
    echo "║      GESTION FTP - vsftpd        ║"
    echo "║   Administracion de Sistemas     ║"
    echo "╠══════════════════════════════════╣"
    echo "║  1) Instalar y Configurar        ║"
    echo "║  2) Crear Usuarios               ║"
    echo "║  3) Cambiar Grupo de Usuario     ║"
    echo "║  4) Listar Usuarios              ║"
    echo "║  5) Estado del Servicio          ║"
    echo "║  6) Borrar Todo                  ║"
    echo "║  0) Salir                        ║"
    echo "╚══════════════════════════════════╝"
    echo -e "${NC}"
    echo -ne "Opcion [0-6]: "; read -r op
    case $op in
        1) instalar_configurar ;;
        2) crear_usuarios      ;;
        3) cambiar_grupo       ;;
        4) listar_usuarios     ;;
        5) estado_servicio     ;;
        6) borrar_todo         ;;
        0) echo -e "\n${GREEN}Saliendo...${NC}\n"; exit 0 ;;
        *) log_warn "Opcion no valida." ;;
    esac
    pausar
done
