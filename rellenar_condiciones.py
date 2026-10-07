#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Relleno de las condiciones de lo que está abierto
=================================================================

La tabla `condiciones` (Decisión 54) la llena el scraper cada día, pero
solo con lo que pasa por el feed desde que existe. Este script relee los
ZIP mensuales de PLACSP y guarda las condiciones (solvencia,
clasificación, garantías, contacto y documentos) de las licitaciones que
siguen publicadas y con plazo, con la misma función de la base que usa
el scraper (`guardar_condiciones`). No toca `licitaciones`.

El ZIP del mes en curso existe y se actualiza a diario, así que con este
mes y los dos anteriores se cubre casi todo lo abierto (lo publicado
antes y aún con plazo es muy raro).

Uso:
    python rellenar_condiciones.py                    (este mes y los dos anteriores)
    python rellenar_condiciones.py --meses 2026-09,2026-10 --conjunto 643
    python rellenar_condiciones.py --simulacro        (lee y cuenta, sin escribir)
"""
from __future__ import annotations

import argparse
import io
import logging
import zipfile
from datetime import date, datetime, timezone

import lector_atom as lector
import procesar_historico as ph

LOTE = 200


def meses_por_defecto(n: int = 3) -> list[tuple[int, int]]:
    hoy = date.today()
    anio, mes = hoy.year, hoy.month
    salida = []
    for _ in range(n):
        salida.append((anio, mes))
        anio, mes = (anio - 1, 12) if mes == 1 else (anio, mes - 1)
    return salida


def leer_mes(contenido: bytes, extractor, fuente: str,
             por_id: dict[str, dict]) -> int:
    """Añade a `por_id` la última versión de cada expediente. Devuelve entradas leídas."""
    entradas = 0
    with zipfile.ZipFile(io.BytesIO(contenido)) as paquete:
        atoms = sorted(n for n in paquete.namelist() if n.lower().endswith(".atom"))
        for indice, nombre in enumerate(atoms, 1):
            raiz = lector.parsear_xml(paquete.read(nombre))
            if raiz is None:
                continue
            for entrada in lector.localizar_entradas(raiz):
                if lector.buscar_hijos(entrada, "deleted-entry"):
                    continue
                entradas += 1
                try:
                    item = extractor(entrada, fuente)
                except Exception as error:      # una entrada rara no para el mes
                    logging.debug("Entrada ilegible: %s", error)
                    continue
                if not item:
                    continue
                previa = por_id.get(item["id_licitacion"])
                if previa and (previa.get("fecha_actualizacion") or "") >= (
                        item.get("fecha_actualizacion") or ""):
                    continue
                por_id[item["id_licitacion"]] = item
            if indice % 50 == 0:
                logging.info("  %d/%d ficheros · %d entradas", indice, len(atoms), entradas)
    return entradas


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--meses", default="",
                   help="AAAA-MM separados por comas. Vacío: este mes y los dos anteriores.")
    p.add_argument("--conjunto", default="643,1044",
                   help="Sindicaciones separadas por comas (643, 1044).")
    p.add_argument("--simulacro", action="store_true",
                   help="Lee y cuenta, sin escribir en la base.")
    a = p.parse_args()
    ph.configurar_logging()

    meses = ([(int(x[:4]), int(x[5:7])) for x in a.meses.split(",") if x.strip()]
             or meses_por_defecto())
    extractores = {"643": lector.extraer_placsp, "1044": lector.extraer_catalunya}

    por_id: dict[str, dict] = {}
    for conjunto in [c.strip() for c in a.conjunto.split(",") if c.strip()]:
        for anio, mes in meses:
            contenido = ph.descargar(conjunto, anio, mes)
            if contenido is None:
                logging.warning("Sin ZIP para %s %d-%02d", conjunto, anio, mes)
                continue
            n = leer_mes(contenido, extractores[conjunto],
                         f"Relleno {conjunto} · {anio}-{mes:02d}", por_id)
            logging.info("%s %d-%02d · %d entradas · %d expedientes acumulados",
                         conjunto, anio, mes, n, len(por_id))

    ahora = datetime.now(timezone.utc).isoformat()
    abiertas = [x for x in por_id.values()
                if x.get("estado_licitacion") == "PUB"
                and (x.get("fecha_limite") or "") >= ahora[:10]]
    economica = sum(1 for x in abiertas if any(
        s["clase"] in ("economica", "tecnica") and not s["es_remision"]
        for s in x.get("solvencia") or []))
    logging.info("Abiertas: %d · con solvencia propia en el feed: %d · "
                 "con clasificación: %d · con documentos: %d",
                 len(abiertas), economica,
                 sum(1 for x in abiertas if x.get("clasificacion")),
                 sum(1 for x in abiertas if x.get("documentos")))
    if a.simulacro:
        return 0

    cliente = lector.obtener_cliente_supabase()
    filas = [lector.fila_de_condiciones(x) for x in abiertas]
    guardadas = fallos = 0
    for i in range(0, len(filas), LOTE):
        lote = filas[i:i + LOTE]
        try:
            n = lector.con_reintentos(
                lambda: cliente.rpc("guardar_condiciones", {"filas": lote}).execute().data,
                f"Condiciones de un lote de {len(lote)} filas")
            guardadas += int((n[0] if isinstance(n, list) and n else n) or 0)
        except Exception as error:
            fallos += 1
            logging.error("Lote fallido: %s", error)
    logging.info("Guardadas %d condiciones. Lotes fallidos: %d", guardadas, fallos)
    return 1 if fallos else 0


if __name__ == "__main__":
    raise SystemExit(main())
