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
     con el nombre del SHA-256 de su URL. Un ZIP no se deja entero: se
     abre aquí (de cualquier tamaño, y los ZIP que lleve dentro) y se deja
     lo útil de dentro en una carpeta con ese nombre, en orden de interés.
     La función no puede: tiene 256 MB de memoria.
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

import base64
import hashlib
import io
import logging
import os
import re
import sys
import zipfile
from datetime import datetime, timedelta, timezone

import requests

ALMACEN = "relevo"
MAX_DOCUMENTO = 25 * 1024 * 1024   # lo que la función puede recoger de una vez
MAX_DESCARGA = 300 * 1024 * 1024   # un ZIP grande se abre aquí
MAX_DENTRO = 10                    # lo que la función sube de un ZIP, como mucho
NIVELES = 2                        # ZIP dentro de ZIP
# Lo que la función sabe leer (o abrir, en el caso del ZIP).
LEGIBLES = {"pdf", "docx", "doc", "txt", "html", "htm", "odt", "rtf", "pptx", "zip"}

# Las mismas reglas que zip.ts de la función, para ordenar lo de dentro de
# un ZIP: el pliego, el cuadro y los criterios primero; los modelos y
# declaraciones para rellenar, al final.
PATRON_PLIEGO = re.compile(r"pliego|pcap|ppt|prescrip|cuadro|quadre|caracter|car[aà]tula|criteri|"
                           r"cl[aà]usul|plec|memoria", re.I)
PATRON_FORMULARIO = re.compile(r"model|declaraci|compromi|submissi|encarregat|certificat|protecci|"
                               r"confidencial|\bute\b|plantilla|formulari", re.I)
PATRON_FUERA = re.compile(r"deuc|espd|__macosx|(^|/)\.", re.I)


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


def interes(nombre: str, ext: str) -> int:
    nota = 0 if " › " in nombre else 2
    propio = nombre.split(" › ")[-1]
    if PATRON_PLIEGO.search(propio):
        nota += 3
    if PATRON_FORMULARIO.search(propio):
        nota -= 3
    if ext == "pdf":
        nota += 1
    return nota


def extension_por_contenido(datos: bytes) -> str | None:
    if datos[:4] == b"%PDF":
        return "pdf"
    if datos[:2] == b"PK":
        try:
            with zipfile.ZipFile(io.BytesIO(datos)) as z:
                nombres = z.namelist()
        except zipfile.BadZipFile:
            return None
        if any(n.startswith("word/") for n in nombres):
            return "docx"
        if any(n.startswith("ppt/") for n in nombres):
            return "pptx"
        if "content.xml" in nombres and "mimetype" in nombres:
            return "odt"
        return "zip"
    return None


def nombre_legible(info: zipfile.ZipInfo) -> str:
    """Sin la marca UTF-8, zipfile lee los nombres en cp437: tildes rotas."""
    nombre = info.filename
    if not info.flag_bits & 0x800:
        try:
            nombre = nombre.encode("cp437").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
    return nombre.rsplit("/", 1)[-1]


def abrir_zip(datos: bytes, nivel: int = 1) -> list[tuple[str, bytes, str]]:
    """Lo legible de dentro (y de los ZIP de dentro): (nombre, datos, ext)."""
    salida = []
    try:
        z = zipfile.ZipFile(io.BytesIO(datos))
    except zipfile.BadZipFile:
        return salida
    with z:
        for info in z.infolist():
            if info.is_dir() or PATRON_FUERA.search(info.filename):
                continue
            nombre = nombre_legible(info)
            ext = nombre.rsplit(".", 1)[-1].lower() if "." in nombre else ""
            if ext not in LEGIBLES or info.file_size > MAX_DESCARGA:
                continue
            contenido = z.read(info)
            real = extension_por_contenido(contenido) or ext
            if real == "zip":
                if nivel < NIVELES:
                    salida += [(f"{nombre} › {n}", d, e) for n, d, e in abrir_zip(contenido, nivel + 1)]
                continue
            if len(contenido) <= MAX_DOCUMENTO:
                salida.append((nombre, contenido, real))
    return salida


def descargar(sesion: requests.Session, url: str) -> bytes | None:
    try:
        r = sesion.get(url, timeout=90, stream=True)
        if r.status_code != 200:
            logging.warning("Descarga: HTTP %s", r.status_code)
            return None
        trozos, total = [], 0
        for trozo in r.iter_content(256 * 1024):
            total += len(trozo)
            if total > MAX_DESCARGA:
                logging.warning("Documento de más de %d MB: fuera", MAX_DESCARGA // 2**20)
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
        almacen = cli.storage.from_(ALMACEN)

        def mirar(lista, carpeta=""):
            for f in lista or []:
                ruta = f"{carpeta}{f['name']}"
                if not f.get("id"):          # una carpeta (lo de dentro de un ZIP)
                    mirar(almacen.list(ruta), ruta + "/")
                    continue
                creado = f.get("created_at")
                if creado and datetime.fromisoformat(creado.replace("Z", "+00:00")) < limite:
                    viejos.append(ruta)
        mirar(almacen.list())
        if viejos:
            cli.storage.from_(ALMACEN).remove(viejos)
            logging.info("Borrados %d ficheros viejos del almacén.", len(viejos))
    except Exception as error:
        logging.warning("No se pudo limpiar el almacén: %s", error)


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)-8s | %(message)s",
                        datefmt="%H:%M:%S", stream=sys.stdout)
    # La librería de Supabase escribe cada petición (con la licitación y los
    # nombres de los ficheros) en un registro que es público: fuera.
    for ruidoso in ("httpx", "httpcore", "hpack"):
        logging.getLogger(ruidoso).setLevel(logging.WARNING)
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
        opciones = {"content-type": "application/octet-stream", "upsert": "true"}
        huella = clave_de(url)
        try:
            if extension_por_contenido(datos) == "zip":
                dentro = sorted(abrir_zip(datos), key=lambda e: -interes(e[0], e[2]))[:MAX_DENTRO]
                logging.info("ZIP de %.1f MB: %d ficheros útiles dentro.", len(datos) / 2**20, len(dentro))
                for n, (nombre, contenido, _ext) in enumerate(dentro):
                    cifrado = base64.urlsafe_b64encode(nombre.encode("utf-8")).decode().rstrip("=")
                    cli.storage.from_(ALMACEN).upload(f"{huella}/{n:02d}-{cifrado}", contenido,
                                                      file_options=opciones)
                subidos += bool(dentro)
            elif len(datos) <= MAX_DOCUMENTO:
                cli.storage.from_(ALMACEN).upload(huella, datos, file_options=opciones)
                subidos += 1
            else:
                logging.warning("Documento de más de %d MB que no es un ZIP: fuera",
                                MAX_DOCUMENTO // 2**20)
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
