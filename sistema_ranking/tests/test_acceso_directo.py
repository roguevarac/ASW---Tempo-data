"""
Prueba "bash ranking.sh acceso-directo" sin Windows: powershell.exe y wslpath simulados (como en WSL). Revisa:
- el lanzador .cmd (fin de línea de Windows, arranca Docker como root de WSL y después el sistema con la ventana abierta);
- el ícono copiado a la carpeta del usuario de Windows;
- el script de PowerShell que crea los accesos directos: se lee sin errores en PowerShell real, apunta al lanzador y
  al ícono (con una carpeta de usuario con espacio y apóstrofo, para probar las comillas) y agrega el de inicio de
  Windows solo si se pide.
Variables: PWSH (PowerShell, para leer el script; si no está, se saltea esa parte).
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

import pexpect

RAIZ = pathlib.Path(__file__).resolve().parents[1]
PWSH = os.environ.get("PWSH") or str(pathlib.Path(os.environ.get("CACHE_PRUEBAS", "/var/tmp/rk_pruebas_cache")) / "pwsh" / "pwsh")
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


base = pathlib.Path(tempfile.mkdtemp(prefix="rk_lnk_"))
proyecto = base / "home" / "proyectos" / "ranking" / "sistema_ranking"
shutil.copytree(RAIZ, proyecto, ignore=shutil.ignore_patterns("tests", "__pycache__"))
config = base / "ranking.env"
config.write_text("PUERTO=8000\n")
c = base / "c"
LOCAL = r"C:\Users\Juan O'Neil\AppData\Local"
bin_ = base / "bin"
bin_.mkdir()
LOCAL_SH = LOCAL.replace("'", "'\\''")
(bin_ / "powershell.exe").write_text(f"""#!/bin/sh
for a in "$@"; do ultimo="$a"; done
case "$ultimo" in
  *'$env:LOCALAPPDATA'*) printf '%s\\r\\n' '{LOCAL_SH}' ;;
  *CreateShortcut*) n=$(ls '{base}'/ps_*.txt 2>/dev/null | wc -l); printf '%s' "$ultimo" > '{base}'/ps_$n.txt
                    printf 'C:\\\\Users\\\\Juan\\\\Desktop\\r\\n' ;;
esac
""")
(bin_ / "wslpath").write_text(f"""#!/bin/sh
[ "$1" = "-u" ] && shift
printf '%s\\n' "$1" | sed -e 's#^C:#{c}#' -e 's#\\\\#/#g'
""")
for f in bin_.iterdir():
    f.chmod(0o755)
ENTORNO = dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}", RK_CONFIG=str(config), WSL_DISTRO_NAME="Ubuntu-26.04", TERM="dumb")


def correr(respuesta):
    p = pexpect.spawn("bash", [str(proyecto / "ranking.sh"), "acceso-directo"], env=ENTORNO, encoding="utf-8", timeout=60)
    p.expect(r"arranque solo cada vez que entrás a Windows\? .*\(S/N\)")
    p.sendline(respuesta)
    p.expect(pexpect.EOF)
    p.close()
    return p.exitstatus, p.before


codigo, salida = correr("N")
carpeta = c / "Users" / "Juan O'Neil" / "AppData" / "Local" / "RankingDigital"
lanzador = carpeta / "Ranking Digital.cmd"
check("termina bien y dice dónde quedó el ícono", codigo == 0 and "Desktop" in salida, salida[-600:])
check("el ícono queda en la carpeta del usuario de Windows", (carpeta / "ranking.ico").read_bytes() == (RAIZ / "windows" / "ranking.ico").read_bytes())
cmd = lanzador.read_bytes() if lanzador.exists() else b""
check("el lanzador tiene fin de línea de Windows", cmd.count(b"\r\n") == 5 and cmd.count(b"\n") == 5, cmd)
texto = cmd.decode()
check("el lanzador arranca Docker como root de WSL (sin pedir contraseña)",
      'wsl.exe -d "Ubuntu-26.04" -u root -- service docker start' in texto)
check("y después el sistema, con la ventana abierta, desde la carpeta del proyecto",
      f'wsl.exe -d "Ubuntu-26.04" --cd "{proyecto}" -- bash ranking.sh abrir --mantener' in texto)
check("si algo falla, la ventana espera para que se lea el motivo", "if errorlevel 1 pause" in texto)
ps = (base / "ps_0.txt").read_text() if (base / "ps_0.txt").exists() else ""
check("el acceso directo apunta al lanzador y al ícono (con el apóstrofo bien escapado)",
      r"TargetPath = 'C:\Users\Juan O''Neil\AppData\Local\RankingDigital\Ranking Digital.cmd'" in ps
      and r"IconLocation = 'C:\Users\Juan O''Neil\AppData\Local\RankingDigital\ranking.ico,0'" in ps, ps)
check("sin pedirlo, no lo agrega al inicio de Windows", "if (0 -eq 1)" in ps, ps)
if pathlib.Path(PWSH).exists():
    (base / "acceso.ps1").write_text(ps)
    r = subprocess.run([PWSH, "-NoProfile", "-Command", "$e=$null; $t=$null; [System.Management.Automation.Language.Parser]::"
                        f"ParseFile('{base / 'acceso.ps1'}', [ref]$t, [ref]$e) | Out-Null; $e.Count"], capture_output=True, text=True)
    check("el script de PowerShell se lee sin errores", r.stdout.strip() == "0", r.stdout + r.stderr)

codigo, salida = correr("S")
ps = (base / "ps_1.txt").read_text() if (base / "ps_1.txt").exists() else ""
check("si se pide, también lo agrega al inicio de Windows", codigo == 0 and "if (1 -eq 1)" in ps and "GetFolderPath('Startup')" in ps, ps)

shutil.rmtree(base, ignore_errors=True)
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
