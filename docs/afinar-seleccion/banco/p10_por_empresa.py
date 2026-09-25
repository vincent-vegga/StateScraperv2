"""
Paso 10 · Comparar dos versiones del juez EMPRESA POR EMPRESA.

La media esconde lo que más importa: un cambio que mejora a casi todas y
hunde a unas pocas. Pasó antes en este proyecto: ajustar el filtro
mirando una empresa concreta empeoró a las demás. Antes de llevar a
producción cualquier cambio del juez o de la puntuación, esta tabla debe
salir limpia: ninguna empresa pierde más de un contrato, o se explica
por qué.

Uso: python3 p10_por_empresa.py datos/veredictos_ejemplos.json datos/veredictos_v2.json [grupo]
Sin coste: solo lee veredictos ya guardados.
"""
from __future__ import annotations

import json
import sys

import numpy as np

from comun import DATOS
from metricas import combinada_loco, umbral_de

ACEPTA = {"si", "quizas"}


def medir(filas, s, u, d):
    y = np.array([x["y"] for x in filas])
    nneg = (y == 0).sum()
    vol = 1000 * sum(1 for x, sc in zip(filas, s)
                     if sc >= u and x["y"] == 0 and d.get(x["id"]) in ACEPTA) / nneg
    rec = sum(1 for x, sc in zip(filas, s)
              if sc >= u and x["y"] == 1 and d.get(x["id"]) in ACEPTA)
    return vol, rec


def main() -> None:
    a, b = sys.argv[1], sys.argv[2]
    grupo = float(sys.argv[3]) if len(sys.argv) > 3 else 100.0
    puntos = json.load(open(DATOS / "puntos.json"))
    comb = combinada_loco(puntos)
    va = json.load(open(a))["veredictos"]
    vb = json.load(open(b))["veredictos"]
    filas = []
    for et, fl in puntos.items():
        y = np.array([x["y"] for x in fl])
        u = umbral_de(comb[et], y, grupo)
        (vo1, r1), (vo2, r2) = medir(fl, comb[et], u, va[et]), medir(fl, comb[et], u, vb[et])
        filas.append((et, int(y.sum()), r1, r2, vo1, vo2))
    filas.sort(key=lambda r: (r[3] - r[2], r[5] - r[4]))
    print(f"{'empresa':10s} {'positivos':>9s}  recall A→B     volumen/1.000 A→B")
    for et, n, r1, r2, vo1, vo2 in filas:
        marca = "  <-- pierde" if r2 < r1 else ("  <-- gana" if r2 > r1 else "")
        print(f"{et:10s} {n:9d}  {r1:3d}→{r2:3d}        {vo1:6.1f}→{vo2:6.1f}{marca}")
    pierden = [r for r in filas if r[3] < r[2]]
    peor = max((r[2] - r[3] for r in pierden), default=0)
    vr = np.array([(r[5] - r[4]) / max(r[4], 1e-9) for r in filas])
    print(f"\npierden: {len(pierden)} empresas ({sum(r[2] - r[3] for r in pierden)} contratos; "
          f"la que más, {peor}) · ganan: {sum(1 for r in filas if r[3] > r[2])} · "
          f"de {sum(r[1] for r in filas)} contratos")
    print(f"volumen por empresa: mediana {100 * np.median(vr):+.0f} %, "
          f"de {100 * vr.min():+.0f} % a {100 * vr.max():+.0f} %")
    print("VEREDICTO:", "limpio" if peor <= 1 else "REVISAR antes de llevarlo a producción")


if __name__ == "__main__":
    main()
