# Instala y arranca el sistema en esta PC. Se corre con 1_INSTALAR.bat.
. "$PSScriptRoot\comun.ps1"

Titulo "1/4 Docker Desktop"
Verificar-Docker
Ok "Docker funcionando."

Titulo "2/4 Configuracion"
if (Test-Path (Ruta-Env)) {
    Ok "Ya existe la configuracion (.env); se mantiene."
} else {
    $lineas = [IO.File]::ReadAllLines((Join-Path $Raiz '.env.example'), $Utf8)
    $lineas = $lineas | ForEach-Object {
        if ($_ -match '^(POSTGRES_PASSWORD|AUTHENTICATOR_PASSWORD|JWT_SECRET)=$') { "$($matches[1])=$(Nueva-Clave)" } else { $_ }
    }
    [IO.File]::WriteAllLines((Ruta-Env), [string[]]$lineas, $Utf8)
    Ok "Configuracion creada con claves nuevas al azar (archivo .env; no lo compartas)."
}

Titulo "3/4 Armando y arrancando el sistema (la primera vez tarda varios minutos)"
docker compose up -d --build
if ($LASTEXITCODE -ne 0) {
    Fallar ("No se pudo armar el sistema.`n" +
            "Si arriba aparece 'SSL', 'certificate' o 'proxy', la red de la empresa esta bloqueando las descargas:`n" +
            "conectate a otra red (por ejemplo, el celular) solo para este paso y volve a correr 1_INSTALAR.bat.")
}
Esperar-Sistema
Ok "Sistema funcionando en $(Direccion)"

Titulo "4/4 Usuarios"
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

Ok "`nListo. El sistema queda funcionando y vuelve a arrancar solo cuando se abre Docker Desktop."
Write-Host "Para entrar: ABRIR_SISTEMA.bat (o $(Direccion) en el navegador)."
Start-Process (Direccion)
Read-Host "Presiona Enter para cerrar" | Out-Null
