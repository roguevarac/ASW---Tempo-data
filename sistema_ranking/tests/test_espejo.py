"""
Espejo de auditoría en OneDrive (api/espejo.py): dónde va cada carga, que nunca interrumpe nada y que solo escribe.
Con PGURL y STORAGE_DIR (como en correr_todo, después de la prueba del navegador) también prueba la sincronización
de todas las cargas registradas.
"""
import os
import pathlib
import shutil
import stat
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "api"))
import espejo  # noqa: E402

fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


tmp = pathlib.Path(tempfile.mkdtemp())
storage = tmp / "storage"
base = tmp / "OneDrive - Sony" / "RANKING DIGITAL REGIONAL"


def archivo(ruta, contenido="rank\n1\n"):
    f = storage / "csv-uploads" / ruta
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(contenido, encoding="utf-8")
    return ruta


def carga(fmt, ruta, nombre, cargadas=1):
    return {"format": fmt, "file_path": ruta, "filename": nombre, "updated_rows": cargadas}


# ---- sin carpeta configurada: no hace nada
os.environ.pop("ESPEJO", None)
check("sin ESPEJO no copia nada ni falla",
      espejo.copiar(carga("spotify", archivo("spotify/AR/2026-10-22/1_a.csv"), "a.csv"), storage) is False and not base.exists())

# ---- sin carpeta (servidor sin OneDrive, como en AWS): el servicio queda encendido y no copia; el comando suelto avisa
import subprocess  # noqa: E402
import time  # noqa: E402
_entorno = {k: v for k, v in os.environ.items() if k != "ESPEJO"}
_entorno["PGURL"] = "postgresql://nadie@127.0.0.1:1/nada?connect_timeout=1"   # sin base: el latido falla y se ignora
_script = str(pathlib.Path(espejo.__file__))
_servicio = subprocess.Popen([sys.executable, _script, "--servicio"], env=_entorno,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(4)
_sigue = _servicio.poll() is None
_servicio.kill()
_salida = _servicio.communicate()[0]
check("sin ESPEJO, el servicio queda encendido (no se reinicia sin fin)", _sigue and "apagado" in _salida, _salida)
_suelto = subprocess.run([sys.executable, _script], env=_entorno, capture_output=True, text=True)
check("sin ESPEJO, el comando suelto avisa y sale con error",
      _suelto.returncode != 0 and "No hay carpeta de espejo" in _suelto.stderr, (_suelto.returncode, _suelto.stderr))

os.environ["ESPEJO"] = str(base)
casos = [
    (carga("spotify", archivo("spotify/AR/2026-10-22/1_regional-ar-weekly-2026-10-15.csv"), "regional-ar-weekly-2026-10-15.csv"),
     "Spotify Charts/ar/regional-ar-weekly-2026-10-15.csv"),
    (carga("youtube", archivo("youtube/PY/2026-10-22/2_y.csv"), "youtube-charts-top-songs-py-weekly-20230309.csv"),
     "Youtube Charts/py/youtube-charts-top-songs-py-weekly-20230309.csv"),
    (carga("bo_report", archivo("bo_report/CL/2026-10-22/3_bo.csv"), "Reporte_PAIS_CHILE.csv"),
     "Reportes BackOffice/cl/Reporte_PAIS_CHILE.csv"),
    (carga("tempo_report", archivo("tempo_report/2026-10-22/4_t.csv"), "reporte tempo.csv"),
     "Reportes Tempo Control/reporte tempo.csv"),
    (carga("master_tempo", archivo("tempo_ids/2026-10-22/5_ids.csv"), "tempo_ids.csv"),
     "Reportes Tempo Control/Tempo IDs/tempo_ids.csv"),
    (carga("spotify", archivo("spotify/2026-10-22/6_viejo.csv"), "regional-uy-weekly-2021-01-07.csv"),   # carpeta vieja, sin país
     "Spotify Charts/sin_pais/regional-uy-weekly-2021-01-07.csv"),
    (carga("spotify", archivo("spotify/AR/2026-10-22/7_r.csv"), 'semana: "1/2"?.csv'),
     "Spotify Charts/ar/semana_ _1_2__.csv"),
]
for c, esperado in casos:
    check(f"{c['format']} '{c['filename']}' -> {esperado}",
          espejo.copiar(c, storage) is True and (base / esperado).read_text() == "rank\n1\n",
          sorted(str(p.relative_to(base)) for p in base.rglob("*") if p.is_file()))
check("deja el LEEME que explica que la carpeta es un respaldo que no afecta al sistema",
      "no cambian" in (base / "LEEME - Respaldo y auditoria.txt").read_text(encoding="utf-8"))
check("no quedan archivos a medio copiar", not list(base.rglob("*.copiando")))

# ---- lo que no es una carga, o no cargó nada: no va al espejo
for c in [carga("bo_generado", archivo("bo_generado/2026-10-22/8_r.csv"), "reporte_bo_carga3.csv"),
          carga("csv_principal", archivo("csv_principal/2026-10-22/9_t.csv"), "tabla_principal.csv"),
          carga("spotify", archivo("spotify/AR/2026-10-22/10_e.csv"), "con-errores.csv", cargadas=0),
          carga(None, None, "sin-formato.csv", cargadas=0)]:
    check(f"no copia '{c['filename']}' ({c['format']}, {c['updated_rows']} cargadas)",
          espejo.copiar(c, storage) is False and not list(base.rglob(c["filename"])))

# ---- nunca interrumpe: falta el archivo de origen, o no se puede escribir en el espejo
check("si falta el archivo de origen, avisa sin fallar",
      espejo.copiar(carga("spotify", "spotify/AR/x/no-existe.csv", "no-existe.csv"), storage) is False)
bloqueada = base / "Youtube Charts" / "py"
bloqueada.chmod(stat.S_IRUSR | stat.S_IXUSR)
try:
    if os.geteuid() != 0:   # root escribe igual: solo se prueba con un usuario común
        check("si no se puede escribir en OneDrive, avisa sin fallar",
              espejo.copiar(carga("youtube", archivo("youtube/PY/x/11.csv"), "otra.csv"), storage) is False)
finally:
    bloqueada.chmod(0o755)

# ---- solo escribe: borrar algo en el espejo no cambia el sistema, y se vuelve a copiar
(base / "Spotify Charts/ar/regional-ar-weekly-2026-10-15.csv").unlink()
check("borrar un archivo del espejo no toca el original del sistema",
      (storage / "csv-uploads/spotify/AR/2026-10-22/1_regional-ar-weekly-2026-10-15.csv").exists())
check("sincronizar sin pisar: lo existente queda y lo que falta vuelve",
      espejo.copiar(casos[0][0], storage, solo_faltantes=True) and (base / casos[0][1]).exists())

# ---- sincronización de todas las cargas registradas en la base (si hay una)
if os.environ.get("PGURL") and os.environ.get("STORAGE_DIR"):
    import psycopg
    otra = tmp / "espejo-completo"
    os.environ["ESPEJO"] = str(otra)
    copiadas, aplica = espejo.sincronizar(os.environ["PGURL"], os.environ["STORAGE_DIR"])
    with psycopg.connect(os.environ["PGURL"]) as con:
        esperadas = con.execute("select count(*) from csv_uploads where updated_rows > 0 and file_path is not null and format in "
                                "('spotify','youtube','bo_report','tempo_report','master_tempo')").fetchone()[0]
    en_espejo = [p for p in otra.rglob("*.csv")]
    check("sincronizar: copia todas las cargas registradas de la base", copiadas == aplica == esperadas > 0
          and len(en_espejo) <= esperadas, (copiadas, aplica, esperadas, len(en_espejo)))
    again = espejo.sincronizar(os.environ["PGURL"], os.environ["STORAGE_DIR"])
    check("sincronizar dos veces no duplica nada", again == (copiadas, aplica) and len(list(otra.rglob("*.csv"))) == len(en_espejo))

    # ---- servicio sin carpeta (servidor sin OneDrive, 18/11/2026): queda en espera e informa al Panel; antes terminaba
    # con error, Docker lo reiniciaba sin fin y "verificar" mostraba "Contenedor espejo apagado".
    import subprocess
    import time
    entorno = {k: v for k, v in os.environ.items() if k != "ESPEJO"}
    with psycopg.connect(os.environ["PGURL"], autocommit=True) as con:
        con.execute("delete from panel.servicios where servicio = 'espejo'")
    proc = subprocess.Popen([sys.executable, str(pathlib.Path(espejo.__file__)), "--servicio"], env=entorno,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        time.sleep(4)
        sigue = proc.poll() is None
        with psycopg.connect(os.environ["PGURL"]) as con:
            latido = con.execute("select detalle->>'apagado' from panel.servicios where servicio = 'espejo'").fetchone()
    finally:
        proc.kill()
    check("servicio sin carpeta de OneDrive: sigue en espera (no se reinicia sin fin) y avisa al Panel que está apagado",
          sigue and latido == ("true",), (sigue, latido, proc.stderr.read().decode()[-400:]))

shutil.rmtree(tmp, ignore_errors=True)
print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
