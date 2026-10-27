"""
Prueba de punta a punta del sistema propio: hace por HTTP las mismas operaciones que el
front (con los mismos parámetros que manda tempo-client.js) y revisa la lógica de negocio
y la seguridad. También corre la tarea de YouTube con una respuesta de YouTube simulada.

Requiere: la base instalada (tests/reinstalar_local.sh), los usuarios de prueba y la API
corriendo. Ver tests/correr_todo.sh.
"""
import json
import os
import subprocess
import sys

import httpx

BASE = os.environ.get("BASE", "http://localhost:8787")
PGURL = os.environ["PGURL"]
fallas = []


def check(nombre, cond, extra=""):
    print(("OK   " if cond else "FAIL ") + nombre + ("" if cond else f"  -> {extra}"))
    if not cond:
        fallas.append(nombre)


def sqlq(q):
    r = subprocess.run(["psql", PGURL, "-At", "-c", q], capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"SQL del test falló: {q}\n{r.stderr}")
    return r.stdout.strip()


def login(email, pw):
    r = httpx.post(f"{BASE}/auth/login", json={"email": email, "password": pw})
    return r


class Cliente:
    def __init__(self, token):
        self.h = {"Authorization": f"Bearer {token}"}

    def rpc(self, fn, params=None, **qs):
        return httpx.post(f"{BASE}/rpc/{fn}", json=params or {}, params=qs, headers=self.h, timeout=60)

    def get(self, tabla, params, csv=False):
        h = dict(self.h, **({"Accept": "text/csv"} if csv else {}))
        return httpx.get(f"{BASE}/rest/{tabla}", params=params, headers=h)

    def patch(self, tabla, filtros, cambios):
        return httpx.patch(f"{BASE}/rest/{tabla}", params=filtros, json=cambios, headers=self.h)

    def post(self, tabla, fila):
        return httpx.post(f"{BASE}/rest/{tabla}", json=fila, headers=self.h)


# ------------------------------------------------------------------ login
r = login("admin@prueba.local", "mal")
check("login con contraseña mala da un mensaje claro", r.status_code == 400 and r.json()["message"] == "El email o la contraseña no son correctos.", r.text)
r = login("admin@prueba.local", "clave-admin-123")
check("login admin", r.status_code == 200 and r.json()["access_token"], r.text)
admin = Cliente(r.json()["access_token"]); admin_id = r.json()["user"]["id"]
est = Cliente(login("estandar@prueba.local", "clave-estandar-123").json()["access_token"])
aud = Cliente(login("auditor@prueba.local", "clave-auditor-123").json()["access_token"])
check("sin token: 401", httpx.get(f"{BASE}/rest/tracks_master").status_code == 401)
check("token falso: 401", httpx.get(f"{BASE}/rest/tracks_master", headers={"Authorization": "Bearer xx"}).status_code == 401)

# ------------------------------------------------------------------ perfil (loadProfile)
r = admin.get("app_users", {"select": "app_role,oficina", "user_id": f"eq.{admin_id}", "single": "1"})
check("perfil del usuario (.single())", r.status_code == 200 and r.json() == {"app_role": "admin", "oficina": "AR"}, r.text)

# ------------------------------------------------------------------ carga de ranking (Spotify)
filas = [
    {"track_name": "Canción Uno (En Vivo)", "artist_names": "Artista A & Artista B", "pais_code": "AR", "rank": 1,
     "peak_rank": 1, "previous_rank": 3, "weeks_on_chart": 5, "streams": 1000, "source": "x", "uri": "spotify:1",
     "weekly_growth": 1.5, "snapshot_date": "2026-10-01"},
    {"track_name": "Canción Uno", "artist_names": "Artista A, Artista B", "pais_code": "CL", "rank": 4,
     "peak_rank": None, "previous_rank": None, "weeks_on_chart": 1, "streams": "500", "source": None, "uri": None,
     "weekly_growth": None, "snapshot_date": "2026-10-01"},
    {"track_name": "Otra", "artist_names": "", "pais_code": "MX", "rank": "n/a", "snapshot_date": "2026-10-01"},
]
r = est.rpc("fn_upsert_ranking_batch", {"p_rows": filas, "p_platform": "spotify"})
res = r.json()
check("fn_upsert_ranking_batch responde idx/track_created/error_message", r.status_code == 200 and len(res) == 3 and all(x["error_message"] is None for x in res), r.text)
check("misma canción en 2 países = 1 obra (normalización '(En Vivo)' y '&')", [x["track_created"] for x in res] == [True, False, True], res)
check("obra normalizada", sqlq("select track_artist_concat from tracks_master order by created_at limit 1") == "Cancion Uno - Artista A, Artista B")
check("artista vacío -> 'Sin artista' y rank 'n/a' -> NULL", sqlq("select artist_name_raw || '|' || coalesce(rank::text,'null') from tracks_master m join territory_tracks t on t.track_master_id=m.id where pais_code='MX'") == "Sin artista|null")

# ------------------------------------------------------------------ tempo IDs (fn_upsert_master_tempo_batch)
r = est.rpc("fn_upsert_master_tempo_batch", {"p_rows": [{"track_artist": "Cancion Uno - Artista A, Artista B", "tempo_id": "0012345"},
                                                         {"track_artist": "No existe - Nadie", "tempo_id": "1"}]})
check("carga de tempo_id + error por obra inexistente", r.status_code == 200 and r.json()[0]["error_message"] is None and "No se encontró" in (r.json()[1]["error_message"] or ""), r.text)
check("trigger sincroniza tempo_id a territory_tracks", sqlq("select count(distinct t.tempo_id) || '|' || min(t.tempo_id) from territory_tracks t join tracks_master m on m.id=t.track_master_id where m.track_name_clean='Cancion Uno'") == "1|0012345")

# ------------------------------------------------------------------ fusión de duplicados (fn_set_tempo_id)
otra = sqlq("select id from tracks_master where track_name_raw='Otra'")
r = est.rpc("fn_set_tempo_id", {"p_track_id": otra, "p_tempo_id": "999"})
check("fn_set_tempo_id devuelve un número (función escalar)", r.status_code == 200 and r.json() == 0, r.text)
# Igual que en Supabase: con un tempo_id que ya tiene otra obra, la restricción
# UNIQUE(tempo_id) frena el UPDATE antes de fusionar (el front usa fn_asignar_tempo_id: ver test_uso_diario.py).
r = est.rpc("fn_set_tempo_id", {"p_track_id": otra, "p_tempo_id": "0012345"})
check("fn_set_tempo_id con tempo_id repetido: mismo error que Supabase (UNIQUE)", r.status_code == 409 and "uq_tracks_master_tempo_id" in r.json()["message"], r.text)

# ------------------------------------------------------------------ vistas paginadas (fetchAll)
r = admin.rpc("fn_master_view", {"p_date_from": None, "p_date_to": None, "p_pais": None, "p_include_deleted": False}, offset=0, limit=1000)
check("fn_master_view (rango 0-999)", r.status_code == 200 and len(r.json()) >= 1 and "last_chart_date" in r.json()[0], r.text)
r = admin.rpc("fn_territory_view", {"p_date_from": "2026-01-01", "p_date_to": None, "p_pais": "AR", "p_include_deleted": False}, offset=0, limit=1000)
check("fn_territory_view con país (enum) y fecha", r.status_code == 200 and all(x["pais_code"] == "AR" for x in r.json()) and len(r.json()) == 1, r.text)
r = admin.rpc("fn_territory_view", {"p_pais": None}, offset=1, limit=1)
check("paginado offset/limit", r.status_code == 200 and len(r.json()) == 1, r.text)

# ------------------------------------------------------------------ reporte Tempo + BO -> estado_trabajo automático
tid = sqlq("select tempo_id from tracks_master where tempo_id ~ '^[0-9]+$' limit 1")
r = est.rpc("fn_upsert_tempo_report_batch", {"p_rows": [
    {"tempo_id": tid, "pais_code": "AR", "created_date": "2020-01-01", "perf_pc": "50", "mech_pc": "100", "sync_pc": "", "originating_office": "Argentina"},
    {"tempo_id": tid, "pais_code": "CL", "created_date": "", "perf_pc": "NVFT", "mech_pc": "40", "sync_pc": "40", "originating_office": "México"}]})
check("fn_upsert_tempo_report_batch", r.status_code == 200 and all(x["error_message"] is None for x in r.json()), r.text)
r = est.rpc("fn_upsert_bo_report_batch", {"p_rows": [{"tempo_id": tid, "bo_id": "000777", "ca": "C", "bo_status": "WORK", "reclamos": "", "mech_bo": "100"}], "p_pais_code": "AR"})
check("fn_upsert_bo_report_batch", r.status_code == 200 and r.json()[0]["error_message"] is None, r.text)
check("estado_trabajo automático 'OK BO-Tempo' y BO sin ceros", sqlq(f"select estado_trabajo||'|'||bo_id from territory_bo_report where pais_code='AR'") == "OK BO-Tempo|777")
est.rpc("fn_upsert_bo_report_batch", {"p_rows": [{"tempo_id": tid, "mech_bo": "0"}], "p_pais_code": "CL"})
check("excepción BO 0% y obra de México -> 'OK - Obra MX'", sqlq("select estado_trabajo from territory_bo_report where pais_code='CL'") == "OK - Obra MX")
estado_ar = lambda: sqlq("select estado_trabajo from territory_bo_report where pais_code='AR'")
est.rpc("fn_upsert_bo_report_batch", {"p_rows": [{"tempo_id": tid, "bo_status": "WORK", "reclamos": "No", "mech_bo": "50"}], "p_pais_code": "AR"})
check("% Mech de BO distinto del de Tempo -> 'REVISAR %'", estado_ar() == "REVISAR %", estado_ar())
est.rpc("fn_upsert_bo_report_batch", {"p_rows": [{"tempo_id": tid, "bo_status": "SONG", "reclamos": "No", "mech_bo": "100"}], "p_pais_code": "AR"})
check("estado de BO distinto de WORK -> 'REVISAR NOT WORK'", estado_ar() == "REVISAR NOT WORK", estado_ar())
est.rpc("fn_upsert_bo_report_batch", {"p_rows": [{"tempo_id": tid, "bo_status": "SONG", "reclamos": "Active", "mech_bo": "50"}], "p_pais_code": "AR"})
check("varios problemas -> se muestran todos ('RECLAMO ACTIVO / REVISAR NOT WORK / REVISAR %')",
      estado_ar() == "RECLAMO ACTIVO / REVISAR NOT WORK / REVISAR %", estado_ar())
for problema in ("RECLAMO ACTIVO", "REVISAR NOT WORK", "REVISAR %"):
    check(f"el filtro '{problema}' encuentra la obra con varios problemas",
          sqlq(f"select count(*) from fn_territory_pagina(p_pais => 'AR', p_estado_trabajo => '{problema}')") == "1")
check("las opciones del filtro de estado de trabajo van separadas por problema",
      sqlq("select count(*) from fn_territory_opciones() where campo = 'estado_trabajo' and valor like '% / %'") == "0")
est.rpc("fn_upsert_bo_report_batch", {"p_rows": [{"tempo_id": tid, "bo_status": "SONG", "reclamos": "", "mech_bo": "50"}], "p_pais_code": "AR"})
check("NOT WORK y % distintos -> 'REVISAR NOT WORK / REVISAR %'", estado_ar() == "REVISAR NOT WORK / REVISAR %", estado_ar())
est.rpc("fn_upsert_bo_report_batch", {"p_rows": [{"tempo_id": tid, "bo_status": "WORK", "reclamos": "", "mech_bo": "100"}], "p_pais_code": "AR"})
check("sin reclamo, WORK y % iguales -> vuelve a 'OK BO-Tempo'", estado_ar() == "OK BO-Tempo", estado_ar())

# ------------------------------------------------------------------ edición desde la tabla (updateMasterField / updateBoReportField)
mid = sqlq(f"select id from tracks_master where tempo_id='{tid}'")
r = est.patch("tracks_master", {"id": f"eq.{mid}"}, {"bo_id": "B-1"})
check("PATCH tracks_master (bo_id)", r.status_code == 204 and sqlq(f"select bo_id from tracks_master where id='{mid}'") == "B-1", r.text)
bid = sqlq("select id from territory_bo_report where pais_code='AR'")
r = est.patch("territory_bo_report", {"id": f"eq.{bid}"}, {"estado_trabajo": "dif de split"})
check("PATCH territory_bo_report (estado_trabajo manual se respeta)", r.status_code == 204 and sqlq(f"select estado_trabajo from territory_bo_report where id='{bid}'") == "dif de split", r.text)
check("PATCH sin filtro: rechazado", est.patch("tracks_master", {}, {"bo_id": "x"}).status_code == 400)

# ------------------------------------------------------------------ histórico (fn_obra_history)
r = admin.rpc("fn_obra_history", {"p_track_master_id": mid, "p_pais": "AR"})
check("fn_obra_history devuelve cambios con usuario", r.status_code == 200 and len(r.json()) >= 1 and r.json()[0]["changed_by"] in (admin_id, sqlq("select id from auth.users where email like 'estandar%'")), r.text)
check("auditoría guarda el usuario (auth.uid())", sqlq("select count(*) from audit_logs where changed_by in (select id::text from auth.users)") != "0")

# ------------------------------------------------------------------ borrado lógico / restaurar
tt = sqlq("select id from territory_tracks where pais_code='MX'")
# Igual que en Supabase: la política de lectura oculta filas borradas a quien no es admin,
# y Postgres exige que la fila modificada siga visible. Solo admin borra/restaura.
r = est.patch("territory_tracks", {"id": f"eq.{tt}"}, {"deleted_at": "2026-10-14T10:00:00Z"})
check("usuario estándar no puede borrar (igual que Supabase)", r.status_code == 403, r.text)
r = admin.patch("territory_tracks", {"id": f"eq.{tt}"}, {"deleted_at": "2026-10-14T10:00:00Z"})
check("admin hace borrado lógico", r.status_code == 204 and sqlq(f"select deleted_at is not null from territory_tracks where id='{tt}'") == "t", r.text)
r = est.get("territory_tracks", {"select": "id", "id": f"eq.{tt}"})
check("usuario estándar no ve filas borradas", r.json() == [], r.text)
r = admin.get("territory_tracks", {"select": "id", "id": f"eq.{tt}"})
check("admin sí ve filas borradas", len(r.json()) == 1, r.text)
r = admin.patch("territory_tracks", {"id": f"eq.{tt}"}, {"deleted_at": None})
check("restaurar", r.status_code == 204 and sqlq(f"select deleted_at is null from territory_tracks where id='{tt}'") == "t", r.text)
out = subprocess.run(["psql", PGURL, "-c", f"delete from territory_tracks where id='{tt}'"], capture_output=True, text=True)
check("DELETE físico bloqueado por trigger", "DELETE físico no permitido" in out.stderr, out.stderr)

# ------------------------------------------------------------------ contador BO (fn_next_bo_carga)
a = admin.rpc("fn_next_bo_carga").json(); b = admin.rpc("fn_next_bo_carga").json()
check("fn_next_bo_carga incrementa", isinstance(a, int) and b == a + 1, (a, b))

# ------------------------------------------------------------------ archivos
up = httpx.post(f"{BASE}/storage/upload/csv-uploads/spotify/2026-10-14/1_prueba.csv", content=b"a,b\n1,2\n",
                headers=dict(est.h, **{"Content-Type": "text/csv"}))
check("subir archivo", up.status_code == 200, up.text)
dup = httpx.post(f"{BASE}/storage/upload/csv-uploads/spotify/2026-10-14/1_prueba.csv", content=b"x", headers=est.h)
check("subir archivo repetido: 409 'The resource already exists'", dup.status_code == 409 and dup.json()["message"] == "The resource already exists", dup.text)
tr = httpx.post(f"{BASE}/storage/upload/csv-uploads/%2e%2e/%2e%2e/etc/x", content=b"x", headers=est.h)
check("ruta con '..' codificado: rechazada", tr.status_code == 400, (tr.status_code, tr.text))
tr2 = httpx.post(f"{BASE}/storage/upload/csv-uploads/a/..%2f..%2fx", content=b"x", headers=est.h)
check("ruta con '../' codificado: rechazada", tr2.status_code == 400, (tr2.status_code, tr2.text))
otro = httpx.post(f"{BASE}/storage/upload/otro-bucket/a.csv", content=b"x", headers=est.h)
check("bucket sin política: rechazado", otro.status_code >= 400, otro.text)
s = httpx.post(f"{BASE}/storage/sign/csv-uploads/spotify/2026-10-14/1_prueba.csv", json={"expiresIn": 300}, headers=est.h)
check("link firmado", s.status_code == 200 and s.json()["signedUrl"].startswith("/storage/object/"), s.text)
d = httpx.get(BASE + s.json()["signedUrl"])
check("descarga con link firmado", d.status_code == 200 and d.content == b"a,b\n1,2\n", d.status_code)
d2 = httpx.get(BASE + s.json()["signedUrl"].replace("token=", "token=0"))
check("link alterado: rechazado", d2.status_code == 403, d2.status_code)

# ------------------------------------------------------------------ historial de cargas (csv_uploads)
r = est.post("csv_uploads", {"filename": "prueba.csv", "total_rows": 3, "created_tracks": 2, "updated_rows": 3, "error_count": 1,
                             "errors": ["fila 2: error"], "file_path": "spotify/2026-10-14/1_prueba.csv", "format": "spotify"})
check("insert en csv_uploads (errors como jsonb)", r.status_code == 201, r.text)
r = est.get("csv_uploads", {"select": "*", "order": "uploaded_at.desc", "limit": "50"})
check("listado de cargas ordenado", r.status_code == 200 and r.json()[0]["filename"] == "prueba.csv" and r.json()[0]["errors"] == ["fila 2: error"], r.text)
check("uploaded_by = usuario logueado", sqlq("select uploaded_by from csv_uploads where filename='prueba.csv'") == sqlq("select id from auth.users where email like 'estandar%'"))

# ------------------------------------------------------------------ última carga de chart (loadLastChartLoad)
r = est.get("territory_tracks", {"select": "snapshot_date", "platform": "eq.spotify", "deleted_at": "is.null", "order": "snapshot_date.desc", "limit": "1"})
check("última fecha de chart por plataforma", r.status_code == 200 and r.json() == [{"snapshot_date": "2026-10-01"}], r.text)

# ------------------------------------------------------------------ exportaciones CSV (downloadFilteredCsv)
r = httpx.post(f"{BASE}/rpc/fn_territory_export", json={"p_date_from": None, "p_date_to": None, "p_pais": None},
               params={"offset": 0, "limit": 1000}, headers=dict(admin.h, Accept="text/csv"))
lineas = r.text.strip().split("\n")
check("exportar territorio a CSV con encabezados", r.status_code == 200 and lineas[0].startswith("Pais,Track - Artista,Created date,Tempo ID"), r.text[:200])
r = httpx.post(f"{BASE}/rpc/fn_master_export", json={"p_date_from": None, "p_date_to": None, "p_pais": None},
               params={"offset": 0, "limit": 1000}, headers=dict(admin.h, Accept="text/csv"))
check("exportar tabla principal a CSV", r.status_code == 200 and r.text.startswith("track_artist_concat,tempo_id"), r.text[:100])

# ------------------------------------------------------------------ seguridad por rol
r = aud.rpc("fn_upsert_ranking_batch", {"p_rows": [{"track_name": "X", "artist_names": "Y", "pais_code": "AR"}], "p_platform": "spotify"})
check("auditor no puede cargar (RLS)", r.status_code == 200 and r.json()[0]["error_message"] and "row-level security" in r.json()[0]["error_message"], r.text)
r = est.get("audit_logs", {"select": "id"})
check("usuario estándar no ve la auditoría", r.status_code == 200 and r.json() == [], r.text)
r = aud.get("audit_logs", {"select": "id", "limit": "1"})
check("auditor ve la auditoría", r.status_code == 200 and len(r.json()) == 1, r.text)
r = est.get("vw_tracks_master_active", {"select": "id"})
check("vistas respetan RLS (no se saltean permisos)", r.status_code == 200, r.text)
check("rol anon sin permisos sobre vistas", sqlq("select count(*) from information_schema.role_table_grants where grantee='anon'") == "0")
r = est.rpc("fn_inexistente")
check("función inexistente: 404", r.status_code == 404, r.text)
r = est.get("tracks_master", {"select": "id;drop table x"})
check("nombres de columna inválidos: rechazados", r.status_code == 400, r.text)

# ------------------------------------------------------------------ bloqueo de usuario (admin/usuarios.py bloquear)
sqlq("update auth.users set banned_until = 'infinity' where email like 'auditor%'")
r = aud.get("tracks_master", {"select": "id"})
check("usuario bloqueado pierde la sesión en el acto (401)", r.status_code == 401, r.text)
check("usuario bloqueado no puede volver a entrar", login("auditor@prueba.local", "clave-auditor-123").status_code == 400)
sqlq("update auth.users set banned_until = null where email like 'auditor%'")
check("al desbloquearlo vuelve a funcionar la misma sesión", aud.get("tracks_master", {"select": "id"}).status_code == 200)

print(f"\nFallas: {len(fallas)}")
sys.exit(1 if fallas else 0)
