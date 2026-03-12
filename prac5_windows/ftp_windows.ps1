# =================================================================
#  ftp_windows.ps1 - Gestion FTP - Windows Server - IIS
#  Alumno: Laurean Acosta Luis Donaldo
#  Practica 5 - Administracion de Sistemas
#
#  USO: .\ftp_windows.ps1  (PowerShell como Administrador)
# =================================================================

# Verificar administrador
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "[ERROR] Ejecuta PowerShell como Administrador." -ForegroundColor Red
    exit 1
}

# --- RUTAS Y VARIABLES GLOBALES ---
$FTP_ROOT    = "C:\inetpub\ftproot"
$USERS_HOME  = "C:\ftp_users"
$SITE_NAME   = "FTP-Administracion"
$GRUPOS      = @("reprobados", "recursadores")

# Colores
function Log-Ok    { param($m) Write-Host "[OK]    $m" -ForegroundColor Green }
function Log-Info  { param($m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Log-Warn  { param($m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Log-Error { param($m) Write-Host "[ERROR] $m" -ForegroundColor Red }
function Pausar    { Read-Host "`nPresiona Enter para continuar..." | Out-Null }
function Separador { Write-Host ("=" * 50) -ForegroundColor DarkGray }

# =================================================================
# 1. INSTALAR Y CONFIGURAR IIS FTP (idempotente)
# =================================================================
function Instalar-Configurar {
    Separador
    Log-Info "Verificando instalacion de IIS y FTP..."

    # Instalar features necesarias
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service")
    foreach ($f in $features) {
        $feat = Get-WindowsFeature -Name $f
        if (-not $feat.Installed) {
            Log-Info "Instalando $f..."
            Install-WindowsFeature -Name $f | Out-Null
            Log-Ok "$f instalado."
        } else {
            Log-Ok "$f ya instalado."
        }
    }

    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Crear grupos locales
    foreach ($grupo in $GRUPOS) {
        $grp = Get-LocalGroup -Name $grupo -EA SilentlyContinue
        if (-not $grp) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo" | Out-Null
            Log-Ok "Grupo '$grupo' creado."
        } else {
            Log-Ok "Grupo '$grupo' ya existe."
        }
    }

    # Crear grupo ftp para acceso a general
    $grpFtp = Get-LocalGroup -Name "ftp" -EA SilentlyContinue
    if (-not $grpFtp) {
        New-LocalGroup -Name "ftp" -Description "Grupo FTP general" | Out-Null
        Log-Ok "Grupo 'ftp' creado."
    }

    # Crear estructura de carpetas
    Log-Info "Creando estructura de directorios..."
    @("$FTP_ROOT\general", "$FTP_ROOT\reprobados", "$FTP_ROOT\recursadores",
      "$FTP_ROOT\anonimo", "$USERS_HOME") | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

    # Crear carpeta anonimo\general (junction a general)
    $anonimoGeneral = "$FTP_ROOT\anonimo\general"
    if (-not (Test-Path $anonimoGeneral)) {
        New-Item -ItemType Junction -Path $anonimoGeneral -Target "$FTP_ROOT\general" | Out-Null
        Log-Ok "Junction anonimo\general -> general creado."
    }

    # Configurar permisos NTFS usando SIDs universales
    # /general: grupo ftp puede escribir
    $sidFtp = (Get-LocalGroup "ftp").SID
    Set-NtfsPermissions -Path "$FTP_ROOT\general" -Sid $sidFtp -Rights "Modify"

    # /reprobados y /recursadores: solo su grupo
    foreach ($grupo in $GRUPOS) {
        $sid = (Get-LocalGroup $grupo).SID
        Set-NtfsPermissions -Path "$FTP_ROOT\$grupo" -Sid $sid -Rights "Modify"
    }

    Log-Ok "Carpetas creadas:"
    Log-Ok "  $FTP_ROOT\general      -> lectura anonima + escritura autenticados"
    Log-Ok "  $FTP_ROOT\reprobados   -> escritura grupo reprobados"
    Log-Ok "  $FTP_ROOT\recursadores -> escritura grupo recursadores"
    Log-Ok "  $FTP_ROOT\anonimo      -> raiz anonimo (ve /general)"

    # Crear sitio FTP en IIS
    Crear-SitioFTP

    # Firewall
    $r1 = Get-NetFirewallRule -Name "FTP-21" -EA SilentlyContinue
    if (-not $r1) {
        New-NetFirewallRule -Name "FTP-21" -DisplayName "FTP Puerto 21" `
            -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Log-Ok "Puerto 21 abierto."
    }
    $r2 = Get-NetFirewallRule -Name "FTP-Pasivo" -EA SilentlyContinue
    if (-not $r2) {
        New-NetFirewallRule -Name "FTP-Pasivo" -DisplayName "FTP Pasivo" `
            -Direction Inbound -Protocol TCP -LocalPort "40000-40100" -Action Allow | Out-Null
        Log-Ok "Puertos pasivos 40000-40100 abiertos."
    }

    Log-Ok "Instalacion completada."
}

# ── Funcion auxiliar para permisos NTFS ──────────────────────
function Set-NtfsPermissions {
    param([string]$Path, $Sid, [string]$Rights)
    try {
        $acl = Get-Acl $Path
        $identity = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity, $Rights, "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($rule)
        Set-Acl -Path $Path -AclObject $acl
    } catch {
        Log-Warn "No se pudieron configurar permisos en $Path : $_"
    }
}

# ── Crear sitio FTP en IIS ────────────────────────────────────
function Crear-SitioFTP {
    Import-Module WebAdministration -EA SilentlyContinue

    $sitio = Get-WebSite -Name $SITE_NAME -EA SilentlyContinue
    if ($sitio) {
        Log-Ok "Sitio '$SITE_NAME' ya existe."
        Start-WebSite -Name $SITE_NAME -EA SilentlyContinue
        return
    }

    Log-Info "Creando sitio FTP en IIS..."

    New-WebFtpSite -Name $SITE_NAME -Port 21 -PhysicalPath $FTP_ROOT -Force | Out-Null

    # Autenticacion anonima y basica
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true

    # Sin SSL (laboratorio)
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy -Value 0

    # Aislamiento de usuario (cada uno ve su HOME)
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode -Value 3

    # Puertos pasivos
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.firewallSupport.lowDataChannelPort -Value 40000
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.firewallSupport.highDataChannelPort -Value 40100

    # Reglas de autorizacion
    # Anonimo: solo lectura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -Value @{accessType="Allow"; users=""; roles=""; permissions="Read"} `
        -PSPath "IIS:\" -Location $SITE_NAME -EA SilentlyContinue

    # Usuarios autenticados: leer y escribir
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -Value @{accessType="Allow"; users="*"; roles=""; permissions="Read,Write"} `
        -PSPath "IIS:\" -Location $SITE_NAME -EA SilentlyContinue

    Start-WebSite -Name $SITE_NAME -EA SilentlyContinue
    Log-Ok "Sitio '$SITE_NAME' creado e iniciado."
}

# =================================================================
# 2. CREAR USUARIOS
# =================================================================
function Crear-Usuarios {
    Separador
    Write-Host "`n[INFO]  === Gestion de Usuarios FTP ===" -ForegroundColor Cyan

    $n = Read-Host "Numero de usuarios a crear"
    if ($n -notmatch "^\d+$" -or [int]$n -lt 1) { Log-Error "Numero invalido."; return }

    for ($i = 1; $i -le [int]$n; $i++) {
        Write-Host "`n--- Usuario $i de $n ---" -ForegroundColor Cyan

        # Nombre
        do {
            $username = Read-Host "   > Nombre de usuario"
        } while ([string]::IsNullOrWhiteSpace($username))

        # Contrasena
        do {
            $p1 = Read-Host "   > Contrasena" -AsSecureString
            $p2 = Read-Host "   > Confirmar contrasena" -AsSecureString
            $ps1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p1))
            $ps2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p2))
            if ($ps1 -ne $ps2) { Log-Error "Las contrasenas no coinciden." }
        } while ($ps1 -ne $ps2)

        # Grupo
        do {
            $grupo = (Read-Host "   > Grupo (reprobados / recursadores)").Trim().ToLower()
            if ($grupo -ne "reprobados" -and $grupo -ne "recursadores") {
                Log-Error "Grupo invalido. Escribe 'reprobados' o 'recursadores'."
                $ok = $false
            } else { $ok = $true }
        } while (-not $ok)

        Crear-Usuario -Username $username -Pass $ps1 -Grupo $grupo
    }
}

# ── Crear usuario con estructura de carpetas ──────────────────
function Crear-Usuario {
    param([string]$Username, [string]$Pass, [string]$Grupo)

    # Crear usuario local
    $usr = Get-LocalUser -Name $Username -EA SilentlyContinue
    $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
    if (-not $usr) {
        New-LocalUser -Name $Username -Password $secPass `
            -FullName "FTP $Username" -PasswordNeverExpires | Out-Null
        Log-Ok "Usuario '$Username' creado."
    } else {
        Set-LocalUser -Name $Username -Password $secPass
        Log-Warn "Usuario '$Username' ya existia. Contrasena actualizada."
    }

    # Agregar a grupos
    Add-LocalGroupMember -Group $Grupo -Member $Username -EA SilentlyContinue
    Add-LocalGroupMember -Group "ftp" -Member $Username -EA SilentlyContinue

    # Estructura de carpetas del usuario
    # C:\ftp_users\<usuario>\          <- HOME raiz (chroot)
    # C:\ftp_users\<usuario>\general\  <- junction a general
    # C:\ftp_users\<usuario>\<grupo>\  <- junction a grupo
    # C:\ftp_users\<usuario>\<usuario>\<- carpeta personal

    $userHome = "$USERS_HOME\$Username"
    @($userHome, "$userHome\$Username") | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }

    # Junctions (equivalente a bind mount en Windows)
    $genJunction = "$userHome\general"
    if (-not (Test-Path $genJunction)) {
        New-Item -ItemType Junction -Path $genJunction -Target "$FTP_ROOT\general" | Out-Null
    }

    $grpJunction = "$userHome\$Grupo"
    if (-not (Test-Path $grpJunction)) {
        New-Item -ItemType Junction -Path $grpJunction -Target "$FTP_ROOT\$Grupo" | Out-Null
    }

    # Permisos NTFS carpeta personal
    $sidUser = (Get-LocalUser $Username).SID
    Set-NtfsPermissions -Path "$userHome\$Username" -Sid $sidUser -Rights "Modify"

    # Permisos HOME raiz (solo lectura para el usuario — IIS requiere esto)
    $acl = Get-Acl $userHome
    $acl.SetAccessRuleProtection($true, $false)
    $sidAdmin = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
    $ruleAdmin = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidAdmin, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($ruleAdmin)
    $ruleUser = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $sidUser, "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($ruleUser)
    Set-Acl -Path $userHome -AclObject $acl

    # Archivo de bienvenida
    "Bienvenido $Username - grupo $Grupo" | Out-File "$userHome\$Username\bienvenida.txt"

    # Registrar usuario en IIS FTP con su home
    Import-Module WebAdministration -EA SilentlyContinue
    $vtPath = "IIS:\Sites\$SITE_NAME\$Username"
    if (-not (Test-Path $vtPath -EA SilentlyContinue)) {
        New-Item $vtPath -PhysicalPath $userHome -Type VirtualDirectory -EA SilentlyContinue | Out-Null
    }

    Log-Ok "Usuario '$Username' listo -> grupo: $Grupo"
    Log-Ok "  Al conectarse vera: \general, \$Grupo, \$Username"
}

# =================================================================
# 3. CAMBIAR GRUPO DE USUARIO
# =================================================================
function Cambiar-Grupo {
    Separador
    $username = Read-Host "   > Nombre del usuario"
    $usr = Get-LocalUser -Name $username -EA SilentlyContinue
    if (-not $usr) { Log-Error "Usuario '$username' no existe."; return }

    # Detectar grupo actual
    $grupoActual = ""
    foreach ($g in $GRUPOS) {
        $miembros = Get-LocalGroupMember -Group $g -EA SilentlyContinue | Select-Object -ExpandProperty Name
        if ($miembros -match $username) { $grupoActual = $g; break }
    }
    Log-Info "Grupo actual: $grupoActual"

    do {
        $nuevoGrupo = (Read-Host "   > Nuevo grupo (reprobados / recursadores)").Trim().ToLower()
        if ($nuevoGrupo -ne "reprobados" -and $nuevoGrupo -ne "recursadores") {
            Log-Error "Grupo invalido."; $ok = $false
        } else { $ok = $true }
    } while (-not $ok)

    if ($grupoActual -eq $nuevoGrupo) { Log-Warn "Ya pertenece a '$nuevoGrupo'."; return }

    # Quitar del grupo anterior
    if ($grupoActual) {
        Remove-LocalGroupMember -Group $grupoActual -Member $username -EA SilentlyContinue
    }

    # Agregar al nuevo grupo
    Add-LocalGroupMember -Group $nuevoGrupo -Member $username -EA SilentlyContinue

    # Actualizar junction de grupo en home del usuario
    $userHome = "$USERS_HOME\$username"
    $oldJunction = "$userHome\$grupoActual"
    $newJunction = "$userHome\$nuevoGrupo"

    if (Test-Path $oldJunction) {
        Remove-Item $oldJunction -Force -Recurse
    }
    if (-not (Test-Path $newJunction)) {
        New-Item -ItemType Junction -Path $newJunction -Target "$FTP_ROOT\$nuevoGrupo" | Out-Null
    }

    Log-Ok "'$username' movido de '$grupoActual' a '$nuevoGrupo'."
    Log-Ok "Ahora vera: \general, \$nuevoGrupo, \$username"
}

# =================================================================
# 4. LISTAR USUARIOS
# =================================================================
function Listar-Usuarios {
    Separador
    Write-Host "`n  Usuarios FTP por grupo:`n" -ForegroundColor Cyan

    foreach ($grupo in $GRUPOS) {
        Write-Host "  Grupo: $grupo" -ForegroundColor White
        $miembros = Get-LocalGroupMember -Group $grupo -EA SilentlyContinue
        if ($miembros) {
            $miembros | ForEach-Object {
                $u = $_.Name.Split('\')[-1]
                Write-Host "    -> $u"
            }
        } else { Write-Host "    (Sin usuarios)" }
        Write-Host ""
    }

    Write-Host "  Estructura de directorios:" -ForegroundColor Cyan
    if (Test-Path $USERS_HOME) {
        Get-ChildItem $USERS_HOME | Format-Table Name, LastWriteTime -AutoSize
    }
}

# =================================================================
# 5. ESTADO DEL SERVICIO
# =================================================================
function Estado-Servicio {
    Separador
    Import-Module WebAdministration -EA SilentlyContinue
    Log-Info "Estado del sitio FTP:"
    $sitio = Get-WebSite -Name $SITE_NAME -EA SilentlyContinue
    if ($sitio) {
        $color = if ($sitio.State -eq "Started") { "Green" } else { "Red" }
        Write-Host "  Nombre:  $($sitio.Name)" -ForegroundColor Gray
        Write-Host "  Estado:  $($sitio.State)" -ForegroundColor $color
        Write-Host "  Ruta:    $($sitio.PhysicalPath)" -ForegroundColor Gray
    } else { Log-Warn "Sitio FTP no encontrado." }

    Write-Host ""
    Log-Info "Puerto 21 en escucha:"
    netstat -an | Select-String ":21 "
}

# =================================================================
# 6. BORRAR TODO
# =================================================================
function Borrar-Todo {
    Separador
    $confirm = Read-Host "Confirmas borrado total? (s/N)"
    if ($confirm -notmatch "^[Ss]$") { Log-Warn "Cancelado."; return }

    Import-Module WebAdministration -EA SilentlyContinue
    Stop-WebSite -Name $SITE_NAME -EA SilentlyContinue
    Remove-WebSite -Name $SITE_NAME -EA SilentlyContinue
    Log-Ok "Sitio FTP eliminado."

    # Eliminar usuarios
    foreach ($grupo in $GRUPOS) {
        $miembros = Get-LocalGroupMember -Group $grupo -EA SilentlyContinue
        foreach ($m in $miembros) {
            $u = $m.Name.Split('\')[-1]
            Remove-LocalUser -Name $u -EA SilentlyContinue
            Log-Ok "Usuario '$u' eliminado."
        }
    }

    # Eliminar carpetas y grupos
    Remove-Item $USERS_HOME -Recurse -Force -EA SilentlyContinue
    Remove-Item $FTP_ROOT -Recurse -Force -EA SilentlyContinue
    foreach ($grupo in $GRUPOS) {
        Remove-LocalGroup -Name $grupo -EA SilentlyContinue
    }
    Remove-LocalGroup -Name "ftp" -EA SilentlyContinue

    Log-Ok "Limpieza completa."
}

# =================================================================
# MENU PRINCIPAL
# =================================================================
while ($true) {
    Clear-Host
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║     GESTION FTP - IIS Windows Server ║" -ForegroundColor Cyan
    Write-Host "║     Administracion de Sistemas       ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  1) Instalar y Configurar            ║" -ForegroundColor Cyan
    Write-Host "║  2) Crear Usuarios                   ║" -ForegroundColor Cyan
    Write-Host "║  3) Cambiar Grupo de Usuario         ║" -ForegroundColor Cyan
    Write-Host "║  4) Listar Usuarios                  ║" -ForegroundColor Cyan
    Write-Host "║  5) Estado del Servicio              ║" -ForegroundColor Cyan
    Write-Host "║  6) Borrar Todo                      ║" -ForegroundColor Cyan
    Write-Host "║  0) Salir                            ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    $op = Read-Host "Opcion [0-6]"
    switch ($op) {
        "1" { Instalar-Configurar }
        "2" { Crear-Usuarios }
        "3" { Cambiar-Grupo }
        "4" { Listar-Usuarios }
        "5" { Estado-Servicio }
        "6" { Borrar-Todo }
        "0" { Write-Host "`nSaliendo...`n" -ForegroundColor Green; exit 0 }
        default { Log-Warn "Opcion no valida." }
    }
    Pausar
}
