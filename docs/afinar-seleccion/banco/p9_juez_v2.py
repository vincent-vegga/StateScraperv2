"""
Paso 9 · Juez v2 (destinatario y reglas del cliente) en el banco.

Las instrucciones son las de producción (`puntuador.INSTRUCCIONES_JUEZ`,
`puntuador.mensajes_juez`), con los ejemplos como los ve producción
(título solo). Se rejuzga solo lo que el juez v1 aceptó (sí o quizás) en
el grupo de 100/1.000 del paso 6: v2 es más estricto, así que lo que v1
rechazó se da por rechazado.

Uso: python3 p9_juez_v2.py estimar | hacer
"""
from __future__ import annotations

import json
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from comun import (CORTE, DATOS, RAIZ, Cache, ParadaPresupuesto, chat, coste,
                   gasto_total, log, tokens_aprox)
from p3_actual import cribador, preparar
from p4_embeddings import normal, titulos

sys.path.insert(0, str(RAIZ))
import puntuador  # noqa: E402

EJEMPLOS = 8


def main(modo: str) -> None:
    base, muestra = preparar()
    lic = base["lic"]
    ts = titulos()
    fila = {t: i for i, t in enumerate(ts)}
    emb = np.load(DATOS / "emb.npy", mmap_mode="r")
    v1 = json.load(open(DATOS / "veredictos_ejemplos.json"))["veredictos"]
    cache = Cache("juez_v2")  # la clave incluye las instrucciones: v3 no reutiliza v2

    tareas = []
    for emp in muestra["empresas"]:
        et = emp["etiqueta"]
        propias = sorted({a[0] for a in base["por_cif"][emp["cif"]] if a[2] and a[2] < CORTE})
        por_titulo = {}
        for i in propias:
            por_titulo.setdefault(normal(lic[i]["titulo"]), i)
        ids_e = [i for t, i in por_titulo.items() if t in fila]
        E = np.asarray(emb[[fila[normal(lic[i]["titulo"])] for i in ids_e]], np.float32)
        for idl, ver in v1[et].items():
            if ver not in ("si", "quizas"):
                continue
            r = fila.get(normal(lic[idl]["titulo"]))
            v = np.asarray(emb[r], np.float32) if r is not None else np.zeros(E.shape[1], np.float32)
            ejemplos = [f"- {normal(lic[ids_e[j]]['titulo'])}" for j in np.argsort(-(E @ v))[:EJEMPLOS]]
            f = {k: lic[idl][k] for k in ("titulo", "organo", "presupuesto", "cpvs")}
            tareas.append((et, idl, puntuador.mensajes_juez(f, ejemplos, [], [])))

    if modo == "estimar":
        tok = sum(sum(tokens_aprox(m["content"]) for m in t[2]) for t in tareas)
        log(f"juez v2: {len(tareas)} llamadas, ~{tok} tokens → "
            f"{coste('gpt-4o-mini', tok, len(tareas) * 60):.3f} $ (estimación por lo alto)")
        return

    def juzgar(t):
        et, idl, msgs = t
        try:
            contenido, _ = chat("juez_v2", cache, msgs, "gpt-4o-mini", 150)
            v = cribador.sin_tildes(str(json.loads(contenido).get("veredicto", ""))).strip().lower()
        except ParadaPresupuesto:
            raise
        except Exception:
            v = "error"
        return et, idl, v

    v2 = defaultdict(dict)
    with ThreadPoolExecutor(16) as ex:
        for n, (et, idl, v) in enumerate(ex.map(juzgar, tareas), 1):
            v2[et][idl] = v
            if n % 1000 == 0:
                log(f"{n}/{len(tareas)} · gasto {gasto_total():.3f} $")
    # Lo que v1 rechazó, rechazado.
    for et, d in v1.items():
        for idl, ver in d.items():
            if ver not in ("si", "quizas"):
                v2[et][idl] = ver
    json.dump({"volumen": 100.0, "veredictos": v2}, open(DATOS / f"veredictos_{puntuador.VERSION.split('-')[-1]}.json", "w"))
    log(f"hecho: {Counter(x for d in v2.values() for x in d.values())} · gasto {gasto_total():.3f} $")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "estimar")
