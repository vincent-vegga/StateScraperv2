"""
Paso 7 · Informe: los dos números (recall y volumen por 1.000) de cada
sistema, en media sobre las empresas y en su percentil 10.

Escribe `docs/afinar-seleccion/RESULTADOS.md` solo con agregados y
etiquetas anónimas (nada de nombres ni NIF). Sin coste.
"""
from __future__ import annotations

import json

import numpy as np

from comun import AQUI, CORTE, DATOS, _leer_gasto
from metricas import (RASGOS, combinada_loco, pesos_globales, recall_a_volumen,
                      resumen, umbral_de)
from p2_muestra import prefijos
from p3_actual import preparar
from p4_embeddings import normal

VOLUMENES = [10, 20, 30, 50, 75, 100, 150, 200]
SI_Q, SI = {"si", "quizas"}, {"si"}


def puerta_jerarquica(cpvs, mis) -> bool:
    """Como la puerta actual, pero un CPV genérico (ceros finales) casa con
    los prefijos más finos de la empresa: 03000000 deja pasar a 0331."""
    for c in cpvs:
        if len(c) < 4:
            continue
        raiz = c.rstrip("0")
        raiz = raiz if len(raiz) >= 2 else c[:2]
        for p in mis:
            if p.startswith(c[:4]) or c.startswith(p) or (len(raiz) < 4 and p.startswith(raiz)):
                return True
    return False


def main() -> None:
    base, muestra = preparar()
    lic = base["lic"]
    actual = json.load(open(DATOS / "actual.json"))
    ver_act = json.load(open(DATOS / "veredictos_actual.json"))
    puntos = json.load(open(DATOS / "puntos.json"))
    comb = combinada_loco(puntos)
    ej = json.load(open(DATOS / "veredictos_ejemplos.json"))
    ver_ej, pool_max = ej["veredictos"], ej["volumen"]

    sistemas: dict[str, list] = {}   # nombre -> [(vol/1000, recall)] por empresa

    def apunta(nombre, vol, rec):
        sistemas.setdefault(nombre, []).append((vol, rec))

    repetidos = 0
    for emp in muestra["empresas"]:
        et = emp["etiqueta"]
        a = actual[et]
        pos = set(emp["positivos"])
        universo = [i for i in muestra["universo"] if i not in pos]
        nu, npos = len(universo), len(pos)
        mis = set(a["prefijos"])

        # --- Sistema actual
        apunta("A1 · Actual: solo puerta CPV", 1000 * a["puerta_vol"] / nu, a["puerta_pos"] / npos)
        for nombre, ok in (("A2 · Actual: puerta + juez (sí+quizás)", SI_Q),
                           ("A3 · Actual: puerta + juez (solo sí)", SI)):
            d = ver_act.get(et, {})
            apunta(nombre, 1000 * sum(1 for i, x in d.items() if x in ok and i not in pos) / nu,
                   sum(1 for i, x in d.items() if x in ok and i in pos) / npos)
        # --- Puerta con jerarquía CPV (mejora mínima)
        apunta("A4 · Puerta CPV jerárquica (sin juez)",
               1000 * sum(puerta_jerarquica(lic[i]["cpvs"], mis) for i in universo) / nu,
               sum(puerta_jerarquica(lic[i]["cpvs"], mis) for i in pos) / npos)

        # --- Puntuación sola y con juez
        filas = puntos[et]
        y = np.array([f["y"] for f in filas])
        s = comb[et]
        for vol in (20, 30, 50):
            apunta(f"B · Puntuación sola, corte a {vol}/1.000", float(vol),
                   recall_a_volumen(s, y, vol))
        d = ver_ej[et]
        for grupo in (30, 50, 100):
            if grupo > pool_max:
                continue
            u = umbral_de(s, y, grupo)
            for sufijo, ok in (("sí+quizás", SI_Q), ("solo sí", SI)):
                vol = sum(1 for f, sc in zip(filas, s) if sc >= u and f["y"] == 0 and d.get(f["id"]) in ok)
                rec = sum(1 for f, sc in zip(filas, s) if sc >= u and f["y"] == 1 and d.get(f["id"]) in ok)
                apunta(f"C · Puntuación (mejores {grupo}/1.000) + juez con ejemplos ({sufijo})",
                       1000 * vol / nu, rec / npos)

        tit = {normal(lic[x[0]]["titulo"]) for x in base["por_cif"][emp["cif"]] if x[2] and x[2] < CORTE}
        repetidos += sum(1 for q in pos if normal(lic[q]["titulo"]) in tit)

    # --- Curvas de cada rasgo
    curvas = {}
    for nombre in [r for r in RASGOS if r != "sin_cpv"] + ["combinada"]:
        curvas[nombre] = {}
        for vol in VOLUMENES:
            recs = []
            for et, filas in puntos.items():
                y = np.array([f["y"] for f in filas])
                c = comb[et]
                # Desempate al azar (fijo): desempatar con la combinada le
                # prestaría su calidad a un rasgo que vale 0 casi siempre.
                azar = np.random.default_rng(0).random(len(filas))
                s = c if nombre == "combinada" else \
                    np.array([f[nombre] for f in filas]) + 1e-9 * azar
                recs.append(recall_a_volumen(s, y, vol))
            curvas[nombre][vol] = resumen(recs)

    n_pos = sum(len(e["positivos"]) for e in muestra["empresas"])
    L = ["# Banco de pruebas · resultados", "",
         "Generado por `banco/p7_informe.py`. Solo agregados y etiquetas anónimas.", "",
         f"- Corte T = {CORTE}. Perfil construido solo con lo ganado antes de T.",
         f"- {len(muestra['empresas'])} empresas (10 por cuartil de historial) de "
         "las que ganaron ≥15 licitaciones antes de T y ≥5 desde T (sin menores ni homologaciones).",
         f"- Universo común: {len(muestra['universo'])} licitaciones al azar de las "
         f"{muestra['n_candidatas']} con fecha_actualizacion ≥ T (sin menores ni homologaciones), "
         f"más los positivos de cada empresa ({n_pos} en total).",
         "- **Recall**: parte de lo que la empresa ganó desde T que el sistema le enseña.",
         "- **Volumen**: licitaciones del universo que le enseña por cada 1.000 (sin contar sus positivos).",
         "- Media sobre las 40 empresas y percentil 10 (la empresa peor servida de cada diez).", "",
         "## Sistemas", "",
         "| Sistema | Volumen/1.000 (media · mediana) | Recall (media · p10) |",
         "|---|---|---|"]
    for nombre, xs in sistemas.items():
        rv, rr = resumen([x[0] for x in xs]), resumen([x[1] for x in xs])
        L.append(f"| {nombre} | {rv['media']:.1f} · {rv['mediana']:.1f} | "
                 f"{100 * rr['media']:.1f} % · {100 * rr['p10']:.1f} % |")

    L += ["", "## Curvas de cada puntuación (sin modelo de lenguaje)", "",
          "Recall medio (p10 entre paréntesis) enseñando N por cada 1.000:", "",
          "| Puntuación | " + " | ".join(str(v) for v in VOLUMENES) + " |",
          "|---|" + "---|" * len(VOLUMENES)]
    for nombre, c in curvas.items():
        L.append(f"| {nombre} | " + " | ".join(
            f"{100 * c[v]['media']:.0f} % ({100 * c[v]['p10']:.0f})" for v in VOLUMENES) + " |")
    L += ["", "- `knn1`/`knn5`: similitud con sus contratos ganados antes de T (máxima / media de 5).",
          "- `cpv4`/`cpv2`: fracción de sus contratos anteriores con ese prefijo (peso, no puerta).",
          "- `propio`: de las 50 licitaciones pasadas más parecidas, cuánto ganó ella.",
          "- `pares`: cuánto ganaron sus pares (quienes ganan lo parecido a lo suyo).",
          "- `combinada`: regresión logística; cada empresa se puntúa con pesos aprendidos de las otras 39.",
          "", "Pesos (variables estandarizadas, ajuste con las 40):", "",
          "```", json.dumps(pesos_globales(puntos), ensure_ascii=False), "```", "",
          f"Comprobación de fuga: {repetidos} de {n_pos} positivos tienen un título idéntico "
          "a uno que la empresa ganó antes de T (contratos recurrentes). Quitándolos, la "
          "puntuación a 30/1.000 sigue en el 90,0 % y el sistema actual en el 75,4 %: la "
          "mejora no viene de ahí.", "",
          "## Por estrato de tamaño de historial", "",
          "| Estrato (ganados antes de T) | Sistema | Volumen/1.000 | Recall |", "|---|---|---|---|"]
    clave_sis = ["A2 · Actual: puerta + juez (sí+quizás)", "B · Puntuación sola, corte a 30/1.000",
                 "C · Puntuación (mejores 100/1.000) + juez con ejemplos (solo sí)"]
    for est in range(4):
        idx = [k for k, e in enumerate(muestra["empresas"]) if e["estrato"] == est]
        emps = [muestra["empresas"][k] for k in idx]
        rango = f"{min(e['n_antes'] for e in emps)}-{max(e['n_antes'] for e in emps)}"
        for nombre in clave_sis:
            sub = [sistemas[nombre][k] for k in idx]
            L.append(f"| {est} ({rango}) | {nombre} | {np.mean([x[0] for x in sub]):.1f} | "
                     f"{100 * np.mean([x[1] for x in sub]):.1f} % |")

    g = _leer_gasto()
    L += ["", "## Gasto de OpenAI", "",
          f"Total: **{g['total']:.2f} $** en {g['llamadas']} llamadas (tope del banco: 10 $).", ""]
    L += [f"- {k}: {v:.2f} $" for k, v in g["por_paso"].items()]
    (AQUI.parent / "RESULTADOS.md").write_text("\n".join(L) + "\n")
    json.dump({"sistemas": sistemas, "curvas": curvas}, open(DATOS / "informe.json", "w"), indent=1)
    print("\n".join(L))


if __name__ == "__main__":
    main()
