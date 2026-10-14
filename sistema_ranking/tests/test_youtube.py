"""
Prueba la tarea de YouTube Charts con respuestas de YouTube simuladas (sin salir a internet).
Requiere la base instalada. Variables: PGURL (superusuario), DATABASE_URL (authenticator), STORAGE_DIR.
"""
import json
import os
import pathlib
import subprocess
import sys

import httpx

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "api"))
os.environ.setdefault("JWT_SECRET", "secreto-de-prueba-local-de-mas-de-32-caracteres")
import app as api  # noqa: E402
import youtube_job  # noqa: E402

PGURL = os.environ["PGURL"]
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sqlq(q):
    return subprocess.run(["psql", PGURL, "-At", "-c", q], capture_output=True, text=True, check=True).stdout.strip()


def respuesta(pais):
    vistas = [
        {"name": "Tema Compartido", "artists": [{"name": "Banda X"}], "viewCount": "123456",
         "encryptedVideoId": "abc123",
         "chartEntryMetadata": {"currentPosition": 1, "previousPosition": 2, "periodsOnChart": 7, "percentViewsChange": 0.125}},
        {"name": f"Solo {pais}", "artists": [{"name": "Uno"}, {"name": "Dos"}], "viewCount": "99",
         "chartEntryMetadata": {"currentPosition": 2, "periodsOnChart": 1}},
    ]
    return {"contents": {"sectionListRenderer": {"contents": [{"musicAnalyticsSectionRenderer": {"content": {
        "trackTypes": [{"trackViews": vistas}],
        "perspectiveMetadata": {"availableChartsInfo": [
            {"chartType": "CHART_TYPE_TRACKS", "chartPeriodType": "CHART_PERIOD_TYPE_WEEKLY", "latestEndDate": "2026-10-08"}]}}}}]}}}


def handler(request: httpx.Request):
    body = json.loads(request.content)
    gl = body["context"]["client"]["gl"]
    assert body["query"].endswith("&chart_params_period_type=WEEKLY") and f"chart_params_country_code={gl.lower()}" in body["query"]
    if gl == "PY":
        return httpx.Response(500)
    if gl == "EC":
        return httpx.Response(200, json={"contents": {}})
    return httpx.Response(200, json=respuesta(gl))


api.pool.open(wait=True)
cliente = httpx.Client(transport=httpx.MockTransport(handler))
resumen = youtube_job.correr(client=cliente)
por = {r["country"]: r for r in resumen}
check("8 países procesados en orden", [r["country"] for r in resumen] == youtube_job.COUNTRIES, resumen)
check("país con HTTP 500 informa el error y no frena a los demás", por["py"].get("error") == "HTTP 500", por["py"])
check("país sin filas informa 'sin filas en la respuesta'", por["ec"].get("error") == "sin filas en la respuesta", por["ec"])
check("países OK: 2 filas, sin errores", all(por[c]["rows"] == 2 and por[c]["errors"] == 0 for c in ["ar", "cl", "pe", "uy", "co", "mx"]), resumen)
check("la canción compartida se crea una sola vez", por["ar"]["created"] == 2 and por["cl"]["created"] == 1, (por["ar"], por["cl"]))
check("filas de YouTube con la fecha del chart (no la de hoy)",
      sqlq("select count(*) || '|' || min(snapshot_date) from territory_tracks where platform='youtube'") == "12|2026-10-08")
check("weekly_growth en porcentaje y link de YouTube",
      sqlq("select weekly_growth || '|' || uri from territory_tracks t join tracks_master m on m.id=t.track_master_id where platform='youtube' and m.track_name_raw='Tema Compartido' and pais_code='AR'")
      == "12.500|https://www.youtube.com/watch?v=abc123")
check("6 registros en csv_uploads con formato youtube y archivo",
      sqlq("select count(*) from csv_uploads where format='youtube' and file_path like '2026-10-08/auto_youtube_%.csv' and uploaded_by is null") == "6")
ruta = sqlq("select file_path from csv_uploads where format='youtube' and filename='youtube_charts_ar_2026-10-08.csv'")
archivo = pathlib.Path(os.environ["STORAGE_DIR"]) / "csv-uploads" / ruta
check("CSV guardado en el bucket con el encabezado original", archivo.exists() and archivo.read_text().startswith(
    "rank,track_name,artist_names,streams,previous_rank,weeks_on_chart,weekly_growth,uri\n1,Tema Compartido,Banda X,123456,2,7,12.5,"), archivo)
check("archivo registrado en storage.objects", sqlq(f"select count(*) from storage.objects where name='{ruta}'") == "1")

resumen2 = youtube_job.correr(client=cliente)
check("segunda corrida actualiza sin duplicar", sqlq("select count(*) from territory_tracks where platform='youtube'") == "12"
      and sum(r.get("created", 0) for r in resumen2) == 0, resumen2)

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
