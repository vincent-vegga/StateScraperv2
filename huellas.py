#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Huellas de títulos (embeddings) en Supabase Storage
===================================================================

Cada título distinto de licitación tiene una «huella»: un vector de 256
números (text-embedding-3-small, recortado a 256 dimensiones) que pone
cerca los títulos que hablan de lo mismo aunque usen palabras distintas.
Es la base de la puntuación de `puntuador.py`.

Por qué en Storage y no en la base: son ~1,1 millones de vectores
(~600 MB). En Postgres, con su índice, ocuparían ~1,5 GB de un disco de
8 GB y no cabrían en 1 GB de RAM. En Storage no cuentan para nada de eso;
el cálculo se hace en GitHub Actions, que tiene memoria de sobra.

Formato (bucket privado `huellas`):
    v1/manifiesto.json   {"dim": 256, "modelo": ..., "partes": [
                            {"vectores": "v1/p0000.npy",
                             "titulos": "v1/p0000.json.gz", "n": 70000}, ...]}
    v1/pNNNN.npy         float16 [n, 256], normalizados
    v1/pNNNN.json.gz     lista de n títulos, en el mismo orden

Los títulos van normalizados con `normal()` (espacios colapsados). Las
partes nuevas se añaden al final; nunca se reescribe una parte existente.
"""
from __future__ import annotations

import gzip
import io
import json
import os
import time
from pathlib import Path

import numpy as np
import requests

BUCKET = "huellas"
PREFIJO = "v1"
DIM = 256
MODELO = "text-embedding-3-small"
MAX_CAR = 800          # los títulos más largos se recortan (~200 tokens)
POR_PARTE = 70_000     # ~36 MB por parte: por debajo del límite de subida


def normal(titulo: str | None) -> str:
    return " ".join((titulo or "").split())


# ------------------------------------------------------------
# Storage
# ------------------------------------------------------------
def _base() -> tuple[str, dict]:
    url = os.environ["SUPABASE_URL"].strip().rstrip("/")
    for sufijo in ("/rest/v1", "/rest"):
        if url.endswith(sufijo):
            url = url[: -len(sufijo)].rstrip("/")
    clave = os.environ["SUPABASE_KEY"].strip()
    return url + "/storage/v1", {"apikey": clave, "Authorization": f"Bearer {clave}"}


def _get(ruta: str) -> bytes | None:
    base, cab = _base()
    for intento in range(5):
        try:
            r = requests.get(f"{base}/object/{BUCKET}/{ruta}", headers=cab, timeout=300)
            if r.status_code == 200:
                return r.content
            if r.status_code in (400, 404) and "not_found" in r.text.lower().replace(" ", "_"):
                return None
            if r.status_code == 404:
                return None
        except requests.RequestException:
            pass
        time.sleep(2 ** intento)
    raise RuntimeError(f"Storage: no se pudo leer {ruta}")


def _put(ruta: str, datos: bytes, tipo: str) -> None:
    base, cab = _base()
    for intento in range(5):
        try:
            r = requests.post(f"{base}/object/{BUCKET}/{ruta}", data=datos, timeout=600,
                              headers={**cab, "Content-Type": tipo, "x-upsert": "true"})
            if r.status_code == 200:
                return
            err = f"{r.status_code} {r.text[:200]}"
        except requests.RequestException as e:
            err = str(e)
        time.sleep(2 ** intento)
    raise RuntimeError(f"Storage: no se pudo escribir {ruta}: {err}")


def leer_manifiesto() -> dict:
    crudo = _get(f"{PREFIJO}/manifiesto.json")
    if crudo is None:
        return {"dim": DIM, "modelo": MODELO, "partes": []}
    return json.loads(crudo)


# ------------------------------------------------------------
# Lectura (con caché local: en Actions, actions/cache guarda la carpeta)
# ------------------------------------------------------------
def cargar(cache: Path) -> tuple[list[str], np.ndarray]:
    """Todos los títulos y sus huellas (float16, normalizadas)."""
    cache.mkdir(parents=True, exist_ok=True)
    man = leer_manifiesto()
    titulos: list[str] = []
    bloques = []
    for parte in man["partes"]:
        fv = cache / Path(parte["vectores"]).name
        ft = cache / Path(parte["titulos"]).name
        if not (fv.exists() and ft.exists()):
            fv.write_bytes(_get(parte["vectores"]))
            ft.write_bytes(_get(parte["titulos"]))
        v = np.load(fv)
        t = json.loads(gzip.decompress(ft.read_bytes()))
        assert len(t) == len(v) == parte["n"], f"parte corrupta: {parte}"
        titulos += t
        bloques.append(v)
    if not bloques:
        return [], np.zeros((0, man["dim"]), np.float16)
    return titulos, np.concatenate(bloques)


# ------------------------------------------------------------
# Escritura
# ------------------------------------------------------------
def anadir(titulos: list[str], vectores: np.ndarray) -> None:
    """Añade títulos nuevos como partes nuevas y actualiza el manifiesto."""
    assert len(titulos) == len(vectores) and vectores.shape[1] == DIM
    man = leer_manifiesto()
    n_partes = len(man["partes"])
    for a in range(0, len(titulos), POR_PARTE):
        nombre = f"{PREFIJO}/p{n_partes:04d}"
        buf = io.BytesIO()
        np.save(buf, vectores[a:a + POR_PARTE].astype(np.float16))
        _put(f"{nombre}.npy", buf.getvalue(), "application/octet-stream")
        _put(f"{nombre}.json.gz",
             gzip.compress(json.dumps(titulos[a:a + POR_PARTE], ensure_ascii=False).encode()),
             "application/gzip")
        man["partes"].append({"vectores": f"{nombre}.npy", "titulos": f"{nombre}.json.gz",
                              "n": len(titulos[a:a + POR_PARTE])})
        n_partes += 1
        # El manifiesto se escribe tras cada parte: si algo se corta, lo
        # ya subido queda registrado y la siguiente pasada sigue desde ahí.
        _put(f"{PREFIJO}/manifiesto.json", json.dumps(man).encode(), "application/json")


def calcular(textos: list[str], clave_openai: str, lote: int = 1000,
             por_minuto: int = 800_000) -> np.ndarray:
    """Huellas nuevas con OpenAI. Respeta el límite de 1 M tokens/min."""
    sesion = requests.Session()
    salida = []
    for a in range(0, len(textos), lote):
        trozo = [t[:MAX_CAR] or "-" for t in textos[a:a + lote]]
        espera = 1.0
        for intento in range(30):
            try:
                r = sesion.post("https://api.openai.com/v1/embeddings", timeout=120,
                                headers={"Authorization": f"Bearer {clave_openai}"},
                                json={"model": MODELO, "input": trozo, "dimensions": DIM})
            except requests.RequestException:
                time.sleep(espera)
                espera = min(espera * 2, 30)
                continue
            if r.status_code == 200:
                break
            if r.status_code == 429 and "insufficient_quota" in r.text:
                raise RuntimeError("OpenAI sin cuota")
            if r.status_code not in (429, 500, 502, 503, 504):
                raise RuntimeError(f"OpenAI {r.status_code}: {r.text[:300]}")
            time.sleep(espera)
            espera = min(espera * 2, 30)
        else:
            raise RuntimeError("OpenAI: sin respuesta tras 30 intentos")
        datos = r.json()
        v = np.array([d["embedding"] for d in sorted(datos["data"], key=lambda d: d["index"])],
                     np.float32)
        v /= np.linalg.norm(v, axis=1, keepdims=True)
        salida.append(v.astype(np.float16))
        # Ritmo: tokens usados / límite por minuto.
        time.sleep(60 * datos["usage"]["prompt_tokens"] / por_minuto)
    return np.concatenate(salida) if salida else np.zeros((0, DIM), np.float16)
