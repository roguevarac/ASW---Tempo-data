"""
Arranca la API sin ventana (versión portable de Windows: se corre con pythonw.exe) y deja los mensajes en RK_LOG.
Variables: las de app.py, más PORT (puerto), HOST (por defecto 127.0.0.1: solo esta PC) y RK_LOG (archivo de registro).
"""
import os
import pathlib
import sys

AQUI = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(AQUI))
os.chdir(AQUI)

if os.environ.get("RK_LOG"):
    registro = open(os.environ["RK_LOG"], "a", encoding="utf-8", buffering=1)
    sys.stdout = sys.stderr = registro

import uvicorn  # noqa: E402

uvicorn.run("app:app", host=os.environ.get("HOST", "127.0.0.1"), port=int(os.environ.get("PORT", "8000")))
