# Trae de Supabase los datos, los usuarios y el historial de cargas. Se corre con 2_MIGRAR_DESDE_SUPABASE.bat.
# Todo va por HTTPS (funciona en la red de la empresa). La service_role key no se guarda en ningun archivo.
. "$PSScriptRoot\comun.ps1"
$ProyectoPorDefecto = 'https://ltosqbvzlnncxijzodvd.supabase.co'
$OneDrive = Unir $env:USERPROFILE 'OneDrive - Sony' 'SMP-Administration Argentina - Documents' 'Latam' 'Backoffice'
$CarpetasPorDefecto = @((Join-Path $OneDrive 'Charts historicos Youtube'), (Join-Path $OneDrive 'Charts historicos_spotify'))

Titulo "1/6 Sistema"
Verificar-Instalado
Iniciar-Sistema
Ok "Sistema funcionando."

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
if (Test-Path (Unir $Exportacion 'manifiesto.json')) {
    $bajar = Preguntar-SiNo "Ya hay una descarga anterior. Bajar todo de nuevo (recomendado si se cargaron datos despues)?"
}
$exportar = Unir $App 'migracion' 'exportar_supabase.py'
if ($bajar) {
    if (Test-Path $Exportacion) { Remove-Item -Recurse -Force $Exportacion }
    & $PyExe $exportar $Exportacion --sin-archivos
    if ($LASTEXITCODE -ne 0) {
        Fallar ("No se pudo bajar de Supabase (el motivo esta arriba).`n" +
                "Si dice 401 o 403, la clave no es la service_role. Si dice 'certificate' o 'SSL', proba desde otra red.")
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
$desde = @()
foreach ($c in $carpetas) { $desde += @('--archivos-desde', $c) }

Titulo "5/6 Importando en el sistema nuevo"
$reemplazar = @()
$hay = [int](Consulta-Base "select (select count(*) from auth.users) + (select count(*) from public.tracks_master)")
if ($hay -gt 0) {
    if (-not (Preguntar-SiNo "El sistema nuevo ya tiene datos o usuarios. Borrarlos y cargar lo de Supabase?")) { Fallar "Cancelado. No se toco nada." }
    $reemplazar = @('--reemplazar')
}
$faltantes = Unir $Exportacion 'archivos_faltantes.txt'
$importar = Unir $App 'migracion' 'importar.py'
# Se llama como instruccion para que la salida se vea; el resultado queda en $script:Codigo.
function Importar($opciones) {
    Remove-Item $faltantes -ErrorAction SilentlyContinue
    $env:STORAGE_DIR = $Archivos
    Python-Admin $importar $Exportacion @desde @reemplazar @opciones
    Remove-Item Env:STORAGE_DIR -ErrorAction SilentlyContinue
}
Importar @()
if ($script:Codigo -ne 0 -and (Test-Path $faltantes)) {
    $n = @(Get-Content $faltantes | Where-Object { $_ }).Count
    Write-Host ""
    Aviso "$n archivos del historial no estan en esas carpetas (lista en $faltantes)."
    Write-Host "  1 = Bajar solo esos del bucket de Supabase (recomendado)"
    Write-Host "  2 = Importar sin ellos (la carga queda en el historial, pero sin archivo para descargar)"
    Write-Host "  3 = Cancelar"
    $op = Read-Host "Opcion"
    if ($op -eq '1') {
        & $PyExe $exportar $Exportacion --bajar-faltantes
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

Titulo "6/6 Contrasenas"
Write-Host "Supabase no entrega las contrasenas, asi que cada usuario necesita una nueva (minimo 10 caracteres)."
foreach ($email in @(Consulta-Base "select email from auth.users where encrypted_password is null order by email")) {
    if (-not $email) { continue }
    if (-not (Preguntar-SiNo "Poner contrasena a $email ahora?")) { Aviso "  Pendiente: hacelo despues con USUARIOS.bat."; continue }
    do {
        Usuarios clave $email
    } while ($script:Codigo -ne 0 -and (Preguntar-SiNo "No se pudo. Reintentar?"))
}

Ok "`nMigracion completa. Entra con tu email y la contrasena nueva."
Write-Host "Revisa la tabla principal, territorios e historial. Cuando todo este bien, podes apagar Supabase"
Write-Host "y cambiar la contrasena de la base y las claves del proyecto de Supabase."
Start-Process (Direccion)
Limpiar-Secretos
Read-Host "Presiona Enter para cerrar" | Out-Null
