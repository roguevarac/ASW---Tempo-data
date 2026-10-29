"""
Prueba "bash ranking.sh acceso-directo" (la aplicación de Windows) sin Windows: powershell.exe y wslpath simulados.
1) Lo que deja en %LOCALAPPDATA%\\RankingDigital: lanzar.ps1 (BOM y CRLF, con distro/proyecto/puerto, se lee sin errores
   en PowerShell), iniciando.html con el puerto, el ícono, y que borra el lanzador viejo con ventana negra.
2) Los accesos (script de PowerShell que los crea): escritorio, menú Inicio (abrir y apagar), inicio de Windows solo si
   se pide, ocultos (sin ventana), con el ícono; rutas con espacio y apóstrofo bien escapadas.
3) El lanzador en funcionamiento (lanzar.ps1 real en PowerShell, con Windows simulado: procesos, navegador, servidor):
   servidor apagado -> enciende (Docker como root + mantenedor oculto) y abre la ventana de "iniciando";
   servidor prendido -> abre la aplicación en ventana propia (Edge --app); mantenedor ya corriendo -> no lo duplica;
   -SoloServidor -> enciende sin abrir nada; -Apagar -> detiene y corta el mantenedor.
Variables: PWSH (PowerShell; sin él se saltean las partes 1-3 que lo necesitan).
"""
import json
import os
import re
import pathlib
import shutil
import subprocess
import sys
import tempfile

import pexpect

RAIZ = pathlib.Path(__file__).resolve().parents[1]
PWSH = os.environ.get("PWSH") or str(pathlib.Path(os.environ.get("CACHE_PRUEBAS", "/var/tmp/rk_pruebas_cache")) / "pwsh" / "pwsh")
HAY_PWSH = pathlib.Path(PWSH).exists()
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


base = pathlib.Path(tempfile.mkdtemp(prefix="rk_lnk_"))
proyecto = base / "home" / "proyectos" / "ranking" / "sistema_ranking"
shutil.copytree(RAIZ, proyecto, ignore=shutil.ignore_patterns("tests", "__pycache__"))
config = base / "ranking.env"
config.write_text("PUERTO=8123\n")
c = base / "c"
LOCAL = r"C:\Users\Juan O'Neil\AppData\Local"
LOCAL_SH = LOCAL.replace("'", "'\\''")
bin_ = base / "bin"
bin_.mkdir()
(bin_ / "powershell.exe").write_text(f"""#!/bin/sh
for a in "$@"; do ultimo="$a"; done
case "$ultimo" in
  *'$env:LOCALAPPDATA'*) printf '%s\\r\\n' '{LOCAL_SH}' ;;
  *CreateShortcut*) n=$(ls '{base}'/ps_*.txt 2>/dev/null | wc -l); printf '%s' "$ultimo" > '{base}'/ps_$n.txt
                    printf 'C:\\\\Users\\\\Juan\\\\OneDrive\\\\Desktop\\\\Auditor de Rankings Digitales.lnk\\r\\n' ;;
esac
""")
(bin_ / "wslpath").write_text(f"""#!/bin/sh
[ "$1" = "-u" ] && shift
printf '%s\\n' "$1" | sed -e 's#^C:#{c}#' -e 's#\\\\#/#g'
""")
for f in bin_.iterdir():
    f.chmod(0o755)
ENTORNO = dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}", RK_CONFIG=str(config), WSL_DISTRO_NAME="Ubuntu-26.04", TERM="dumb")
carpeta = c / "Users" / "Juan O'Neil" / "AppData" / "Local" / "RankingDigital"
carpeta.mkdir(parents=True)
(carpeta / "Ranking Digital.cmd").write_text("lanzador viejo")


def correr(respuesta):
    p = pexpect.spawn("bash", [str(proyecto / "ranking.sh"), "acceso-directo"], env=ENTORNO, encoding="utf-8", timeout=60)
    p.expect(r"arranque solo \(oculto\) cada vez que entrás a Windows\? .*\(S/N\)")
    p.sendline(respuesta)
    p.expect(pexpect.EOF)
    p.close()
    return p.exitstatus, p.before


# ================================================================ 1) archivos
codigo, salida = correr("N")
check("termina bien y lista los accesos creados", codigo == 0 and "Auditor de Rankings Digitales.lnk" in salida, salida[-600:])
lanzar = (carpeta / "lanzar.ps1").read_bytes() if (carpeta / "lanzar.ps1").exists() else b""
check("lanzar.ps1 con BOM y fin de línea de Windows (para PowerShell 5.1)",
      lanzar.startswith(b"\xef\xbb\xbf") and lanzar.count(b"\n") == lanzar.count(b"\r\n") > 20)
texto = lanzar.decode("utf-8-sig")
check("lanzar.ps1 con la distro, la carpeta del proyecto y el puerto de esta PC",
      "$Distro = 'Ubuntu-26.04'" in texto and f"$Proyecto = '{proyecto}'" in texto and "$Puerto = 8123" in texto
      and not re.search(r"__[A-Z_]+__", texto), texto[:600])   # sin marcadores sin completar (la carpeta temporal puede tener "__")
sin_susp = (carpeta / "sin-suspension.ps1").read_bytes() if (carpeta / "sin-suspension.ps1").exists() else b""
check("sin-suspension.ps1 (la PC no se suspende mientras se comparte), con BOM y fin de línea de Windows",
      sin_susp.startswith(b"\xef\xbb\xbf") and sin_susp.count(b"\n") == sin_susp.count(b"\r\n") > 3
      and b"SetThreadExecutionState" in sin_susp, sin_susp[:200])
check("iniciando.html espera al puerto de esta PC", "http://localhost:8123/" in (carpeta / "iniciando.html").read_text())
check("ícono copiado", (carpeta / "ranking.ico").read_bytes() == (RAIZ / "windows" / "ranking.ico").read_bytes())
check("borra el lanzador viejo (el de la ventana negra)", not (carpeta / "Ranking Digital.cmd").exists())
check("recuerda la elección para regenerarlo al actualizar", "ACCESO_DIRECTO=1" in config.read_text() and "INICIO_AUTOMATICO=N" in config.read_text())

# ================================================================ 2) accesos
ps = (base / "ps_0.txt").read_text() if (base / "ps_0.txt").exists() else ""
check("accesos en el escritorio y en el menú Inicio (abrir y apagar)",
      "Acceso $escritorio 'Auditor de Rankings Digitales' ''" in ps and "Acceso $menu 'Auditor de Rankings Digitales' ''" in ps
      and "Acceso $menu 'Apagar Auditor de Rankings Digitales' ' -Apagar'" in ps
      and "Remove-Item (Join-Path $escritorio 'Ranking Digital.lnk')" in ps and "Remove-Item (Join-Path $programas 'Ranking Digital') -Recurse" in ps, ps)
check("ocultos: PowerShell sin ventana, minimizado, con el ícono",
      "-WindowStyle Hidden -File" in ps and "$a.WindowStyle = 7" in ps
      and r"$a.IconLocation = 'C:\Users\Juan O''Neil\AppData\Local\RankingDigital\ranking.ico' + ',0'" in ps, ps)
check("apuntan a lanzar.ps1 (apóstrofo bien escapado)", r"'C:\Users\Juan O''Neil\AppData\Local\RankingDigital\lanzar.ps1'" in ps, ps)
check("registra el enlace auditor-rankings:// para este usuario (sin administrador): enciende el servidor oculto",
      r"'HKCU:\Software\Classes\auditor-rankings'" in ps and "'URL Protocol'" in ps
      and r"""-WindowStyle Hidden -File "' + 'C:\Users\Juan O''Neil\AppData\Local\RankingDigital\lanzar.ps1' + '" -SoloServidor')""" in ps, ps[-900:])
check("sin pedirlo, no lo agrega al inicio de Windows (y saca el viejo)", "if (0 -eq 1)" in ps and "Remove-Item (Join-Path $inicio 'Ranking Digital.lnk')" in ps)
if HAY_PWSH:
    for nombre, contenido in (("accesos.ps1", ps), ("lanzar.ps1", texto), ("sin-suspension.ps1", sin_susp.decode("utf-8-sig"))):
        (base / nombre).write_text(contenido)
        r = subprocess.run([PWSH, "-NoProfile", "-Command", "$e=$null; $t=$null; [System.Management.Automation.Language.Parser]::"
                            f"ParseFile('{base / nombre}', [ref]$t, [ref]$e) | Out-Null; $e.Count"], capture_output=True, text=True)
        check(f"{nombre} se lee sin errores en PowerShell", r.stdout.strip() == "0", r.stdout + r.stderr)
codigo, salida = correr("S")
ps = (base / "ps_1.txt").read_text() if (base / "ps_1.txt").exists() else ""
check("si se pide, enciende el servidor (oculto) al iniciar Windows", codigo == 0 and "if (1 -eq 1) { Acceso $inicio 'Auditor de Rankings Digitales' ' -SoloServidor'" in ps, ps)
check("y lo recuerda", "INICIO_AUTOMATICO=S" in config.read_text())

# ================================================================ 3) el lanzador funcionando
if HAY_PWSH:
    pf = base / "ProgramFiles(x86)"
    (pf / "Microsoft" / "Edge" / "Application").mkdir(parents=True)
    (pf / "Microsoft" / "Edge" / "Application" / "msedge.exe").write_text("")

    (base / "lanzar_compartiendo.ps1").write_text(texto.replace("$Compartir = $false", "$Compartir = $true"))

    def lanzador(*args, responde=False, mantenedor=False, compartiendo=False):
        """Corre lanzar.ps1 con Windows simulado; devuelve la lista de programas que lanzó."""
        stubs = f"""
            $global:llamadas = @()
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', '{pf}')
            function Start-Process {{ param($FilePath, $ArgumentList, $WindowStyle, [switch]$Wait)
                $global:llamadas += ,@{{ programa = $FilePath; args = (@($ArgumentList) -join ' '); oculto = ($WindowStyle -eq 'Hidden'); espera = [bool]$Wait }} }}
            function Invoke-WebRequest {{ if ({'$true' if responde else '$false'}) {{ return @{{ StatusCode = 200 }} }} else {{ throw 'sin servidor' }} }}
            function Get-CimInstance {{ if ({'$true' if mantenedor else '$false'}) {{ return @(@{{ ProcessId = 4242; CommandLine = 'wsl.exe -d Ubuntu-26.04 --cd x -- bash ranking.sh abrir --mantener --sin-navegador' }}) }} }}
            function Stop-Process {{ param($Id, [switch]$Force) $global:llamadas += ,@{{ programa = 'Stop-Process'; args = "$Id"; oculto = $true; espera = $false }} }}
            & '{base / ("lanzar_compartiendo.ps1" if compartiendo else "lanzar.ps1")}' {' '.join(args)}
            $global:llamadas | ConvertTo-Json -Compress -Depth 3
        """
        r = subprocess.run([PWSH, "-NoProfile", "-Command", stubs], capture_output=True, text=True, timeout=60)
        try:
            salida = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else []
            return salida if isinstance(salida, list) else [salida], r.stderr
        except (json.JSONDecodeError, IndexError):
            return [], r.stdout + r.stderr

    ll, err = lanzador()
    progs = [(x["programa"], x["args"], x["oculto"]) for x in ll]
    check("servidor apagado: arranca Docker como root (oculto, esperando)",
          ll and ll[0]["programa"] == "wsl.exe" and "-d Ubuntu-26.04 -u root -- service docker start" in ll[0]["args"] and ll[0]["oculto"] and ll[0]["espera"], (progs, err))
    check("...enciende el mantenedor oculto en la carpeta del proyecto",
          len(ll) > 1 and ll[1]["programa"] == "wsl.exe" and ll[1]["oculto"] and not ll[1]["espera"]
          and f"--cd {proyecto} -- bash ranking.sh abrir --mantener --sin-navegador" in ll[1]["args"], progs)
    check("...y abre la ventana propia con la pantalla de 'iniciando'",
          len(ll) > 2 and ll[2]["programa"].endswith("msedge.exe") and ll[2]["args"].startswith("--app=file://")
          and ll[2]["args"].endswith("iniciando.html"), progs)
    ll, err = lanzador(responde=True, mantenedor=True)
    check("servidor prendido y mantenido: solo abre la aplicación en su ventana (Edge --app), sin duplicar nada",
          [(x["programa"].endswith("msedge.exe"), x["args"]) for x in ll] == [(True, "--app=http://localhost:8123/")], (ll, err))
    ll, err = lanzador(responde=True)
    check("servidor prendido sin mantenedor (por ej. desde una terminal): lo mantiene y abre la aplicación",
          [x["programa"] for x in ll][:2] == ["wsl.exe", "wsl.exe"] and ll[-1]["args"] == "--app=http://localhost:8123/", (ll, err))
    ll, err = lanzador("-SoloServidor")
    check("-SoloServidor (inicio de Windows): enciende sin abrir ninguna ventana",
          [x["programa"] for x in ll] == ["wsl.exe", "wsl.exe"] and all(x["oculto"] for x in ll), (ll, err))
    ll, err = lanzador("-SoloServidor", compartiendo=True)
    check("compartiendo: al encender, también evita que la PC se suspenda (sin-suspension.ps1, oculto)",
          [x["programa"] for x in ll] == ["powershell.exe", "wsl.exe", "wsl.exe"] and "sin-suspension.ps1" in ll[0]["args"]
          and ll[0]["oculto"] and "-WindowStyle Hidden" in ll[0]["args"], (ll, err))
    ll, err = lanzador("-Apagar", mantenedor=True)
    check("-Apagar: detiene el sistema y corta el mantenedor",
          len(ll) == 2 and "bash ranking.sh detener" in ll[0]["args"] and ll[0]["espera"] and ll[1] == {
              "programa": "Stop-Process", "args": "4242", "oculto": True, "espera": False}, (ll, err))

shutil.rmtree(base, ignore_errors=True)
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
