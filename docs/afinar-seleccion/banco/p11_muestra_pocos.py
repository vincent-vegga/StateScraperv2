"""
Paso 11 · Muestra de empresas con POCO historial (5-14 contratos ganados
antes de T y >=3 después), para decidir si el sistema nuevo les sirve y
se puede bajar `minimo_ganados` (hoy 15). Mismo universo de licitaciones
que la muestra principal. Sin coste.

Después, con MUESTRA=muestra_pocos:
    p3_actual.py lecturas | juez      (sistema actual)
    DIM=256 p5_puntuacion.py          (rasgos)
    p12_juez_pocos.py estimar | hacer (sistema nuevo, pesos de producción)
"""
from __future__ import annotations

import json
import random
from collections import defaultdict

from comun import CORTE, DATOS, HOY, etiqueta, log
from p2_muestra import cargar_base

SEMILLA = 20260925
POR_ESTRATO = 10


def main() -> None:
    base = cargar_base()
    principal = json.load(open(DATOS / "muestra.json"))
    ya = {e["cif"] for e in principal["empresas"]}
    antes, despues = defaultdict(set), defaultdict(set)
    for idl, cif, fecha, _imp, menor, homol in base["adj"]:
        if not fecha:
            continue
        if fecha < CORTE:
            antes[cif].add(idl)
        elif fecha < HOY and not menor and not homol:
            despues[cif].add(idl)
    rnd = random.Random(SEMILLA)
    empresas = []
    for i, (lo, hi) in enumerate(((5, 9), (10, 14))):
        elegibles = sorted(c for c in antes if lo <= len(antes[c]) <= hi
                           and len(despues[c]) >= 3 and c not in ya)
        log(f"estrato {lo}-{hi}: {len(elegibles)} elegibles")
        for c in rnd.sample(elegibles, POR_ESTRATO):
            empresas.append({"cif": c, "estrato": i, "etiqueta": etiqueta(c),
                             "n_antes": len(antes[c]), "positivos": sorted(despues[c])})
    json.dump({"empresas": empresas, "universo": principal["universo"],
               "n_candidatas": principal["n_candidatas"]},
              open(DATOS / "muestra_pocos.json", "w"), ensure_ascii=False)
    for e in empresas:
        log(e["etiqueta"], "antes", e["n_antes"], "positivos", len(e["positivos"]))


if __name__ == "__main__":
    main()
