# Funciones compartidas por los scripts de Windows (se cargan con ". .\comun.ps1"). PowerShell 5.1 o superior.
# Version portable: PostgreSQL y Python corren desde una carpeta del usuario, sin instalar nada ni ser administrador.
#   %LOCALAPPDATA%\RankingDigital\
#       runtime\pgsql, runtime\python   componentes (se bajan una vez, verificados por sha256)
#       app\                            copia del programa (api, front, db, ...)
#       datos\pg, datos\archivos        base de datos y archivos del historial (fuera de OneDrive a proposito)
#       logs\, config.env               registros y claves internas (generadas al azar)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # en Windows PowerShell 5.1 la barra de progreso vuelve lentisimas las descargas
$Raiz = Split-Path $PSScriptRoot -Parent
$Utf8 = New-Object System.Text.UTF8Encoding($false)
$EsWindows = ($env:OS -eq 'Windows_NT')
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# Une una carpeta con varios tramos (sin escribir separadores, sirve igual en Windows y en Linux).
function Unir($base) { foreach ($tramo in $args) { $base = Join-Path $base $tramo }; return $base }

# ---------------------------------------------------------------- componentes (versiones fijas y verificadas)
$Componentes = @{
    python = @{ Archivo = 'python.3.12.10.nupkg'; Sha256 = '0eb85c2dfccccf1b17352de4c397f69194035b7d37149eacc16f1147d93de3b8'
                Url = 'https://api.nuget.org/v3-flatcontainer/python/3.12.10/python.3.12.10.nupkg'; Dentro = 'tools' }
    pgsql  = @{ Archivo = 'windows-x64-17.10.0-beta.17.tgz'; Sha256 = '262161722259e884ec238d9dfb163fec84b9f474649e207238af97b7fcdf62f7'
                Url = 'https://registry.npmjs.org/@embedded-postgres/windows-x64/-/windows-x64-17.10.0-beta.17.tgz'; Dentro = 'package/native' }
}

# ---------------------------------------------------------------- carpetas
$Inst = Unir $env:LOCALAPPDATA 'RankingDigital'
$Runtime = Unir $Inst 'runtime'
$PgDir = Unir $Runtime 'pgsql'
$PyDir = Unir $Runtime 'python'
$PyExe = Unir $PyDir 'python.exe'
$PywExe = Unir $PyDir 'pythonw.exe'
$PgCtl = Unir $PgDir 'bin' 'pg_ctl.exe'
$Initdb = Unir $PgDir 'bin' 'initdb.exe'
$App = Unir $Inst 'app'
$Datos = Unir $Inst 'datos'
$PgData = Unir $Datos 'pg'
$Archivos = Unir $Datos 'archivos'
$Logs = Unir $Inst 'logs'
$Config = Unir $Inst 'config.env'
$Exportacion = Unir $Inst 'exportacion'
$Descargas = Unir $Inst 'descargas'

function Titulo($texto) { Write-Host ""; Write-Host "== $texto" -ForegroundColor Cyan }
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
    foreach ($v in 'SUPABASE_SERVICE_KEY', 'PGURL', 'AUTHENTICATOR_PASSWORD', 'DATABASE_URL', 'JWT_SECRET') {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
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

function Sha256($ruta) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $ruta).Hash.ToLower() }

# Opciones para que los procesos de fondo no abran ventana (en Linux, donde se prueban, no existe la opcion).
function Oculto { if ($EsWindows) { return @{ WindowStyle = 'Hidden' } } else { return @{} } }

# ---------------------------------------------------------------- configuracion (claves internas)
function Leer-Config {
    $valores = @{}
    if (Test-Path $Config) {
        foreach ($linea in [IO.File]::ReadAllLines($Config, $Utf8)) {
            if ($linea -match '^\s*([A-Z_]+)=(.*)$') { $valores[$matches[1]] = $matches[2] }
        }
    }
    return $valores
}
function Poner-Config($clave, $valor) {
    $lineas = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path $Config) { foreach ($l in [IO.File]::ReadAllLines($Config, $Utf8)) { $lineas.Add($l) } }
    $hecho = $false
    for ($i = 0; $i -lt $lineas.Count; $i++) {
        if ($lineas[$i] -match "^$clave=") { $lineas[$i] = "$clave=$valor"; $hecho = $true }
    }
    if (-not $hecho) { $lineas.Add("$clave=$valor") }
    [IO.File]::WriteAllLines($Config, $lineas, $Utf8)
}
function Puerto-Libre($puerto) {
    try {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, [int]$puerto)
        $l.Start(); $l.Stop(); return $true
    } catch { return $false }
}
function Primer-Puerto-Libre($desde) {
    for ($p = [int]$desde; $p -lt [int]$desde + 100; $p++) { if (Puerto-Libre $p) { return $p } }
    Fallar "No hay ningun puerto libre entre $desde y $([int]$desde + 99)."
}
function Direccion { return "http://localhost:$((Leer-Config)['PUERTO'])" }
function Url-Base($rol) {
    $c = Leer-Config
    if ($rol -eq 'api') { return "postgresql://authenticator:$($c['AUTHENTICATOR_PASSWORD'])@127.0.0.1:$($c['PUERTO_BASE'])/ranking" }
    return "postgresql://postgres:$($c['POSTGRES_PASSWORD'])@127.0.0.1:$($c['PUERTO_BASE'])/ranking"
}
function Verificar-Instalado {
    if (-not ((Test-Path $Config) -and (Test-Path (Unir $PgData 'PG_VERSION')) -and (Test-Path $PyExe))) {
        Fallar "El sistema no esta instalado en esta PC. Corre primero 1_INSTALAR.bat."
    }
}

# ---------------------------------------------------------------- base de datos
# pg_ctl se lanza con Start-Process y se espera solo a el: si se capturara su salida, PowerShell quedaria
# esperando a PostgreSQL, que hereda esa salida y sigue corriendo.
function Correr-PgCtl($argumentos) {
    $o = Oculto
    $p = Start-Process -FilePath $PgCtl -ArgumentList $argumentos -PassThru @o
    $null = $p.Handle
    $p.WaitForExit()
    return $p.ExitCode
}
# La base esta funcionando si acepta conexiones en su puerto (sin mensajes de pg_ctl en pantalla).
function Base-Funcionando {
    try {
        $t = New-Object Net.Sockets.TcpClient
        $t.Connect('127.0.0.1', [int]((Leer-Config)['PUERTO_BASE']))
        $t.Close()
        return $true
    } catch { return $false }
}
function Iniciar-Base {
    if (Base-Funcionando) { return }
    $log = Unir $Logs 'postgres.log'
    if ((Correr-PgCtl @('start', '-D', "`"$PgData`"", '-l', "`"$log`"", '-w', '-t', '120')) -ne 0) {
        if (Test-Path $log) { Get-Content $log -Tail 15 | Write-Host }
        Fallar "No arranco la base de datos (arriba estan los ultimos mensajes; registro completo en $log)."
    }
}
function Detener-Base {
    if (Base-Funcionando) { Correr-PgCtl @('stop', '-D', "`"$PgData`"", '-m', 'fast', '-w', '-t', '60') | Out-Null }
}

# Corre un script de Python del programa (admin, db, migracion) como instruccion, para que lo que pregunta se vea.
# El resultado queda en $script:Codigo (0 = bien). PGURL apunta a la base como superusuario solo mientras corre.
function Python-Admin {
    $env:PGURL = Url-Base 'super'
    & $PyExe @args
    $script:Codigo = $LASTEXITCODE
    Remove-Item Env:PGURL -ErrorAction SilentlyContinue
}
function Usuarios { Python-Admin (Unir $App 'admin' 'usuarios.py') @args }

# Consulta de solo lectura; devuelve las filas (columnas separadas por |).
function Consulta-Base($sql) {
    $env:PGURL = Url-Base 'super'
    $salida = & $PyExe (Unir $App 'admin' 'sql.py') $sql
    $codigo = $LASTEXITCODE
    Remove-Item Env:PGURL -ErrorAction SilentlyContinue
    if ($codigo -ne 0) { Fallar "No se pudo consultar la base: $sql" }
    return $salida
}

# ---------------------------------------------------------------- API (servidor web)
function Api-Responde {
    try { return ((Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 "$(Direccion)/health").StatusCode -eq 200) } catch { return $false }
}
function Iniciar-Api {
    if (Api-Responde) { return }
    $c = Leer-Config
    if (-not (Puerto-Libre $c['PUERTO'])) {
        Fallar "Otro programa esta usando el puerto $($c['PUERTO']). Cerralo o cambia PUERTO en $Config."
    }
    $env:DATABASE_URL = Url-Base 'api'
    $env:JWT_SECRET = $c['JWT_SECRET']
    $env:STORAGE_DIR = $Archivos
    $env:FRONT_DIR = Unir $App 'front'
    $env:PORT = $c['PUERTO']
    $env:SESSION_HOURS = $c['SESSION_HOURS']
    $env:RK_LOG = Unir $Logs 'api.log'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $o = Oculto
    $p = Start-Process -FilePath $PywExe -ArgumentList "`"$(Unir $App 'api' 'servir.py')`"" -WorkingDirectory (Unir $App 'api') -PassThru @o
    [IO.File]::WriteAllText((Unir $Inst 'api.pid'), [string]$p.Id)
    foreach ($v in 'DATABASE_URL', 'JWT_SECRET', 'STORAGE_DIR', 'FRONT_DIR', 'PORT', 'SESSION_HOURS', 'RK_LOG') {
        Remove-Item "Env:$v" -ErrorAction SilentlyContinue
    }
    for ($i = 0; $i -lt 60; $i++) {
        if (Api-Responde) { return }
        if ($p.HasExited) { break }
        Start-Sleep -Seconds 1
    }
    $log = Unir $Logs 'api.log'
    if (Test-Path $log) { Get-Content $log -Tail 20 | Write-Host }
    Fallar "El servidor del sistema no arranco (arriba estan los ultimos mensajes; registro completo en $log)."
}
function Detener-Api {
    $pidArchivo = Unir $Inst 'api.pid'
    if (Test-Path $pidArchivo) {
        $id = [int]([IO.File]::ReadAllText($pidArchivo).Trim())
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -like 'python*') { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; $p.WaitForExit(10000) | Out-Null }
        Remove-Item $pidArchivo -ErrorAction SilentlyContinue
    }
}
function Iniciar-Sistema { Iniciar-Base; Iniciar-Api }
function Detener-Sistema { Detener-Api; Detener-Base }
function Reiniciar-Api { Detener-Api; Iniciar-Api }

# ---------------------------------------------------------------- instalacion de componentes
# Busca el archivo ya bajado (en windows\paquetes, en Descargas o en una descarga anterior) o lo baja.
# Siempre verifica el sha256: un archivo distinto en un solo byte se rechaza.
function Obtener-Componente($c) {
    $lugares = @((Unir $Raiz 'windows' 'paquetes'), (Unir $env:USERPROFILE 'Downloads'), $Descargas)
    foreach ($l in $lugares) {
        $f = Join-Path $l $c.Archivo
        if ((Test-Path -LiteralPath $f) -and ((Sha256 $f) -eq $c.Sha256)) { return $f }
    }
    New-Item -ItemType Directory -Force $Descargas | Out-Null
    $destino = Join-Path $Descargas $c.Archivo
    Write-Host "Bajando $($c.Archivo) ..."
    try {
        $wc = New-Object Net.WebClient
        $wc.Proxy = [Net.WebRequest]::GetSystemWebProxy()
        $wc.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials
        $wc.DownloadFile($c.Url, "$destino.parcial")
        Move-Item -Force "$destino.parcial" $destino
    } catch {
        Aviso "  No se pudo bajar: $($_.Exception.Message)"
        Remove-Item "$destino.parcial" -ErrorAction SilentlyContinue
    }
    if ((Test-Path -LiteralPath $destino) -and ((Sha256 $destino) -eq $c.Sha256)) { return $destino }
    if (Test-Path -LiteralPath $destino) { Remove-Item $destino; Aviso "  El archivo bajado no coincide con el esperado y se descarto." }
    Fallar ("No se pudo bajar $($c.Archivo).`n" +
            "Bajalo con el navegador desde este link (queda en tu carpeta Descargas) y volve a correr 1_INSTALAR.bat:`n" +
            "  $($c.Url)")
}
function Extraer($archivo, $destino) {
    New-Item -ItemType Directory -Force $destino | Out-Null
    if ($archivo -match '\.(nupkg|zip)$') {
        # ZIP (el paquete de Python): con .NET, que esta en Windows PowerShell 5.1 y en PowerShell 7.
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($archivo, $destino)
        } catch { Fallar "No se pudo descomprimir ${archivo}: $($_.Exception.Message)" }
        return
    }
    # .tgz (el paquete de PostgreSQL): con tar, que viene con Windows 10 y 11.
    $tar = 'tar'
    if ($EsWindows) { $tar = Unir $env:SystemRoot 'System32' 'tar.exe' }
    & $tar -xzf $archivo -C $destino
    if ($LASTEXITCODE -ne 0) { Fallar "No se pudo descomprimir $archivo." }
}
# Deja runtime\<nombre> con el contenido del componente (reemplaza una version anterior).
function Instalar-Componente($nombre) {
    $c = $Componentes[$nombre]
    $archivo = Obtener-Componente $c
    $tmp = Unir $Runtime "$nombre.tmp"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Extraer $archivo $tmp
    $origen = $tmp
    foreach ($parte in ($c.Dentro -split '/')) { $origen = Join-Path $origen $parte }
    $final = Unir $Runtime $nombre
    if (Test-Path $final) { Remove-Item -Recurse -Force $final }
    Move-Item $origen $final
    Remove-Item -Recurse -Force $tmp
}
function Version-Runtime {
    return "$($Componentes.python.Sha256) $($Componentes.pgsql.Sha256) $(Sha256 (Unir $Raiz 'windows' 'paquetes' 'requisitos.txt'))"
}
# Comprueba que Windows deje correr los programas portables (algunas PC de empresa los bloquean por directiva).
function Probar-Programas {
    $pruebas = @(@{ Exe = $PyExe; Args = @('-c', 'print("FUNCIONA")'); Nombre = 'Python' },
                 @{ Exe = (Unir $PgDir 'bin' 'postgres.exe'); Args = @('--version'); Nombre = 'PostgreSQL' })
    foreach ($t in $pruebas) {
        $salida = ''
        try { $salida = (& $t.Exe @($t.Args) 2>&1 | Out-String) } catch { $salida = $_.Exception.Message }
        if ($salida -notmatch 'FUNCIONA|PostgreSQL') {
            Fallar ("Windows no deja correr $($t.Nombre) desde $Runtime.`n  $($salida.Trim())`n" +
                    "Si dice 'bloqueado' o 'directiva de grupo', pedile a IT que permita ejecutar programas desde`n" +
                    "  $Inst`n" +
                    "(son PostgreSQL y Python oficiales; no necesitan permisos de administrador).")
        }
    }
}
function Preparar-Runtime {
    $marca = Unir $Runtime 'version.txt'
    if ((Test-Path $marca) -and ([IO.File]::ReadAllText($marca).Trim() -eq (Version-Runtime))) {
        Probar-Programas
        Ok "Componentes ya instalados."
        return
    }
    $pgAnterior = Test-Path (Unir $PgData 'PG_VERSION')
    if ($pgAnterior) { Detener-Sistema }
    New-Item -ItemType Directory -Force $Runtime | Out-Null
    Write-Host "PostgreSQL 17 ..."
    Instalar-Componente 'pgsql'
    Write-Host "Python 3.12 ..."
    Instalar-Componente 'python'
    Probar-Programas
    Write-Host "Paquetes de Python (sin internet, desde windows\paquetes) ..."
    & $PyExe -m ensurepip --default-pip *> (Unir $Logs 'pip.log')
    $paq = Unir $Raiz 'windows' 'paquetes'
    & $PyExe -m pip install --no-index --no-deps --find-links $paq -r (Unir $paq 'requisitos.txt') `
        --disable-pip-version-check --no-warn-script-location *>> (Unir $Logs 'pip.log')
    if ($LASTEXITCODE -ne 0) {
        Get-Content (Unir $Logs 'pip.log') -Tail 15 | Write-Host
        Fallar "No se pudieron instalar los paquetes de Python (registro en $(Unir $Logs 'pip.log'))."
    }
    [IO.File]::WriteAllText($marca, (Version-Runtime))
    Ok "Componentes instalados."
}
