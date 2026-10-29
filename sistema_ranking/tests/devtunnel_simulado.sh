#!/bin/sh
# Simula devtunnel.exe de Microsoft para las pruebas (test_tunel.py): mismos comandos y mensajes que usa
# escritorio/tunel.ps1, sin conexión a Microsoft. Guarda su estado en .simulado, junto al programa.
E="$(dirname "$0")/.simulado"; mkdir -p "$E"
echo "$*" >> "$E/comandos"
case "$1 $2" in
    "user show")
        if [ -f "$E/sesion" ]; then echo "Logged in as prueba@empresa.com using Microsoft."; exit 0; fi
        echo "Not logged in."; exit 1 ;;
    "user login")
        echo "To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code PRUEBA123"
        touch "$E/sesion"; echo "Logged in as prueba@empresa.com using Microsoft."; exit 0 ;;
    "port create")
        if [ -f "$E/puerto-$3" ]; then echo "Tunnel service error: Conflict with existing entity. Tunnel port number conflicts with an existing port in the tunnel."; exit 1; fi
        touch "$E/puerto-$3"; echo "Port 8000 created."; exit 0 ;;
    "access reset") rm -f "$E/acceso"; exit 0 ;;
    "access create") echo "$4" > "$E/acceso"; exit 0 ;;
esac
case "$1" in
    show)
        if [ -f "$E/tunel-$2" ]; then echo "Tunnel ID: $2.brs"; exit 0; fi
        echo "Tunnel not found."; exit 1 ;;
    create) touch "$E/tunel-$2"; echo "Tunnel ID: $2.brs"; exit 0 ;;
    host)
        if [ ! -f "$E/sesion" ]; then echo "Unauthorized: please log in again."; exit 1; fi
        echo "Hosting port: 8000"
        echo "Connect via browser: https://$2-8000.brs.devtunnels.ms, https://$2.brs.devtunnels.ms"
        echo "Inspect network activity: https://$2-8000-inspect.brs.devtunnels.ms"
        echo "Ready to accept connections for tunnel: $2.brs"
        exec sleep 100000 ;;
esac
echo "Comando no simulado: $*"; exit 2
