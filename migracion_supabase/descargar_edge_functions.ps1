# =====================================================================
# Descarga el código de TODAS las Edge Functions del proyecto de Supabase.
# Las Edge Functions no viven en la base de datos, por eso no salen con
# extraer_esquema.sql.
#
# Requisitos (una sola vez):
#   1. Node.js instalado (https://nodejs.org).
#   2. En PowerShell:  npx supabase login
#      Se abre el navegador para autorizar. No hay que escribir contraseñas acá.
#
# Uso (PowerShell, en la carpeta donde quieras guardar el código):
#   powershell -ExecutionPolicy Bypass -File .\descargar_edge_functions.ps1
#
# Resultado: carpeta supabase\functions\<nombre_funcion>\ con el código de cada una.
# Comprimí la carpeta supabase\functions y subila al repo (migracion_supabase\edge_functions\)
# o adjuntala en el chat.
#
# Los secretos de las funciones (variables de entorno) NO se descargan: solo se lista
# su NOMBRE en secretos_nombres.txt, para saber cuáles hay que volver a cargar.
# =====================================================================
$ErrorActionPreference = "Stop"
$ProjectRef = "ltosqbvzlnncxijzodvd"

Write-Host "Listando funciones del proyecto $ProjectRef..."
$lista = npx --yes supabase functions list --project-ref $ProjectRef --output json | ConvertFrom-Json
if (-not $lista) { Write-Host "No se encontraron Edge Functions."; exit 0 }

foreach ($f in $lista) {
    $nombre = $f.slug
    Write-Host "Descargando $nombre ..."
    # --use-api descarga sin necesitar Docker
    npx --yes supabase functions download $nombre --project-ref $ProjectRef --use-api
}

Write-Host "Listando nombres de secretos (sin valores)..."
npx --yes supabase secrets list --project-ref $ProjectRef | Out-File -Encoding utf8 secretos_nombres.txt

Write-Host ""
Write-Host "Listo. Codigo en .\supabase\functions\  |  nombres de secretos en .\secretos_nombres.txt"
