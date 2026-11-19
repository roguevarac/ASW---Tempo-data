"""
Envío del reporte BO al servidor de BackOffice (antes se subía a mano con FileZilla).

Sube el archivo a la carpeta en la que entra el usuario de BO al conectarse, como hace FileZilla con un servidor FTP:
primero intenta FTP con cifrado TLS (FTPS explícito); si el servidor solo acepta cifrados o versiones de TLS antiguas,
vuelve a intentar en modo compatible (como FileZilla); si el servidor no ofrece TLS o el cifrado no se puede establecer,
FTP simple. El usuario y la contraseña de BO llegan en cada envío y no se guardan en ningún lado.

Configuración (ranking.env, la pasa docker-compose.yml):
  BO_SERVIDOR        intranet.backoffice-ms.com
  BO_PUERTO          21
  BO_MODO            auto (FTPS si se puede, si no FTP) | ftps (solo cifrado) | ftp
  BO_TLS_VERIFICAR   1 = exige un certificado válido (o firmado por los certificados de la empresa) o uno que una
                     persona aceptó (como en FileZilla); 0 = acepta cualquiera

Certificado no reconocido (autofirmado, de otro nombre, vencido): como FileZilla, el sistema muestra el certificado y,
si una persona lo acepta, recuerda su huella SHA-256 (tabla envio_bo_certificados) y desde entonces solo acepta ese
certificado. Antes de aceptarlo no se envían el usuario ni la contraseña.
"""
import ftplib
import hashlib
import io
import os
import posixpath
import re
import socket
import ssl
import tempfile

SERVIDOR = os.environ.get("BO_SERVIDOR", "intranet.backoffice-ms.com")
PUERTO = int(os.environ.get("BO_PUERTO", "21") or 21)
MODO = (os.environ.get("BO_MODO", "auto") or "auto").lower()
TLS_VERIFICAR = os.environ.get("BO_TLS_VERIFICAR", "1") != "0"
ESPERA = int(os.environ.get("BO_ESPERA", "30") or 30)


class ErrorEnvio(Exception):
    pass


class CertificadoDesconocido(ErrorEnvio):
    """El servidor presenta un certificado que no es de confianza y nadie lo aceptó. info: datos para mostrarlo."""

    def __init__(self, info):
        self.info = info
        super().__init__(f"El certificado del servidor de BO no es de confianza: {info['motivo']}.")


class CarpetaSinPermiso(ErrorEnvio):
    """El servidor no deja cargar el archivo en esa carpeta. carpeta: la carpeta actual; carpetas: sus subcarpetas, para
    que la persona elija la misma que usa en FileZilla."""

    def __init__(self, carpeta, carpetas, texto):
        self.carpeta, self.carpetas = carpeta, carpetas
        super().__init__(texto)


class _CertNoAceptado(Exception):
    def __init__(self, der):
        self.der = der


def huella(der):
    """Huella SHA-256 del certificado, como la muestra FileZilla (pares hexadecimales separados por ':')."""
    h = hashlib.sha256(der).hexdigest()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


class _Registro:
    """Anota la conversación con el servidor, como el registro de FileZilla (la contraseña nunca se anota)."""
    registro = None

    def _anotar(self, texto):
        if self.registro is not None and len(self.registro) < 300:
            self.registro.append(texto)

    def putline(self, line):
        self._anotar("Comando: " + ("PASS ********" if line[:5].upper() == "PASS " else line))
        super().putline(line)

    def getline(self):
        line = super().getline()
        self._anotar("Respuesta: " + line)
        return line


class _FTP(_Registro, ftplib.FTP):
    pass


class _FTPS(_Registro, ftplib.FTP_TLS):
    """FTPS que reutiliza la sesión TLS en la conexión de datos (lo exigen muchos servidores, como FileZilla Server).
    Con huellas (certificados aceptados por una persona) no verifica la cadena, pero solo sigue si el certificado es
    uno de esos, en la conexión de control y en la de datos."""
    huellas = None

    def _controlar(self, sock):
        if self.huellas is not None:
            der = sock.getpeercert(binary_form=True)
            if not der or huella(der) not in self.huellas:
                raise _CertNoAceptado(der)

    def auth(self):
        r = super().auth()
        self._controlar(self.sock)
        return r

    def ntransfercmd(self, cmd, rest=None):
        conn, size = ftplib.FTP.ntransfercmd(self, cmd, rest)
        if self._prot_p:
            conn = self.context.wrap_socket(conn, server_hostname=self.host, session=self.sock.session)
            try:
                self._controlar(conn)
            except _CertNoAceptado:
                conn.close()
                raise
        return conn, size


class _SinTLS(Exception):
    """El servidor no ofrece TLS (respondió con error a AUTH TLS)."""


class _FallaTLS(Exception):
    """El servidor ofrece TLS, pero no se pudo establecer el cifrado."""


def _contexto(compatible=False, sin_verificar=False):
    ctx = ssl.create_default_context()
    if compatible:
        # Python solo ofrece por defecto TLS 1.2+ con cifrados ECDHE/DHE y sin SHA1. Muchos servidores FTP (IIS, versiones
        # anteriores de FileZilla Server) solo aceptan cifrados con intercambio RSA o SHA1, o TLS 1.0/1.1, y rechazan el
        # saludo con "handshake failure". FileZilla los acepta: este modo también.
        ctx.set_ciphers("DEFAULT:@SECLEVEL=0")
        try:
            ctx.minimum_version = ssl.TLSVersion.TLSv1
        except (ValueError, AttributeError):
            pass
        ctx.options |= getattr(ssl, "OP_LEGACY_SERVER_CONNECT", 0)
    if sin_verificar or not TLS_VERIFICAR:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _error_login(e):
    texto = str(e)
    if texto.startswith("530") or "login" in texto.lower():
        return ErrorEnvio("BO rechazó el usuario o la contraseña. Verificalos e intentá de nuevo.")
    return ErrorEnvio(f"El servidor de BO respondió: {texto}")


def _pwd(ftp):
    try:
        return ftp.pwd() or "/"
    except ftplib.all_errors:
        return "/"


def _carpetas(ftp):
    """Subcarpetas de la carpeta actual (MLSD; si el servidor no lo tiene, LIST en formato Unix o de IIS)."""
    try:
        return sorted((n for n, f in ftp.mlsd(facts=["type"]) if f.get("type") == "dir"), key=str.lower)
    except ftplib.all_errors:
        pass
    lineas = []
    try:
        ftp.retrlines("LIST", lineas.append)
    except ftplib.all_errors:
        return []
    nombres = []
    for linea in lineas:
        m = re.match(r"^\S+\s+\S+\s+<DIR>\s+(.+)$", linea)   # IIS: "11-17-26  01:23PM  <DIR>  Upload"
        if m:
            nombres.append(m.group(1).strip())
        elif linea.startswith("d"):                         # Unix: "drwxr-xr-x 2 user group 4096 Nov 17 13:23 Upload"
            partes = linea.split(None, 8)
            if len(partes) == 9:
                nombres.append(partes[8].strip())
    return sorted((n for n in nombres if n not in (".", "..")), key=str.lower)


_SIN_PERMISO = ("550", "553", "532", "552")


class _Resultado(str):
    """Cómo se conectó ("FTPS" o "FTP"), con la carpeta donde quedó el archivo."""
    carpeta = None


def _sin_permiso(ftp, e):
    actual = _pwd(ftp)
    return CarpetaSinPermiso(actual, _carpetas(ftp), f"Tu usuario de BO no tiene permiso para cargar archivos en la carpeta "
                             f"{actual} del servidor ({e}).")


def _subir(ftp, nombre, contenido, carpeta=None):
    """Carga el archivo y devuelve la carpeta donde quedó. Sin carpeta indicada, como hace la persona en FileZilla: si en
    la carpeta que se abre al conectarse no se puede escribir y adentro hay una sola carpeta (en BO, la de carga de cada
    usuario, por ejemplo /12345), lo carga ahí."""
    if carpeta:
        try:
            ftp.cwd(carpeta)
        except ftplib.error_perm as e:
            raise CarpetaSinPermiso(_pwd(ftp), _carpetas(ftp), f"No se pudo abrir la carpeta {carpeta} en el servidor de BO ({e}).")
    try:
        ftp.storbinary(f"STOR {nombre}", io.BytesIO(contenido))
        return _pwd(ftp)
    except ftplib.error_perm as e:
        if str(e)[:3] not in _SIN_PERMISO:
            raise
        error = e
    inicial = _pwd(ftp)
    carpetas = _carpetas(ftp)
    if carpeta or len(carpetas) != 1:
        raise CarpetaSinPermiso(inicial, carpetas, f"Tu usuario de BO no tiene permiso para cargar archivos en la carpeta "
                                f"{inicial} del servidor ({error}).")
    ftp._anotar(f"Estado: Sin permiso en {inicial}; se usa la única carpeta que contiene: {carpetas[0]}")
    try:
        ftp.cwd(carpetas[0])
        ftp.storbinary(f"STOR {nombre}", io.BytesIO(contenido))
        return _pwd(ftp)
    except ftplib.error_perm as e:
        if str(e)[:3] in _SIN_PERMISO:
            raise _sin_permiso(ftp, e)
        raise


def _por_tls(servidor, puerto, usuario, clave, nombre, contenido, compatible, huellas=None, carpeta=None, registro=None):
    ftp = _FTPS(context=_contexto(compatible, sin_verificar=huellas is not None), timeout=ESPERA)
    ftp.huellas, ftp.registro = huellas, registro
    if registro is not None:
        registro.append(f"Estado: Conectando a {servidor}:{puerto} (TLS{' compatible' if compatible else ''}"
                        f"{', certificado aceptado' if huellas is not None else ''})...")
    ftp.connect(servidor, puerto)
    try:
        try:
            ftp.auth()
        except ftplib.error_perm as e:
            raise _SinTLS(e)
        try:
            ftp.login(usuario, clave)
        except ftplib.error_perm as e:
            raise _error_login(e)
        ftp.prot_p()
        destino = _subir(ftp, nombre, contenido, carpeta)
        ftp.quit()
        return destino
    except ssl.SSLCertVerificationError:
        raise
    except ssl.SSLError as e:
        raise _FallaTLS(e)
    finally:
        ftp.close()


_MOTIVOS = (("self-signed", "es autofirmado (no lo emitió una entidad de certificación reconocida)"),
            ("self signed", "es autofirmado (no lo emitió una entidad de certificación reconocida)"),
            ("unable to get local issuer", "lo emitió una entidad de certificación que esta computadora no reconoce"),
            ("hostname mismatch", "fue emitido para otro nombre de servidor"),
            ("ip address mismatch", "fue emitido para otro nombre de servidor"),
            ("expired", "está vencido"),
            ("not yet valid", "todavía no es válido"))


def _motivo(e):
    texto = (getattr(e, "verify_message", "") or str(e))
    for clave, motivo in _MOTIVOS:
        if clave in texto.lower():
            return motivo
    return texto


def _nombre(rdns):
    datos = {k: v for rdn in (rdns or ()) for k, v in rdn}
    return datos.get("commonName") or datos.get("organizationName") or ", ".join(f"{k}={v}" for k, v in datos.items())


def info_certificado(der, servidor, motivo):
    """Datos del certificado para mostrarlo a la persona (como el aviso de FileZilla)."""
    info = {"servidor": servidor, "huella": huella(der), "motivo": motivo}
    try:   # Python no expone otra forma de leer un certificado sin la biblioteca cryptography
        with tempfile.NamedTemporaryFile("w", suffix=".pem", delete=False) as f:
            f.write(ssl.DER_cert_to_PEM_cert(der))
        try:
            c = ssl._ssl._test_decode_cert(f.name)
        finally:
            os.unlink(f.name)
        info.update(emitido_para=_nombre(c.get("subject")), emitido_por=_nombre(c.get("issuer")),
                    valido_desde=c.get("notBefore"), valido_hasta=c.get("notAfter"),
                    nombres=", ".join(v for k, v in c.get("subjectAltName", ()) if k in ("DNS", "IP Address")))
    except Exception:
        pass
    return info


def subir(usuario, clave, nombre, contenido, servidor=None, puerto=None, modo=None, huellas=(), carpeta=None):
    """Sube el archivo. Devuelve cómo se conectó ("FTPS" o "FTP"). Errores con un mensaje para la persona y, en
    e.registro, la conversación con el servidor (sin la contraseña), como el registro de FileZilla.
    huellas: certificados del servidor que una persona aceptó (CertificadoDesconocido si presenta otro).
    carpeta: carpeta del servidor donde se carga (vacía: la que se abre al conectarse); CarpetaSinPermiso si no se puede."""
    registro = []
    try:
        return _subir_todo(usuario, clave, nombre, contenido, servidor, puerto, modo, huellas, carpeta, registro)
    except ErrorEnvio as e:
        e.registro = registro
        raise


def _resultado(protocolo, carpeta):
    r = _Resultado(protocolo)
    r.carpeta = carpeta
    return r


def _subir_todo(usuario, clave, nombre, contenido, servidor, puerto, modo, huellas, carpeta, registro):
    carpeta = posixpath.normpath(carpeta.strip()) if carpeta and carpeta.strip() else None
    servidor, puerto, modo = servidor or SERVIDOR, puerto or PUERTO, (modo or MODO)
    if not usuario or not clave:
        raise ErrorEnvio("Ingresá el usuario y la contraseña de BO.")
    falla_tls = None
    try:
        if modo in ("auto", "ftps"):
            for compatible in (False, True):
                try:
                    return _resultado("FTPS", _por_tls(servidor, puerto, usuario, clave, nombre, contenido, compatible,
                                                       carpeta=carpeta, registro=registro))
                except _SinTLS as e:
                    if modo == "ftps":
                        raise ErrorEnvio(f"El servidor de BO no acepta conexiones cifradas: {e}")
                    break
                except _FallaTLS as e:
                    falla_tls = e.args[0]
                except ssl.SSLCertVerificationError as e:
                    # Certificado no reconocido: se acepta solo si una persona aceptó ese mismo certificado. Esta segunda
                    # conexión controla la huella antes de enviar el usuario y la contraseña.
                    try:
                        return _resultado("FTPS", _por_tls(servidor, puerto, usuario, clave, nombre, contenido, compatible,
                                                           huellas=set(huellas or ()), carpeta=carpeta, registro=registro))
                    except _CertNoAceptado as c:
                        if not c.der:
                            raise ErrorEnvio("El servidor de BO no presentó su certificado.")
                        raise CertificadoDesconocido(info_certificado(c.der, servidor, _motivo(e)))
            if falla_tls is not None and modo == "ftps":
                raise ErrorEnvio(f"No se pudo establecer la conexión cifrada con el servidor de BO: {falla_tls}")
        # FTP simple: el servidor no ofrece TLS, el cifrado no se pudo establecer (modo auto) o BO_MODO=ftp.
        ftp = _FTP(timeout=ESPERA)
        ftp.registro = registro
        registro.append(f"Estado: Conectando a {servidor}:{puerto} (sin cifrado)...")
        ftp.connect(servidor, puerto)
        try:
            ftp.login(usuario, clave)
        except ftplib.error_perm as e:
            if falla_tls is not None:
                raise ErrorEnvio(f"El servidor de BO no aceptó el ingreso sin cifrado ({e}) y la conexión cifrada no se "
                                 f"pudo establecer ({falla_tls}). Si el usuario y la contraseña son correctos, informá "
                                 "este mensaje a quien administra el sistema.")
            raise _error_login(e)
        try:
            destino = _subir(ftp, nombre, contenido, carpeta)
            ftp.quit()
        finally:
            ftp.close()
        return _resultado("FTP", destino)
    except ErrorEnvio:
        raise
    except ssl.SSLCertVerificationError as e:   # en la conexión de datos, con un certificado distinto
        raise ErrorEnvio(f"El certificado del servidor de BO no es de confianza: {_motivo(e)}.")
    except ssl.SSLError as e:
        raise ErrorEnvio(f"No se pudo establecer la conexión cifrada con el servidor de BO: {e}")
    except socket.gaierror:
        raise ErrorEnvio(f"No se encontró el servidor de BO ({servidor}). Verificá que la computadora donde funciona "
                         "el sistema tenga conexión a internet.")
    except (socket.timeout, TimeoutError, ConnectionRefusedError, OSError) as e:
        raise ErrorEnvio(f"No se pudo conectar con el servidor de BO ({servidor}:{puerto}): {e}. Verificá que la "
                         "computadora donde funciona el sistema tenga conexión a internet y que el servidor de BO esté "
                         "disponible.")
    except ftplib.all_errors as e:
        raise ErrorEnvio(f"El servidor de BO respondió: {e}")
