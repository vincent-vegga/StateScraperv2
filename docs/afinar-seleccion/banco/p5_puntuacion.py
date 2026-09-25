"""
Paso 5 · Puntuación sin modelo de lenguaje (solo embeddings ya pagados).

Para cada empresa y cada licitación de su universo (muestra fija + sus
positivos) calcula:

  knn1, knn5   similitud con lo que ganó ANTES de T (máxima y media de 5)
  cpv4, cpv2   afinidad CPV ponderada: fracción de sus contratos
               anteriores con ese prefijo (peso, no puerta)
  propio       de las 50 licitaciones pasadas más parecidas, cuánto
               (ponderado por similitud) ganó ella
  pares        lo mismo, pero ganado por sus pares: empresas que ganan
               lo parecido a lo que ella ganó

"Pasado" = licitaciones adjudicadas antes de T, sin las del universo.
Sin coste de OpenAI.
"""
from __future__ import annotations

import json
import os
from collections import Counter, defaultdict

import numpy as np

from comun import CORTE, DATOS, SUFIJO, log
from p3_actual import preparar
from p4_embeddings import normal, titulos

# Variantes (docs/afinar-seleccion/RESULTADOS.md, «mejoras de la auditoría»):
# SIN_HOMOL=1 no cuenta como ganado estar admitido en un acuerdo marco o
# sistema dinámico sin importe; ANIOS=N usa solo lo ganado en los N años
# anteriores al corte (si quedan al menos 10 contratos).
SIN_HOMOL = os.environ.get("SIN_HOMOL") == "1"
ANIOS = int(os.environ.get("ANIOS", "0"))
M_VECINOS = 50       # vecinos pasados por licitación candidata
M_PARES = 20         # vecinos por contrato propio para hallar pares
MAX_PROPIOS = 400    # contratos propios usados para hallar pares
BLOQUE = 256


def top_m(q: np.ndarray, P: np.ndarray, m: int) -> tuple[np.ndarray, np.ndarray]:
    """Índices y similitudes de los m más parecidos de P para cada fila de q."""
    idx = np.empty((len(q), m), np.int64)
    sim = np.empty((len(q), m), np.float32)
    for a in range(0, len(q), BLOQUE):
        s = q[a:a + BLOQUE] @ P.T
        part = np.argpartition(-s, m, axis=1)[:, :m]
        ps = np.take_along_axis(s, part, 1)
        orden = np.argsort(-ps, axis=1)
        idx[a:a + BLOQUE] = np.take_along_axis(part, orden, 1)
        sim[a:a + BLOQUE] = np.take_along_axis(ps, orden, 1)
    return idx, sim


def main() -> None:
    base, muestra = preparar()
    lic = base["lic"]
    ts = titulos()
    fila = {t: i for i, t in enumerate(ts)}
    emb = np.load(DATOS / "emb.npy", mmap_mode="r")
    dim = int(os.environ.get("DIM", "512"))
    if dim < emb.shape[1]:
        # Los embeddings de OpenAI admiten recorte: primeras dimensiones y
        # renormalizar. Sirve para medir cuánto se pierde guardando menos.
        e = np.asarray(emb[:, :dim], np.float32)
        emb = (e / np.linalg.norm(e, axis=1, keepdims=True)).astype(np.float16)
    hecho = np.load(DATOS / "emb_hecho.npy")
    if not os.environ.get("PRUEBA"):
        assert hecho.all(), "faltan embeddings"
    else:
        muestra["empresas"] = muestra["empresas"][:2]

    def fila_de(idl):
        return fila.get(normal(lic[idl]["titulo"]))

    # ---- Candidatas: universo común + positivos de todas
    candidatas = set(muestra["universo"])
    for e in muestra["empresas"]:
        candidatas |= set(e["positivos"])

    # ---- Pasado: título -> ganadores antes de T (sin candidatas)
    ganadores = defaultdict(Counter)
    for idl, cif, fecha, _i, _m, _h in base["adj"]:
        if fecha and fecha < CORTE and idl not in candidatas:
            r = fila_de(idl)
            if r is not None:
                ganadores[r][cif] += 1
    filas_p = np.array(sorted(ganadores), np.int64)
    P = np.asarray(emb[filas_p], np.float32)
    log(f"pasado: {len(filas_p)} títulos adjudicados antes de T")

    # ---- Vecinos pasados de cada candidata
    cand = sorted(c for c in candidatas if fila_de(c) is not None)
    Q = np.asarray(emb[[fila_de(c) for c in cand]], np.float32)
    vi, vs = top_m(Q, P, M_VECINOS)
    pos_cand = {c: k for k, c in enumerate(cand)}
    log(f"vecinos de {len(cand)} candidatas hechos")

    puntos = {}
    for emp in muestra["empresas"]:
        cif = emp["cif"]
        propias = sorted({a[0] for a in base["por_cif"][cif] if a[2] and a[2] < CORTE
                          and not (SIN_HOMOL and a[5])})
        if ANIOS:
            desde = f"{int(CORTE[:4]) - ANIOS}{CORTE[4:]}"
            recientes = sorted({a[0] for a in base["por_cif"][cif]
                                if a[2] and desde <= a[2] < CORTE and not (SIN_HOMOL and a[5])})
            if len(recientes) >= 10:
                propias = recientes
        filas_propias = sorted({fila_de(i) for i in propias} - {None})
        E = np.asarray(emb[filas_propias], np.float32)

        # CPV ponderado
        c4, c2 = Counter(), Counter()
        for i in propias:
            cp = lic[i]["cpvs"]
            for p in {c[:4] for c in cp if len(c) >= 4}:
                c4[p] += 1
            for p in {c[:2] for c in cp if len(c) >= 2}:
                c2[p] += 1
        n = max(len(propias), 1)

        # Pares: quién gana lo parecido a lo que ella ganó
        recientes = filas_propias if len(filas_propias) <= MAX_PROPIOS else \
            list(np.random.default_rng(0).choice(filas_propias, MAX_PROPIOS, replace=False))
        pi, ps = top_m(np.asarray(emb[recientes], np.float32), P, M_PARES + 1)
        pares = Counter()
        for q_fila, fila_i, fila_s in zip(recientes, pi, ps):
            for j, s in zip(fila_i, fila_s):
                if filas_p[j] == q_fila:
                    continue           # su propio título
                for otro, k in ganadores[filas_p[j]].items():
                    if otro != cif:
                        pares[otro] += float(s)
        tot = sum(pares.values()) or 1.0
        peso_par = {o: v / tot for o, v in pares.most_common(200)}

        universo = [i for i in muestra["universo"] if i not in set(emp["positivos"])]
        filas_u = universo + emp["positivos"]
        etiquetas = [0] * len(universo) + [1] * len(emp["positivos"])
        res = []
        for idl, y in zip(filas_u, etiquetas):
            l = lic[idl]
            f = {"id": idl, "y": y}
            r = fila_de(idl)
            if r is None or not len(E):
                f.update(knn1=0.0, knn5=0.0)
            else:
                s = E @ np.asarray(emb[r], np.float32)
                s.sort()
                f.update(knn1=float(s[-1]), knn5=float(s[-5:].mean()))
            p4 = {c[:4] for c in l["cpvs"] if len(c) >= 4}
            p2 = {c[:2] for c in l["cpvs"] if len(c) >= 2}
            f["cpv4"] = max((c4[p] / n for p in p4), default=0.0)
            f["cpv2"] = max((c2[p] / n for p in p2), default=0.0)
            f["sin_cpv"] = int(not p4)
            k = pos_cand.get(idl)
            if k is None:
                f.update(propio=0.0, pares=0.0)
            else:
                w = np.maximum(vs[k], 0) ** 4
                ws = float(w.sum()) or 1.0
                propio = pares_s = 0.0
                for j, wj in zip(vi[k], w):
                    g = ganadores[filas_p[j]]
                    tg = sum(g.values())
                    if cif in g:
                        propio += wj * g[cif] / tg
                    pares_s += wj * sum(peso_par.get(o, 0.0) * v for o, v in g.items()) / tg
                f.update(propio=float(propio / ws), pares=float(pares_s / ws))
            res.append(f)
        puntos[emp["etiqueta"]] = res
        log(emp["etiqueta"], f"{len(propias)} propias, {len(peso_par)} pares")

    json.dump(puntos, open(DATOS / ("puntos_prueba.json" if os.environ.get("PRUEBA") else
                                 "puntos.json" if dim == 512 else
                                 f"puntos_{dim}{'_sinhomol' if SIN_HOMOL else ''}"
                                 f"{f'_{ANIOS}a' if ANIOS else ''}{SUFIJO}.json"), "w"))
    log("puntos guardados")


if __name__ == "__main__":
    main()
