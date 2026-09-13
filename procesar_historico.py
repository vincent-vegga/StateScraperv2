#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Procesador de histórico a catálogo
==================================================

Convierte un mes de datos abiertos de PLACSP en un CSV comprimido con los
campos útiles de cada licitación, y lo guarda en Supabase Storage.

Por qué existe:

  El trabajo caro no es descargar, es LEER el XML. Un año son 620.000
  entradas y más de una hora de recorrido. Repetir eso cada vez que llega
  un cliente de un sector nuevo es inviable.

  Procesando una vez y guardando el resultado plano, filtrar por cualquier
  sector pasa a ser cuestión de segundos. El trabajo caro se paga una vez.

  ZIP de Hacienda ──[una vez]──▶ CSV.gz ──[segundos]──▶ cualquier sector

Se trabaja MES A MES y no por año: el fichero anual supera el gigabyte,
no cabe en memoria y agota el tiempo del job. Doce meses en paralelo
tardan lo que el más lento, y si uno falla los demás siguen.

Formato de salida: CSV comprimido con gzip. Se descarta Parquet a
propósito: filtraría algo más rápido, pero obliga a añadir una
dependencia que pesa más que todo el proyecto junto, y filtrar 600.000
líneas de CSV son unos segundos.

Uso:
    python procesar_historico.py --anio 2025 --mes 3
    python procesar_historico.py --anio 2025 --mes 3 --local  (sin subir)
"""

from __future__ import annotations

import argparse
import csv
import gzip
import io
import json
import logging
import os
import sys
import zipfile
from collections import Counter
from datetime import datetime, timezone

import requests

import lector_atom as lector

# ==============================================================
# 1. CONFIGURACIÓN
# ==============================================================

BASE = "https://contrataciondelsectorpublico.gob.es/sindicacion"
CONJUNTOS: dict[str, tuple[str, str]] = {
    "643": ("sindicacion_643", "licitacionesPerfilesContratanteCompleto3"),
    "1044": ("sindicacion_1044", "PlataformasAgregadasSinMenores"),
    "1143": ("sindicacion_1143", "contratosMenoresPerfilesContratantes"),
}

DEPOSITO = "historico"          # bucket de Supabase Storage
TIMEOUT = 900

# Los campos del catálogo. Se guardan TODOS los CPV, no solo el que
# activó un filtro: el catálogo tiene que servir para cualquier sector
# futuro, no solo para el que motivó su creación.
CAMPOS = [
    "id_licitacion", "expediente", "titulo", "organo", "enlace",
    "codigo_postal", "presupuesto", "cpvs", "estado_licitacion",
    "adjudicatario", "adjudicatario_cif", "importe_adjudicacion",
    "procedimiento", "urgencia", "licitadores", "lotes",
    "adjudicaciones", "adjudicatarios",
    "fecha_actualizacion", "fecha_publicacion", "fecha_limite",
]


def configurar_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%H:%M:%S", stream=sys.stdout,
    )


# ==============================================================
# 2. EL ADJUDICATARIO
# ==============================================================

def normalizar_cif(valor: str) -> str:
    """
    Deja el identificador fiscal en su forma comparable.

    Llega escrito de mil maneras —con guiones, espacios, minúsculas o
    con el prefijo "ES"— y sin normalizar no se puede buscar por él.
    """
    limpio = "".join(c for c in (valor or "").upper() if c.isalnum())
    if limpio.startswith("ES") and len(limpio) > 9:
        limpio = limpio[2:]
    return limpio


def extraer_adjudicaciones(entrada) -> list[dict]:
    """
    TODAS las adjudicaciones del expediente, una por lote.

    Antes se cogía la primera y se paraba. En un contrato de cinco lotes
    con cinco ganadores, eso dejaba fuera a cuatro empresas: no salían en
    su ficha, ni en la competencia, ni en quién compra un organismo. Y el
    importe guardado era el de un lote suelto, que comparado con el
    presupuesto del expediente entero daba porcentajes absurdos.

    En CODICE cada lote es un <cac:TenderResult> dentro del mismo
    expediente, con su adjudicatario y su importe.
    """
    adjudicaciones = []

    for numero, resultado in enumerate(lector.buscar_todos(entrada, "TenderResult"), 1):
        nombre, cif = "", ""
        for parte in lector.buscar_todos(resultado, "WinningParty"):
            if not nombre:
                nombre = lector.primer_texto(parte, "Name")
            if not cif:
                for ident in lector.buscar_todos(parte, "PartyIdentification"):
                    cif = normalizar_cif(lector.primer_texto(ident, "ID"))
                    if cif:
                        break
            if nombre and cif:
                break

        importe = None
        for proyecto in lector.buscar_todos(resultado, "AwardedTenderedProject"):
            for etiqueta in ("PayableAmount", "TotalAmount", "TaxExclusiveAmount"):
                importe = lector.a_numero(lector.primer_texto(proyecto, etiqueta))
                if importe is not None:
                    break
            if importe is not None:
                break

        if nombre or cif or importe is not None:
            adjudicaciones.append({
                "lote": numero,
                "adjudicatario": nombre,
                "cif": cif,
                "importe": importe,
            })

    return adjudicaciones


def resumir_adjudicaciones(adjudicaciones: list[dict]) -> tuple[str, str, float | None]:
    """
    De la lista de lotes, el ganador principal y el importe total.

    Principal es quien más dinero se lleva, no quien aparece primero: en
    un contrato por lotes el orden no significa nada, y el que más pesa
    es el que describe mejor de quién es ese contrato.

    El importe es la SUMA de todos los lotes, que es lo único comparable
    con el presupuesto publicado.
    """
    if not adjudicaciones:
        return "", "", None

    total = sum(a["importe"] for a in adjudicaciones if a["importe"] is not None)
    principal = max(adjudicaciones, key=lambda a: a["importe"] or 0)
    return principal["adjudicatario"], principal["cif"], (total or None)


def extraer_adjudicacion(entrada) -> tuple[str, str, float | None]:
    """
    Quién ganó el contrato, con qué CIF y por cuánto.

    Es el dato que convierte un archivo de licitaciones en inteligencia
    de mercado, y sobre todo es lo que permite que un cliente nuevo se
    identifique y el sistema sepa al instante a qué se presenta: nada
    que él pueda contarnos es tan fiable como lo que ya ha ganado.

    El CIF importa más que el nombre. Una misma empresa aparece como
    "CONFECCIONES IBERICAS, S.L.", "Confecciones Ibéricas SL" o con el
    identificador pegado al nombre; el CIF es lo único que no cambia.

    En CODICE vive dentro de <cac:TenderResult>: el adjudicatario en
    <cac:WinningParty>, su identificación en <cac:PartyIdentification>
    y el importe en <cac:AwardedTenderedProject>.
    """
    nombre, cif, importe = "", "", None

    for resultado in lector.buscar_todos(entrada, "TenderResult"):
        for parte in lector.buscar_todos(resultado, "WinningParty"):
            if not nombre:
                nombre = lector.primer_texto(parte, "Name")
            if not cif:
                for identificacion in lector.buscar_todos(parte, "PartyIdentification"):
                    cif = normalizar_cif(lector.primer_texto(identificacion, "ID"))
                    if cif:
                        break
            if nombre and cif:
                break

        for proyecto in lector.buscar_todos(resultado, "AwardedTenderedProject"):
            for etiqueta in ("PayableAmount", "TotalAmount", "TaxExclusiveAmount"):
                importe = lector.a_numero(lector.primer_texto(proyecto, etiqueta))
                if importe is not None:
                    break
            if importe is not None:
                break
        if nombre or cif or importe is not None:
            break

    return nombre, cif, importe


def a_fila(entrada, etiqueta: str) -> dict | None:
    """Convierte una entrada del feed en una fila del catálogo."""
    datos = lector.extraer_placsp(entrada, etiqueta)
    if datos is None:
        return None

    adjudicaciones = extraer_adjudicaciones(entrada)
    adjudicatario, cif, importe = resumir_adjudicaciones(adjudicaciones)
    fecha_act = lector.a_fecha(datos["fecha_actualizacion"])

    return {
        "id_licitacion": datos["id_licitacion"],
        "expediente": datos["expediente"],
        "titulo": " ".join((datos["titulo"] or "").split()),
        "organo": datos["organo"],
        "enlace": datos["enlace"],
        "codigo_postal": datos["codigo_postal"] or "",
        "presupuesto": datos["presupuesto"] if datos["presupuesto"] is not None else "",
        # Los CPV van como texto separado por comas y no como JSON: el
        # catálogo se filtra leyendo líneas, y una comparación de texto
        # es más simple y más rápida que interpretar JSON en cada fila.
        "cpvs": ",".join(datos["cpvs"]),
        "estado_licitacion": datos["estado_licitacion"] or "",
        "adjudicatario": adjudicatario,
        "adjudicatario_cif": cif,
        # Los tres datos que explican una adjudicación: cómo se adjudicó,
        # cuántos se presentaron y en cuántos lotes iba. Sin ellos, el
        # porcentaje sobre el presupuesto no se puede calcular bien,
        # porque se compara un lote con el expediente entero.
        # La lista entera, para que cada empresa reciba el crédito de su
        # lote en las consultas de inteligencia.
        "adjudicaciones": json.dumps(adjudicaciones, ensure_ascii=False),
        "adjudicatarios": len({a["cif"] for a in adjudicaciones if a["cif"]}),
        "procedimiento": lector.extraer_procedimiento(entrada)[1],
        "urgencia": lector.extraer_urgencia(entrada),
        "licitadores": lector.extraer_licitadores(entrada),
        "lotes": lector.extraer_lotes(entrada),
        "importe_adjudicacion": importe if importe is not None else "",
        "fecha_actualizacion": fecha_act.isoformat() if fecha_act else "",
        "fecha_publicacion": datos.get("fecha_publicacion") or "",
        "fecha_limite": datos.get("fecha_limite") or "",
    }


# ==============================================================
# 3. DESCARGA Y PROCESADO
# ==============================================================

def descargar(conjunto: str, anio: int, mes: int) -> bytes | None:
    carpeta, nombre = CONJUNTOS[conjunto]
    candidatas = [
        f"{BASE}/{carpeta}/{nombre}_{anio}{mes:02d}.zip",
        f"{BASE}/{carpeta}/{nombre}_{anio}_{mes:02d}.zip",
        f"{BASE}/{carpeta}/{nombre}_{anio}-{mes:02d}.zip",
    ]
    sesion = requests.Session()
    sesion.headers.update({"User-Agent": lector.USER_AGENT})

    for url in candidatas:
        logging.info("Probando %s", url)
        try:
            respuesta = sesion.get(url, timeout=TIMEOUT, stream=True)
            if respuesta.status_code == 404:
                continue
            respuesta.raise_for_status()
            contenido = respuesta.content
            logging.info("Descargado: %.1f MB", len(contenido) / (1024 * 1024))
            return contenido
        except requests.exceptions.RequestException as error:
            logging.warning("  Falló: %s", error)
    return None


def procesar(contenido: bytes, etiqueta: str) -> tuple[list[dict], dict]:
    """
    Recorre los .atom del ZIP y devuelve una fila por licitación.

    El histórico trae varias versiones del mismo expediente, una por cada
    cambio de estado. Se conserva la más reciente, que es la que dice
    cómo acabó y quién ganó.
    """
    filas: dict[str, dict] = {}
    stats = {"ficheros": 0, "entradas": 0, "errores": 0}

    with zipfile.ZipFile(io.BytesIO(contenido)) as paquete:
        atoms = sorted(n for n in paquete.namelist() if n.lower().endswith(".atom"))
        logging.info("Ficheros .atom: %d", len(atoms))

        for indice, nombre in enumerate(atoms, 1):
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
                if lector.buscar_hijos(entrada, "deleted-entry"):
                    continue
                try:
                    fila = a_fila(entrada, etiqueta)
                except Exception:
                    stats["errores"] += 1
                    continue
                if fila is None:
                    continue

                anterior = filas.get(fila["id_licitacion"])
                if anterior is None or fila["fecha_actualizacion"] >= anterior["fecha_actualizacion"]:
                    filas[fila["id_licitacion"]] = fila

            if indice % 20 == 0:
                logging.info("  %d/%d ficheros · %d entradas · %d licitaciones",
                             indice, len(atoms), stats["entradas"], len(filas))

    return list(filas.values()), stats


def escribir_csv(filas: list[dict]) -> bytes:
    """Serializa a CSV comprimido."""
    buffer = io.StringIO()
    escritor = csv.DictWriter(buffer, fieldnames=CAMPOS, extrasaction="ignore")
    escritor.writeheader()
    escritor.writerows(filas)
    return gzip.compress(buffer.getvalue().encode("utf-8"), compresslevel=6)


# ==============================================================
# 4. SUBIDA
# ==============================================================

def subir(datos: bytes, ruta: str) -> bool:
    """
    Guarda el catálogo en Supabase Storage.

    Va a Storage y no a una tabla porque 620.000 filas con sus índices se
    comen el medio giga del plan gratuito. El mismo contenido comprimido
    son decenas de megas y entra en el gigabyte gratuito de ficheros.
    """
    cliente = lector.obtener_cliente_supabase()
    try:
        try:
            cliente.storage.create_bucket(DEPOSITO, options={"public": False})
            logging.info("Creado el depósito '%s'.", DEPOSITO)
        except Exception:
            pass   # ya existía

        almacen = cliente.storage.from_(DEPOSITO)
        try:
            almacen.remove([ruta])
        except Exception:
            pass   # no estaba

        almacen.upload(
            path=ruta, file=datos,
            file_options={"content-type": "application/gzip", "upsert": "true"},
        )
        logging.info("Subido %s (%.1f MB).", ruta, len(datos) / (1024 * 1024))
        return True
    except Exception as error:
        logging.error("No se pudo subir el catálogo: %s", error)
        return False


def volcar_todo(filas: list[dict], etiqueta: str) -> int:
    """
    Guarda en la base todas las licitaciones del mes, vivas o cerradas.

    Volcar solo las abiertas fue un error: de 12.000 licitaciones de un
    sector, apenas 40 siguen vivas en un momento dado, y con eso no hay
    material suficiente para que un cliente entrene su criterio. La
    muestra acababa llenándose de las familias con más volumen, que
    normalmente no son las suyas.

    Y para entrenar, lo cerrado es MEJOR: son contratos que el
    profesional probablemente reconoce, y llevan adjudicatario, así que
    de paso enseñan quién ganó y por cuánto.

    Lo cerrado no contamina las alertas: la vista `oportunidades` solo
    deja pasar lo que está en estado PUB con plazo abierto.

    Sin filtrar por sector: el catálogo sirve para cualquier cliente
    futuro, y guardar solo lo de los sectores actuales obligaría a
    reprocesarlo cada vez que entrara alguien nuevo.
    """
    if not filas:
        return 0

    vivas = filas
    cliente = lector.obtener_cliente_supabase()
    filas_bd = [
        {
            "id_licitacion": f["id_licitacion"],
            "fuente": etiqueta,
            "origen": "Estado",
            "expediente": f["expediente"] or None,
            "titulo": f["titulo"],
            "organo": f["organo"],
            "enlace": f["enlace"] or None,
            "codigo_postal": f["codigo_postal"] or None,
            "presupuesto": f["presupuesto"] if f["presupuesto"] != "" else None,
            "cpvs": [c for c in f["cpvs"].split(",") if c],
            "estado_licitacion": f["estado_licitacion"] or None,
            "fecha_actualizacion": f["fecha_actualizacion"] or None,
            "fecha_publicacion": f["fecha_publicacion"] or None,
            "fecha_limite": f["fecha_limite"] or None,
            # Sin esto el histórico de adjudicaciones se quedaba en los
            # ficheros del catálogo y no se podía consultar. Es lo que
            # permite que un cliente se identifique y el sistema sepa al
            # instante a qué contratos se presenta.
            "adjudicatario": f.get("adjudicatario") or None,
            "adjudicatario_cif": f.get("adjudicatario_cif") or None,
            "procedimiento": f.get("procedimiento") or None,
            "urgencia": f.get("urgencia") or None,
            "licitadores": (int(f["licitadores"])
                            if str(f.get("licitadores") or "").isdigit() else None),
            "lotes": (int(f["lotes"])
                      if str(f.get("lotes") or "").isdigit() else 0),
            "adjudicaciones": (json.loads(f["adjudicaciones"])
                               if f.get("adjudicaciones") else []),
            "adjudicatarios": (int(f["adjudicatarios"])
                               if str(f.get("adjudicatarios") or "").isdigit() else 0),
            "importe_adjudicacion": (f["importe_adjudicacion"]
                                     if f.get("importe_adjudicacion") not in ("", None)
                                     else None),
            "estado_pipeline": "pendiente_analisis",
        }
        for f in vivas
    ]

    guardadas = 0
    for i in range(0, len(filas_bd), 200):
        try:
            # `ignore_duplicates`: lo que ya capturó el scraper en vivo
            # conserva sus datos y su veredicto. Esto solo añade.
            (cliente.table("licitaciones").upsert(
                filas_bd[i:i + 200], on_conflict="id_licitacion",
                ignore_duplicates=True).execute())
            guardadas += len(filas_bd[i:i + 200])
        except Exception as error:
            logging.error("Fallo al volcar un lote: %s", error)

    abiertas = sum(1 for f in filas if f["estado_licitacion"] == "PUB")
    logging.info("Volcadas %d licitaciones (%d abiertas, %d cerradas).",
                 guardadas, abiertas, guardadas - abiertas)

    # El upsert de arriba usa `ignore_duplicates`, así que una licitación
    # que ya existía se salta ENTERA: sus columnas nuevas nunca se
    # rellenan. Se extraían miles de adjudicatarios por mes y se
    # descartaban todos.
    #
    # Esta segunda pasada completa solo esos tres campos, y solo donde
    # faltan: no pisa el estado ni el plazo, que pueden venir de una
    # captura más reciente del scraper.
    con_adjudicatario = [f for f in filas if f.get("adjudicatario")]
    if con_adjudicatario:
        completadas = 0
        for i in range(0, len(con_adjudicatario), 500):
            lote = [
                {
                    "id": f["id_licitacion"],
                    "adjudicatario": f["adjudicatario"],
                    "cif": f.get("adjudicatario_cif") or "",
                    "importe": (str(f["importe_adjudicacion"])
                                if f.get("importe_adjudicacion") not in ("", None) else ""),
                }
                for f in con_adjudicatario[i:i + 500]
            ]
            try:
                respuesta = cliente.rpc("completar_adjudicatarios",
                                        {"datos": lote}).execute()
                completadas += respuesta.data or 0
            except Exception as error:
                logging.error("Fallo al completar adjudicatarios: %s", error)
        logging.info("Adjudicatarios completados en %d filas ya existentes.",
                     completadas)

    return guardadas


def refrescar_resumen() -> None:
    """
    Pide a la base que recalcule el resumen por familia CPV.

    Se hace en SQL y no aquí por una razón de corrección: un expediente
    aparece en varios meses del catálogo, uno por cada cambio de estado,
    así que contarlo mes a mes en Python lo sumaba tantas veces como
    meses en los que se hubiera movido. En la tabla `licitaciones` cada
    expediente es una única fila, y la cuenta sale exacta.
    """
    try:
        cliente = lector.obtener_cliente_supabase()
        respuesta = cliente.rpc("refrescar_resumen_cpv", {}).execute()
        logging.info("Resumen de CPV recalculado: %s familias.", respuesta.data)
    except Exception as error:
        logging.error("No se pudo recalcular el resumen: %s", error)


# ==============================================================
# 5. ORQUESTACIÓN
# ==============================================================

def main() -> int:
    p = argparse.ArgumentParser(
        description="Procesa un mes de histórico de PLACSP a catálogo CSV."
    )
    p.add_argument("--anio", type=int, required=True)
    p.add_argument("--mes", type=int, required=True, choices=range(1, 13))
    p.add_argument("--conjunto", default="643", choices=list(CONJUNTOS))
    p.add_argument("--local", action="store_true",
                   help="Escribe el fichero en disco y NO lo sube.")
    opciones = p.parse_args()

    configurar_logging()
    etiqueta = f"Histórico {opciones.conjunto} · {opciones.anio}-{opciones.mes:02d}"
    ruta = f"{opciones.conjunto}/{opciones.anio}-{opciones.mes:02d}.csv.gz"

    logging.info("=" * 62)
    logging.info("PROCESADOR DE HISTÓRICO · %s", etiqueta)
    logging.info("=" * 62)

    contenido = descargar(opciones.conjunto, opciones.anio, opciones.mes)
    if contenido is None:
        logging.error("No se pudo descargar el fichero de ese periodo.")
        return 1

    filas, stats = procesar(contenido, etiqueta)
    if not filas:
        logging.error("El paquete no ha producido ninguna fila.")
        return 1

    datos = escribir_csv(filas)

    logging.info("--- RESULTADO ---")
    logging.info("  Entradas leídas:  %d", stats["entradas"])
    logging.info("  Licitaciones:     %d", len(filas))
    logging.info("  Con adjudicatario:%d", sum(1 for f in filas if f["adjudicatario"]))
    logging.info("  Comprimido:       %.1f MB", len(datos) / (1024 * 1024))
    logging.info("  Por licitación:   %.0f bytes", len(datos) / len(filas))
    if stats["errores"]:
        logging.warning("  Errores de parseo: %d", stats["errores"])

    reparto = Counter(f["estado_licitacion"] or "(vacío)" for f in filas)
    logging.info("  Estados: %s", ", ".join(f"{k}={v}" for k, v in reparto.most_common(6)))

    if not opciones.local:
        volcar_todo(filas, etiqueta)
        # El resumen se recalcula al final, sobre lo ya volcado: contarlo
        # mes a mes duplicaba los expedientes que se mueven varias veces.
        refrescar_resumen()

    if opciones.local:
        destino = ruta.replace("/", "_")
        with open(destino, "wb") as fichero:
            fichero.write(datos)
        logging.info("Escrito en disco: %s", destino)
        return 0

    return 0 if subir(datos, ruta) else 1


if __name__ == "__main__":
    sys.exit(main())
