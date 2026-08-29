# ============================================================
# PAC-MAN MUNDIALISTA - SERVIDOR LAN AUTOELEVADO
# ============================================================

$ErrorActionPreference = "Stop"

$Puerto = 8095
$NombreRegla = "PacMan Mundialista LAN $Puerto"

# ------------------------------------------------------------
# 0) AUTOELEVACION
# ------------------------------------------------------------
$identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identidad)
$esAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $esAdmin) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host ""
        Write-Host "ERROR: Este script debe ejecutarse desde un archivo .ps1 para poder autoelevarse." -ForegroundColor Red
        Write-Host "Guarde el archivo y ejecutelo nuevamente." -ForegroundColor Yellow
        Read-Host "Presione ENTER para salir"
        exit 1
    }

    Write-Host "Solicitando permisos de Administrador..." -ForegroundColor Yellow

    Start-Process powershell.exe `
        -Verb RunAs `
        -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`""
        )

    exit
}

Clear-Host
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PAC-MAN MUNDIALISTA - SERVIDOR LAN" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[OK] PowerShell ejecutandose como Administrador." -ForegroundColor Green

# ------------------------------------------------------------
# 1) LOCALIZAR JUEGO
# ------------------------------------------------------------
$rutaOneDrive = Join-Path $env:USERPROFILE "OneDrive - grupocanuelas\Escritorio\PacMan_Mundialista"
$rutaDesktop  = Join-Path ([Environment]::GetFolderPath("Desktop")) "PacMan_Mundialista"

if (Test-Path (Join-Path $rutaOneDrive "index.html")) {
    $CarpetaJuego = $rutaOneDrive
}
elseif (Test-Path (Join-Path $rutaDesktop "index.html")) {
    $CarpetaJuego = $rutaDesktop
}
else {
    Write-Host ""
    Write-Host "[ERROR] No se encontro index.html." -ForegroundColor Red
    Write-Host "Se busco en:" -ForegroundColor Yellow
    Write-Host "  $rutaOneDrive"
    Write-Host "  $rutaDesktop"
    Write-Host ""
    Read-Host "Presione ENTER para salir"
    exit 1
}

Write-Host "[OK] Juego encontrado:" -ForegroundColor Green
Write-Host "     $CarpetaJuego" -ForegroundColor White

# ------------------------------------------------------------
# 2) DETECTAR PYTHON
# ------------------------------------------------------------
$PythonExe = $null
$PythonArgs = @()

if (Get-Command py -ErrorAction SilentlyContinue) {
    $PythonExe = "py"
    $PythonArgs = @("-3")
}
elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonExe = "python"
}
else {
    Write-Host ""
    Write-Host "[ERROR] No se encontro Python (py/python) en PATH." -ForegroundColor Red
    Write-Host "Instale Python o agreguelo al PATH." -ForegroundColor Yellow
    Read-Host "Presione ENTER para salir"
    exit 1
}

Write-Host "[OK] Python detectado: $PythonExe" -ForegroundColor Green

# ------------------------------------------------------------
# 3) DETECTAR IPV4 LAN PRINCIPAL
# ------------------------------------------------------------
$ConfigRed = Get-NetIPConfiguration |
    Where-Object {
        $_.IPv4DefaultGateway -ne $null -and
        $_.IPv4Address -ne $null
    } |
    Sort-Object InterfaceMetric |
    Select-Object -First 1

if (-not $ConfigRed) {
    Write-Host ""
    Write-Host "[ERROR] No se detecto una interfaz IPv4 activa con gateway." -ForegroundColor Red
    Read-Host "Presione ENTER para salir"
    exit 1
}

$IP = $ConfigRed.IPv4Address.IPAddress
$AliasRed = $ConfigRed.InterfaceAlias

Write-Host "[OK] Red detectada: $AliasRed - $IP" -ForegroundColor Green

# ------------------------------------------------------------
# 4) VERIFICAR PUERTO
# ------------------------------------------------------------
$Escucha = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue

if ($Escucha) {
    Write-Host ""
    Write-Host "[ERROR] El puerto $Puerto ya esta ocupado." -ForegroundColor Red
    Write-Host "Proceso(s) detectado(s):" -ForegroundColor Yellow

    foreach ($c in $Escucha) {
        try {
            $p = Get-Process -Id $c.OwningProcess -ErrorAction Stop
            Write-Host "  PID $($c.OwningProcess) - $($p.ProcessName)"
        }
        catch {
            Write-Host "  PID $($c.OwningProcess)"
        }
    }

    Write-Host ""
    Write-Host "Cambie `$Puerto al inicio del script si necesita otro puerto." -ForegroundColor Yellow
    Read-Host "Presione ENTER para salir"
    exit 1
}

Write-Host "[OK] Puerto $Puerto disponible." -ForegroundColor Green

# ------------------------------------------------------------
# 5) FIREWALL
# ------------------------------------------------------------
try {
    $Regla = Get-NetFirewallRule -DisplayName $NombreRegla -ErrorAction SilentlyContinue

    if (-not $Regla) {
        New-NetFirewallRule `
            -DisplayName $NombreRegla `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Puerto `
            -Profile Domain,Private | Out-Null

        Write-Host "[OK] Regla de Firewall creada: $NombreRegla" -ForegroundColor Green
    }
    else {
        Set-NetFirewallRule `
            -DisplayName $NombreRegla `
            -Enabled True `
            -Action Allow `
            -Profile Domain,Private | Out-Null

        Write-Host "[OK] Regla de Firewall habilitada: $NombreRegla" -ForegroundColor Green
    }
}
catch {
    Write-Host ""
    Write-Host "[ADVERTENCIA] Windows no permitio modificar el Firewall." -ForegroundColor Yellow
    Write-Host "Motivo: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "El servidor igualmente intentara iniciar." -ForegroundColor Yellow
    Write-Host "Si localhost funciona pero otra PC no entra, la politica corporativa esta bloqueando el puerto." -ForegroundColor Yellow
    Write-Host ""
}

# ------------------------------------------------------------
# 6) INICIAR SERVIDOR HTTP
# ------------------------------------------------------------
Set-Location $CarpetaJuego

Write-Host ""
Write-Host "Iniciando servidor HTTP..." -ForegroundColor Cyan

if ($PythonExe -eq "py") {
    $Servidor = Start-Process `
        -FilePath "py" `
        -ArgumentList @("-3", "-m", "http.server", "$Puerto", "--bind", "0.0.0.0") `
        -WorkingDirectory $CarpetaJuego `
        -PassThru `
        -WindowStyle Hidden
}
else {
    $Servidor = Start-Process `
        -FilePath "python" `
        -ArgumentList @("-m", "http.server", "$Puerto", "--bind", "0.0.0.0") `
        -WorkingDirectory $CarpetaJuego `
        -PassThru `
        -WindowStyle Hidden
}

# ------------------------------------------------------------
# 7) HEALTH CHECK LOCAL
# ------------------------------------------------------------
$UrlLocal = "http://127.0.0.1:$Puerto/"
$UrlLAN   = "http://${IP}:$Puerto/"

$ServidorOK = $false

for ($i = 1; $i -le 15; $i++) {
    Start-Sleep -Milliseconds 400

    try {
        $respuesta = Invoke-WebRequest `
            -Uri $UrlLocal `
            -UseBasicParsing `
            -TimeoutSec 2

        if ($respuesta.StatusCode -eq 200) {
            $ServidorOK = $true
            break
        }
    }
    catch {
        # seguir intentando
    }
}

if (-not $ServidorOK) {
    Write-Host ""
    Write-Host "[ERROR] El servidor Python no respondio en $UrlLocal" -ForegroundColor Red

    if ($Servidor -and -not $Servidor.HasExited) {
        Stop-Process -Id $Servidor.Id -Force -ErrorAction SilentlyContinue
    }

    Read-Host "Presione ENTER para salir"
    exit 1
}

# ------------------------------------------------------------
# 8) RESULTADO
# ------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " SERVIDOR PAC-MAN ONLINE EN LA LAN" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "[OK] Health HTTP 200" -ForegroundColor Green
Write-Host ""
Write-Host "Carpeta : $CarpetaJuego"
Write-Host "Red     : $AliasRed"
Write-Host "IP      : $IP"
Write-Host "Puerto  : $Puerto"
Write-Host "PID     : $($Servidor.Id)"
Write-Host ""
Write-Host "ESTA PC:" -ForegroundColor Yellow
Write-Host "  $UrlLocal" -ForegroundColor Cyan
Write-Host ""
Write-Host "OTRAS PCs DE LA RED:" -ForegroundColor Yellow
Write-Host "  $UrlLAN" -ForegroundColor Cyan
Write-Host ""
Write-Host "La PC que publica el juego debe permanecer encendida." -ForegroundColor White
Write-Host "Esta ventana tambien debe permanecer abierta." -ForegroundColor White
Write-Host ""
Write-Host "Presione ENTER para apagar el servidor." -ForegroundColor Yellow
Write-Host ""

Start-Process $UrlLocal

Read-Host | Out-Null

# ------------------------------------------------------------
# 9) APAGADO
# ------------------------------------------------------------
if ($Servidor -and -not $Servidor.HasExited) {
    Stop-Process -Id $Servidor.Id -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "[OK] Servidor detenido." -ForegroundColor Green
Start-Sleep -Seconds 1

