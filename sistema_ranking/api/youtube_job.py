"""
Carga automática de YouTube Charts (antes Edge Function de Supabase + pg_cron).

Misma lógica que la Edge Function original:
  - 8 países, uno después del otro (en paralelo, países que comparten una canción
    chocaban al crearla y Postgres abortaba por bloqueo mutuo).
  - Chart semanal de canciones; la fecha es la del chart (latestEndDate), no "hoy".
  - Guarda con fn_upsert_ranking_batch(p_rows, 'youtube').
  - Archiva el CSV en el bucket csv-uploads: <fecha>/auto_youtube_<pais>_<ms>.csv
  - Deja el registro en csv_uploads (format = 'youtube').
Corre con el rol service_role (como la Edge Function con la service role key).

Programación: variable YOUTUBE_CRON (formato cron, hora de YOUTUBE_CRON_TZ).
Vacía = desactivada. También se puede correr a mano: POST /jobs/youtube (admin).
"""
import csv
import datetime as dt
import io
import json
import logging
import os
import sys
import threading
import time
import uuid
from zoneinfo import ZoneInfo

import httpx
from croniter import croniter

import app as api

log = logging.getLogger("ranking.youtube")

COUNTRIES = ["ar", "cl", "pe", "uy", "py", "co", "ec", "mx"]  # minúscula = como los pide YouTube

def verificacion_tls():
    """En Windows usa los certificados del sistema (así funciona detrás del proxy de la empresa, que inspecciona
    HTTPS con su propio certificado). En los demás sistemas, los de certifi, como siempre."""
    if sys.platform == "win32":
        try:
            import ssl
            import truststore
            return truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        except ImportError:
            pass
    return True

BROWSE_URL = "https://charts.youtube.com/youtubei/v1/browse?alt=json"
BUCKET = "csv-uploads"


def build_body(country_code):
    return {
        "context": {
            "client": {
                "clientName": "WEB_MUSIC_ANALYTICS", "clientVersion": "2.0", "hl": "es-419",
                "gl": country_code.upper(), "experimentIds": [], "experimentsToken": "", "theme": "MUSIC",
            },
            "capabilities": {},
            "request": {"internalExperimentFlags": []},
        },
        "browseId": "FEmusic_analytics_charts_home",
        "query": ("flags=MusicCharts__enable_apac_and_shorts_charts_expansion"
                  "&perspective=CHART_DETAILS"
                  f"&chart_params_country_code={country_code}"
                  "&chart_params_chart_type=TRACKS"
                  "&chart_params_period_type=WEEKLY"),
    }


def _get(d, *path):
    for p in path:
        if isinstance(p, int):
            d = d[p] if isinstance(d, list) and len(d) > p else None
        else:
            d = d.get(p) if isinstance(d, dict) else None
        if d is None:
            return None
    return d


def extract_rows(data):
    content = _get(data, "contents", "sectionListRenderer", "contents", 0, "musicAnalyticsSectionRenderer", "content")
    track_views = _get(content, "trackTypes", 0, "trackViews") or []
    infos = _get(content, "perspectiveMetadata", "availableChartsInfo") or []
    info = next((c for c in infos if c.get("chartType") == "CHART_TYPE_TRACKS"
                 and c.get("chartPeriodType") == "CHART_PERIOD_TYPE_WEEKLY"), None)
    snapshot = (info or {}).get("latestEndDate") or dt.date.today().isoformat()
    rows = []
    for t in track_views:
        meta = t.get("chartEntryMetadata") or {}
        growth = meta.get("percentViewsChange")
        vid = t.get("encryptedVideoId")
        rows.append({
            "track_name": t.get("name"),
            "artist_names": ", ".join(a.get("name", "") for a in (t.get("artists") or [])),
            "rank": meta.get("currentPosition"),
            "peak_rank": None,
            "previous_rank": meta.get("previousPosition"),
            "weeks_on_chart": meta.get("periodsOnChart"),
            "streams": t.get("viewCount"),
            "source": None,
            "uri": f"https://www.youtube.com/watch?v={vid}" if vid else None,
            "weekly_growth": growth * 100 if isinstance(growth, (int, float)) and not isinstance(growth, bool) else None,
            "snapshot_date": snapshot,
        })
    return rows, snapshot


def to_csv(rows):
    headers = ["rank", "track_name", "artist_names", "streams", "previous_rank", "weeks_on_chart", "weekly_growth", "uri"]
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(headers)
    for r in rows:
        w.writerow(["" if r.get(h) is None else r.get(h) for h in headers])
    return buf.getvalue()


def _guardar_archivo(cur, nombre, contenido):
    nombre, destino = api._ruta_segura(BUCKET, nombre)
    cur.execute("INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (%s, %s, %s)",
                (BUCKET, nombre, json.dumps({"size": len(contenido), "mimetype": "text/csv"})))
    destino.parent.mkdir(parents=True, exist_ok=True)
    tmp = destino.with_name(destino.name + f".{uuid.uuid4().hex}.tmp")
    tmp.write_bytes(contenido)
    os.replace(tmp, destino)
    return nombre


def process_country(country, client):
    try:
        res = client.post(BROWSE_URL, json=build_body(country), timeout=60)
        if res.status_code >= 400:
            return {"country": country, "error": f"HTTP {res.status_code}"}
        rows, snapshot = extract_rows(res.json())
        if not rows:
            return {"country": country, "error": "sin filas en la respuesta"}
        for r in rows:
            r["pais_code"] = country.upper()

        with api.transaccion(rol="service_role") as cur:
            cur.execute("SELECT * FROM public.fn_upsert_ranking_batch(p_rows => %s, p_platform => %s)",
                        (json.dumps(rows), "youtube"))
            resultados = cur.fetchall()
        created = sum(1 for r in resultados if r["track_created"])
        errors = [{"idx": r["idx"], "error_message": r["error_message"]} for r in resultados if r["error_message"]]

        path = f"{snapshot}/auto_youtube_{country}_{int(time.time() * 1000)}.csv"
        upload_error = None
        try:
            with api.transaccion(rol="service_role") as cur:
                path = _guardar_archivo(cur, path, to_csv(rows).encode("utf-8"))
        except Exception as e:  # noqa: BLE001
            upload_error = str(e)

        log_error = None
        try:
            with api.transaccion(rol="service_role") as cur:
                cur.execute("""INSERT INTO public.csv_uploads
                               (filename, total_rows, updated_rows, created_tracks, error_count, errors, file_path, format)
                               VALUES (%s, %s, %s, %s, %s, %s, %s, 'youtube')""",
                            (f"youtube_charts_{country}_{snapshot}.csv", len(rows), len(rows) - len(errors), created,
                             len(errors), json.dumps(errors[:100]), None if upload_error else path))
        except Exception as e:  # noqa: BLE001
            log_error = str(e)

        return {"country": country, "rows": len(rows), "created": created, "errors": len(errors),
                "sample_error": errors[0]["error_message"] if errors else None,
                "upload_error": upload_error, "log_insert_error": log_error}
    except Exception as e:  # noqa: BLE001
        return {"country": country, "error": str(e)}


_corriendo = threading.Lock()


def correr(client=None):
    """Corre la carga completa. Si ya hay una corriendo (acá o en otro proceso), no hace nada."""
    if not _corriendo.acquire(blocking=False):
        return [{"error": "ya hay una carga de YouTube en curso"}]
    try:
        with api.pool.connection() as conn:
            if not conn.execute("SELECT pg_try_advisory_lock(727001)").fetchone()[0]:
                return [{"error": "ya hay una carga de YouTube en curso en otro proceso"}]
            try:
                propio = client is None
                client = client or httpx.Client(headers={"Content-Type": "application/json"}, verify=verificacion_tls())
                try:
                    resumen = [process_country(c, client) for c in COUNTRIES]
                finally:
                    if propio:
                        client.close()
                log.info("YouTube: %s", json.dumps(resumen))
                return resumen
            finally:
                conn.execute("SELECT pg_advisory_unlock(727001)")
    finally:
        _corriendo.release()


def iniciar_programador():
    expr = os.environ.get("YOUTUBE_CRON", "").strip()
    if not expr:
        log.info("YouTube: programación desactivada (YOUTUBE_CRON vacío)")
        return
    tz = ZoneInfo(os.environ.get("YOUTUBE_CRON_TZ", "America/Argentina/Buenos_Aires"))

    def bucle():
        it = croniter(expr, dt.datetime.now(tz))
        while True:
            proxima = it.get_next(dt.datetime)
            log.info("YouTube: próxima carga %s", proxima.isoformat())
            time.sleep(max(0, (proxima - dt.datetime.now(tz)).total_seconds()))
            try:
                correr()
            except Exception:  # noqa: BLE001
                log.exception("YouTube: falló la carga programada")

    threading.Thread(target=bucle, name="youtube-cron", daemon=True).start()
