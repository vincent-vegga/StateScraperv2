"""
Paso 1 · Descarga (solo lectura) de licitaciones y adjudicaciones.

PostgREST da 1.000 filas por petición; se lee por tramos de
`id_licitacion` en paralelo, con paginación por clave. Los cortes de
tramo salen de una consulta de solo lectura (cada 50.000 filas).
Sin coste de OpenAI.
"""
from __future__ import annotations

import json
import sys
from concurrent.futures import ThreadPoolExecutor

from comun import DATOS, leer, log

CORTES = [
    *(f"https://contrataciondelestado.es/sindicacion/datosAbiertosMenores/{n}" for n in
      (16595929, 16827391, 17081075, 17300895, 17529814, 17720360, 17946500,
       18165138, 18365641, 18575983)),
    *(f"https://contrataciondelestado.es/sindicacion/licitacionesPerfilContratante/{n}" for n in
      (12083103, 14376232, 15103396, 15794312, 16607582, 17329196, 17922331,
       18561144, 19404116, 20015196)),
    *(f"https://contrataciondelestado.es/sindicacion/PlataformasAgregadasSinMenores/{n}" for n in
      (13052432, 15805925, 17960277, 19983237)),
]
TRAMOS = list(zip([None] + CORTES, CORTES + [None]))

CAMPOS_LIC = ("id_licitacion,titulo,cpvs,organo,presupuesto,fecha_actualizacion,"
              "procedimiento,sistema,importe_adjudicacion,estado_licitacion")
CAMPOS_ADJ = "id_licitacion,cif,fecha,importe,es_menor,es_homologacion"


def q(v: str) -> str:
    return '"' + v.replace('"', '\\"') + '"'


def tramo(tabla: str, i: int) -> int:
    desde, hasta = TRAMOS[i]
    salida = DATOS / f"{tabla}_{i:02d}.jsonl"
    hecho = DATOS / f"{tabla}_{i:02d}.ok"
    if hecho.exists():
        return sum(1 for _ in open(salida))
    ultimo, n = desde, 0
    orden, campos = (("id_licitacion", CAMPOS_LIC) if tabla == "licitaciones"
                     else ("id_licitacion,cif", CAMPOS_ADJ))
    with open(salida, "w") as f:
        while True:
            conds = []
            if ultimo:
                conds.append(f"id_licitacion.gt.{q(ultimo)}")
            if hasta:
                conds.append(f"id_licitacion.lte.{q(hasta)}")
            params = {"select": campos, "order": orden, "limit": "1000"}
            if conds:
                params["and"] = "(" + ",".join(conds) + ")"
            filas = leer(tabla, params)
            completa = len(filas) < 1000
            if not completa and tabla != "licitaciones":
                # La última licitación puede venir cortada: se deja para
                # la página siguiente (la paginación es solo por id).
                final = filas[-1]["id_licitacion"]
                recorte = [x for x in filas if x["id_licitacion"] != final]
                if recorte:
                    filas = recorte
            for fila in filas:
                f.write(json.dumps(fila, ensure_ascii=False) + "\n")
            n += len(filas)
            if completa:
                break
            ultimo = filas[-1]["id_licitacion"]
    hecho.touch()
    log(f"{tabla} tramo {i}: {n}")
    return n


if __name__ == "__main__":
    tablas = sys.argv[1:] or ["licitaciones", "adjudicaciones_empresa"]
    for tabla in tablas:
        with ThreadPoolExecutor(12) as ex:
            total = sum(ex.map(lambda i: tramo(tabla, i), range(len(TRAMOS))))
        log(f"{tabla}: {total} filas")
