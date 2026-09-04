#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Importador de histórico
=======================================

Descarga los ficheros de datos abiertos de PLACSP —ZIP mensuales o
anuales— y guarda en Supabase las licitaciones que encajan con unos
prefijos CPV.

Por qué existe:

  · El scraper diario solo captura los CPV configurados en ese momento.
    Al entrar en un sector nuevo, la base no tiene nada de él y habría que
    esperar días para acumular material.

  · Y ese material hace falta desde el minuto uno: el alta de un cliente
    consiste en enseñarle licitaciones reales de su sector para que marque
    cuáles le interesan. Sin histórico, se registra y espera. Con
    histórico, se registra y empieza.

Los ZIP contienen los MISMOS ficheros .atom que sirve la sindicación en
vivo, así que se reutilizan los extractores del lector diario sin
cambiar una línea. Lo único que cambia es de dónde salen los bytes.

Nota sobre lo que se importa: el histórico viene mayoritariamente
adjudicado o formalizado. No contamina la web, porque la vista
`oportunidades` solo deja pasar lo que está en estado PUB. Entra para
entrenar criterios y para consultar quién ganó qué.

Uso:
    python importar_historico.py --cpv 3514,1882 --anio 2026 --mes 8
    python importar_historico.py --cpv 3514 --url https://...zip
    python importar_historico.py --cpv 3514 --anio 2026 --mes 8 --simulacro
"""

from __future__ import annotations

import argparse
import io
import logging
import os
import sys
import zipfile
from collections import Counter
from datetime import datetime, timezone

import requests

# Se reutiliza todo el trabajo del lector diario: parseo de CODICE,
# extractores por fuente, normalización de fechas y códigos postales.
import lector_atom as lector

# ==============================================================
# 1. CONFIGURACIÓN
# ==============================================================

BASE = "https://contrataciondelsectorpublico.gob.es/sindicacion"

# Conjuntos de datos abiertos disponibles. El nombre del fichero es el
# mismo que el del atom en vivo, con el periodo añadido al final.
CONJUNTOS: dict[str, tuple[str, str]] = {
    "643": ("sindicacion_643", "licitacionesPerfilesContratanteCompleto3"),
    "1044": ("sindicacion_1044", "PlataformasAgregadasSinMenores"),
    "1143": ("sindicacion_1143", "contratosMenoresPerfilesContratantes"),
}

TABLA = "licitaciones"
TAMANO_LOTE = 100
TIMEOUT = 300          # los ZIP anuales pesan cientos de megas
MAX_ENTRADAS = int(os.environ.get("MAX_ENTRADAS_HISTORICO", "400000"))


def configurar_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stdout,
    )


def urls_candidatas(conjunto: str, anio: int, mes: int | None) -> list[str]:
    """
    Construye las direcciones posibles del fichero.

    El patrón mensual no está documentado de forma inequívoca, así que se
    prueban varias formas antes de rendirse. Si ninguna funciona, el
    usuario puede pasar la URL exacta con --url en lugar de adivinarla.
    """
    carpeta, nombre = CONJUNTOS[conjunto]
    if mes is None:
        return [f"{BASE}/{carpeta}/{nombre}_{anio}.zip"]
    return [
        f"{BASE}/{carpeta}/{nombre}_{anio}{mes:02d}.zip",
        f"{BASE}/{carpeta}/{nombre}_{anio}_{mes:02d}.zip",
        f"{BASE}/{carpeta}/{nombre}_{anio}-{mes:02d}.zip",
    ]


# ==============================================================
# 2. DESCARGA
# ==============================================================

def descargar(urls: list[str]) -> bytes | None:
    """Prueba las direcciones candidatas y devuelve el primer ZIP válido."""
    sesion = requests.Session()
    sesion.headers.update({"User-Agent": lector.USER_AGENT})

    for url in urls:
        logging.info("Probando %s", url)
        try:
            respuesta = sesion.get(url, timeout=TIMEOUT, stream=True)
            if respuesta.status_code == 404:
                logging.info("  No existe.")
                continue
            respuesta.raise_for_status()

            trozos, total = [], 0
            for trozo in respuesta.iter_content(chunk_size=1024 * 512):
                trozos.append(trozo)
                total += len(trozo)
                if total % (1024 * 1024 * 20) < 1024 * 512:
                    logging.info("  Descargados %d MB...", total // (1024 * 1024))

            logging.info("  Descargado: %.1f MB", total / (1024 * 1024))
            return b"".join(trozos)

        except requests.exceptions.RequestException as error:
            logging.warning("  Falló: %s", error)

    return None


# ==============================================================
# 3. PROCESADO
# ==============================================================

def procesar(contenido: bytes, prefijos: tuple[str, ...],
             etiqueta: str) -> tuple[list[dict], dict]:
    """
    Recorre los .atom del ZIP y devuelve las licitaciones que encajan.

    Los ficheros se procesan de uno en uno y no se cargan todos a la vez:
    un ZIP anual descomprimido ocupa varios gigas.
    """
    encontradas: dict[str, dict] = {}
    stats = {"ficheros": 0, "entradas": 0, "sin_id": 0, "errores": 0}
    estados = Counter()

    with zipfile.ZipFile(io.BytesIO(contenido)) as paquete:
        atoms = [n for n in paquete.namelist() if n.lower().endswith(".atom")]
        logging.info("Ficheros .atom en el paquete: %d", len(atoms))

        for indice, nombre in enumerate(sorted(atoms), 1):
            stats["ficheros"] += 1
            try:
                raiz = lector.parsear_xml(paquete.read(nombre))
            except Exception as error:
                stats["errores"] += 1
                logging.warning("No se pudo leer %s: %s", nombre, error)
                continue
            if raiz is None:
                stats["errores"] += 1
                continue

            for entrada in lector.localizar_entradas(raiz):
                stats["entradas"] += 1
                if stats["entradas"] > MAX_ENTRADAS:
                    logging.warning("Alcanzado el tope de %d entradas. Se corta.",
                                    MAX_ENTRADAS)
                    return list(encontradas.values()), stats

                if lector.buscar_hijos(entrada, "deleted-entry"):
                    continue
                try:
                    datos = lector.extraer_placsp(entrada, etiqueta)
                except Exception:
                    stats["errores"] += 1
                    continue
                if datos is None:
                    stats["sin_id"] += 1
                    continue

                if not any(c.startswith(prefijos) for c in datos["cpvs"]):
                    continue

                # El histórico trae varias versiones del mismo expediente,
                # una por cada cambio de estado. Gana la última, que es la
                # que refleja cómo acabó.
                anterior = encontradas.get(datos["id_licitacion"])
                if anterior is None or (datos["fecha_actualizacion"] or "") >= \
                        (anterior["fecha_actualizacion"] or ""):
                    encontradas[datos["id_licitacion"]] = datos

            if indice % 25 == 0:
                logging.info("  %d/%d ficheros · %d entradas · %d coincidencias",
                             indice, len(atoms), stats["entradas"], len(encontradas))

    for datos in encontradas.values():
        estados[datos["estado_licitacion"] or "(vacío)"] += 1
    stats["estados"] = dict(estados.most_common())
    return list(encontradas.values()), stats


# ==============================================================
# 4. GUARDADO
# ==============================================================

def guardar(cliente, licitaciones: list[dict]) -> tuple[int, int]:
    """
    Inserta lo que no estaba y refresca lo que sí.

    Se usa el mismo criterio que el lector diario: `upsert` con
    `ignore_duplicates` para las nuevas, sin pisar nada de lo existente.
    Una licitación que ya estaba —porque el scraper la capturó en vivo—
    no debe perder su veredicto de cribado.
    """
    if not licitaciones:
        return 0, 0

    ids = [x["id_licitacion"] for x in licitaciones]
    conocidas: set[str] = set()
    for i in range(0, len(ids), TAMANO_LOTE):
        lote = ids[i:i + TAMANO_LOTE]
        try:
            respuesta = (cliente.table(TABLA).select("id_licitacion")
                         .in_("id_licitacion", lote).execute())
            conocidas.update(f["id_licitacion"] for f in (respuesta.data or []))
        except Exception as error:
            logging.error("Consulta fallida, lote omitido: %s", error)
            conocidas.update(lote)

    nuevas = [x for x in licitaciones if x["id_licitacion"] not in conocidas]
    logging.info("De %d encontradas, %d ya estaban y %d son nuevas.",
                 len(licitaciones), len(licitaciones) - len(nuevas), len(nuevas))

    filas = [
        {
            "id_licitacion": x["id_licitacion"],
            "fuente": x["fuente"],
            "origen": x["origen"],
            "expediente": x["expediente"] or None,
            "titulo": x["titulo"],
            "organo": x["organo"],
            "enlace": x["enlace"] or None,
            "codigo_postal": x["codigo_postal"],
            "presupuesto": x["presupuesto"],
            "cpvs": x["cpvs"],
            "estado_licitacion": x["estado_licitacion"] or None,
            "estado_nombre": x.get("estado_nombre") or None,
            "fecha_actualizacion": (
                f.isoformat() if (f := lector.a_fecha(x["fecha_actualizacion"])) else None
            ),
            "fecha_publicacion": x.get("fecha_publicacion"),
            "fecha_limite": x.get("fecha_limite"),
            "estado_pipeline": "historico",
        }
        for x in nuevas
    ]

    guardadas = 0
    for i in range(0, len(filas), TAMANO_LOTE):
        lote = filas[i:i + TAMANO_LOTE]
        try:
            cliente.table(TABLA).upsert(
                lote, on_conflict="id_licitacion", ignore_duplicates=True
            ).execute()
            guardadas += len(lote)
            if guardadas % 500 == 0:
                logging.info("  Guardadas %d/%d...", guardadas, len(filas))
        except Exception as error:
            logging.error("Fallo al guardar un lote de %d: %s", len(lote), error)

    return guardadas, len(licitaciones) - len(nuevas)


# ==============================================================
# 5. ORQUESTACIÓN
# ==============================================================

def main() -> int:
    p = argparse.ArgumentParser(
        description="Importa histórico de PLACSP desde los ZIP de datos abiertos."
    )
    p.add_argument("--cpv", required=True,
                   help="Prefijos CPV separados por comas. Ej: 3514,1882")
    p.add_argument("--anio", type=int, help="Año del fichero. Ej: 2026")
    p.add_argument("--mes", type=int, help="Mes (1-12). Sin él, el ZIP anual.")
    p.add_argument("--conjunto", default="643", choices=list(CONJUNTOS),
                   help="643 perfiles del Estado, 1044 agregadas, 1143 menores.")
    p.add_argument("--url", help="URL exacta del ZIP, si el patrón no acierta.")
    p.add_argument("--simulacro", action="store_true",
                   help="Procesa e informa, pero NO guarda nada.")
    opciones = p.parse_args()

    configurar_logging()
    prefijos = tuple(x.strip() for x in opciones.cpv.split(",") if x.strip())
    if not prefijos:
        logging.error("Hay que indicar al menos un prefijo CPV.")
        return 1

    if opciones.url:
        urls = [opciones.url]
        etiqueta = f"Histórico · {opciones.url.rsplit('/', 1)[-1]}"
    else:
        if not opciones.anio:
            logging.error("Indica --anio, o pasa la dirección con --url.")
            return 1
        urls = urls_candidatas(opciones.conjunto, opciones.anio, opciones.mes)
        periodo = f"{opciones.anio}-{opciones.mes:02d}" if opciones.mes else str(opciones.anio)
        etiqueta = f"Histórico · sindicación {opciones.conjunto} · {periodo}"

    logging.info("=" * 62)
    logging.info("IMPORTADOR DE HISTÓRICO%s", "  ·  SIMULACRO" if opciones.simulacro else "")
    logging.info("Prefijos CPV: %s", ", ".join(prefijos))
    logging.info("Fuente: %s", etiqueta)
    logging.info("=" * 62)

    contenido = descargar(urls)
    if contenido is None:
        logging.error("No se pudo descargar ninguna de las direcciones probadas.")
        logging.error("Busca la URL exacta en la página de datos abiertos de "
                      "PLACSP y pásala con --url.")
        return 1

    licitaciones, stats = procesar(contenido, prefijos, etiqueta)

    logging.info("--- RESULTADO ---")
    logging.info("  Ficheros procesados: %d", stats["ficheros"])
    logging.info("  Entradas leídas:     %d", stats["entradas"])
    logging.info("  Coincidencias CPV:   %d", len(licitaciones))
    if stats["errores"]:
        logging.warning("  Errores de parseo:   %d", stats["errores"])
    if stats.get("estados"):
        logging.info("  Por estado: %s",
                     ", ".join(f"{k}={v}" for k, v in stats["estados"].items()))

    if licitaciones:
        logging.info("--- MUESTRA ---")
        for x in licitaciones[:10]:
            logging.info("  [%s] %s", x["estado_licitacion"] or "?", x["titulo"][:95])

    if opciones.simulacro:
        logging.info("SIMULACRO: no se ha guardado nada.")
        return 0

    if not licitaciones:
        logging.warning("Ninguna licitación encaja con esos prefijos. "
                        "Revisa los códigos antes de dar el sector por vacío.")
        return 0

    cliente = lector.obtener_cliente_supabase()
    guardadas, repetidas = guardar(cliente, licitaciones)
    logging.info("Guardadas %d licitaciones nuevas (%d ya estaban).",
                 guardadas, repetidas)
    return 0


if __name__ == "__main__":
    sys.exit(main())
