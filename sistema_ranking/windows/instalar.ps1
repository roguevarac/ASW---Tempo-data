# Instala el sistema en esta PC, sin Docker ni permisos de administrador. Se corre con 1_INSTALAR.bat.
# Se puede volver a correr (por ejemplo con un ZIP nuevo): actualiza el programa y conserva datos y claves.
. "$PSScriptRoot\comun.ps1"
foreach ($d in $Inst, $Logs, $Datos, $Archivos) { New-Item -ItemType Directory -Force $d | Out-Null }

Titulo "1/5 Componentes (PostgreSQL 17 y Python 3.12; la primera vez bajan unos 50 MB)"
Preparar-Runtime

Titulo "2/5 Programa"
if ($Raiz -ne $App) {
    $huboApi = Api-Responde
    if ($huboApi) { Detener-Api }
    if (Test-Path $App) { Remove-Item -Recurse -Force $App }
    New-Item -ItemType Directory -Force $App | Out-Null
    foreach ($d in 'api', 'front', 'admin', 'migracion', 'db', 'windows') {
        Copy-Item -Recurse (Unir $Raiz $d) (Unir $App $d)
    }
    Get-ChildItem -Path $Raiz -Filter '*.bat' | Copy-Item -Destination $App
    Get-ChildItem -Path $App -Recurse -Directory -Filter '__pycache__' | Remove-Item -Recurse -Force
}
Ok "Programa en $App"

Titulo "3/5 Configuracion"
if (Test-Path $Config) {
    Ok "Ya existe la configuracion; se mantiene."
} else {
    Poner-Config 'POSTGRES_PASSWORD' (Nueva-Clave)
    Poner-Config 'AUTHENTICATOR_PASSWORD' (Nueva-Clave)
    Poner-Config 'JWT_SECRET' (Nueva-Clave)
    Poner-Config 'PUERTO' (Primer-Puerto-Libre 8000)
    Poner-Config 'PUERTO_BASE' (Primer-Puerto-Libre 54329)
    Poner-Config 'SESSION_HOURS' '8'
    Ok "Configuracion creada con claves al azar en $Config (no la compartas)."
}
$cfg = Leer-Config

Titulo "4/5 Base de datos"
if (-not (Test-Path (Unir $PgData 'PG_VERSION'))) {
    $clave = Unir $Inst 'clave.tmp'
    [IO.File]::WriteAllText($clave, $cfg['POSTGRES_PASSWORD'])
    # C.UTF-8 "builtin": ordena y pasa a minusculas igual que la base de Supabase.
    & $Initdb -D $PgData -U postgres -A scram-sha-256 "--pwfile=$clave" -E UTF8 `
        --locale-provider=builtin --builtin-locale=C.UTF-8 --locale=C *> (Unir $Logs 'initdb.log')
    $codigo = $LASTEXITCODE
    Remove-Item $clave -ErrorAction SilentlyContinue
    if ($codigo -ne 0) {
        Get-Content (Unir $Logs 'initdb.log') -Tail 15 | Write-Host
        Fallar "No se pudo crear la base (registro en $(Unir $Logs 'initdb.log'))."
    }
    [IO.File]::AppendAllText((Unir $PgData 'postgresql.conf'),
        "`n# Ranking Digital: solo esta PC`nlisten_addresses = '127.0.0.1'`nport = $($cfg['PUERTO_BASE'])`n", $Utf8)
    Ok "Base creada."
}
Iniciar-Base
$env:AUTHENTICATOR_PASSWORD = $cfg['AUTHENTICATOR_PASSWORD']
Python-Admin (Unir $App 'db' 'instalar.py')
Remove-Item Env:AUTHENTICATOR_PASSWORD -ErrorAction SilentlyContinue
if ($script:Codigo -ne 0) { Fallar "No se pudo instalar la estructura de la base (el motivo esta arriba)." }
Iniciar-Api
Ok "Sistema funcionando en $(Direccion)"

Titulo "5/5 Usuarios y accesos directos"
$cantidad = [int](Consulta-Base "select count(*) from auth.users")
if ($cantidad -gt 0) {
    Ok "Hay $cantidad usuarios cargados."
} else {
    Write-Host "Todavia no hay usuarios."
    Write-Host "  * Si venis de Supabase, NO crees usuarios ahora: corre 2_MIGRAR_DESDE_SUPABASE.bat,"
    Write-Host "    que trae tus usuarios, tus datos y el historial."
    if (Preguntar-SiNo "  * Crear ahora un usuario administrador nuevo?") {
        $email = Read-Host "Email"
        $oficina = Read-Host "Oficina (ej. AR; Enter para dejarla vacia)"
        $extra = @(); if ($oficina) { $extra = @($oficina) }
        Write-Host "Escribi la contrasena (minimo 10 caracteres; no se ve mientras escribis)."
        Usuarios crear $email admin @extra
        if ($script:Codigo -ne 0) { Aviso "No se pudo crear el usuario. Podes reintentar con USUARIOS.bat." }
    }
}
if ($EsWindows) {
    $shell = New-Object -ComObject WScript.Shell
    $abrir = Unir $App 'windows' 'abrir.ps1'
    Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Ranking Digital.lnk') -ErrorAction SilentlyContinue   # nombre anterior
    $acceso = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Auditor de Rankings Digitales.lnk'))
    $acceso.TargetPath = 'powershell.exe'
    $acceso.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$abrir`""
    $acceso.WorkingDirectory = $App
    $acceso.Save()
    Ok "Acceso directo 'Auditor de Rankings Digitales' creado en el escritorio."
    Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'Ranking Digital.lnk') -ErrorAction SilentlyContinue
    $inicio = Join-Path ([Environment]::GetFolderPath('Startup')) 'Auditor de Rankings Digitales.lnk'
    if (Preguntar-SiNo "Arrancar el sistema solo cada vez que prendes la PC?") {
        $auto = $shell.CreateShortcut($inicio)
        $auto.TargetPath = 'powershell.exe'
        $auto.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$abrir`" -SinNavegador"
        $auto.WorkingDirectory = $App
        $auto.Save()
        Ok "Listo: arranca solo al iniciar sesion."
    } elseif (Test-Path $inicio) { Remove-Item $inicio }
}

Ok "`nListo. Para entrar: el acceso directo 'Auditor de Rankings Digitales' del escritorio (o $(Direccion) en el navegador)."
Start-Process (Direccion)
Read-Host "Presiona Enter para cerrar" | Out-Null
