"""
Paso 7 · Informe: los dos números (recall y volumen por 1.000) de cada
sistema, en media sobre las empresas y en su percentil 10.

Escribe `docs/afinar-seleccion/RESULTADOS.md` solo con agregados y
etiquetas anónimas (nada de nombres ni NIF). Sin coste.
"""
from __future__ import annotations

import json

import numpy as np

from comun import AQUI, DATOS, _leer_gasto
from metricas import RASGOS, combinada_loco, pesos_globales, recall_a_volumen, resumen

VOLUMENES = [10, 20, 30, 50, 75, 100, 150, 200]


def main() -> None:
    muestra = json.load(open(DATOS / "muestra.json"))
    actual = json.load(open(DATOS / "actual.json"))
    ver_act = json.load(open(DATOS / "veredictos_actual.json")) \
        if (DATOS / "veredictos_actual.json").exists() else {}
    puntos = json.load(open(DATOS / "puntos.json"))
    comb = combinada_loco(puntos)
    ej = json.load(open(DATOS / "veredictos_ejemplos.json")) \
        if (DATOS / "veredictos_ejemplos.json").exists() else None

    filas_sis = {}   # sistema -> lista de (volumen, recall) por empresa

    def apunta(sis, vol, rec):
        filas_sis.setdefault(sis, []).append((vol, rec))

    for emp in muestra["empresas"]:
        et = emp["etiqueta"]
        a = actual[et]
        nu, npos = a["n_universo"], a["n_pos"]
        pos = set(emp["positivos"])
        apunta("Actual · solo puerta CPV", 1000 * a["puerta_vol"] / nu, a["puerta_pos"] / npos)
        v = ver_act.get(et, {})
        if v:
            for nombre, ok in (("Actual · puerta + juez (sí+quizás)", {"si", "quizas"}),
                               ("Actual · puerta + juez (solo sí)", {"si"})):
                vol = sum(1 for i, x in v.items() if x in ok and i not in pos)
                rec = sum(1 for i, x in v.items() if x in ok and i in pos)
                apunta(nombre, 1000 * vol / nu, rec / npos)
        if ej and et in ej["veredictos"]:
            v = ej["veredictos"][et]
            for nombre, ok in (("Nuevo · puntuación + juez con ejemplos (sí+quizás)", {"si", "quizas"}),
                               ("Nuevo · puntuación + juez con ejemplos (solo sí)", {"si"})):
                vol = sum(1 for i, x in v.items() if x in ok and i not in pos)
                rec = sum(1 for i, x in v.items() if x in ok and i in pos)
                apunta(nombre, 1000 * vol / nu, rec / npos)

    # Curvas de las puntuaciones
    curvas = {}
    for nombre in RASGOS + ["combinada"]:
        if nombre == "sin_cpv":
            continue
        curvas[nombre] = {}
        for vol in VOLUMENES:
            recs = []
            for et, filas in puntos.items():
                y = np.array([f["y"] for f in filas])
                s = comb[et] if nombre == "combinada" else np.array([f[nombre] for f in filas])
                # desempate estable con la combinada
                if nombre != "combinada":
                    s = s + 1e-6 * (comb[et] - comb[et].min()) / (np.ptp(comb[et]) + 1e-9)
                recs.append(recall_a_volumen(s, y, vol))
            curvas[nombre][vol] = resumen(recs)

    # ---- Markdown
    L = ["# Banco de pruebas · resultados", "",
         f"Corte T = 2026-01-01 · {len(muestra['empresas'])} empresas · universo común "
         f"de {len(muestra['universo'])} licitaciones (de {muestra['n_candidatas']} con "
         f"fecha_actualizacion ≥ T, sin menores ni homologaciones) + los positivos de cada una.",
         "", "Recall = parte de lo que la empresa ganó desde T que el sistema le enseña. "
         "Volumen = licitaciones del universo que le enseña por cada 1.000 (sin contar sus positivos). "
         "Media y percentil 10 sobre las empresas.", "",
         "## Sistemas con decisión", "",
         "| Sistema | Volumen/1.000 (media · mediana) | Recall (media · p10) |",
         "|---|---|---|"]
    for sis, xs in filas_sis.items():
        vols = [x[0] for x in xs]
        recs = [x[1] for x in xs]
        rv, rr = resumen(vols), resumen(recs)
        L.append(f"| {sis} | {rv['media']:.1f} · {rv['mediana']:.1f} | "
                 f"{100 * rr['media']:.1f} % · {100 * rr['p10']:.1f} % |")
    L += ["", "## Curvas recall/volumen de las puntuaciones (sin modelo de lenguaje)", "",
          "Recall medio (p10) enseñando N por cada 1.000:", "",
          "| Puntuación | " + " | ".join(str(v) for v in VOLUMENES) + " |",
          "|---|" + "---|" * len(VOLUMENES)]
    for nombre, c in curvas.items():
        L.append(f"| {nombre} | " + " | ".join(
            f"{100 * c[v]['media']:.0f} % ({100 * c[v]['p10']:.0f})" for v in VOLUMENES) + " |")
    L += ["", "Pesos de la combinación (ajustada con todas las empresas; en la evaluación "
          "cada empresa se puntúa con los pesos aprendidos de las demás):", "",
          "```", json.dumps(pesos_globales(puntos), ensure_ascii=False), "```", "",
          "## Por estrato de tamaño de historial", ""]
    L += ["| Estrato | Ganados antes de T | Sistema | Volumen/1.000 | Recall |", "|---|---|---|---|---|"]
    for est in range(4):
        emps = [e for e in muestra["empresas"] if e["estrato"] == est]
        rango = f"{min(e['n_antes'] for e in emps)}-{max(e['n_antes'] for e in emps)}"
        idx = [k for k, e in enumerate(muestra["empresas"]) if e["estrato"] == est]
        for sis, xs in filas_sis.items():
            sub = [xs[k] for k in idx if k < len(xs)]
            L.append(f"| {est} | {rango} | {sis} | {np.mean([x[0] for x in sub]):.1f} | "
                     f"{100 * np.mean([x[1] for x in sub]):.1f} % |")
    g = _leer_gasto()
    L += ["", "## Gasto de OpenAI", "",
          f"Total: {g['total']:.3f} $ en {g['llamadas']} llamadas.", ""]
    L += [f"- {k}: {v:.3f} $" for k, v in g["por_paso"].items()]
    (AQUI.parent / "RESULTADOS.md").write_text("\n".join(L) + "\n")
    json.dump({"sistemas": filas_sis, "curvas": curvas},
              open(DATOS / "informe.json", "w"), indent=1)
    print("\n".join(L))


if __name__ == "__main__":
    main()
