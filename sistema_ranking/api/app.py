"""
API propia de Ranking Digital. Reemplaza las partes de Supabase que usa el front:
login (Auth), lectura/escritura de tablas y funciones (PostgREST) y archivos (Storage).
También corre la tarea programada de YouTube Charts (ex Edge Function).

Seguridad: cada pedido se ejecuta en Postgres con el rol `authenticated` y el usuario
del token (auth.uid()), así que las reglas RLS y políticas de la base deciden qué puede
ver y cambiar cada usuario, igual que en Supabase. La API no tiene una copia propia
de esas reglas.

Variables de entorno: ver ../.env.example
"""
import csv
import datetime as dt
import decimal
import hashlib
import hmac
import io
import json
import logging
import mimetypes
import os
import pathlib
import re
import threading
import time
import uuid
from contextlib import contextmanager

import jwt
import psycopg
from psycopg import sql
from psycopg.types.string import StrDumperUnknown
from psycopg_pool import ConnectionPool
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, Response

log = logging.getLogger("ranking")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

DATABASE_URL = os.environ["DATABASE_URL"]                 # rol authenticator
JWT_SECRET = os.environ["JWT_SECRET"]
if len(JWT_SECRET) < 32:
    raise SystemExit("JWT_SECRET debe tener al menos 32 caracteres")
SESSION_HOURS = float(os.environ.get("SESSION_HOURS", "8"))
STORAGE_DIR = pathlib.Path(os.environ.get("STORAGE_DIR", "/data/storage")).resolve()
FRONT_DIR = pathlib.Path(os.environ.get("FRONT_DIR", pathlib.Path(__file__).resolve().parents[1] / "front")).resolve()
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "50"))
STATEMENT_TIMEOUT = os.environ.get("STATEMENT_TIMEOUT", "120s")

IDENT = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")


def _configurar(conn):
    # Los textos viajan sin tipo: Postgres los convierte al tipo de la columna o del
    # parámetro (uuid, fecha, enum, jsonb...), como hace PostgREST.
    conn.adapters.register_dumper(str, StrDumperUnknown)


pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=int(os.environ.get("DB_POOL", "10")),
                      configure=_configurar, check=ConnectionPool.check_connection, open=False)

app = FastAPI(title="Ranking Digital API", docs_url=None, redoc_url=None)


@app.on_event("startup")
def _inicio():
    pool.open(wait=True)
    STORAGE_DIR.mkdir(parents=True, exist_ok=True)
    from youtube_job import iniciar_programador  # noqa: E402
    iniciar_programador()


@app.on_event("shutdown")
def _fin():
    pool.close()


# ---------------------------------------------------------------- errores
class ErrorApi(Exception):
    def __init__(self, status, message, code=None):
        self.status, self.message, self.code = status, message, code


@app.exception_handler(ErrorApi)
def _error_api(_req, e: ErrorApi):
    return JSONResponse({"message": e.message, "code": e.code}, status_code=e.status)


@app.exception_handler(psycopg.Error)
def _error_db(_req, e: psycopg.Error):
    diag = getattr(e, "diag", None)
    msg = (diag.message_primary if diag and diag.message_primary else str(e)).strip()
    estado = 403 if e.sqlstate == "42501" else 409 if e.sqlstate == "23505" else 400
    return JSONResponse({"message": msg, "code": e.sqlstate}, status_code=estado)


# ---------------------------------------------------------------- JSON / CSV
def _json_default(v):
    if isinstance(v, decimal.Decimal):
        return float(v)
    if isinstance(v, (dt.datetime, dt.date, dt.time)):
        return v.isoformat()
    if isinstance(v, uuid.UUID):
        return str(v)
    if isinstance(v, (bytes, memoryview)):
        return bytes(v).hex()
    raise TypeError(type(v))


def respuesta_json(data, status=200):
    return Response(json.dumps(data, default=_json_default, ensure_ascii=False), status_code=status,
                    media_type="application/json")


def _celda_csv(v):
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return json.dumps(v, default=_json_default, ensure_ascii=False)
    if isinstance(v, (dt.datetime, dt.date)):
        return v.isoformat()
    return str(v)


def respuesta_csv(columnas, filas):
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(columnas)
    for f in filas:
        w.writerow([_celda_csv(f[c]) for c in columnas])
    return PlainTextResponse(buf.getvalue(), media_type="text/csv; charset=utf-8")


def _valor_db(v):
    """Valor de Python para un parámetro: listas/objetos van como JSON (jsonb)."""
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return v


# ---------------------------------------------------------------- sesión
def emitir_token(user_id, email):
    ahora = int(time.time())
    exp = ahora + int(SESSION_HOURS * 3600)
    token = jwt.encode({"sub": str(user_id), "email": email, "role": "authenticated", "iat": ahora, "exp": exp},
                       JWT_SECRET, algorithm="HS256")
    return token, exp


def usuario_del_pedido(request: Request):
    h = request.headers.get("authorization", "")
    if not h.lower().startswith("bearer "):
        raise ErrorApi(401, "Sesión requerida")
    try:
        claims = jwt.decode(h[7:], JWT_SECRET, algorithms=["HS256"], options={"require": ["exp", "sub"]})
    except jwt.ExpiredSignatureError:
        raise ErrorApi(401, "La sesión venció. Volvé a ingresar.")
    except jwt.InvalidTokenError:
        raise ErrorApi(401, "Sesión inválida")
    return claims


@contextmanager
def transaccion(claims=None, rol="authenticated"):
    """Conexión con el rol y el usuario del pedido (auth.uid() = claims['sub'])."""
    with pool.connection() as conn:
        with conn.transaction():
            with conn.cursor(row_factory=psycopg.rows.dict_row) as cur:
                cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(rol)))
                cur.execute("SELECT set_config('statement_timeout', %s, true)", (STATEMENT_TIMEOUT,))
                if claims:
                    cur.execute("SELECT set_config('request.jwt.claims', %s, true), "
                                "set_config('request.jwt.claim.sub', %s, true), "
                                "set_config('app.current_user_id', %s, true), "
                                "auth.usuario_activo(%s::uuid) AS activo",
                                (json.dumps(claims), claims["sub"], claims["sub"], claims["sub"]))
                    if rol == "authenticated" and not cur.fetchone()["activo"]:
                        # Usuario bloqueado o borrado: la sesión deja de valer en el acto.
                        raise ErrorApi(401, "Sesión inválida")
                yield cur


# ---------------------------------------------------------------- login
_intentos = {}
_intentos_lock = threading.Lock()


def _frenar_fuerza_bruta(clave):
    ahora = time.time()
    with _intentos_lock:
        lista = [t for t in _intentos.get(clave, []) if ahora - t < 300]
        if len(lista) >= 8:
            raise ErrorApi(429, "Demasiados intentos. Esperá unos minutos.")
        lista.append(ahora)
        _intentos[clave] = lista


@app.post("/auth/login")
async def login(request: Request):
    body = await request.json()
    email = str(body.get("email") or "").strip().lower()
    password = str(body.get("password") or "")
    _frenar_fuerza_bruta(f"{request.client.host if request.client else '-'}|{email}")
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT auth.login(%s, %s)", (email, password))
        uid = cur.fetchone()[0]
    if not uid:
        raise ErrorApi(400, "Invalid login credentials")
    token, exp = emitir_token(uid, email)
    return respuesta_json({"access_token": token, "token_type": "bearer", "expires_at": exp,
                           "user": {"id": str(uid), "email": email}})


@app.get("/auth/user")
def usuario(request: Request):
    c = usuario_del_pedido(request)
    return respuesta_json({"id": c["sub"], "email": c.get("email")})


# ---------------------------------------------------------------- tablas
FILTROS = {"eq": "=", "neq": "<>", "gt": ">", "gte": ">=", "lt": "<", "lte": "<=", "like": "LIKE", "ilike": "ILIKE"}
PARAMS_RESERVADOS = {"select", "order", "limit", "offset", "single", "columns"}


def _ident(nombre):
    if not IDENT.match(nombre or ""):
        raise ErrorApi(400, f"Nombre inválido: {nombre!r}")
    return sql.Identifier(nombre)


def _columnas_select(select):
    if not select or select.strip() == "*":
        return sql.SQL("*")
    return sql.SQL(", ").join(_ident(c.strip()) for c in select.split(",") if c.strip())


def _where(params):
    partes, valores = [], []
    for col, expr in params:
        if col in PARAMS_RESERVADOS:
            continue
        op, _, val = expr.partition(".")
        if op == "is":
            mapa = {"null": "NULL", "true": "TRUE", "false": "FALSE"}
            if val not in mapa:
                raise ErrorApi(400, f"Valor inválido para is: {val}")
            partes.append(sql.SQL("{} IS " + mapa[val]).format(_ident(col)))
        elif op == "in":
            items = [x for x in val.strip("()").split(",") if x != ""]
            partes.append(sql.SQL("{} = ANY({})").format(_ident(col), sql.Placeholder()))
            valores.append(items)
        elif op in FILTROS:
            partes.append(sql.SQL("{} " + FILTROS[op] + " {}").format(_ident(col), sql.Placeholder()))
            valores.append(val)
        else:
            raise ErrorApi(400, f"Filtro no soportado: {op}")
    cond = sql.SQL(" AND ").join(partes) if partes else sql.SQL("TRUE")
    return cond, valores, len(partes)


def _orden(order):
    if not order:
        return sql.SQL("")
    piezas = []
    for item in order.split(","):
        col, *mods = item.split(".")
        s = _ident(col)
        txt = " DESC" if "desc" in mods else " ASC"
        if "nullsfirst" in mods:
            txt += " NULLS FIRST"
        elif "nullslast" in mods:
            txt += " NULLS LAST"
        piezas.append(sql.SQL("{}" + txt).format(s))
    return sql.SQL(" ORDER BY ") + sql.SQL(", ").join(piezas)


def _paginado(params):
    lim = params.get("limit")
    off = params.get("offset")
    s = sql.SQL("")
    if lim is not None:
        s += sql.SQL(" LIMIT {}").format(sql.Literal(int(lim)))
    if off is not None:
        s += sql.SQL(" OFFSET {}").format(sql.Literal(int(off)))
    return s


def _salida(request, filas, single):
    if single:
        if len(filas) != 1:
            raise ErrorApi(406, "JSON object requested, multiple (or no) rows returned", "PGRST116")
        return respuesta_json(filas[0])
    if "text/csv" in request.headers.get("accept", ""):
        cols = list(filas[0].keys()) if filas else []
        return respuesta_csv(cols, filas)
    return respuesta_json(filas)


@app.get("/rest/{tabla}")
def leer(tabla: str, request: Request):
    claims = usuario_del_pedido(request)
    qp = request.query_params
    cond, valores, _ = _where(qp.multi_items())
    q = (sql.SQL("SELECT {} FROM public.{} WHERE ").format(_columnas_select(qp.get("select")), _ident(tabla))
         + cond + _orden(qp.get("order")) + _paginado(qp))
    with transaccion(claims) as cur:
        cur.execute(q, valores)
        filas = cur.fetchall()
    return _salida(request, filas, qp.get("single") == "1")


@app.patch("/rest/{tabla}")
async def modificar(tabla: str, request: Request):
    claims = usuario_del_pedido(request)
    cambios = await request.json()
    if not isinstance(cambios, dict) or not cambios:
        raise ErrorApi(400, "Cuerpo vacío")
    cond, valores, n_filtros = _where(request.query_params.multi_items())
    if n_filtros == 0:
        raise ErrorApi(400, "UPDATE sin filtro no permitido")
    sets = sql.SQL(", ").join(sql.SQL("{} = {}").format(_ident(k), sql.Placeholder()) for k in cambios)
    q = sql.SQL("UPDATE public.{} SET ").format(_ident(tabla)) + sets + sql.SQL(" WHERE ") + cond
    with transaccion(claims) as cur:
        cur.execute(q, [_valor_db(v) for v in cambios.values()] + valores)
    return Response(status_code=204)


@app.post("/rest/{tabla}")
async def insertar(tabla: str, request: Request):
    claims = usuario_del_pedido(request)
    body = await request.json()
    filas = body if isinstance(body, list) else [body]
    with transaccion(claims) as cur:
        for f in filas:
            if not isinstance(f, dict) or not f:
                raise ErrorApi(400, "Fila inválida")
            cols = sql.SQL(", ").join(_ident(k) for k in f)
            q = sql.SQL("INSERT INTO public.{} ({}) VALUES ({})").format(
                _ident(tabla), cols, sql.SQL(", ").join(sql.Placeholder() * len(f)))
            cur.execute(q, [_valor_db(v) for v in f.values()])
    return Response(status_code=201)


# ---------------------------------------------------------------- funciones (RPC)
@app.post("/rpc/{funcion}")
async def rpc(funcion: str, request: Request):
    claims = usuario_del_pedido(request)
    if not funcion.startswith("fn_"):
        raise ErrorApi(404, "Función no disponible")
    texto = await request.body()
    params = json.loads(texto) if texto.strip() else {}
    qp = request.query_params
    with transaccion(claims) as cur:
        cur.execute("""SELECT p.proretset OR t.typtype = 'c' OR p.prorettype = 'record'::regtype AS tabla
                       FROM pg_proc p JOIN pg_type t ON t.oid = p.prorettype
                       WHERE p.pronamespace = 'public'::regnamespace AND p.proname = %s
                         AND p.prorettype <> 'trigger'::regtype
                       LIMIT 1""", (funcion,))
        meta = cur.fetchone()
        if not meta:
            raise ErrorApi(404, f"No existe la función {funcion}")
        args = sql.SQL(", ").join(sql.SQL("{} => {}").format(_ident(k), sql.Placeholder()) for k in params)
        llamada = sql.SQL("public.{}({})").format(_ident(funcion), args)
        valores = [_valor_db(v) for v in params.values()]
        if meta["tabla"]:
            q = sql.SQL("SELECT {} FROM ").format(_columnas_select(qp.get("select"))) + llamada + _paginado(qp)
            cur.execute(q, valores)
            filas = cur.fetchall()
            return _salida(request, filas, qp.get("single") == "1")
        cur.execute(sql.SQL("SELECT ") + llamada + sql.SQL(" AS v"), valores)
        return respuesta_json(cur.fetchone()["v"])


# ---------------------------------------------------------------- archivos
def _ruta_segura(bucket, nombre):
    if not IDENT.match(bucket.replace("-", "_")):
        raise ErrorApi(400, "Bucket inválido")
    partes = [p for p in nombre.split("/") if p]
    if not partes or any(p in (".", "..") or "\\" in p or "\x00" in p for p in partes):
        raise ErrorApi(400, "Ruta de archivo inválida")
    nombre = "/".join(partes)
    destino = (STORAGE_DIR / bucket / nombre).resolve()
    if STORAGE_DIR / bucket not in destino.parents:
        raise ErrorApi(400, "Ruta de archivo inválida")
    return nombre, destino


@app.post("/storage/upload/{bucket}/{nombre:path}")
async def subir(bucket: str, nombre: str, request: Request):
    claims = usuario_del_pedido(request)
    nombre, destino = _ruta_segura(bucket, nombre)
    contenido = await request.body()
    if len(contenido) > MAX_UPLOAD_MB * 1024 * 1024:
        raise ErrorApi(413, f"El archivo supera {MAX_UPLOAD_MB} MB")
    tipo = request.headers.get("content-type", "application/octet-stream")
    with transaccion(claims) as cur:
        try:
            cur.execute("INSERT INTO storage.objects (bucket_id, name, metadata) VALUES (%s, %s, %s)",
                        (bucket, nombre, json.dumps({"size": len(contenido), "mimetype": tipo})))
        except psycopg.errors.UniqueViolation:
            raise ErrorApi(409, "The resource already exists", "Duplicate")
        destino.parent.mkdir(parents=True, exist_ok=True)
        tmp = destino.with_name(destino.name + f".{uuid.uuid4().hex}.tmp")
        tmp.write_bytes(contenido)
        os.replace(tmp, destino)
    return respuesta_json({"path": nombre, "fullPath": f"{bucket}/{nombre}"})


def _firma(bucket, nombre, exp):
    return hmac.new(JWT_SECRET.encode(), f"{bucket}|{nombre}|{exp}".encode(), hashlib.sha256).hexdigest()


@app.post("/storage/sign/{bucket}/{nombre:path}")
async def firmar(bucket: str, nombre: str, request: Request):
    claims = usuario_del_pedido(request)
    nombre, destino = _ruta_segura(bucket, nombre)
    body = await request.json() if (await request.body()).strip() else {}
    segundos = max(1, min(int(body.get("expiresIn", 300)), 3600))
    with transaccion(claims) as cur:   # la política del bucket decide si puede verlo
        cur.execute("SELECT 1 FROM storage.objects WHERE bucket_id = %s AND name = %s", (bucket, nombre))
        if not cur.fetchone() or not destino.exists():
            raise ErrorApi(404, "Object not found")
    exp = int(time.time()) + segundos
    url = f"/storage/object/{bucket}/{nombre}?exp={exp}&token={_firma(bucket, nombre, exp)}"
    return respuesta_json({"signedUrl": url})


@app.get("/storage/object/{bucket}/{nombre:path}")
def bajar(bucket: str, nombre: str, exp: int, token: str):
    nombre, destino = _ruta_segura(bucket, nombre)
    if exp < time.time() or not hmac.compare_digest(token, _firma(bucket, nombre, exp)):
        raise ErrorApi(403, "Link vencido o inválido")
    if not destino.exists():
        raise ErrorApi(404, "Object not found")
    return FileResponse(destino, filename=destino.name)


# ---------------------------------------------------------------- tarea YouTube (manual)
@app.post("/jobs/youtube")
def correr_youtube(request: Request):
    claims = usuario_del_pedido(request)
    with transaccion(claims) as cur:
        cur.execute("SELECT public.fn_app_role() AS rol")
        if cur.fetchone()["rol"] != "admin":
            raise ErrorApi(403, "Solo un admin puede correr la carga de YouTube a mano")
    from youtube_job import correr
    return respuesta_json(correr())


# ---------------------------------------------------------------- front
@app.get("/health")
def salud():
    with pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"ok": True}


# Tipos que mimetypes no siempre conoce (el manifiesto de la PWA debe ir como application/manifest+json).
mimetypes.add_type("application/manifest+json", ".webmanifest")
mimetypes.add_type("text/javascript", ".js")


@app.get("/{archivo:path}")
def front(archivo: str):
    nombre = archivo or "index.html"
    destino = (FRONT_DIR / nombre).resolve()
    if FRONT_DIR not in destino.parents or not destino.is_file() or destino.suffix == ".py":
        destino = FRONT_DIR / "index.html"   # los generadores (.py) de la carpeta no se publican
    return FileResponse(destino, headers={"Cache-Control": "no-cache"})
