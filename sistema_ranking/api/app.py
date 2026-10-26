"""
API propia de Ranking Digital. Reemplaza las partes de Supabase que usa el front:
login (Auth), lectura/escritura de tablas y funciones (PostgREST) y archivos (Storage).
Los charts de Spotify y YouTube se cargan a mano (CSV desde el front): no hay tareas programadas.

Seguridad: cada pedido se ejecuta en Postgres con el rol `authenticated` y el usuario
del token (auth.uid()), así que las reglas RLS y políticas de la base deciden qué puede
ver y cambiar cada usuario, igual que en Supabase. La API no tiene una copia propia
de esas reglas.

Variables de entorno: ver ../.env.example
"""
import collections
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
import shutil
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
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, Response

log = logging.getLogger("ranking")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
INICIO_API = dt.datetime.now(dt.timezone.utc)


class _RegistroEnMemoria(logging.Handler):
    """Últimas líneas del registro de la API, para el Panel de control (sin acceso a Docker)."""
    def __init__(self):
        super().__init__(level=logging.INFO)
        self.lineas = collections.deque(maxlen=500)

    def emit(self, record):
        try:
            self.lineas.append({"fecha": dt.datetime.fromtimestamp(record.created, dt.timezone.utc).isoformat(),
                                "nivel": record.levelname, "mensaje": record.getMessage()[:2000]})
        except Exception:   # el registro nunca interrumpe un pedido
            pass


REGISTRO = _RegistroEnMemoria()
log.addHandler(REGISTRO)
logging.getLogger("uvicorn.error").addHandler(REGISTRO)

DATABASE_URL = os.environ["DATABASE_URL"]                 # rol authenticator
JWT_SECRET = os.environ["JWT_SECRET"]
if len(JWT_SECRET) < 32:
    raise SystemExit("JWT_SECRET debe tener al menos 32 caracteres")
SESSION_HOURS = float(os.environ.get("SESSION_HOURS", "8"))
STORAGE_DIR = pathlib.Path(os.environ.get("STORAGE_DIR", "/data/storage")).resolve()
FRONT_DIR = pathlib.Path(os.environ.get("FRONT_DIR", pathlib.Path(__file__).resolve().parents[1] / "front")).resolve()
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "50"))
STATEMENT_TIMEOUT = os.environ.get("STATEMENT_TIMEOUT", "120s")
# La carga de un archivo va en una sola consulta (todo o nada): un reporte grande puede tardar más que una consulta común.
CARGA_TIMEOUT = os.environ.get("CARGA_TIMEOUT", "900s")
FUNCIONES_DE_CARGA = {"fn_cargar_archivo"}

IDENT = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")


def _configurar(conn):
    # Los textos viajan sin tipo: Postgres los convierte al tipo de la columna o del
    # parámetro (uuid, fecha, enum, jsonb...), como hace PostgREST.
    conn.adapters.register_dumper(str, StrDumperUnknown)


pool = ConnectionPool(DATABASE_URL, min_size=1, max_size=int(os.environ.get("DB_POOL", "10")),
                      configure=_configurar, check=ConnectionPool.check_connection, open=False)

app = FastAPI(title="Ranking Digital API", docs_url=None, redoc_url=None)
# Respuestas comprimidas: el front, las tablas y los CSV viajan varias veces más livianos.
app.add_middleware(GZipMiddleware, minimum_size=1024)


@app.on_event("startup")
def _inicio():
    pool.open(wait=False)   # sin esperar a la base: la API responde enseguida y /health avisa cuando la base está lista
    STORAGE_DIR.mkdir(parents=True, exist_ok=True)
    log.info("API iniciada")


@app.middleware("http")
async def _registrar_fallas(request: Request, siguiente):
    """Deja en el registro los pedidos que fallan (para el Panel de control), sin datos del cuerpo."""
    try:
        respuesta = await siguiente(request)
    except Exception:
        log.exception("Error inesperado en %s %s", request.method, request.url.path)
        raise
    if respuesta.status_code >= 400 and request.url.path != "/panel/acceso":
        (log.error if respuesta.status_code >= 500 else log.warning)(
            "%s %s -> %s", request.method, request.url.path, respuesta.status_code)
    return respuesta


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
    log.warning("Base de datos (%s): %s", e.sqlstate, msg)
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
# Cada ingreso abre una sesión en la base (auth.sesiones, db/mejoras/04_uso_diario.sql). El token dura SESSION_HOURS y
# el front lo renueva mientras se usa la aplicación (/auth/renovar); la sesión vence tras SESSION_HOURS sin uso, al
# cerrarla (/auth/salir), al cambiar o restablecer la contraseña (/auth/clave, /auth/restablecer) o al bloquear al
# usuario.
INACTIVIDAD = f"{SESSION_HOURS} hours"


def emitir_token(user_id, email, sesion):
    ahora = int(time.time())
    exp = ahora + int(SESSION_HOURS * 3600)
    token = jwt.encode({"sub": str(user_id), "email": email, "role": "authenticated", "sid": str(sesion),
                        "iat": ahora, "exp": exp}, JWT_SECRET, algorithm="HS256")
    return token, exp


def respuesta_sesion(user_id, email, sesion):
    token, exp = emitir_token(user_id, email, sesion)
    return respuesta_json({"access_token": token, "token_type": "bearer", "expires_at": exp,
                           "expires_in": int(SESSION_HOURS * 3600), "user": {"id": str(user_id), "email": email}})


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
def transaccion(claims=None, rol="authenticated", limite=None):
    """Conexión con el rol y el usuario del pedido (auth.uid() = claims['sub'])."""
    with pool.connection() as conn:
        with conn.transaction():
            with conn.cursor(row_factory=psycopg.rows.dict_row) as cur:
                cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(rol)))
                cur.execute("SELECT set_config('statement_timeout', %s, true)", (limite or STATEMENT_TIMEOUT,))
                if claims:
                    cur.execute("SELECT set_config('request.jwt.claims', %s, true), "
                                "set_config('request.jwt.claim.sub', %s, true), "
                                "set_config('app.current_user_id', %s, true)",
                                (json.dumps(claims), claims["sub"], claims["sub"]))
                    if rol == "authenticated":
                        # Sesión cerrada o vencida, o usuario bloqueado o borrado: deja de valer en el acto.
                        cur.execute("SELECT auth.sesion_valida(%s::uuid, %s::uuid, %s::interval) AS activo",
                                    (claims.get("sid"), claims["sub"], INACTIVIDAD))
                        if not cur.fetchone()["activo"]:
                            raise ErrorApi(401, "La sesión venció. Volvé a ingresar.")
                yield cur


# ---------------------------------------------------------------- login
_intentos = {}
_intentos_lock = threading.Lock()


def _frenar_fuerza_bruta(clave):
    """Frena después de 8 intentos fallidos en 5 minutos (los correctos no cuentan)."""
    ahora = time.time()
    with _intentos_lock:
        lista = [t for t in _intentos.get(clave, []) if ahora - t < 300]
        _intentos[clave] = lista
        if len(lista) >= 8:
            raise ErrorApi(429, "Demasiados intentos fallidos. Esperá unos minutos y volvé a intentar.")


def _intento_fallido(clave):
    with _intentos_lock:
        _intentos.setdefault(clave, []).append(time.time())


@app.post("/auth/login")
async def login(request: Request):
    body = await request.json()
    email = str(body.get("email") or "").strip().lower()
    password = str(body.get("password") or "")
    clave = f"{request.client.host if request.client else '-'}|{email}"
    _frenar_fuerza_bruta(clave)
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute("SELECT auth.login(%s, %s)", (email, password))
        uid = cur.fetchone()[0]
        if not uid:
            _intento_fallido(clave)
            raise ErrorApi(400, "El email o la contraseña no son correctos.")
        cur.execute("SELECT auth.abrir_sesion(%s)", (uid,))
        sesion = cur.fetchone()[0]
    return respuesta_sesion(uid, email, sesion)


@app.post("/auth/renovar")
def renovar(request: Request):
    """Token nuevo para la misma sesión, si sigue vigente (el front lo pide mientras se usa la aplicación)."""
    c = usuario_del_pedido(request)
    with transaccion(c):
        pass
    return respuesta_sesion(c["sub"], c.get("email"), c.get("sid"))


@app.post("/auth/salir")
def salir(request: Request):
    try:
        c = usuario_del_pedido(request)
    except ErrorApi:
        return Response(status_code=204)
    if c.get("sid"):
        with pool.connection() as conn:
            conn.execute("SELECT auth.cerrar_sesion(%s::uuid)", (c["sid"],))
    return Response(status_code=204)


def _clave_ingreso(request, nombre, funcion, args, mensaje):
    """Cambio o restablecimiento de contraseña desde la pantalla de ingreso (sin sesión)."""
    email = str(args[0] or "").strip().lower()
    clave = f"{nombre}|{request.client.host if request.client else '-'}|{email}"
    _frenar_fuerza_bruta(clave)
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(sql.SQL("SELECT auth.{}(%s, %s, %s)").format(sql.Identifier(funcion)), [email, *args[1:]])
        correcto = cur.fetchone()[0]
    if not correcto:   # fuera del "with": el intento fallido del código queda registrado en la base
        _intento_fallido(clave)
        raise ErrorApi(400, mensaje)
    return Response(status_code=204)


@app.post("/auth/clave")
async def cambiar_clave(request: Request):
    b = await request.json()
    return _clave_ingreso(request, "clave", "cambiar_clave",
                          [b.get("email"), str(b.get("actual") or ""), str(b.get("nueva") or "")],
                          "El email o la contraseña actual no son correctos.")


@app.post("/auth/restablecer")
async def restablecer_clave(request: Request):
    b = await request.json()
    return _clave_ingreso(request, "restablecer", "restablecer_clave",
                          [b.get("email"), str(b.get("codigo") or ""), str(b.get("nueva") or "")],
                          "El código no es válido o venció. Solicitá uno nuevo a la persona que administra el sistema.")


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
    with transaccion(claims, limite=CARGA_TIMEOUT if funcion in FUNCIONES_DE_CARGA else None) as cur:
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


# ---------------------------------------------------------------- Panel de control
# Solo para las personas de panel.acceso (db/mejoras/05_panel.sql). La API lo verifica en cada pedido y las funciones
# de la base lo vuelven a verificar.
def _panel(request):
    claims = usuario_del_pedido(request)
    with transaccion(claims) as cur:
        cur.execute("SELECT panel.tiene_acceso() AS ok")
        if not cur.fetchone()["ok"]:
            raise ErrorApi(403, "Sin acceso al Panel de control.")
    return claims


def _panel_consulta(claims, consulta, params=(), una=False):
    with transaccion(claims) as cur:
        cur.execute(consulta, params)
        return cur.fetchone() if una else cur.fetchall()


@app.get("/panel/acceso")
def panel_acceso(request: Request):
    claims = usuario_del_pedido(request)
    with transaccion(claims) as cur:
        cur.execute("SELECT to_regprocedure('panel.tiene_acceso()') IS NOT NULL AS hay")
        if not cur.fetchone()["hay"]:
            return respuesta_json({"acceso": False})
        cur.execute("SELECT panel.tiene_acceso() AS ok")
        return respuesta_json({"acceso": cur.fetchone()["ok"]})


def _recursos():
    r = {"cpus": os.cpu_count()}
    try:
        r["carga"] = os.getloadavg()
    except OSError:
        pass
    try:
        d = shutil.disk_usage(STORAGE_DIR)
        r["disco"] = {"total": d.total, "usado": d.used, "libre": d.free}
    except OSError:
        pass
    try:
        info = dict(l.split(":", 1) for l in pathlib.Path("/proc/meminfo").read_text().splitlines() if ":" in l)
        kb = lambda k: int(info[k].strip().split()[0]) * 1024
        r["memoria"] = {"total": kb("MemTotal"), "disponible": kb("MemAvailable")}
    except (OSError, KeyError, ValueError):
        pass
    return r


@app.get("/panel/estado")
def panel_estado(request: Request):
    c = _panel(request)
    estado = _panel_consulta(c, "SELECT panel.estado() AS e", una=True)["e"]
    estado["recursos"] = _recursos()
    estado["api"] = {"iniciada": INICIO_API.isoformat(), "pool": pool.get_stats().get("pool_size"),
                     "fallas_recientes": sum(1 for l in REGISTRO.lineas if l["nivel"] in ("ERROR", "CRITICAL"))}
    return respuesta_json(estado)


@app.get("/panel/eventos")
def panel_eventos(request: Request, servicio: str = None, nivel: str = None, limite: int = 200):
    c = _panel(request)
    return respuesta_json(_panel_consulta(c, "SELECT * FROM panel.eventos(%s, %s, %s)", (servicio, nivel, limite)))


@app.get("/panel/registro")
def panel_registro(request: Request):
    _panel(request)
    return respuesta_json(list(reversed(REGISTRO.lineas)))


@app.get("/panel/usuarios")
def panel_usuarios(request: Request):
    c = _panel(request)
    return respuesta_json(_panel_consulta(c, "SELECT * FROM panel.usuarios()"))


ACCIONES_USUARIO = {
    "crear": ("SELECT panel.crear_usuario(%s, %s, %s) AS r", ("email", "rol", "oficina")),
    "rol": ("SELECT panel.cambiar_rol(%s, %s, %s) AS r", ("email", "rol", "oficina")),
    "bloquear": ("SELECT panel.bloquear(%s, true) AS r", ("email",)),
    "desbloquear": ("SELECT panel.bloquear(%s, false) AS r", ("email",)),
    "codigo": ("SELECT panel.codigo_clave(%s) AS r", ("email",)),
    "cerrar_sesiones": ("SELECT panel.cerrar_sesiones(%s) AS r", ("email",)),
}


@app.post("/panel/usuarios")
async def panel_usuario_accion(request: Request):
    c = _panel(request)
    b = await request.json()
    accion = ACCIONES_USUARIO.get(b.get("accion"))
    if not accion:
        raise ErrorApi(400, "Acción desconocida")
    consulta, campos = accion
    fila = _panel_consulta(c, consulta, [b.get(k) for k in campos], una=True)
    return respuesta_json({"resultado": fila["r"]})


@app.get("/panel/actividad")
def panel_actividad(request: Request, usuario: str = None, tipo: str = None, desde: str = None, hasta: str = None,
                    limite: int = 300):
    c = _panel(request)
    return respuesta_json(_panel_consulta(c, "SELECT * FROM panel.actividad(%s, %s, %s::date, %s::date, %s)",
                                          (usuario or None, tipo or None, desde or None, hasta or None, limite)))


@app.get("/panel/integridad")
def panel_integridad(request: Request):
    c = _panel(request)
    charts = _panel_consulta(c, "SELECT * FROM panel.integridad_charts()")
    problemas = _panel_consulta(c, "SELECT * FROM panel.cargas_con_problemas(200)")
    registrados = _panel_consulta(c, "SELECT * FROM panel.archivos_registrados()")
    # Archivos registrados en la base contra los archivos reales del almacenamiento.
    base = STORAGE_DIR / "csv-uploads"
    faltantes, distinto = [], []
    for a in registrados:
        f = base / a["nombre"]
        try:
            tam = f.stat().st_size
        except OSError:
            faltantes.append({"archivo": a["filename"] or a["nombre"], "ruta": a["nombre"]})
            continue
        if a["tamano"] is not None and tam != a["tamano"]:
            distinto.append({"archivo": a["filename"] or a["nombre"], "ruta": a["nombre"], "registrado": a["tamano"], "real": tam})
    nombres = {a["nombre"] for a in registrados}
    sueltos = sum(1 for f in base.rglob("*") if f.is_file() and not f.name.endswith(".tmp")
                  and f.relative_to(base).as_posix() not in nombres) if base.exists() else 0
    return respuesta_json({"charts": charts, "problemas": problemas,
                           "archivos": {"registrados": len(registrados), "faltantes": faltantes[:200],
                                        "cantidad_faltantes": len(faltantes), "distinto_tamano": distinto[:200],
                                        "sin_registrar": sueltos}})


@app.post("/panel/respaldo")
def panel_respaldo(request: Request):
    c = _panel(request)
    with transaccion(c) as cur:
        cur.execute("SELECT panel.pedir_respaldo() AS id")
        return respuesta_json({"id": cur.fetchone()["id"]})


# ---------------------------------------------------------------- front
def _base_lista():
    try:
        with pool.connection(timeout=3) as conn:
            conn.execute("SELECT 1")
        return True
    except Exception:
        return False


@app.get("/health")
def salud():
    if not _base_lista():
        return JSONResponse({"ok": False, "message": "La base de datos todavía no responde"}, status_code=503)
    return {"ok": True}


@app.get("/listo.png")
def listo():
    """Para la pantalla "Iniciando" del lanzador de Windows (un archivo local solo puede probar imágenes): responde una
    imagen cuando la aplicación y la base están listas para ingresar."""
    if not _base_lista():
        return Response(status_code=503)
    return FileResponse(FRONT_DIR / "iconos" / "icono-32.png", headers={"Cache-Control": "no-store"})


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
