# =============================================================
#  Main.ps1 - Script Principal FTP
#  Practica 5 - Servidor FTP - Windows Server
#  Alumno: Laurean Acosta Luis Donaldo
#
#  USO: .\Main.ps1  (PowerShell como Administrador)
#
#  Estructura:
#    Main.ps1                 <- este archivo
#    lib\FuncionesComunes.ps1 <- utilidades compartidas
#    lib\FuncionesFTP.ps1     <- modulo FTP (IIS)
# =============================================================

$LIB = Join-Path $PSScriptRoot "lib"
. "$LIB\FuncionesComunes.ps1"
. "$LIB\FuncionesFTP.ps1"

Verificar-Admin
Menu-FTP
