"""
Banco de pruebas · lo compartido por todos los pasos.

- Lectura de Supabase por PostgREST (solo GET: el banco no escribe nunca
  en producción).
- Llamadas a OpenAI con caché en disco (la misma petición no se paga dos
  veces) y contador de gasto que se para solo al llegar al tope.
- Rutas: los datos viven en `datos/`, fuera de git, porque llevan NIF y
  títulos de clientes.
"""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
import random
import sqlite3
import sys
import threading
import time
from pathlib import Path

import requests

AQUI = Path(__file__).resolve().parent
DATOS = AQUI / "datos"
DATOS.mkdir(exist_ok=True)
RAIZ = AQUI.parents[2]

# Qué muestra de empresas se usa: "muestra" (las 40 con >=15 contratos) o,
# con MUESTRA=muestra_pocos, las de poco historial. Los resultados de una
# muestra que no sea la principal llevan su nombre como sufijo.
MUESTRA = os.environ.get("MUESTRA", "muestra")
SUFIJO = "" if MUESTRA == "muestra" else "_" + MUESTRA.removeprefix("muestra_")

CORTE = "2026-01-01"          # T: el perfil solo ve lo ganado antes
HOY = "2026-09-25"            # fechas de adjudicación posteriores son ruido

# ------------------------------------------------------------
# Gasto
# ------------------------------------------------------------
# Precios en dólares por millón de tokens (tarifa estándar publicada).
PRECIOS = {
    "gpt-4o":                 (2.50, 10.00),
    "gpt-4o-mini":            (0.15, 0.60),
    "text-embedding-3-small": (0.02, 0.0),
}
TOPE = float(os.environ.get("TOPE_GASTO", "16.0"))   # parada automática (límite del proyecto: 17 $)
FICHERO_GASTO = DATOS / "gasto.json"
_hilos = threading.Lock()


class _Cerrojo:
    """Hilos y procesos: varios pasos pueden gastar a la vez."""
    def __enter__(self):
        _hilos.acquire()
        self.f = open(DATOS / "gasto.lock", "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()
        _hilos.release()


_cerrojo = _Cerrojo()


class ParadaPresupuesto(RuntimeError):
    pass


def _leer_gasto() -> dict:
    if FICHERO_GASTO.exists():
        return json.loads(FICHERO_GASTO.read_text())
    return {"total": 0.0, "por_paso": {}, "llamadas": 0}


def gasto_total() -> float:
    with _cerrojo:
        return _leer_gasto()["total"]


def _apuntar(paso: str, coste: float) -> None:
    g = _leer_gasto()
    g["total"] += coste
    g["por_paso"][paso] = g["por_paso"].get(paso, 0.0) + coste
    g["llamadas"] += 1
    tmp = FICHERO_GASTO.with_suffix(".tmp")
    tmp.write_text(json.dumps(g, indent=1))
    tmp.replace(FICHERO_GASTO)


def tokens_aprox(texto: str) -> int:
    """Por lo alto: en español son ~4 caracteres por token; se cuenta 3.
    Solo para estimar antes de gastar; lo que se apunta es el `usage` real."""
    return len(texto) // 3 + 1


def coste(modelo: str, entrada: int, salida: int) -> float:
    pin, pout = PRECIOS[modelo]
    return (entrada * pin + salida * pout) / 1e6


# ------------------------------------------------------------
# Caché en disco
# ------------------------------------------------------------
class Cache:
    def __init__(self, nombre: str):
        self.db = sqlite3.connect(DATOS / f"cache_{nombre}.sqlite",
                                  check_same_thread=False)
        self.db.execute("create table if not exists c (k text primary key, v text)")
        self.cerrojo = threading.Lock()

    def get(self, k: str):
        with self.cerrojo:
            fila = self.db.execute("select v from c where k=?", (k,)).fetchone()
        return json.loads(fila[0]) if fila else None

    def put(self, k: str, v) -> None:
        with self.cerrojo:
            self.db.execute("insert or replace into c values (?,?)", (k, json.dumps(v)))
            self.db.commit()


def clave(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, ensure_ascii=False)
                          .encode()).hexdigest()


# ------------------------------------------------------------
# OpenAI
# ------------------------------------------------------------
_sesion_ia = requests.Session()


def _post_openai(ruta: str, cuerpo: dict) -> dict:
    clave_api = os.environ["OPENAI_API_KEY"]
    espera = 1.0
    for intento in range(30):
        try:
            r = _sesion_ia.post(f"https://api.openai.com/v1/{ruta}", json=cuerpo,
                                headers={"Authorization": f"Bearer {clave_api}"},
                                timeout=120)
        except requests.RequestException:
            # Corte de red: la petición pudo cobrarse sin llegar; se repite.
            time.sleep(espera + random.random())
            espera = min(espera * 2, 30)
            continue
        if r.status_code == 200:
            return r.json()
        if r.status_code == 429 and "insufficient_quota" in r.text:
            raise ParadaPresupuesto(f"OpenAI sin cuota: {r.text[:200]}")
        if r.status_code in (429, 500, 502, 503, 504) and intento < 29:
            pedido = r.headers.get("retry-after-ms") or r.headers.get("retry-after")
            try:
                w = float(pedido) / (1000 if r.headers.get("retry-after-ms") else 1)
            except (TypeError, ValueError):
                w = espera
            time.sleep(max(w, espera) + random.random())
            espera = min(espera * 2, 30)
            continue
        raise RuntimeError(f"OpenAI {r.status_code}: {r.text[:300]}")
    raise RuntimeError("OpenAI: sin respuesta")


def chat(paso: str, cache: Cache, mensajes: list, modelo: str, max_tokens: int,
         seed: int | None = None) -> tuple[str, bool]:
    """Devuelve (contenido, venia_de_cache). Para antes de pasarse del tope."""
    cuerpo = {"model": modelo, "messages": mensajes,
              "response_format": {"type": "json_object"},
              "temperature": 0, "max_tokens": max_tokens}
    if seed is not None:
        cuerpo["seed"] = seed
    k = clave(cuerpo)
    hit = cache.get(k)
    if hit is not None:
        return hit, True
    # Peor caso de esta llamada: entrada estimada (4 caracteres por
    # token, a lo bruto y por lo alto) más la salida máxima.
    entrada_est = sum(len(m["content"]) for m in mensajes) // 3 + 20
    peor = coste(modelo, entrada_est, max_tokens)
    with _cerrojo:
        if _leer_gasto()["total"] + peor > TOPE:
            raise ParadaPresupuesto(f"gasto {_leer_gasto()['total']:.4f} $ + {peor:.4f} > {TOPE} $")
    datos = _post_openai("chat/completions", cuerpo)
    u = datos.get("usage", {})
    with _cerrojo:
        _apuntar(paso, coste(modelo, u.get("prompt_tokens", 0),
                             u.get("completion_tokens", 0)))
    contenido = datos["choices"][0]["message"]["content"] or ""
    cache.put(k, contenido)
    return contenido, False


def embeddings(paso: str, textos: list[str], dimensiones: int,
               modelo: str = "text-embedding-3-small",
               tokens_est: int | None = None) -> list[list[float]]:
    peor = coste(modelo, tokens_est or sum(len(t) for t in textos) // 2, 0)
    with _cerrojo:
        if _leer_gasto()["total"] + peor > TOPE:
            raise ParadaPresupuesto(f"gasto {_leer_gasto()['total']:.4f} $ + {peor:.4f} > {TOPE} $")
    datos = _post_openai("embeddings", {"model": modelo, "input": textos,
                                        "dimensions": dimensiones,
                                        "encoding_format": "float"})
    with _cerrojo:
        _apuntar(paso, coste(modelo, datos["usage"]["prompt_tokens"], 0))
    return [d["embedding"] for d in sorted(datos["data"], key=lambda d: d["index"])]


# ------------------------------------------------------------
# Supabase (solo lectura)
# ------------------------------------------------------------
_sesion_db = requests.Session()


def leer(tabla: str, params: dict) -> list[dict]:
    url = os.environ["SUPABASE_URL"].rstrip("/") + f"/rest/v1/{tabla}"
    k = os.environ["SUPABASE_KEY"]
    for intento in range(6):
        try:
            r = _sesion_db.get(url, params=params, timeout=60,
                               headers={"apikey": k, "Authorization": f"Bearer {k}"})
            if r.status_code == 200:
                return r.json()
            err = f"{r.status_code} {r.text[:200]}"
        except requests.RequestException as e:
            err = str(e)
        time.sleep(2 ** intento)
    raise RuntimeError(f"PostgREST {tabla}: {err}")


def log(*a) -> None:
    print(time.strftime("%H:%M:%S"), *a, flush=True)
    sys.stdout.flush()


def etiqueta(cif: str) -> str:
    """Nombre anónimo y estable de una empresa para registros e informes."""
    return "e" + hashlib.sha256(cif.encode()).hexdigest()[:8]
