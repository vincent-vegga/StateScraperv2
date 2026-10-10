#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Relevo de pliegos (Decisión 57)
===============================================

La función `pliego` de Supabase no puede descargar del portal de
contratación vasco: su cliente de red rechaza el certificado. Desde aquí
(GitHub Actions) se descarga bien. Este script hace de relevo:

  1. Lee los documentos de una licitación (`condiciones.documentos`).
  2. Los descarga y los deja en el almacén privado `relevo` de Supabase,
     con el nombre del SHA-256 de su URL.
  3. Apunta `pliegos_openai.relevo_hecho` y borra `relevo`: la función,
     que estaba esperando, los coge, los sube a OpenAI y los borra.

No se archiva nada (Decisión 16): los ficheros están en el almacén lo que
tarda la función en recogerlos. Por si alguno se queda, al empezar se
borra lo que lleve más de un día.

En el registro no se escribe nada de ningún cliente: los registros de
Actions son públicos.

Uso:
    LICITACION=<id_licitacion> python relevo_pliego.py
"""
from __future__ import annotations

import hashlib
import logging
import os
import sys
from datetime import datetime, timedelta, timezone

import requests

ALMACEN = "relevo"
MAX_DOCUMENTO = 25 * 1024 * 1024   # el mismo tope que la función
# Lo que la función sabe leer (o abrir, en el caso del ZIP).
LEGIBLES = {"pdf", "docx", "doc", "txt", "html", "htm", "odt", "rtf", "pptx", "zip"}


def cliente():
    from supabase import create_client
    url = os.environ.get("SUPABASE_URL", "").strip().rstrip("/")
    for sufijo in ("/rest/v1", "/rest"):
        if url.endswith(sufijo):
            url = url[: -len(sufijo)].rstrip("/")
    return create_client(url, os.environ["SUPABASE_KEY"].strip())


def clave_de(url: str) -> str:
    """El nombre en el almacén: el mismo cálculo que la función (SHA-256)."""
    return hashlib.sha256(url.encode("utf-8")).hexdigest()


def descargar(sesion: requests.Session, url: str) -> bytes | None:
    try:
        r = sesion.get(url, timeout=90, stream=True)
        if r.status_code != 200:
            logging.warning("Descarga: HTTP %s", r.status_code)
            return None
        trozos, total = [], 0
        for trozo in r.iter_content(256 * 1024):
            total += len(trozo)
            if total > MAX_DOCUMENTO:
                logging.warning("Documento de más de %d MB: fuera", MAX_DOCUMENTO // 2**20)
                return None
            trozos.append(trozo)
        return b"".join(trozos)
    except requests.RequestException as error:
        logging.warning("Descarga fallida: %s", type(error).__name__)
        return None


def limpiar_viejos(cli) -> None:
    """Lo que lleve más de un día en el almacén no lo va a recoger nadie."""
    try:
        limite = datetime.now(timezone.utc) - timedelta(days=1)
        viejos = []
        for f in cli.storage.from_(ALMACEN).list() or []:
            creado = f.get("created_at")
            if creado and datetime.fromisoformat(creado.replace("Z", "+00:00")) < limite:
                viejos.append(f["name"])
        if viejos:
            cli.storage.from_(ALMACEN).remove(viejos)
            logging.info("Borrados %d ficheros viejos del almacén.", len(viejos))
    except Exception as error:
        logging.warning("No se pudo limpiar el almacén: %s", error)


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)-8s | %(message)s",
                        datefmt="%H:%M:%S", stream=sys.stdout)
    licitacion = os.environ.get("LICITACION", "").strip()
    if not licitacion:
        logging.error("Falta LICITACION.")
        return 1

    cli = cliente()
    limpiar_viejos(cli)

    fila = (cli.table("condiciones").select("documentos")
            .eq("id_licitacion", licitacion).limit(1).execute().data)
    docs = (fila[0].get("documentos") if fila else None) or []

    sesion = requests.Session()
    sesion.headers["User-Agent"] = "StateScraper/1.0 (lectura de pliegos)"
    subidos = vistos = 0
    for d in docs:
        url, nombre = d.get("url"), (d.get("nombre") or "")
        ext = (d.get("extension") or nombre.rsplit(".", 1)[-1]).lower().strip()
        # El DEUC es un formulario: la función tampoco lo sube.
        if not url or ext not in LEGIBLES or "deuc" in nombre.lower() or "espd" in nombre.lower():
            continue
        vistos += 1
        datos = descargar(sesion, url)
        if not datos:
            continue
        try:
            cli.storage.from_(ALMACEN).upload(
                clave_de(url), datos,
                file_options={"content-type": "application/octet-stream", "upsert": "true"})
            subidos += 1
        except Exception as error:
            logging.warning("No se pudo dejar en el almacén: %s", error)

    logging.info("Documentos: %d a relevar, %d dejados en el almacén.", vistos, subidos)
    ahora = datetime.now(timezone.utc).isoformat()
    cambios = {"relevo": None, "relevo_hecho": ahora}
    if not subidos:
        # Ni desde aquí: que la función no lo pida otra vez en 24 h.
        cambios["fallo"] = ahora
    cli.table("pliegos_openai").update(cambios).eq("id_licitacion", licitacion).execute()
    return 0


if __name__ == "__main__":
    sys.exit(main())
