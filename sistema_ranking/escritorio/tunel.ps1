# Auditor de Rankings Digitales: acceso desde otras computadoras (bash ranking.sh compartir).
# Mantiene abierto un enlace HTTPS fijo de Microsoft Dev Tunnels hacia este sistema (http://localhost:PUERTO), con la
# herramienta devtunnel.exe de esta carpeta. Corre en Windows porque ahi la sesion de Microsoft queda guardada (en
# Linux, sin llavero del sistema, se pierde). Mientras corre, la PC no se suspende por inactividad.
# Lo genera ranking.sh (no editar: se regenera al actualizar) y lo inicia lanzar.ps1, oculto.
#   (sin opciones)   abre el tunel y lo mantiene (si se corta, lo reabre); deja el estado en tunel-estado.json
#   -Preparar        crea el tunel, publica el puerto y configura quien entra; sale (lo usa "compartir")
param([switch]$Preparar)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$TunelId = '__TUNEL_ID__'
$Acceso = '__ACCESO__'          # empresa: solo cuentas Microsoft de la empresa | cualquiera: cualquiera con el enlace
$Puerto = __PUERTO__
$Dt = Join-Path $PSScriptRoot 'devtunnel.exe'
$EstadoArchivo = Join-Path $PSScriptRoot 'tunel-estado.json'
$Log = Join-Path $PSScriptRoot 'tunel.log'

function Anotar($texto) { Add-Content -Path $Log -Value "$(Get-Date -Format s) $texto" -Encoding UTF8 }
function Estado($estado, $url, $mensaje) {
    $e = [ordered]@{ estado = $estado; url = $url; acceso = $Acceso; mensaje = $mensaje
                     fecha = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); pid = $PID }
    $tmp = "$EstadoArchivo.tmp"
    [IO.File]::WriteAllText($tmp, ($e | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    Move-Item -Force $tmp $EstadoArchivo
    Anotar "estado: $estado $url $mensaje"
}
function Dt([string[]]$argumentos) {
    $salida = (& $Dt @argumentos 2>&1 | Out-String)
    $codigo = $LASTEXITCODE
    if ($codigo -ne 0) { Anotar "devtunnel $($argumentos -join ' ') -> $codigo $($salida.Trim())" }
    return @{ codigo = $codigo; salida = $salida }
}
function ConSesion {
    $r = Dt @('user', 'show')
    return ($r.codigo -eq 0 -and $r.salida -notmatch 'not logged in|no user|not signed')
}
function PrepararTunel {
    if ((Dt @('show', $TunelId)).codigo -ne 0) {
        $r = Dt @('create', $TunelId, '--expiration', '30d')
        if ($r.codigo -ne 0) { throw "No se pudo crear el tunel ${TunelId}: $($r.salida.Trim())" }
    }
    $r = Dt @('port', 'create', $TunelId, '-p', "$Puerto", '--protocol', 'http')
    if ($r.codigo -ne 0 -and $r.salida -notmatch 'already exists|conflict') { throw "No se pudo publicar el puerto ${Puerto}: $($r.salida.Trim())" }
    Dt @('access', 'reset', $TunelId) | Out-Null
    $r = Dt @('access', 'create', $TunelId, $(if ($Acceso -eq 'cualquiera') { '--anonymous' } else { '--tenant' }))
    if ($r.codigo -ne 0) { throw "No se pudo configurar quien puede entrar: $($r.salida.Trim())" }
}
# El enlace del navegador para el puerto del sistema (no el de "inspect").
function ElegirUrl($linea) {
    $urls = @([regex]::Matches($linea, 'https://[A-Za-z0-9.-]*devtunnels\.ms[^\s,]*') | ForEach-Object { $_.Value.TrimEnd('/', '.', ';') } |
              Where-Object { $_ -notmatch 'inspect' })
    if ($urls.Count -eq 0) { return $null }
    $conPuerto = @($urls | Where-Object { $_ -match "-$Puerto\." })
    if ($conPuerto.Count -gt 0) { return $conPuerto[0] + '/' }
    return $urls[0] + '/'
}

if (-not (Test-Path $Dt)) { Estado 'error' $null 'Falta devtunnel.exe: ejecuta en Ubuntu bash ranking.sh compartir'; exit 1 }
if ($Preparar) {
    if (-not (ConSesion)) { Write-Output 'Sin sesion de Microsoft.'; exit 2 }
    try { PrepararTunel; Write-Output 'Tunel preparado.'; exit 0 } catch { Write-Output $_.Exception.Message; exit 1 }
}

# La PC no se suspende por inactividad mientras se comparte (no impide apagarla, suspenderla a mano ni cerrar la tapa).
try {
    $energia = Add-Type -Name Energia -Namespace AuditorRankings -PassThru -MemberDefinition `
        '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint estado);'
    [void]$energia::SetThreadExecutionState([Convert]::ToUInt32('80000001', 16))   # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
} catch { }

while ($true) {
    Estado 'iniciando' $null $null
    if (-not (ConSesion)) {
        Estado 'sin_sesion' $null 'La sesion de Microsoft vencio. En Ubuntu: bash ranking.sh compartir'
        Start-Sleep -Seconds 300; continue
    }
    try { PrepararTunel } catch {
        Estado 'error' $null $_.Exception.Message
        Start-Sleep -Seconds 60; continue
    }
    $url = $null; $ultimas = New-Object System.Collections.Generic.List[string]
    # La salida de "devtunnel host" se lee linea por linea (salida de error incluida) hasta que se cierra.
    $comando = "`"$Dt`" host $TunelId 2>&1"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { $psi.FileName = '/bin/sh'; $psi.ArgumentList.Add('-c'); $psi.ArgumentList.Add($comando) }
    else { $psi.FileName = 'cmd.exe'; $psi.Arguments = "/d /s /c `"$comando`"" }
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
    $proceso = [Diagnostics.Process]::Start($psi)
    while (-not $proceso.StandardOutput.EndOfStream) {
        $linea = $proceso.StandardOutput.ReadLine()
        Anotar $linea
        $ultimas.Add($linea); if ($ultimas.Count -gt 20) { $ultimas.RemoveAt(0) }
        if (-not $url) { $url = ElegirUrl $linea; if ($url) { Estado 'activo' $url $null } }
    }
    $proceso.WaitForExit()
    $texto = $ultimas -join ' '
    if ($texto -match 'login|log in|sign in|unauthorized|not authenticated|expired') {
        Estado 'sin_sesion' $null 'La sesion de Microsoft vencio. En Ubuntu: bash ranking.sh compartir'
    } else {
        Estado 'error' $null ('El acceso se cerro; se reabre solo. ' + $texto.Substring([Math]::Max(0, $texto.Length - 300)))
    }
    Start-Sleep -Seconds 30
}
