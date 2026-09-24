"""
Paso 4 · Embeddings de todos los títulos (text-embedding-3-small, 512
dimensiones). Títulos idénticos se piden una sola vez.

Uso: python3 p4_embeddings.py estimar | hacer
Salida: datos/titulos.json (lista de títulos distintos), datos/emb.f16
(memmap float16 [n, 512], normalizados) y datos/emb_hecho.npy (máscara).
"""
from __future__ import annotations

import json
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from comun import DATOS, ParadaPresupuesto, coste, embeddings, gasto_total, log, tokens_aprox
from p2_muestra import cargar_base

DIM = 512
LOTE = 1000
MAX_CAR = 800        # ~200 tokens: los títulos más largos se recortan


class Ritmo:
    """Cubo de tokens: el límite de la cuenta es 1 M tokens/min."""
    def __init__(self, por_minuto: int):
        self.cap, self.hay, self.t = por_minuto, por_minuto, time.monotonic()
        self.c = threading.Lock()

    def pedir(self, n: int) -> None:
        while True:
            with self.c:
                ahora = time.monotonic()
                self.hay = min(self.cap, self.hay + (ahora - self.t) * self.cap / 60)
                self.t = ahora
                if self.hay >= n:
                    self.hay -= n
                    return
                falta = (n - self.hay) * 60 / self.cap
            time.sleep(falta)


RITMO = Ritmo(850_000)


def normal(t: str) -> str:
    return " ".join((t or "").split())


def titulos() -> list[str]:
    ruta = DATOS / "titulos.json"
    if ruta.exists():
        return json.load(open(ruta))
    base = cargar_base()
    ts = sorted({normal(l["titulo"]) for l in base["lic"].values()} - {""})
    json.dump(ts, open(ruta, "w"), ensure_ascii=False)
    return ts


def recortar(t: str) -> tuple[str, int]:
    t = t[:MAX_CAR]
    return t, tokens_aprox(t)


def main(modo: str) -> None:
    ts = titulos()
    log(f"{len(ts)} títulos distintos")
    if modo == "estimar":
        n = sum(recortar(t)[1] for t in ts)
        log(f"{n} tokens → {coste('text-embedding-3-small', n, 0):.3f} $")
        return

    emb = np.lib.format.open_memmap(DATOS / "emb.npy", mode="r+" if (DATOS / "emb.npy").exists() else "w+",
                                    dtype=np.float16, shape=(len(ts), DIM))
    ruta_hecho = DATOS / "emb_hecho.npy"
    hecho = np.load(ruta_hecho) if ruta_hecho.exists() else np.zeros(len(ts), bool)
    lotes = [(a, min(a + LOTE, len(ts))) for a in range(0, len(ts), LOTE)
             if not hecho[a:min(a + LOTE, len(ts))].all()]
    log(f"{len(lotes)} lotes pendientes")

    def uno(lote):
        a, b = lote
        textos, toks = zip(*(recortar(t) for t in ts[a:b]))
        RITMO.pedir(sum(toks) * 3 // 4)   # tokens_aprox cuenta ~33 % de más
        v = np.asarray(embeddings("embeddings", list(textos), DIM, tokens_est=sum(toks)),
                       dtype=np.float32)
        v /= np.linalg.norm(v, axis=1, keepdims=True)
        return a, b, v.astype(np.float16)

    try:
        with ThreadPoolExecutor(6) as ex:
            for n, (a, b, v) in enumerate(ex.map(uno, lotes), 1):
                emb[a:b] = v
                hecho[a:b] = True
                if n % 50 == 0:
                    emb.flush()
                    np.save(ruta_hecho, hecho)
                    log(f"{n}/{len(lotes)} lotes · gasto {gasto_total():.3f} $")
    except ParadaPresupuesto as e:
        log("PARADA POR PRESUPUESTO:", e)
    finally:
        emb.flush()
        np.save(ruta_hecho, hecho)
    log(f"hechos {hecho.sum()}/{len(ts)} · gasto {gasto_total():.4f} $")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "estimar")
