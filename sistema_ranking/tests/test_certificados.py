"""
Prueba "bash ranking.sh certificados" sin Windows: un powershell.exe simulado devuelve los certificados raíz como lo
hace el de verdad desde WSL (PEM, con fin de línea de Windows) y un sudo simulado anota lo que se haría como root.
Revisa que queden en certificados/ (uno por archivo, válidos, sin \\r) y que se instalen en Ubuntu y se reinicie Docker.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

RAIZ = pathlib.Path(__file__).resolve().parents[1]
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


base = pathlib.Path(tempfile.mkdtemp(prefix="rk_cert_"))
proyecto = base / "sistema_ranking"
shutil.copytree(RAIZ, proyecto, ignore=shutil.ignore_patterns("tests", "__pycache__", "*.crt"))
bin_ = base / "bin"
bin_.mkdir()
pems = []
for i in range(3):
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", f"/CN=Raiz {i}",
                    "-keyout", str(base / f"k{i}"), "-out", str(base / f"c{i}.pem")], check=True, capture_output=True)
    pems.append((base / f"c{i}.pem").read_text())
(base / "salida_windows.txt").write_bytes("".join(pems).replace("\n", "\r\n").encode())
(bin_ / "powershell.exe").write_text(f"#!/bin/sh\ncat '{base / 'salida_windows.txt'}'\n")
destino = base / "ca-certificates"
(bin_ / "sudo").write_text(f"""#!/bin/sh
echo "$@" >> '{base / 'sudo.log'}'
case "$1" in
  mkdir) mkdir -p '{destino}' ;;
  cp) shift; n=$#; i=1; for f in "$@"; do [ $i -lt $n ] && cp "$f" '{destino}/'; i=$((i+1)); done ;;
esac
exit 0
""")
for f in bin_.iterdir():
    f.chmod(0o755)

r = subprocess.run(["bash", str(proyecto / "ranking.sh"), "certificados"], capture_output=True, text=True,
                   env=dict(os.environ, PATH=f"{bin_}:{os.environ['PATH']}"))
salida = r.stdout + r.stderr
guardados = sorted((proyecto / "certificados").glob("windows-*.crt"))
check("termina bien y avisa cuántos guardó", r.returncode == 0 and "3 certificados guardados" in salida, salida[-800:])
check("un certificado por archivo, sin fin de línea de Windows", len(guardados) == 3 and all(b"\r" not in f.read_bytes() for f in guardados))
validos = all(subprocess.run(["openssl", "x509", "-noout", "-in", str(f)], capture_output=True).returncode == 0 for f in guardados)
check("cada archivo es un certificado válido, idéntico al de Windows", validos and [f.read_text() for f in guardados] == pems)
sudo = (base / "sudo.log").read_text() if (base / "sudo.log").exists() else ""
check("los instala en Ubuntu y reinicia Docker", "update-ca-certificates" in sudo and "service docker restart" in sudo
      and len(list(destino.glob("windows-*.crt"))) == 3, sudo)
check("el LEEME de la carpeta sigue (la imagen no lo usa como certificado)", (proyecto / "certificados" / "LEEME.txt").exists())

shutil.rmtree(base, ignore_errors=True)
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
