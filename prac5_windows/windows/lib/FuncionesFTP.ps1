# =============================================================
#  lib/FuncionesFTP.ps1
#  Gestion completa de IIS FTP en Windows Server
#  Practica 5 - Servidor FTP
# =============================================================

. "$PSScriptRoot\FuncionesComunes.ps1"

# Variables globales
$script:FTP_ROOT    = "C:\inetpub\ftproot"
$script:FTP_GENERAL = "$($script:FTP_ROOT)\general"
$script:GRUPOS      = @("reprobados", "recursadores")
$script:SITE_NAME   = "FTP-Administracion"

# ── Opcion 1: Instalacion idempotente ─────────────────────────
function FTP-Instalar {
    Separador
    Log-Info "Verificando instalacion de IIS y FTP..."

    # Instalar IIS con FTP
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Service", "Web-Ftp-Extensibility")
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

    # Importar modulo WebAdministration
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Crear grupos locales
    foreach ($grupo in $script:GRUPOS) {
        $grp = Get-LocalGroup -Name $grupo -EA SilentlyContinue
        if (-not $grp) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP $grupo" | Out-Null
            Log-Ok "Grupo local '$grupo' creado."
        } else {
            Log-Ok "Grupo '$grupo' ya existe."
        }
    }

    # Crear estructura de directorios
    Log-Info "Creando estructura de directorios..."
    @($script:FTP_ROOT, $script:FTP_GENERAL) | ForEach-Object {
        if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
    }
    foreach ($grupo in $script:GRUPOS) {
        $dir = "$($script:FTP_ROOT)\$grupo"
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    Log-Ok "Estructura creada en: $($script:FTP_ROOT)"

    # Configurar permisos NTFS en /general (todos leen, autenticados escriben)
    FTP-ConfigurarPermisosGeneral

    # Crear sitio FTP en IIS
    FTP-CrearSitio

    # Reglas de firewall
    $regla = Get-NetFirewallRule -Name "FTP-Server" -EA SilentlyContinue
    if (-not $regla) {
        New-NetFirewallRule -Name "FTP-Server" -DisplayName "FTP Server" `
            -Direction Inbound -Protocol TCP -LocalPort 21 -Action Allow | Out-Null
        Log-Ok "Puerto 21 abierto en firewall."
    }

    # Puertos pasivos
    $reglaP = Get-NetFirewallRule -Name "FTP-Pasivo" -EA SilentlyContinue
    if (-not $reglaP) {
        New-NetFirewallRule -Name "FTP-Pasivo" -DisplayName "FTP Pasivo" `
            -Direction Inbound -Protocol TCP -LocalPort "40000-50000" -Action Allow | Out-Null
        Log-Ok "Puertos pasivos 40000-50000 abiertos."
    }
}

# ── Crear sitio FTP en IIS ────────────────────────────────────
function FTP-CrearSitio {
    Import-Module WebAdministration -EA SilentlyContinue

    $sitio = Get-WebSite -Name $script:SITE_NAME -EA SilentlyContinue
    if ($sitio) {
        Log-Ok "Sitio FTP '$($script:SITE_NAME)' ya existe."
        Start-WebSite -Name $script:SITE_NAME -EA SilentlyContinue
        return
    }

    Log-Info "Creando sitio FTP en IIS..."

    # Detener sitio Default si usa puerto 21
    $default = Get-WebSite | Where-Object { $_.Bindings.Collection.bindingInformation -like "*:21:*" }
    if ($default) { Stop-WebSite -Name $default.Name -EA SilentlyContinue }

    New-WebFtpSite -Name $script:SITE_NAME -Port 21 -PhysicalPath $script:FTP_ROOT -Force | Out-Null

    # Configurar autenticacion
    Set-ItemProperty "IIS:\Sites\$($script:SITE_NAME)" -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$($script:SITE_NAME)" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true

    # Acceso SSL (no requerido para laboratorio)
    Set-ItemProperty "IIS:\Sites\$($script:SITE_NAME)" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$($script:SITE_NAME)" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0

    # Habilitar aislamiento de usuario
    Set-ItemProperty "IIS:\Sites\$($script:SITE_NAME)" -Name ftpServer.userIsolation.mode -Value 3

    # Reglas de autorizacion FTP
    # Anonimo: solo lectura
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -Value @{accessType="Allow"; users=""; roles=""; permissions="Read"} `
        -PSPath "IIS:\" -Location "$($script:SITE_NAME)/general" -EA SilentlyContinue

    # Usuarios autenticados: lectura y escritura en general
    Add-WebConfiguration "/system.ftpServer/security/authorization" `
        -Value @{accessType="Allow"; users="*"; roles=""; permissions="Read,Write"} `
        -PSPath "IIS:\" -Location "$($script:SITE_NAME)/general" -EA SilentlyContinue

    Start-WebSite -Name $script:SITE_NAME
    Log-Ok "Sitio FTP '$($script:SITE_NAME)' creado e iniciado."
}

# ── Configurar permisos NTFS en /general ──────────────────────
function FTP-ConfigurarPermisosGeneral {
    $acl = Get-Acl $script:FTP_GENERAL

    # Todos leen
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Everyone", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.SetAccessRule($rule)

    # Usuarios autenticados escriben
    $rule2 = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Authenticated Users", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.SetAccessRule($rule2)

    Set-Acl -Path $script:FTP_GENERAL -AclObject $acl
    Log-Ok "Permisos NTFS configurados en /general."
}

# ── Opcion 2: Gestion de usuarios ────────────────────────────
function FTP-GestionarUsuarios {
    Separador
    Write-Host "-- Gestion de Usuarios FTP --" -ForegroundColor White
    Write-Host ""

    $n = Read-Host "Cuantos usuarios deseas crear?"
    if ($n -notmatch "^\d+$" -or [int]$n -lt 1) { Log-Error "Numero invalido."; return }

    for ($i = 1; $i -le [int]$n; $i++) {
        Write-Host ""
        Write-Host "-- Usuario $i de $n --" -ForegroundColor Cyan

        # Nombre
        do {
            $usuario = Read-Host "   > Nombre de usuario"
        } while ([string]::IsNullOrWhiteSpace($usuario))

        # Contrasena
        do {
            $pass1 = Read-Host "   > Contrasena" -AsSecureString
            $pass2 = Read-Host "   > Confirmar contrasena" -AsSecureString
            $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass1))
            $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass2))
            if ($p1 -ne $p2) { Log-Error "Las contrasenas no coinciden." }
        } while ($p1 -ne $p2)

        # Grupo
        do {
            Write-Host "   > Grupo: [1] reprobados  [2] recursadores" -ForegroundColor White
            $gsel = Read-Host "   Selecciona [1-2]"
            switch ($gsel) {
                "1" { $grupo = "reprobados"; $ok = $true }
                "2" { $grupo = "recursadores"; $ok = $true }
                default { Log-Error "Opcion invalida."; $ok = $false }
            }
        } while (-not $ok)

        FTP-CrearUsuario -Usuario $usuario -Pass $p1 -Grupo $grupo
    }
}

# ── Crear usuario con estructura de carpetas ──────────────────
function FTP-CrearUsuario {
    param([string]$Usuario, [string]$Pass, [string]$Grupo)

    # Crear usuario local
    $usr = Get-LocalUser -Name $Usuario -EA SilentlyContinue
    if (-not $usr) {
        $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
        New-LocalUser -Name $Usuario -Password $secPass -FullName "FTP $Usuario" `
            -Description "Usuario FTP grupo $Grupo" -PasswordNeverExpires | Out-Null
        Log-Ok "Usuario local '$Usuario' creado."
    } else {
        $secPass = ConvertTo-SecureString $Pass -AsPlainText -Force
        Set-LocalUser -Name $Usuario -Password $secPass
        Log-Warn "Usuario '$Usuario' ya existia. Contrasena actualizada."
    }

    # Agregar al grupo
    Add-LocalGroupMember -Group $Grupo -Member $Usuario -EA SilentlyContinue
    Log-Ok "Usuario '$Usuario' agregado al grupo '$Grupo'."

    # Crear carpeta personal
    $userDir = "$($script:FTP_ROOT)\$Usuario"
    if (-not (Test-Path $userDir)) {
        New-Item -ItemType Directory -Path $userDir -Force | Out-Null
    }

    # Permisos NTFS carpeta personal
    $acl = Get-Acl $userDir
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Usuario, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl -Path $userDir -AclObject $acl

    # Permisos en carpeta de grupo
    $grupoDir = "$($script:FTP_ROOT)\$Grupo"
    $aclG = Get-Acl $grupoDir
    $ruleG = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Usuario, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $aclG.AddAccessRule($ruleG)
    Set-Acl -Path $grupoDir -AclObject $aclG

    # Archivo de bienvenida
    "Carpeta personal de $Usuario - grupo $Grupo" | Out-File "$userDir\bienvenida.txt"

    Log-Ok "Estructura creada para '$Usuario':"
    Log-Ok "  Acceso a: \general, \$Grupo, \$Usuario"
}

# ── Opcion 3: Cambiar grupo ───────────────────────────────────
function FTP-CambiarGrupo {
    Separador
    $usuario = Read-Host "   > Nombre de usuario"
    $usr = Get-LocalUser -Name $usuario -EA SilentlyContinue
    if (-not $usr) { Log-Error "Usuario '$usuario' no existe."; return }

    # Grupo actual
    $grupoActual = ""
    foreach ($g in $script:GRUPOS) {
        $miembros = Get-LocalGroupMember -Group $g -EA SilentlyContinue | Select-Object -ExpandProperty Name
        if ($miembros -match $usuario) { $grupoActual = $g; break }
    }
    Log-Info "Grupo actual: $grupoActual"

    Write-Host "   > Nuevo grupo: [1] reprobados  [2] recursadores"
    $gsel = Read-Host "   Selecciona [1-2]"
    $nuevoGrupo = switch ($gsel) { "1" { "reprobados" } "2" { "recursadores" } default { "" } }
    if (-not $nuevoGrupo) { Log-Error "Opcion invalida."; return }

    if ($grupoActual -eq $nuevoGrupo) { Log-Warn "El usuario ya pertenece a '$nuevoGrupo'."; return }

    # Quitar del grupo anterior y agregar al nuevo
    if ($grupoActual) { Remove-LocalGroupMember -Group $grupoActual -Member $usuario -EA SilentlyContinue }
    Add-LocalGroupMember -Group $nuevoGrupo -Member $usuario -EA SilentlyContinue

    # Actualizar permisos en carpeta de grupo nuevo
    $grupoDir = "$($script:FTP_ROOT)\$nuevoGrupo"
    $aclG = Get-Acl $grupoDir
    $ruleG = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $usuario, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
    $aclG.AddAccessRule($ruleG)
    Set-Acl -Path $grupoDir -AclObject $aclG

    Log-Ok "Usuario '$usuario' movido de '$grupoActual' a '$nuevoGrupo'."
}

# ── Opcion 4: Listar usuarios ─────────────────────────────────
function FTP-Listar {
    Separador
    Log-Info "Usuarios FTP por grupo:"
    Write-Host ""

    foreach ($grupo in $script:GRUPOS) {
        Write-Host "  Grupo: $grupo" -ForegroundColor White
        $miembros = Get-LocalGroupMember -Group $grupo -EA SilentlyContinue
        if ($miembros) {
            $miembros | ForEach-Object { Write-Host "    -> $($_.Name.Split('\')[-1])" }
        } else { Write-Host "    (Sin usuarios)" }
        Write-Host ""
    }

    Log-Info "Estructura de directorios:"
    Get-ChildItem $script:FTP_ROOT | Format-Table Name, LastWriteTime, Attributes -AutoSize
}

# ── Opcion 5: Estado ──────────────────────────────────────────
function FTP-Estado {
    Separador
    Import-Module WebAdministration -EA SilentlyContinue
    Log-Info "Estado del sitio FTP:"
    $sitio = Get-WebSite -Name $script:SITE_NAME -EA SilentlyContinue
    if ($sitio) {
        Write-Host "  Nombre:  $($sitio.Name)"  -ForegroundColor Gray
        Write-Host "  Estado:  $($sitio.State)"  -ForegroundColor $(if ($sitio.State -eq "Started") {"Green"} else {"Red"})
        Write-Host "  Ruta:    $($sitio.PhysicalPath)" -ForegroundColor Gray
    } else { Log-Warn "Sitio FTP no encontrado." }

    Write-Host ""
    Log-Info "Puerto 21 en escucha:"
    netstat -an | Select-String ":21 "
}

# ── Opcion 6: Dar de baja ─────────────────────────────────────
function FTP-Baja {
    Separador
    $conf = Read-Host "Confirmas dar de baja el servidor FTP? (s/n)"
    if ($conf -notmatch "^[Ss]$") { Log-Warn "Cancelado."; return }

    Import-Module WebAdministration -EA SilentlyContinue
    Stop-WebSite -Name $script:SITE_NAME -EA SilentlyContinue
    Remove-WebSite -Name $script:SITE_NAME -EA SilentlyContinue
    Log-Ok "Sitio FTP eliminado."

    $del = Read-Host "Eliminar usuarios FTP creados? (s/n)"
    if ($del -match "^[Ss]$") {
        foreach ($grupo in $script:GRUPOS) {
            $miembros = Get-LocalGroupMember -Group $grupo -EA SilentlyContinue
            foreach ($m in $miembros) {
                $u = $m.Name.Split('\')[-1]
                Remove-LocalUser -Name $u -EA SilentlyContinue
                Remove-Item "$($script:FTP_ROOT)\$u" -Recurse -Force -EA SilentlyContinue
                Log-Ok "Usuario '$u' eliminado."
            }
        }
    }
}

# ── Menu FTP ──────────────────────────────────────────────────
function Menu-FTP {
    while ($true) {
        Print-Banner "Administrador FTP - IIS - Windows Server"
        Write-Host "  1) Instalacion Idempotente"
        Write-Host "  2) Gestion de Usuarios y Grupos"
        Write-Host "  3) Cambiar Grupo de Usuario"
        Write-Host "  4) Listar Usuarios y Estructura"
        Write-Host "  5) Estado del Servicio"
        Write-Host "  6) Dar de Baja FTP"
        Write-Host "  0) Salir"
        Write-Host ""
        $opt = Read-Host "Opcion [0-6]"
        switch ($opt) {
            "1" { FTP-Instalar }
            "2" { FTP-GestionarUsuarios }
            "3" { FTP-CambiarGrupo }
            "4" { FTP-Listar }
            "5" { FTP-Estado }
            "6" { FTP-Baja }
            "0" { Write-Host "`nSaliendo...`n" -ForegroundColor Green; exit 0 }
            default { Log-Warn "Opcion invalida." }
        }
        Pausar
    }
}
