"""
Métricas comunes: recall de los contratos futuros frente a volumen
enseñado por cada 1.000 licitaciones del universo, y la combinación de
puntuaciones (regresión logística ajustada dejando fuera a la empresa
que se evalúa: nunca se puntúa con pesos aprendidos de sus propios
positivos).
"""
from __future__ import annotations

import math

import numpy as np

RASGOS = ["knn1", "knn5", "cpv4", "cpv2", "sin_cpv", "propio", "pares"]


def matriz(filas: list[dict]) -> np.ndarray:
    X = np.array([[f[r] for r in RASGOS] for f in filas], np.float64)
    X[:, RASGOS.index("propio")] = np.log1p(50 * X[:, RASGOS.index("propio")])
    X[:, RASGOS.index("pares")] = np.log1p(50 * X[:, RASGOS.index("pares")])
    return X


def logistica(X, y, l2=1e-2, pasos=3000, ritmo=0.2):
    mu, sd = X.mean(0), X.std(0) + 1e-9
    Z = np.c_[(X - mu) / sd, np.ones(len(X))]
    # Cada clase pesa lo mismo: hay ~100 veces más negativos.
    w_cls = np.where(y == 1, 0.5 / max(y.sum(), 1), 0.5 / max((1 - y).sum(), 1))
    b = np.zeros(Z.shape[1])
    for _ in range(pasos):
        p = 1 / (1 + np.exp(-Z @ b))
        g = Z.T @ (w_cls * (p - y)) + l2 * np.r_[b[:-1], 0]
        b -= ritmo * g
    return mu, sd, b


def aplicar(modelo, X):
    mu, sd, b = modelo
    return np.c_[(X - mu) / sd, np.ones(len(X))] @ b


def combinada_loco(puntos: dict) -> dict[str, np.ndarray]:
    """Puntuación combinada de cada empresa con pesos aprendidos del resto."""
    Xs = {e: matriz(f) for e, f in puntos.items()}
    ys = {e: np.array([x["y"] for x in f], float) for e, f in puntos.items()}
    out = {}
    for e in puntos:
        otros = [o for o in puntos if o != e]
        X = np.vstack([Xs[o] for o in otros])
        y = np.concatenate([ys[o] for o in otros])
        out[e] = aplicar(logistica(X, y), Xs[e])
    return out


def pesos_globales(puntos: dict):
    X = np.vstack([matriz(f) for f in puntos.values()])
    y = np.concatenate([[x["y"] for x in f] for f in puntos.values()]).astype(float)
    mu, sd, b = logistica(X, y)
    return dict(zip(RASGOS + ["constante"], b.round(3).tolist()))


def recall_a_volumen(score: np.ndarray, y: np.ndarray, por_mil: float) -> float:
    neg = np.sort(score[y == 0])[::-1]
    k = max(1, math.ceil(por_mil / 1000 * len(neg)))
    umbral = neg[min(k, len(neg)) - 1]
    pos = score[y == 1]
    return float((pos >= umbral).mean()) if len(pos) else float("nan")


def umbral_de(score: np.ndarray, y: np.ndarray, por_mil: float) -> float:
    neg = np.sort(score[y == 0])[::-1]
    k = max(1, math.ceil(por_mil / 1000 * len(neg)))
    return float(neg[min(k, len(neg)) - 1])


def resumen(valores: list[float]) -> dict:
    v = np.array([x for x in valores if not math.isnan(x)])
    return {"media": round(float(v.mean()), 4), "p10": round(float(np.percentile(v, 10)), 4),
            "mediana": round(float(np.median(v)), 4), "n": int(len(v))}
