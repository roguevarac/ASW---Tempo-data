# Menu de usuarios (reemplaza Authentication > Users de Supabase). Se corre con USUARIOS.bat.
. "$PSScriptRoot\comun.ps1"
Verificar-Instalado
Iniciar-Base
while ($true) {
    Titulo "Usuarios"
    Usuarios listar
    Write-Host ""
    Write-Host "  1 = Crear usuario        2 = Cambiar contrasena    3 = Cambiar rol u oficina"
    Write-Host "  4 = Bloquear usuario     5 = Desbloquear usuario   0 = Salir"
    $op = Read-Host "Opcion"
    if ($op -eq '0' -or -not $op) { break }
    $email = Read-Host "Email"
    if (-not $email) { continue }
    switch ($op) {
        '1' {
            $rol = Read-Host "Rol (admin / usuario_estandar / auditor)"
            $oficina = Read-Host "Oficina (ej. AR; Enter para dejarla vacia)"
            $extra = @(); if ($oficina) { $extra = @($oficina) }
            Usuarios crear $email $rol @extra
        }
        '2' { Usuarios clave $email }
        '3' {
            $rol = Read-Host "Rol (admin / usuario_estandar / auditor)"
            $oficina = Read-Host "Oficina (Enter = no cambiarla)"
            $extra = @(); if ($oficina) { $extra = @($oficina) }
            Usuarios rol $email $rol @extra
        }
        '4' { Usuarios bloquear $email }
        '5' { Usuarios desbloquear $email }
        default { Aviso "Opcion invalida." }
    }
}
