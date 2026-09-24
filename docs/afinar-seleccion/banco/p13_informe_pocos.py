"""
Paso 13 · Empresas con poco historial: sistema actual frente al nuevo
(pesos de producción, grupo 100/1.000, juez de producción), por estrato
y empresa por empresa. Sin coste.

Uso: python3 p13_informe_pocos.py [veredictos_nuevo]   (por defecto v4_pocos)
"""
from __future__ import annotations

import json
import os
import sys

os.environ["MUESTRA"] = "muestra_pocos"

import numpy as np  # noqa: E402

from comun import DATOS  # noqa: E402
from p12_juez_produccion import grupo_de, puntuaciones  # noqa: E402

SI_Q = {"si", "quizas"}


def main() -> None:
    nuevo = sys.argv[1] if len(sys.argv) > 1 else "v4_pocos"
    m = json.load(open(DATOS / "muestra_pocos.json"))
    act = json.load(open(DATOS / "actual_pocos.json"))
    v_act = json.load(open(DATOS / "veredictos_actual_pocos.json"))
    v_new = json.load(open(DATOS / f"veredictos_{nuevo}.json"))["veredictos"]
    puntos = json.load(open(DATOS / "puntos_256_pocos.json"))
    punt = puntuaciones(puntos, "produccion")
    filas = []
    for e in m["empresas"]:
        et = e["etiqueta"]
        pos = set(e["positivos"])
        nu = act[et]["n_universo"]
        d = v_act.get(et, {})
        a_vol = 1000 * sum(1 for i, x in d.items() if x in SI_Q and i not in pos) / nu
        a_rec = sum(1 for i, x in d.items() if x in SI_Q and i in pos)
        g = grupo_de(puntos[et], punt[et])
        dn = v_new[et]
        n_vol = 1000 * sum(1 for i in g if dn.get(i) in SI_Q and i not in pos) / nu
        n_rec = sum(1 for i in g if dn.get(i) in SI_Q and i in pos)
        filas.append((et, e["estrato"], e["n_antes"], len(pos), a_rec, n_rec, a_vol, n_vol))
    print(f"{'empresa':10s} {'antes':>5s} {'pos':>4s}  recall actual→nuevo   volumen actual→nuevo")
    for et, es, na, n, ar, nr, av, nv in sorted(filas, key=lambda r: (r[5] - r[4])):
        marca = "  <-- pierde" if nr < ar else ("  <-- gana" if nr > ar else "")
        print(f"{et:10s} {na:5d} {n:4d}  {ar:3d}→{nr:3d}              {av:6.1f}→{nv:6.1f}{marca}")
    for es, nombre in ((0, "5-9"), (1, "10-14"), (None, "todas")):
        sub = [f for f in filas if es is None or f[1] == es]
        ra = np.array([f[4] / f[3] for f in sub])
        rn = np.array([f[5] / f[3] for f in sub])
        print(f"{nombre:6s}: actual {100 * ra.mean():.1f} % (p10 {100 * np.percentile(ra, 10):.1f}) · "
              f"vol {np.mean([f[6] for f in sub]):.1f}  |  nuevo {100 * rn.mean():.1f} % "
              f"(p10 {100 * np.percentile(rn, 10):.1f}) · vol {np.mean([f[7] for f in sub]):.1f}")


if __name__ == "__main__":
    main()
