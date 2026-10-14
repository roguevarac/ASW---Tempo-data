# Funciones compartidas por los scripts de Windows (se cargan con ". .\comun.ps1"). PowerShell 5.1 o superior.
$ErrorActionPreference = 'Continue'
$Raiz = Split-Path $PSScriptRoot -Parent
Set-Location $Raiz
$Utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Titulo($texto) { Write-Host ""; Write-Host "== $texto" -ForegroundColor Cyan }
# Une una carpeta con varios tramos (sin escribir separadores, sirve igual en Windows y en Linux).
function Unir($base) { foreach ($tramo in $args) { $base = Join-Path $base $tramo }; return $base }
function Ok($texto) { Write-Host $texto -ForegroundColor Green }
function Aviso($texto) { Write-Host $texto -ForegroundColor Yellow }
function Fallar($texto) {
    Write-Host ""
    Write-Host $texto -ForegroundColor Red
    Limpiar-Secretos
    Read-Host "Presiona Enter para cerrar" | Out-Null
    exit 1
}
function Preguntar-SiNo($texto) { return ((Read-Host "$texto (S/N)") -match '^\s*[sS]') }

function Limpiar-Secretos {
    foreach ($v in 'SUPABASE_SERVICE_KEY', 'PGURL') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
}

function Leer-Secreto($texto) {
    $seguro = Read-Host $texto -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($seguro)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Nueva-Clave {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------------------------------------------------------------- .env
function Ruta-Env { return (Join-Path $Raiz '.env') }
function Leer-Env {
    $valores = @{}
    if (Test-Path (Ruta-Env)) {
        foreach ($linea in [IO.File]::ReadAllLines((Ruta-Env), $Utf8)) {
            if ($linea -match '^\s*([A-Z_]+)=(.*)$') { $valores[$matches[1]] = $matches[2] }
        }
    }
    return $valores
}
function Poner-Env($clave, $valor) {
    $lineas = [Collections.Generic.List[string]]([IO.File]::ReadAllLines((Ruta-Env), $Utf8))
    $hecho = $false
    for ($i = 0; $i -lt $lineas.Count; $i++) {
        if ($lineas[$i] -match "^$clave=") { $lineas[$i] = "$clave=$valor"; $hecho = $true }
    }
    if (-not $hecho) { $lineas.Add("$clave=$valor") }
    [IO.File]::WriteAllLines((Ruta-Env), $lineas, $Utf8)
}
function Puerto { $p = (Leer-Env)['PUERTO']; if ($p) { return $p } else { return '8000' } }
function Direccion { return "http://localhost:$(Puerto)" }

# ---------------------------------------------------------------- Docker
function Verificar-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Fallar ("No esta instalado Docker Desktop.`n" +
                "Instalalo desde https://www.docker.com/products/docker-desktop/ (si la PC es de la empresa, pedilo a IT),`n" +
                "reinicia la PC, abri Docker Desktop una vez y volve a correr este archivo.")
    }
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { return }
    $exe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path $exe) { Write-Host "Abriendo Docker Desktop..."; Start-Process $exe }
    Write-Host "Esperando que Docker Desktop termine de arrancar (puede tardar un minuto)..."
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        docker info *> $null
        if ($LASTEXITCODE -eq 0) { return }
    }
    Fallar "Docker Desktop no arranco. Abrilo a mano, espera a que diga 'Engine running' y volve a correr este archivo."
}

function Esperar-Sistema {
    Write-Host "Esperando que el sistema responda en $(Direccion) ..."
    for ($i = 0; $i -lt 60; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$(Direccion)/health"
            if ($r.StatusCode -eq 200) { return }
        } catch { }
        Start-Sleep -Seconds 2
    }
    docker compose logs --tail 30 api
    Fallar "El sistema no responde. Arriba estan los ultimos mensajes de la API."
}

# Consulta SQL de solo lectura en la base nueva (dentro del contenedor, sin contraseña por el socket local).
function Consulta-Base($sql) {
    $salida = docker compose exec -T db psql -U postgres -d ranking -At -c $sql
    if ($LASTEXITCODE -ne 0) { Fallar "No se pudo consultar la base: $sql" }
    return $salida
}

# Corre admin/usuarios.py dentro del contenedor (la contraseña se escribe ahí, sin mostrarse).
# Se llama como instrucción (no dentro de una expresión) para que lo que pregunta se vea en pantalla;
# el resultado queda en $script:Codigo (0 = bien).
function Usuarios {
    $env:PGURL = "postgresql://postgres:$((Leer-Env)['POSTGRES_PASSWORD'])@db:5432/ranking"
    docker compose exec -e PGURL api python /app/admin/usuarios.py @args
    $script:Codigo = $LASTEXITCODE
    Remove-Item Env:PGURL -ErrorAction SilentlyContinue
}
