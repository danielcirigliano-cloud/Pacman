# ============================================================
# PAC-MAN MUNDIALISTA ONLINE FIN-07 - LAN / IP PUBLICA
# ============================================================

$ErrorActionPreference = "Stop"
$Puerto = 8095
$NombreRegla = "PacMan Mundialista ONLINE $Puerto"

# AUTOELEVACION
$identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identidad)
$esAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $esAdmin) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host "Guarde este script como .ps1 y vuelva a ejecutarlo." -ForegroundColor Red
        Read-Host "ENTER para salir"
        exit 1
    }

    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy","Bypass",
        "-File","`"$PSCommandPath`""
    )
    exit
}

Clear-Host
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PAC-MAN MUNDIALISTA ONLINE FIN-07" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# CARPETA
$rutaOneDrive = Join-Path $env:USERPROFILE "OneDrive - grupocanuelas\Escritorio\PacMan_Mundialista"
$rutaDesktop  = Join-Path ([Environment]::GetFolderPath("Desktop")) "PacMan_Mundialista"

if ((Test-Path (Join-Path $rutaOneDrive "index.html")) -and
    (Test-Path (Join-Path $rutaOneDrive "PacMan_Mundialista_Online_Server.py"))) {
    $CarpetaJuego = $rutaOneDrive
}
elseif ((Test-Path (Join-Path $rutaDesktop "index.html")) -and
        (Test-Path (Join-Path $rutaDesktop "PacMan_Mundialista_Online_Server.py"))) {
    $CarpetaJuego = $rutaDesktop
}
elseif ((Test-Path (Join-Path $PSScriptRoot "index.html")) -and
        (Test-Path (Join-Path $PSScriptRoot "PacMan_Mundialista_Online_Server.py"))) {
    $CarpetaJuego = $PSScriptRoot
}
else {
    Write-Host ""
    Write-Host "[ERROR] Deben existir en la misma carpeta:" -ForegroundColor Red
    Write-Host "  index.html"
    Write-Host "  PacMan_Mundialista_Online_Server.py"
    Write-Host "  imagenes\..."
    Write-Host ""
    Read-Host "ENTER para salir"
    exit 1
}

Write-Host "[OK] Juego: $CarpetaJuego" -ForegroundColor Green

# PYTHON
if (Get-Command py -ErrorAction SilentlyContinue) {
    $PythonExe = "py"
}
elseif (Get-Command python -ErrorAction SilentlyContinue) {
    $PythonExe = "python"
}
else {
    Write-Host "[ERROR] Python no esta en PATH." -ForegroundColor Red
    Read-Host "ENTER para salir"
    exit 1
}

# RED
$ConfigRed = Get-NetIPConfiguration |
    Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.IPv4Address -ne $null } |
    Sort-Object InterfaceMetric |
    Select-Object -First 1

if (-not $ConfigRed) {
    Write-Host "[ERROR] No se detecto una interfaz IPv4 activa." -ForegroundColor Red
    Read-Host "ENTER para salir"
    exit 1
}

$IPLAN = $ConfigRed.IPv4Address.IPAddress
$Gateway = $ConfigRed.IPv4DefaultGateway.NextHop

# IP PUBLICA
$IPPublica = $null
foreach ($url in @("https://api.ipify.org","https://icanhazip.com")) {
    try {
        $r = (Invoke-RestMethod -Uri $url -TimeoutSec 5).ToString().Trim()
        if ($r -match '^\d{1,3}(\.\d{1,3}){3}$') {
            $IPPublica = $r
            break
        }
    } catch {}
}

# LIBERAR SOLO SERVIDORES PAC-MAN/PYTHON ANTERIORES DEL MISMO PUERTO
$Listeners = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
if ($Listeners) {
    foreach ($l in $Listeners) {
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$($l.OwningProcess)"
            $cmd = "$($proc.CommandLine)"
            if ($proc.Name -match 'python|py' -and
                ($cmd -match 'http\.server' -or $cmd -match 'PacMan_Mundialista_Online_Server\.py')) {
                Write-Host "[INFO] Deteniendo servidor Pac-Man anterior PID $($l.OwningProcess)..." -ForegroundColor Yellow
                Stop-Process -Id $l.OwningProcess -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 700
            }
        } catch {}
    }
}

if (Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue) {
    Write-Host "[ERROR] El puerto $Puerto sigue ocupado por otro proceso." -ForegroundColor Red
    Read-Host "ENTER para salir"
    exit 1
}

# FIREWALL
try {
    $rule = Get-NetFirewallRule -DisplayName $NombreRegla -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule `
            -DisplayName $NombreRegla `
            -Direction Inbound `
            -Action Allow `
            -Protocol TCP `
            -LocalPort $Puerto `
            -Profile Any | Out-Null
    } else {
        Set-NetFirewallRule -DisplayName $NombreRegla -Enabled True -Action Allow -Profile Any | Out-Null
    }
    Write-Host "[OK] Firewall Windows: TCP $Puerto habilitado." -ForegroundColor Green
}
catch {
    Write-Host "[ADVERTENCIA] No fue posible modificar Firewall: $($_.Exception.Message)" -ForegroundColor Yellow
}

$serverFile = Join-Path $CarpetaJuego "PacMan_Mundialista_Online_Server.py"

# START
if ($PythonExe -eq "py") {
    $Servidor = Start-Process `
        -FilePath "py" `
        -ArgumentList @("-3","`"$serverFile`"","--port","$Puerto","--root","`"$CarpetaJuego`"") `
        -WorkingDirectory $CarpetaJuego `
        -PassThru
}
else {
    $Servidor = Start-Process `
        -FilePath "python" `
        -ArgumentList @("`"$serverFile`"","--port","$Puerto","--root","`"$CarpetaJuego`"") `
        -WorkingDirectory $CarpetaJuego `
        -PassThru
}

# HEALTH
$UrlLocal = "http://127.0.0.1:$Puerto/"
$UrlLAN   = "http://${IPLAN}:$Puerto/"
$ok = $false

for ($i=0;$i -lt 20;$i++) {
    Start-Sleep -Milliseconds 350
    try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Puerto/api/status" -TimeoutSec 2
        if ($h.status -eq "ok") { $ok=$true; break }
    } catch {}
}

if (-not $ok) {
    Write-Host "[ERROR] El servidor no respondio al health check." -ForegroundColor Red
    Stop-Process -Id $Servidor.Id -Force -ErrorAction SilentlyContinue
    Read-Host "ENTER para salir"
    exit 1
}

Clear-Host
Write-Host "============================================================" -ForegroundColor Green
Write-Host " PAC-MAN MUNDIALISTA ONLINE ACTIVO" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "[OK] BUILD FIN-07 ONLINE"
Write-Host "[OK] HTTP + WebSocket"
Write-Host "[OK] Hasta 4 jugadores por sala"
Write-Host ""
Write-Host "IP LAN    : $IPLAN"
Write-Host "Gateway   : $Gateway"
Write-Host "Puerto    : $Puerto"
Write-Host "PID       : $($Servidor.Id)"
Write-Host ""
Write-Host "MISMA PC:" -ForegroundColor Yellow
Write-Host "  $UrlLocal" -ForegroundColor Cyan
Write-Host ""
Write-Host "MISMA RED / WI-FI:" -ForegroundColor Yellow
Write-Host "  $UrlLAN" -ForegroundColor Cyan
Write-Host ""

if ($IPPublica) {
    Write-Host "IP PUBLICA DETECTADA:" -ForegroundColor Yellow
    Write-Host "  http://${IPPublica}:$Puerto/" -ForegroundColor Magenta
    Write-Host ""
}

Write-Host "PARA INTERNET:" -ForegroundColor Yellow
Write-Host "  Router/NAT TCP $Puerto -> $IPLAN`:${Puerto}" -ForegroundColor White
Write-Host "  Si hay CGNAT o firewall del ISP/empresa, la IP publica directa puede no funcionar." -ForegroundColor White
Write-Host ""
Write-Host "Abrí el juego localmente. Esta ventana controla el servidor." -ForegroundColor White
Write-Host "Presione ENTER para APAGAR el servidor." -ForegroundColor Yellow

Start-Process $UrlLocal
Read-Host | Out-Null

Stop-Process -Id $Servidor.Id -Force -ErrorAction SilentlyContinue
Write-Host "[OK] Servidor detenido." -ForegroundColor Green
