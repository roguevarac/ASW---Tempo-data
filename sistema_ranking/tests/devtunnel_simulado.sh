#!/bin/sh
# Simula la herramienta "devtunnel" de Microsoft para las pruebas (test_tunel.py y test_docker_linux.py): mismos
# comandos y mensajes que usa api/tunel.py, sin conexión a Microsoft. Guarda su estado en $HOME/.simulado.
E="$HOME/.simulado"; mkdir -p "$E"
echo "$*" >> "$E/comandos"
case "$1 $2" in
    "user show")
        if [ -f "$E/sesion" ]; then echo "Logged in as prueba@empresa.com using Microsoft."; exit 0; fi
        echo "Not logged in."; exit 1 ;;
    "user login")
        echo "To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code PRUEBA123"
        touch "$E/sesion"; echo "Logged in as prueba@empresa.com using Microsoft."; exit 0 ;;
    "port create")
        if [ -f "$E/puerto-$3" ]; then echo "Tunnel port 8000 already exists."; exit 1; fi
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
        # ¿Llega a la API por localhost:8000 (red compartida con el servicio api)?
        python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=5)" > /dev/null 2>&1 \
            && echo si > "$E/api_alcanzable" || echo no > "$E/api_alcanzable"
        echo "Hosting port: 8000"
        echo "Connect via browser: https://$2-8000.brs.devtunnels.ms, https://$2.brs.devtunnels.ms"
        echo "Inspect network activity: https://$2-8000-inspect.brs.devtunnels.ms"
        echo "Ready to accept connections for tunnel: $2.brs"
        exec sleep 100000 ;;
esac
echo "Comando no simulado: $*"; exit 2
