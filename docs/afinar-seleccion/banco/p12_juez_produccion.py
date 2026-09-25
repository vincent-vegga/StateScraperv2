"""
Paso 12 · El juez tal cual lo usa producción (instrucciones y formato de
`puntuador.py`), sobre el grupo de 100/1.000 de una puntuación.

  --puntos F       rasgos (datos/F.json)
  --pesos loco     pesos aprendidos dejando fuera a cada empresa (muestra
                   principal) | produccion (puntuacion_pesos.json, para
                   muestras que no entraron en el ajuste)
  --sin-homol      los ejemplos no incluyen homologaciones
  --atajo V1       solo se juzga lo que el juez V1 aceptó y lo que entra
                   nuevo en el grupo; lo que V1 rechazó se da por rechazado
                   (así se midieron v2 y v3)
  --salida N       datos/veredictos_N.json

Uso: MUESTRA=... python3 p12_juez_produccion.py estimar|hacer [opciones]
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from comun import (CORTE, DATOS, RAIZ, Cache, ParadaPresupuesto, chat, coste,
                   gasto_total, log, tokens_aprox)
from metricas import RASGOS, combinada_loco
from p3_actual import cribador, preparar
from p4_embeddings import normal, titulos

sys.path.insert(0, str(RAIZ))
import puntuador  # noqa: E402

EJEMPLOS = 8
GRUPO = 100


def puntuaciones(puntos: dict, pesos: str) -> dict[str, np.ndarray]:
    if pesos == "loco":
        return combinada_loco(puntos)
    return {et: puntuador.combinar(np.array([[x[r] for r in RASGOS] for x in fl]))
            for et, fl in puntos.items()}


def grupo_de(filas, s) -> set[str]:
    """Las mejores GRUPO/1.000 del universo (sin positivos) y los positivos
    que quedan por encima de ese corte."""
    y = np.array([x["y"] for x in filas])
    neg = np.sort(s[y == 0])[::-1]
    u = neg[min(math.ceil(GRUPO / 1000 * len(neg)), len(neg)) - 1]
    return {x["id"] for x, sc in zip(filas, s) if sc >= u}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("modo", choices=["estimar", "hacer"])
    ap.add_argument("--puntos", required=True)
    ap.add_argument("--pesos", choices=["loco", "produccion"], default="loco")
    ap.add_argument("--sin-homol", action="store_true")
    ap.add_argument("--con-organo", action="store_true",
                    help="ejemplos con quién convocó (v4, descartado: empeora)")
    ap.add_argument("--atajo")
    ap.add_argument("--salida", required=True)
    a = ap.parse_args()

    base, muestra = preparar()
    lic = base["lic"]
    ts = titulos()
    fila = {t: i for i, t in enumerate(ts)}
    emb = np.load(DATOS / "emb.npy", mmap_mode="r")
    puntos = json.load(open(DATOS / f"{a.puntos}.json"))
    punt = puntuaciones(puntos, a.pesos)
    previo = json.load(open(DATOS / f"veredictos_{a.atajo}.json"))["veredictos"] if a.atajo else None
    cache = Cache("juez_produccion")

    tareas, dados = [], defaultdict(dict)
    for emp in muestra["empresas"]:
        et = emp["etiqueta"]
        g = grupo_de(puntos[et], punt[et])
        propias = sorted({x[0] for x in base["por_cif"][emp["cif"]]
                          if x[2] and x[2] < CORTE and not (a.sin_homol and x[5])})
        por_titulo = {}
        for i in propias:
            por_titulo.setdefault(normal(lic[i]["titulo"]), i)
        ids_e = [i for t, i in por_titulo.items() if t in fila]
        E = np.asarray(emb[[fila[normal(lic[i]["titulo"])] for i in ids_e]], np.float32)
        for idl in sorted(g):
            if previo is not None and idl in previo[et] and previo[et][idl] not in ("si", "quizas"):
                dados[et][idl] = previo[et][idl]      # atajo: rechazado antes, rechazado
                continue
            r = fila.get(normal(lic[idl]["titulo"]))
            v = np.asarray(emb[r], np.float32) if r is not None else np.zeros(E.shape[1], np.float32)
            ejemplos = [f"- {normal(lic[ids_e[j]]['titulo'])}"
                        + (f" ({lic[ids_e[j]]['organo']})" if a.con_organo and lic[ids_e[j]]["organo"] else "")
                        for j in np.argsort(-(E @ v))[:EJEMPLOS]]
            f = {k: lic[idl][k] for k in ("titulo", "organo", "presupuesto", "cpvs")}
            tareas.append((et, idl, puntuador.mensajes_juez(f, ejemplos, [], [])))

    if a.modo == "estimar":
        tok = sum(sum(tokens_aprox(m["content"]) for m in t[2]) for t in tareas)
        log(f"{len(tareas)} llamadas, ~{tok} tokens → {coste('gpt-4o-mini', tok, len(tareas) * 60):.3f} $ "
            f"(por lo alto) · gasto actual {gasto_total():.3f} $")
        return

    def juzgar(t):
        et, idl, msgs = t
        try:
            contenido, _ = chat("juez_produccion", cache, msgs, "gpt-4o-mini", 150)
            v = cribador.sin_tildes(str(json.loads(contenido).get("veredicto", ""))).strip().lower()
        except ParadaPresupuesto:
            raise
        except Exception:
            v = "error"
        return et, idl, v

    with ThreadPoolExecutor(16) as ex:
        for n, (et, idl, v) in enumerate(ex.map(juzgar, tareas), 1):
            dados[et][idl] = v
            if n % 1000 == 0:
                log(f"{n}/{len(tareas)} · gasto {gasto_total():.3f} $")
    json.dump({"volumen": GRUPO, "puntos": a.puntos, "pesos": a.pesos, "veredictos": dados},
              open(DATOS / f"veredictos_{a.salida}.json", "w"))
    log(f"hecho: {Counter(x for d in dados.values() for x in d.values())} · gasto {gasto_total():.3f} $")


if __name__ == "__main__":
    main()
