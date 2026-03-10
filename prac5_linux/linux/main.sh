#!/bin/bash
# =============================================================
#  main.sh — Script Principal FTP
#  Práctica 5 - Servidor FTP - OpenSUSE
#  Alumno: Laureán Acosta Luis Donaldo
#
#  USO: sudo bash main.sh
#
#  Estructura:
#    main.sh                  ← este archivo
#    lib/funciones_comunes.sh ← utilidades compartidas
#    lib/funciones_ftp.sh     ← módulo FTP (vsftpd)
# =============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "${SCRIPT_DIR}/lib/funciones_comunes.sh"
source "${SCRIPT_DIR}/lib/funciones_ftp.sh"

verificar_root
menu_ftp
