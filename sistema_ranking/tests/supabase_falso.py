"""
Supabase simulado para las pruebas: imita las APIs que usa exportar_supabase.py, leyendo de una base local.
  /rest/v1/<tabla>          tablas (PostgREST: limit/offset/order, Prefer: count=exact)
  /auth/v1/admin/users      usuarios (sin contraseñas, como el real)
  /storage/v1/object/list   y  /storage/v1/object/<bucket>/<ruta>   bucket
Uso: srv, pedidos = iniciar(origen_url, storage_origen, clave, host="127.0.0.1")
"""
import http.server
import json
import threading
import urllib.parse

import psycopg

ORIGEN = STORAGE_ORIGEN = CLAVE = None
PKS = {"app_users": "user_id", "staging_tempo_historico": "fila", "resultado_tempo_historico": "fila"}
pedidos = []


class SupabaseFalso(http.server.BaseHTTPRequestHandler):
    def _responder(self, codigo, cuerpo=b"", cabeceras=None):
        self.send_response(codigo)
        for k, v in (cabeceras or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)

    def _consulta(self, q, params=()):
        with psycopg.connect(ORIGEN) as con:
            return con.execute(q, params).fetchone()[0]

    def do_GET(self):
        pedidos.append(self.path)
        if self.headers.get("Authorization") != f"Bearer {CLAVE}" or self.headers.get("apikey") != CLAVE:
            return self._responder(401, b'{"message":"Invalid API key"}')
        url = urllib.parse.urlparse(self.path)
        qs = dict(urllib.parse.parse_qsl(url.query))
        if url.path.startswith("/rest/v1/"):
            t = url.path.rsplit("/", 1)[-1]
            pk = PKS.get(t, "id")
            limite, offset = int(qs.get("limit", 1000)), int(qs.get("offset", 0))
            orden = f"ORDER BY {pk}" if qs.get("order") == f"{pk}.asc" else ""
            # Como PostgREST: el JSON sale tal cual lo arma Postgres (50.000 sigue siendo 50.000).
            texto = self._consulta(f"SELECT coalesce(json_agg(x), '[]')::text FROM (SELECT * FROM public.{t} {orden} "
                                   f"LIMIT {limite} OFFSET {offset}) x")
            cab = {"Content-Type": "application/json"}
            if self.headers.get("Prefer") == "count=exact":
                cab["Content-Range"] = f"0-{max(len(json.loads(texto)) - 1, 0)}/{self._consulta(f'SELECT count(*) FROM public.{t}')}"
            return self._responder(200, texto.encode(), cab)
        if url.path == "/auth/v1/admin/users":
            usuarios = [] if qs.get("page") != "1" else self._consulta(
                "SELECT coalesce(json_agg(json_build_object('id', id, 'email', email, 'created_at', created_at, "
                "'last_sign_in_at', last_sign_in_at, 'banned_until', banned_until, 'role', 'authenticated')), '[]') FROM auth.users")
            return self._responder(200, json.dumps({"users": usuarios, "aud": "authenticated"}).encode())
        if url.path.startswith("/storage/v1/object/csv-uploads/"):
            ruta = STORAGE_ORIGEN / "csv-uploads" / urllib.parse.unquote(url.path[len("/storage/v1/object/csv-uploads/"):])
            return self._responder(200, ruta.read_bytes()) if ruta.is_file() else self._responder(404)
        self._responder(404)

    def do_POST(self):
        if self.headers.get("Authorization") != f"Bearer {CLAVE}":
            return self._responder(401)
        if self.path != "/storage/v1/object/list/csv-uploads":
            return self._responder(404)
        cuerpo = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prefijo = cuerpo["prefix"].strip("/")
        hijos = {}
        with psycopg.connect(ORIGEN) as con:
            for nombre, meta, creado, oid in con.execute("SELECT name, metadata, created_at, id FROM storage.objects ORDER BY name"):
                if prefijo and not nombre.startswith(prefijo + "/"):
                    continue
                resto = nombre[len(prefijo) + 1:] if prefijo else nombre
                if "/" in resto:
                    hijos.setdefault(resto.split("/")[0], {"name": resto.split("/")[0], "id": None, "metadata": None})
                else:
                    hijos[resto] = {"name": resto, "id": str(oid), "metadata": meta, "created_at": creado.isoformat()}
        lista = sorted(hijos.values(), key=lambda x: x["name"])
        lista = lista[cuerpo["offset"]: cuerpo["offset"] + cuerpo["limit"]]
        self._responder(200, json.dumps(lista).encode(), {"Content-Type": "application/json"})

    def log_message(self, *a):
        pass




def iniciar(origen, storage_origen, clave, host="127.0.0.1"):
    global ORIGEN, STORAGE_ORIGEN, CLAVE
    ORIGEN, STORAGE_ORIGEN, CLAVE = origen, storage_origen, clave
    pedidos.clear()
    srv = http.server.ThreadingHTTPServer((host, 0), SupabaseFalso)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, pedidos
