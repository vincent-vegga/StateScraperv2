#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Lectura de la solvencia (feed o pliego)
=======================================================

Para cada licitación abierta con condiciones sin leer (tabla
`condiciones`, Decisión 54), deja escrito lo que hay que acreditar para
presentarse, normalizado:

    economica      volumen de negocios (u otro medio) y su importe o regla
    tecnica        trabajos parecidos (u otro medio) y su importe o regla
    seguro         seguro de responsabilidad civil exigido
    clasificacion  grupo, subgrupo y categoría, y si es obligatoria
    rolece, otros  inscripciones y certificados obligatorios
    exento         el pliego dice que no hace falta acreditar solvencia
    cita           una frase literal del requisito principal

DE DÓNDE SE LEE
  - Del FEED, si trae la solvencia económica y la técnica con contenido
    propio (26 % de lo abierto): basta con normalizar ese texto.
  - Del PLIEGO en el resto: el feed remite a él (29 %) o no trae nada
    (45 %, todo el 1044). Se descarga el pliego de cláusulas
    administrativas y los anexos que parecen el cuadro de características,
    se saca el texto y se mandan al modelo solo los trozos que hablan de
    solvencia (un pliego tiene 80.000-500.000 caracteres; los trozos,
    12.000 como mucho). No se archiva nada (Decisión 16).

EL GASTO
  Cada lectura guarda su coste (`lectura_coste`). El script se para al
  llegar a cualquiera de los tres topes: lo gastado hoy (--gasto-dia), en
  el mes (--gasto-mes) o en total desde que existe la tabla
  (--gasto-total; 0 es sin tope). La pasada diaria usa los dos primeros;
  el relleno inicial, el total.

Uso:
    python leer_pliegos.py --tope 300
    python leer_pliegos.py --solo-en-listas --tope 3000 --gasto-total 5
    python leer_pliegos.py --id <id_licitacion> --simulacro   (sin modelo ni escritura)
"""
from __future__ import annotations

import argparse
import io
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from typing import Any

import requests

import lector_atom as lector

MODELO = os.environ.get("MODELO_PLIEGOS", "gpt-4o-mini")
# Dólares por millón de fichas (entrada, salida) del modelo por defecto.
PRECIOS = {"gpt-4o-mini": (0.15, 0.60)}

MAX_DESCARGA = 30 * 1024 * 1024     # un pliego de más de 30 MB es casi siempre escaneado
MAX_PAGINAS_PYPDF = 160
MAX_TROZOS = 12_000                 # caracteres que van al modelo
TANDA = 500                         # filas que se piden a la cola cada vez
VENTANA = 1_400

# Anexos que suelen llevar la solvencia: el cuadro de características o
# "carátula" que resume el pliego, en castellano, catalán y gallego.
PATRON_ANEXO = re.compile(
    r"cuadro|caracter|caratula|car[aà]tula|quadre|anexo\s*i\b|annex\s*i\b|"
    r"resumen|solvenc|pcap|clausulas|cl[aà]usules|administrativ|prego",
    re.IGNORECASE)

# Lo que delata un trozo de solvencia. El texto se compara sin tildes y
# en minúsculas. "kaudimen" es solvencia en euskera.
PATRON_SOLVENCIA = re.compile(
    r"solvenc|volum(?:en|e)? anual|volum anual|cifra (?:anual )?de negoci|"
    r"xifra (?:anual )?de negoci|volume (?:anual )?de negocio|"
    r"clasificaci|classificaci|subgrup|categoria [1-6]\b|"
    r"seguro de responsabilidad|asseguranca|poliza|polissa|"
    r"(?:trabajos|servicios|suministros|obras|serveis|treballs|subministraments)"
    r" (?:realizados|realitzats|ejecutados|executats|similares|similars)|"
    r"importe anual acumulado|import anual acumulat|"
    r"rolece|registro oficial de licitadores|kaudimen")
PATRON_IMPORTE = re.compile(
    r"\d{1,3}(?:[.\s]\d{3})+(?:,\d+)?\s*(?:€|eur)|\d+(?:,\d+)?\s*(?:€|eur)|"
    r"\bveces\b|\bvegades\b|\bveces\b|\bvez\b|\bvegada\b|\d+\s*%")

SISTEMA = """Eres un analista de contratación pública española. Te doy datos de una licitación y fragmentos de su anuncio o de su pliego (pueden estar en castellano, catalán, gallego o euskera). Extrae qué solvencia hay que acreditar para presentarse.

Responde SOLO con un objeto JSON con exactamente estas claves:
{
 "exento": bool,
 "economica": null | {"medio": "volumen_negocios"|"seguro"|"patrimonio"|"otro", "importe": number|null, "multiplo": number|null, "base": "valor_anual"|"valor_estimado"|"presupuesto"|null, "texto": string},
 "tecnica": null | {"medio": "trabajos_similares"|"titulacion"|"medios"|"certificados"|"otro", "importe": number|null, "multiplo": number|null, "base": "valor_anual"|"valor_estimado"|"presupuesto"|null, "anios": number|null, "texto": string},
 "seguro": null | {"importe": number|null, "texto": string},
 "clasificacion": null | {"codigos": [string], "obligatoria": bool, "texto": string},
 "rolece": bool,
 "otros": [string],
 "lotes_distintos": bool,
 "cita": string|null
}

Reglas:
- Importes en euros, sin IVA, como número (1.151.534,92 € -> 1151534.92).
- NO calcules nada. "importe" solo si la cifra está escrita en el texto; si no, null.
- Si el requisito es una regla relativa ("una vez y media el valor anual medio del contrato", "igual o superior al valor estimado"), pon "multiplo" y "base" (valor_anual = valor anual medio; valor_estimado; presupuesto = presupuesto base de licitación). "Igual a" o "equivalente a" es multiplo 1. Si la regla depende de la duración ("1,5 veces el valor estimado si dura un año o menos, y el valor anual medio si dura más"), usa base = valor_anual: se calcula con la duración. Si además el texto da la cifra ya calculada, ponla en "importe".
- En "economica" va el medio principal de solvencia económica. Si se puede acreditar por volumen de negocios O por otro medio, usa volumen_negocios. Si solo se pide un seguro, medio = "seguro" y además rellena "seguro".
- En "tecnica", trabajos_similares es la relación de trabajos/servicios/suministros/obras parecidos ejecutados; "anios" es cuántos años atrás cuentan (normalmente 3, o 5 en obras). "importe" (o multiplo y base) es SOLO el mínimo que el licitador debe haber ejecutado en el año de mayor ejecución o en total. Si piden otra cosa (un número de contratos, cada uno de cierto tamaño, o el tamaño de las obras proyectadas), déjalo en "texto" con importe, multiplo y base a null.
- No mezcles: la cifra de la técnica no va en la económica ni al revés.
- "clasificacion": códigos como "G6-1" (grupo letra, subgrupo número, categoría). obligatoria = true si es exigida; false si solo sustituye a la solvencia (opcional).
- "exento" = true SOLO si dice expresamente que no se exige acreditar solvencia (p. ej. procedimiento abierto simplificado abreviado, art. 159.6 LCSP).
- "rolece" = true si exige estar inscrito en el ROLECE o en un registro autonómico de licitadores (RELI, etc.).
- "otros": como mucho 4 habilitaciones o certificados obligatorios para presentarse (ISO 9001, inscripción en un registro sectorial, carné profesional...), en castellano y breves. No incluyas las declaraciones de trámite (capacidad de obrar, no prohibición, estar al corriente).
- Si hay lotes con requisitos distintos, da los del lote más pequeño y pon lotes_distintos = true.
- "texto": SIEMPRE en castellano llano, aunque el pliego esté en catalán, gallego o euskera; 160 caracteres como mucho, qué hay que acreditar.
- "cita": frase literal (en su idioma) del requisito económico o técnico principal, 250 caracteres como mucho.
- No inventes: si algo no aparece, null (o false, o lista vacía). Si los fragmentos no hablan de solvencia, devuelve economica y tecnica null."""


# ==============================================================
# Texto de los documentos
# ==============================================================

def sin_tildes(texto: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", texto.lower())
                   if unicodedata.category(c) != "Mn")


def texto_pdf(contenido: bytes) -> str:
    """pdftotext si está (rápido, en C); si no, pypdf con tope de páginas."""
    if shutil.which("pdftotext"):
        with tempfile.NamedTemporaryFile(suffix=".pdf") as f:
            f.write(contenido)
            f.flush()
            try:
                r = subprocess.run(["pdftotext", "-q", "-enc", "UTF-8", f.name, "-"],
                                   capture_output=True, timeout=120)
                return r.stdout.decode("utf-8", "ignore")
            except Exception as error:
                logging.debug("pdftotext falló: %s", error)
    from pypdf import PdfReader
    lector_pdf = PdfReader(io.BytesIO(contenido))
    return "\n".join((p.extract_text() or "")
                     for p in lector_pdf.pages[:MAX_PAGINAS_PYPDF])


def texto_docx(contenido: bytes) -> str:
    with zipfile.ZipFile(io.BytesIO(contenido)) as z:
        xml = z.read("word/document.xml").decode("utf-8", "ignore")
    xml = re.sub(r"</w:p>", "\n", xml)
    return re.sub(r"<[^>]+>", "", xml)


def texto_de(contenido: bytes, nombre: str = "") -> list[tuple[str, str]]:
    """[(nombre, texto)] de un fichero; un ZIP puede traer varios."""
    if contenido[:4] == b"%PDF":
        return [(nombre, texto_pdf(contenido))]
    if contenido[:2] == b"PK":
        try:
            with zipfile.ZipFile(io.BytesIO(contenido)) as z:
                nombres = z.namelist()
                if "word/document.xml" in nombres:
                    return [(nombre, texto_docx(contenido))]
                salida = []
                # Dentro de un ZIP, primero lo que parece el pliego o el cuadro.
                for n in sorted(nombres, key=lambda n: not PATRON_ANEXO.search(n)):
                    if n.lower().endswith((".pdf", ".docx")) and len(salida) < 3:
                        salida += texto_de(z.read(n), n)
                return salida
        except zipfile.BadZipFile:
            return []
    return []


def descargar(sesion: requests.Session, url: str) -> bytes | None:
    try:
        r = sesion.get(url, timeout=90, stream=True)
        if r.status_code != 200:
            return None
        trozos, total = [], 0
        for trozo in r.iter_content(256 * 1024):
            total += len(trozo)
            if total > MAX_DESCARGA:
                return None
            trozos.append(trozo)
        return b"".join(trozos)
    except requests.RequestException as error:
        logging.debug("Descarga fallida %s: %s", url[:80], error)
        return None


def trozos_de_solvencia(texto: str) -> str:
    """
    Los fragmentos del pliego que hablan de solvencia, hasta MAX_TROZOS.

    Se puntúa una ventana alrededor de cada mención: cuántas palabras de
    solvencia tiene y, el doble, cuántos importes o reglas ("1,5 veces").
    Las mejores, sin solaparse, en el orden del documento.
    """
    if not texto:
        return ""
    # Las líneas de puntos del índice ("CLÁUSULA 13.- SOLVENCIA ....... 9")
    # puntuaban como un trozo de solvencia sin decir nada.
    texto = re.sub(r"(?:\.\s?){4,}", " … ", texto)
    plano = sin_tildes(texto)
    candidatas = []
    for m in PATRON_SOLVENCIA.finditer(plano):
        ini = max(0, m.start() - VENTANA // 3)
        fin = min(len(texto), ini + VENTANA)
        trozo = plano[ini:fin]
        nota = (len(PATRON_SOLVENCIA.findall(trozo))
                + 2 * len(PATRON_IMPORTE.findall(trozo)))
        candidatas.append((nota, ini, fin))
    elegidas: list[tuple[int, int]] = []
    total = 0
    for nota, ini, fin in sorted(candidatas, key=lambda c: (-c[0], c[1])):
        if any(ini < f and fin > i for i, f in elegidas):
            continue
        elegidas.append((ini, fin))
        total += fin - ini
        if total >= MAX_TROZOS:
            break
    return "\n[...]\n".join(re.sub(r"[ \t]+", " ", texto[i:f]).strip()
                            for i, f in sorted(elegidas))


def documentos_a_leer(docs: list[dict]) -> list[dict]:
    """El pliego administrativo y hasta dos anexos que parecen el cuadro."""
    vistos: set[str] = set()
    docs = [d for d in docs if d.get("url")
            and not ((d.get("nombre") or d["url"]) in vistos
                     or vistos.add(d.get("nombre") or d["url"]))]
    pcap = [d for d in docs if d.get("tipo") in ("pliego_administrativo", "DOC_PCAP")]
    anexos = [d for d in docs if d not in pcap
              and d.get("tipo") not in ("pliego_tecnico", "DOC_PPT")
              and PATRON_ANEXO.search(d.get("nombre") or "")]
    return (pcap[:2] + anexos[:2])[:3]


# ==============================================================
# El modelo
# ==============================================================

def solvencia_del_feed(solvencia: list[dict]) -> tuple[str, bool]:
    """(texto del feed para el modelo, si basta sin pliego)."""
    utiles = [s for s in solvencia if s.get("clase") in ("economica", "tecnica")]
    lineas = []
    for s in utiles:
        umbral = f" [umbral publicado: {s['umbral']:.2f} €]" if s.get("umbral") else ""
        lineas.append(f"- {s['clase']} ({s.get('codigo') or '?'}): "
                      f"{(s.get('descripcion') or '')[:1500]}{umbral}")
    propias = {s["clase"] for s in utiles if not s.get("es_remision")}
    return "\n".join(lineas), propias >= {"economica", "tecnica"}


def preguntar(cliente, fila: dict, feed: str, trozos: str) -> tuple[dict, float]:
    meses = fila.get("duracion_meses")
    contexto = (
        f"Título: {fila.get('titulo')}\n"
        f"Presupuesto base sin IVA: {fila.get('presupuesto_base') or 'no publicado'}\n"
        f"Valor estimado: {fila.get('valor_estimado') or 'no publicado'}\n"
        f"Duración: {f'{meses} meses' if meses else 'no publicada'}\n\n"
        f"SOLVENCIA SEGÚN EL ANUNCIO:\n{feed or '(no publicada en el anuncio)'}\n")
    if trozos:
        contexto += f"\nFRAGMENTOS DEL PLIEGO:\n{trozos}\n"
    for intento in range(3):
        try:
            r = cliente.chat.completions.create(
                model=MODELO,
                messages=[{"role": "system", "content": SISTEMA},
                          {"role": "user", "content": contexto}],
                response_format={"type": "json_object"},
                temperature=0, max_tokens=700)
            entrada, salida = PRECIOS.get(MODELO, (0.15, 0.60))
            coste = (r.usage.prompt_tokens * entrada
                     + r.usage.completion_tokens * salida) / 1e6
            return json.loads(r.choices[0].message.content), coste
        except json.JSONDecodeError:
            logging.warning("Respuesta sin JSON válido (%d/3)", intento + 1)
        except Exception as error:
            logging.warning("Error del modelo (%d/3): %s", intento + 1, error)
            time.sleep(5 * (intento + 1))
    raise RuntimeError("el modelo no respondió")


def cifras_del_texto(texto: str) -> set[int]:
    """Los importes escritos en el texto, en euros enteros ("1.151.534,92" -> 1151534)."""
    plano = re.sub(r"(?<=\d)[.\s](?=\d{3}\b)", "", texto or "")
    return {int(x) for x in re.findall(r"\d{3,}", plano)}


def limpiar(datos: dict, fuente: str = "") -> dict:
    """
    Lo que el modelo devuelve, recortado al esquema.

    Un importe que no está escrito en el anuncio ni en los trozos del
    pliego se quita: el 06/10/2026 el modelo puso 80.036 € en un pliego
    que solo decía "una vez y media el valor anual medio". La regla sí se
    guarda, y la cifra la calcula la base (`importe_exigido`).
    """
    escritas = cifras_del_texto(fuente)

    def bloque(b, claves):
        if not isinstance(b, dict):
            return None
        salida = {k: b.get(k) for k in claves}
        for k in ("importe", "multiplo", "anios"):
            if k in salida and not isinstance(salida[k], (int, float)):
                salida[k] = None
        # "Equivalente a la anualidad media": la base sin múltiplo es 1.
        if (salida.get("base") and salida.get("multiplo") is None
                and re.search(r"equivalente|igual", str(salida.get("texto") or ""), re.I)):
            salida["multiplo"] = 1
        if salida.get("importe") is not None and fuente:
            entero = int(salida["importe"])
            if not ({entero, entero + 1, entero - 1} & escritas):
                salida["importe"] = None
        if isinstance(salida.get("texto"), str):
            salida["texto"] = salida["texto"][:220]
        return salida
    clas = datos.get("clasificacion") if isinstance(datos.get("clasificacion"), dict) else None
    if clas:
        clas = {"codigos": [str(c).replace(" ", "").upper()
                            for c in (clas.get("codigos") or [])][:6],
                "obligatoria": bool(clas.get("obligatoria")),
                "texto": str(clas.get("texto") or "")[:220]}
        if not clas["codigos"]:
            clas = None
    return {
        "exento": bool(datos.get("exento")),
        "economica": bloque(datos.get("economica"),
                            ("medio", "importe", "multiplo", "base", "texto")),
        "tecnica": bloque(datos.get("tecnica"),
                          ("medio", "importe", "multiplo", "base", "anios", "texto")),
        "seguro": bloque(datos.get("seguro"), ("importe", "texto")),
        "clasificacion": clas,
        "rolece": bool(datos.get("rolece")),
        "otros": [str(x)[:80] for x in (datos.get("otros") or [])
                  if isinstance(x, str)][:4],
        "lotes_distintos": bool(datos.get("lotes_distintos")),
        "cita": (str(datos["cita"])[:300] if datos.get("cita") else None),
    }


# ==============================================================
# Una licitación
# ==============================================================

def leer_una(fila: dict, sesion: requests.Session, cliente_ia,
             simulacro: bool) -> dict:
    """Devuelve {estado, origen, datos, coste, documento, trozos}."""
    feed, basta = solvencia_del_feed(fila.get("solvencia") or [])
    trozos, documento = "", None
    if not basta:
        for doc in documentos_a_leer(fila.get("documentos") or []):
            contenido = descargar(sesion, doc["url"])
            if not contenido:
                continue
            for nombre, texto in texto_de(contenido, doc.get("nombre") or ""):
                trozo = trozos_de_solvencia(texto)
                if trozo:
                    trozos += (f"\n=== {nombre} ===\n" if trozos else "") + trozo
                    documento = documento or nombre
            if len(trozos) >= MAX_TROZOS:
                break
        trozos = trozos[:MAX_TROZOS + 2000]

    if not feed and not trozos:
        estado = "sin_pliego" if not fila.get("documentos") else "sin_texto"
        return {"estado": estado, "origen": None, "datos": None, "coste": 0,
                "documento": None, "trozos": ""}
    origen = "pliego" if trozos else "feed"
    if simulacro:
        return {"estado": "simulacro", "origen": origen, "datos": None,
                "coste": 0, "documento": documento, "trozos": trozos,
                "feed": feed}
    datos, coste = preguntar(cliente_ia, fila, feed, trozos)
    return {"estado": "leido", "origen": origen, "datos": limpiar(datos, f"{feed}\n{trozos}"),
            "coste": coste, "documento": documento, "trozos": trozos}


# ==============================================================
# Principal
# ==============================================================

def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--tope", type=int, default=300, help="Licitaciones como mucho.")
    p.add_argument("--solo-en-listas", action="store_true",
                   help="Solo lo que está en la lista de algún cliente.")
    p.add_argument("--gasto-total", type=float, default=0,
                   help="Dólares como mucho, sumando todas las lecturas guardadas (0: sin tope).")
    p.add_argument("--gasto-mes", type=float, default=10.0,
                   help="Dólares como mucho en las lecturas de este mes (UTC).")
    p.add_argument("--gasto-dia", type=float, default=0.5,
                   help="Dólares como mucho en las lecturas de hoy (UTC).")
    p.add_argument("--hilos", type=int, default=6)
    p.add_argument("--id", default="", help="Una licitación concreta (pruebas).")
    p.add_argument("--simulacro", action="store_true",
                   help="Descarga y recorta, sin modelo ni escritura.")
    a = p.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    base = lector.obtener_cliente_supabase()
    hoy = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0, microsecond=0)
    def gastado(desde: datetime | None = None) -> float:
        args = {"desde": desde.isoformat()} if desde else {}
        return float(base.rpc("gasto_lecturas", args).execute().data or 0)

    # Lo ya gastado y cuánto queda bajo cada tope; manda el más estricto.
    topes = [(a.gasto_dia, gastado(hoy)), (a.gasto_mes, gastado(hoy.replace(day=1)))]
    if a.gasto_total > 0:
        topes.append((a.gasto_total, gastado()))
    margen = min(tope - ya for tope, ya in topes)
    logging.info("Gastado: hoy %.4f $ (tope %.2f), este mes %.4f $ (tope %.2f)%s. "
                 "Margen: %.4f $.", topes[0][1], a.gasto_dia, topes[1][1], a.gasto_mes,
                 f", en total {topes[2][1]:.4f} $ (tope {a.gasto_total:.2f})"
                 if a.gasto_total > 0 else "", margen)
    if margen <= 0:
        logging.warning("Tope de gasto alcanzado: no se lee nada.")
        return 0

    cliente_ia = None
    if not a.simulacro:
        from openai import OpenAI
        clave = os.environ.get("OPENAI_API_KEY", "").strip()
        if not clave:
            logging.error("Falta OPENAI_API_KEY.")
            return 1
        cliente_ia = OpenAI(api_key=clave)

    sesion = requests.Session()
    sesion.headers["User-Agent"] = lector.USER_AGENT

    # Un cliente de Supabase por hilo: compartido, las escrituras
    # simultáneas cortaban la conexión de vez en cuando ("Server
    # disconnected", 8 de 1.000 el 06/10/2026; el reintento las salvaba).
    locales = threading.local()

    def base_del_hilo():
        if not hasattr(locales, "base"):
            locales.base = lector.obtener_cliente_supabase()
        return locales.base

    cerrojo = threading.Lock()
    parar = threading.Event()
    cuenta: dict[str, int] = {}
    gasto = {"run": 0.0}

    def trabajar(fila: dict) -> None:
        if parar.is_set():
            return
        try:
            r = leer_una(fila, sesion, cliente_ia, a.simulacro)
        except Exception as error:
            logging.warning("%s: %s", fila["id_licitacion"][-12:], error)
            r = {"estado": "error", "origen": None, "datos": None, "coste": 0,
                 "documento": None}
        with cerrojo:
            cuenta[r["estado"]] = cuenta.get(r["estado"], 0) + 1
            cuenta[f"origen_{r['origen']}"] = cuenta.get(f"origen_{r['origen']}", 0) + 1
            gasto["run"] += r["coste"]
            if gasto["run"] >= margen:
                parar.set()
        if a.simulacro:
            logging.info("%s · %s · %d caracteres · %s", fila["id_licitacion"][-12:],
                         r["origen"], len(r.get("trozos") or ""), r.get("documento"))
            return
        # Un error también se guarda, sin datos: así sale de la cola de esta
        # pasada, y `condiciones_por_leer` lo vuelve a dar al día siguiente.
        lector.con_reintentos(
            lambda: base_del_hilo().rpc("guardar_lectura", {
                "ficha": fila["id_licitacion"], "datos": r["datos"],
                "origen": r["origen"], "estado": r["estado"],
                "coste": round(r["coste"], 6), "documento": r["documento"],
            }).execute(),
            "Guardar una lectura")

    # Por tandas: la API devuelve 1.000 filas como mucho por llamada, y lo
    # leído (o fallido) sale de la cola, así que cada tanda trae lo
    # siguiente. En simulacro no se guarda nada: una sola tanda.
    inicio = time.monotonic()
    hechas = 0
    with ThreadPoolExecutor(max_workers=a.hilos) as grupo:
        while hechas < a.tope and not parar.is_set():
            filas = base.rpc("condiciones_por_leer", {
                "tope": min(TANDA, a.tope - hechas),
                "solo_en_listas": a.solo_en_listas}).execute().data or []
            if a.id:
                filas = [f for f in filas if f["id_licitacion"] == a.id]
            if not filas:
                break
            logging.info("Tanda de %d (llevamos %d)", len(filas), hechas)
            futuros = [grupo.submit(trabajar, f) for f in filas]
            for i, futuro in enumerate(as_completed(futuros), 1):
                futuro.result()
                if (hechas + i) % 100 == 0:
                    logging.info("  %d · %.4f $ · %s", hechas + i, gasto["run"],
                                 json.dumps(cuenta, ensure_ascii=False))
            hechas += len(filas)
            if a.simulacro or a.id:
                break
    if parar.is_set():
        logging.warning("Parado por el tope de gasto.")
    logging.info("Hecho en %.0f s · %.4f $ · %s", time.monotonic() - inicio,
                 gasto["run"], json.dumps(cuenta, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
