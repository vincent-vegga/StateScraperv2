#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Relleno de la duración del contrato en el histórico
===================================================================

El catálogo CSV no guardó la duración, y el ZIP original sí la trae.
Este script relee un mes de datos abiertos de PLACSP y rellena SOLO las
tres columnas nuevas (`duracion_meses`, `duracion_origen`,
`prorrogas_texto`) de lo que ya está en la base, con la función
`rellenar_duracion`. No toca ninguna otra columna ni crea filas, y no
borra: una versión sin periodo no pisa una que lo tenía.

Uso:
    python rellenar_duracion.py --anio 2026 --mes 5 --conjunto 643
    python rellenar_duracion.py --anio 2026 --mes 5 --simulacro
"""
from __future__ import annotations

import argparse
import io
import logging
import zipfile

import lector_atom as lector
import procesar_historico as ph

LOTE = 250


def leer_mes(contenido: bytes) -> tuple[dict[str, dict], int]:
    """Última versión de cada expediente con su duración. Devuelve (filas, entradas)."""
    por_id: dict[str, tuple[str, dict]] = {}
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
                id_lic = (lector.primer_texto(entrada, "id", solo_hijos=True)
                          or lector.extraer_enlace(entrada))
                if not id_lic:
                    continue
                version = lector.primer_texto(entrada, "updated", solo_hijos=True)
                d = lector.extraer_duracion(entrada)
                # Una versión más reciente sin periodo no borra lo que
                # traía una anterior: se queda con lo que haya.
                previa = por_id.get(id_lic)
                if previa and d["duracion_meses"] is None and d["prorrogas_texto"] is None:
                    continue
                if previa and version < previa[0] and previa[1]["duracion_meses"] is not None:
                    continue
                por_id[id_lic] = (version, d)
            if indice % 50 == 0:
                logging.info("  %d/%d ficheros · %d entradas", indice, len(atoms), entradas)
    return {k: v[1] for k, v in por_id.items()}, entradas


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--anio", type=int, required=True)
    p.add_argument("--mes", type=int, required=True)
    p.add_argument("--conjunto", default="643", choices=list(ph.CONJUNTOS))
    p.add_argument("--simulacro", action="store_true",
                   help="Lee y cuenta, sin escribir en la base.")
    a = p.parse_args()
    ph.configurar_logging()

    contenido = ph.descargar(a.conjunto, a.anio, a.mes)
    if contenido is None:
        logging.error("No se pudo descargar %s %d-%02d", a.conjunto, a.anio, a.mes)
        return 1
    filas, entradas = leer_mes(contenido)
    con_dato = [
        {"id": k, **v} for k, v in filas.items()
        if v["duracion_meses"] is not None or v["prorrogas_texto"]]
    publicadas = sum(1 for f in con_dato if f["duracion_origen"] == "publicada")
    logging.info("%s %d-%02d · %d entradas · %d expedientes · %d con dato "
                 "(%d publicada, %d por fechas, %d solo prórrogas)",
                 a.conjunto, a.anio, a.mes, entradas, len(filas), len(con_dato),
                 publicadas,
                 sum(1 for f in con_dato if f["duracion_origen"] == "fechas"),
                 sum(1 for f in con_dato if f["duracion_meses"] is None))
    if a.simulacro:
        return 0

    cliente = lector.obtener_cliente_supabase()
    tocadas = fallos = 0
    for i in range(0, len(con_dato), LOTE):
        lote = con_dato[i:i + LOTE]
        try:
            n = lector.con_reintentos(
                lambda: cliente.rpc("rellenar_duracion", {"filas": lote}).execute().data,
                f"Relleno de un lote de {len(lote)} filas")
            tocadas += int((n[0] if isinstance(n, list) and n else n) or 0)
        except Exception as error:
            fallos += 1
            logging.error("Lote fallido: %s", error)
    logging.info("Actualizadas %d filas (el resto no estaba en la base o ya "
                 "tenía el dato). Lotes fallidos: %d", tocadas, fallos)
    return 1 if fallos else 0


if __name__ == "__main__":
    raise SystemExit(main())
