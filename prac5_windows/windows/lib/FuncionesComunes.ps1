# =============================================================
#  lib/FuncionesComunes.ps1
#  Funciones utilitarias compartidas
#  Práctica 5 - Servidor FTP - Windows Server
# =============================================================

function Log-Info  { param($m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Log-Ok    { param($m) Write-Host "[OK]    $m" -ForegroundColor Green }
function Log-Warn  { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Log-Error { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }
function Separador { Write-Host ("=" * 50) -ForegroundColor DarkGray }

function Verificar-Admin {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
        Log-Error "Ejecuta PowerShell como Administrador."
        exit 1
    }
}

function Pausar { Read-Host "`nPresiona Enter para continuar..." | Out-Null }

function Print-Banner {
    param([string]$Titulo, [string]$Sub = "")
    Clear-Host
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host ("║   " + $Titulo.PadRight(43) + "║") -ForegroundColor Cyan
    if ($Sub) { Write-Host ("║   " + $Sub.PadRight(43) + "║") -ForegroundColor Cyan }
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}
