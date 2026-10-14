# Trae de Supabase los datos, los usuarios y el historial de cargas. Se corre con 2_MIGRAR_DESDE_SUPABASE.bat.
# Todo va por HTTPS (funciona en la red de la empresa). La service_role key no se guarda en ningun archivo.
. "$PSScriptRoot\comun.ps1"
$ProyectoPorDefecto = 'https://ltosqbvzlnncxijzodvd.supabase.co'
$OneDrive = Unir $env:USERPROFILE 'OneDrive - Sony' 'SMP-Administration Argentina - Documents' 'Latam' 'Backoffice'
$CarpetasPorDefecto = @((Join-Path $OneDrive 'Charts historicos Youtube'), (Join-Path $OneDrive 'Charts historicos_spotify'))
$Exportacion = Join-Path $Raiz 'exportacion'

Titulo "1/6 Sistema"
Verificar-Docker
if (-not (Test-Path (Ruta-Env))) { Fallar "Primero corre 1_INSTALAR.bat." }
docker compose up -d
Esperar-Sistema

Titulo "2/6 Datos de Supabase"
$url = Read-Host "URL del proyecto [Enter = $ProyectoPorDefecto]"
if (-not $url) { $url = $ProyectoPorDefecto }
$env:SUPABASE_URL = $url.Trim().TrimEnd('/')
Write-Host "Ahora la service_role key: en Supabase > Project Settings > API Keys > service_role > Reveal > copiar."
Write-Host "(Es secreta: se usa solo para esta descarga y no se guarda en ningun lado.)"
$env:SUPABASE_SERVICE_KEY = Leer-Secreto "service_role key"
if (-not $env:SUPABASE_SERVICE_KEY) { Fallar "No se ingreso la clave." }

Titulo "3/6 Bajando tablas y usuarios de Supabase"
$bajar = $true
if (Test-Path (Join-Path $Exportacion 'manifiesto.json')) {
    $bajar = Preguntar-SiNo "Ya hay una descarga anterior en la carpeta 'exportacion'. Bajar todo de nuevo (recomendado si se cargaron datos despues)?"
}
if ($bajar) {
    if (Test-Path $Exportacion) { Remove-Item -Recurse -Force $Exportacion }
    New-Item -ItemType Directory $Exportacion | Out-Null
    docker compose run --rm -e SUPABASE_URL -e SUPABASE_SERVICE_KEY -v "${Exportacion}:/exportacion" `
        api python /app/migracion/exportar_supabase.py /exportacion --sin-archivos
    if ($LASTEXITCODE -ne 0) {
        Fallar ("No se pudo bajar de Supabase (el motivo esta arriba).`n" +
                "Si dice 'certificate' o 'SSL', la red de la empresa intercepta la conexion: proba desde otra red.`n" +
                "Si dice 401/403, la clave no es la service_role.")
    }
}

Titulo "4/6 Carpetas con los CSV del historial"
Write-Host "Los archivos del historial de cargas se toman de estas carpetas (por nombre y tamano exactos):"
$carpetas = @()
foreach ($c in $CarpetasPorDefecto) {
    if (Test-Path $c) { $carpetas += $c; Ok "  $c" } else { Aviso "  No encontre: $c" }
}
Write-Host "Importante: en OneDrive, clic derecho sobre cada carpeta > 'Mantener siempre en este dispositivo',"
Write-Host "para que los archivos esten descargados en la PC y no solo en la nube."
while ($true) {
    $otra = Read-Host "Agregar otra carpeta con CSV? (pega la ruta, o Enter para seguir)"
    if (-not $otra) { break }
    $otra = $otra.Trim('"', ' ')
    if (Test-Path $otra -PathType Container) { $carpetas += $otra; Ok "  $otra" } else { Aviso "  No existe: $otra" }
}
$montajes = @(); $desde = @(); $i = 0
foreach ($c in $carpetas) {
    $montajes += @('-v', "${c}:/carpetas/${i}:ro"); $desde += @('--archivos-desde', "/carpetas/$i"); $i++
}

Titulo "5/6 Importando en el sistema nuevo"
$reemplazar = @()
$hay = [int](Consulta-Base "select (select count(*) from auth.users) + (select count(*) from public.tracks_master)")
if ($hay -gt 0) {
    if (-not (Preguntar-SiNo "El sistema nuevo ya tiene datos o usuarios. Borrarlos y cargar lo de Supabase?")) { Fallar "Cancelado. No se toco nada." }
    $reemplazar = @('--reemplazar')
}
$faltantes = Join-Path $Exportacion 'archivos_faltantes.txt'
# Se llama como instrucción para que la salida se vea; el resultado queda en $script:Codigo.
function Importar($opciones) {
    Remove-Item $faltantes -ErrorAction SilentlyContinue
    $env:PGURL = "postgresql://postgres:$((Leer-Env)['POSTGRES_PASSWORD'])@db:5432/ranking"
    docker compose run --rm -e PGURL -v "${Exportacion}:/exportacion" @montajes `
        api python /app/migracion/importar.py /exportacion @desde @reemplazar @opciones
    $script:Codigo = $LASTEXITCODE
    Remove-Item Env:PGURL -ErrorAction SilentlyContinue
}
Importar @()
if ($script:Codigo -ne 0 -and (Test-Path $faltantes)) {
    $n = @(Get-Content $faltantes | Where-Object { $_ }).Count
    Write-Host ""
    Aviso "$n archivos del historial no estan en esas carpetas (lista en exportacion\archivos_faltantes.txt)."
    Write-Host "  1 = Bajar solo esos del bucket de Supabase (recomendado)"
    Write-Host "  2 = Importar sin ellos (la carga queda en el historial, pero sin archivo para descargar)"
    Write-Host "  3 = Cancelar"
    $op = Read-Host "Opcion"
    if ($op -eq '1') {
        docker compose run --rm -e SUPABASE_URL -e SUPABASE_SERVICE_KEY -v "${Exportacion}:/exportacion" `
            api python /app/migracion/exportar_supabase.py /exportacion --bajar-faltantes
        if ($LASTEXITCODE -ne 0) { Fallar "No se pudieron bajar esos archivos (motivo arriba). No se importo nada." }
        Importar @()
    } elseif ($op -eq '2') {
        Importar @('--permitir-faltantes')
    } else {
        Fallar "Cancelado. No se importo nada."
    }
}
if ($script:Codigo -ne 0) { Fallar "La importacion no se hizo (el motivo esta arriba). La base quedo como estaba." }
Remove-Item Env:SUPABASE_SERVICE_KEY -ErrorAction SilentlyContinue
Ok "Datos importados y verificados."

Titulo "6/6 Contrasenas y carga automatica de YouTube"
Write-Host "Supabase no entrega las contrasenas, asi que cada usuario necesita una nueva (minimo 10 caracteres)."
foreach ($email in @(Consulta-Base "select email from auth.users where encrypted_password is null order by email")) {
    if (-not $email) { continue }
    if (-not (Preguntar-SiNo "Poner contrasena a $email ahora?")) { Aviso "  Pendiente: hacelo despues con USUARIOS.bat."; continue }
    do {
        Usuarios clave $email
    } while ($script:Codigo -ne 0 -and (Preguntar-SiNo "No se pudo. Reintentar?"))
}
Write-Host ""
Write-Host "Horario de la carga automatica de YouTube Charts. Para verlo: Supabase > SQL Editor > corre"
Write-Host "    select schedule from cron.job;"
Write-Host "y pega lo que aparece (por ejemplo: 0 12 * * 5). Enter = dejarla apagada por ahora."
$cron = (Read-Host "Horario").Trim()
if ($cron) {
    if (($cron -split '\s+').Count -ne 5) { Aviso "No parece un horario valido (son 5 partes). Queda apagada; podes ponerla despues en .env (YOUTUBE_CRON)." }
    else {
        Poner-Env 'YOUTUBE_CRON' $cron
        Poner-Env 'YOUTUBE_CRON_TZ' 'UTC'   # pg_cron de Supabase usa hora UTC
        docker compose up -d
        Ok "Carga automatica de YouTube programada: $cron (hora UTC, como en Supabase)."
    }
}

Ok "`nMigracion completa. Entra con tu email y la contrasena nueva."
Write-Host "Revisa la tabla principal, territorios e historial. Cuando todo este bien, podes apagar Supabase"
Write-Host "y cambiar la contrasena de la base y las claves del proyecto de Supabase."
Start-Process (Direccion)
Limpiar-Secretos
Read-Host "Presiona Enter para cerrar" | Out-Null
