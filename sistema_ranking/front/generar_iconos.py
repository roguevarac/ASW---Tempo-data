"""
Genera los íconos de Ranking Digital (sin librerías externas): barras de ranking sobre el azul del sistema.
  front/iconos/icono-32.png, icono-192.png, icono-512.png   (PWA y pestaña)
  front/iconos/icono-maskable-512.png                       (PWA "maskable": el dibujo queda dentro de la zona segura)
  windows/ranking.ico                                       (accesos directos de Windows)
Uso: python3 sistema_ranking/front/generar_iconos.py
"""
import math
import pathlib
import struct
import zlib

AQUI = pathlib.Path(__file__).resolve().parent
AZUL, BLANCO = (0x0F, 0x4B, 0xAB), (255, 255, 255)
BARRAS = [(0.22, 0.34, 0.55), (0.42, 0.54, 0.38), (0.62, 0.74, 0.22)]   # x0, x1, alto (fracción del ícono)


def pixel(x, y, n, maskable):
    if maskable:   # cuadrado completo; el dibujo, reducido al 70 % central (zona segura de los íconos maskable)
        u, v = (x / n - 0.15) / 0.70, (y / n - 0.15) / 0.70
        fondo, a = AZUL, 255
    else:          # cuadrado redondeado con borde suave
        r, m = n * 0.18, n * 0.04
        cx, cy = min(max(x, m + r), n - m - r), min(max(y, m + r), n - m - r)
        d = math.hypot(x - cx, y - cy)
        if d > r + 0.5:
            return (0, 0, 0, 0)
        a = 255 if d <= r - 0.5 else int(255 * (r + 0.5 - d))
        u, v, fondo = x / n, y / n, AZUL
    for x0, x1, top in BARRAS:
        if x0 <= u < x1 and top <= v < 0.80:
            return BLANCO + (a,)
    if 0.18 <= u < 0.78 and 0.80 <= v < 0.84:
        return BLANCO + (a,)
    return fondo + (a,)


def png(n, maskable=False):
    filas = b"".join(b"\x00" + bytes(c for x in range(n) for c in pixel(x + 0.5, y + 0.5, n, maskable)) for y in range(n))

    def bloque(tipo, datos):
        return struct.pack(">I", len(datos)) + tipo + datos + struct.pack(">I", zlib.crc32(tipo + datos) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + bloque(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
            + bloque(b"IDAT", zlib.compress(filas, 9)) + bloque(b"IEND", b""))


def ico(tamanos):
    imagenes = [png(n) for n in tamanos]
    cabecera = struct.pack("<HHH", 0, 1, len(tamanos))
    entradas, desplazamiento = b"", 6 + 16 * len(tamanos)
    for n, datos in zip(tamanos, imagenes):
        entradas += struct.pack("<BBBBHHII", n % 256, n % 256, 0, 0, 1, 32, len(datos), desplazamiento)
        desplazamiento += len(datos)
    return cabecera + entradas + b"".join(imagenes)


if __name__ == "__main__":
    (AQUI / "iconos").mkdir(exist_ok=True)
    for n in (32, 192, 512):
        (AQUI / "iconos" / f"icono-{n}.png").write_bytes(png(n))
    (AQUI / "iconos" / "icono-maskable-512.png").write_bytes(png(512, maskable=True))
    (AQUI.parent / "windows" / "ranking.ico").write_bytes(ico([16, 24, 32, 48, 64, 256]))
    print("Íconos generados.")
