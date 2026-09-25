"""
Paso 6 · Juez con ejemplos (gpt-4o-mini), sin criterio en prosa.

Para cada empresa, las licitaciones mejor puntuadas por la combinación
(hasta VOLUMEN por cada 1.000 del universo, y sus positivos que queden
por encima de ese corte) se enseñan al modelo junto a los 8 contratos que
ella ganó ANTES de T más parecidos. El modelo decide si/quizas/no.

Uso: python3 p6_juez_ejemplos.py estimar | hacer  [VOLUMEN, por defecto 100]
"""
from __future__ import annotations

import json
import sys
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from comun import (CORTE, DATOS, Cache, ParadaPresupuesto, chat, coste, gasto_total,
                   log, tokens_aprox)
from metricas import combinada_loco, umbral_de
from p3_actual import cribador, preparar
from p4_embeddings import normal, titulos

EJEMPLOS = 8

INSTRUCCIONES = """\
Eres un analista de contratación pública española. Te damos los contratos \
públicos que una empresa ha GANADO que más se parecen a un contrato nuevo. \
Son hechos: describen a qué se dedica. Decide si el contrato nuevo encaja \
con lo que hace, con esta prueba: ¿podría esta empresa ser el proveedor \
principal del contrato nuevo?

- "si": el objeto principal es el mismo tipo de producto o servicio que \
alguno de sus contratos ganados, aunque cambien el organismo, el \
territorio, el tamaño o el colectivo destinatario.
- "quizas": es un producto o servicio vecino que plausiblemente podría \
prestar, o el título es demasiado genérico para saberlo (por ejemplo, un \
sistema dinámico de adquisición o un acuerdo marco amplio).
- "no": el objeto principal es otro producto o servicio, aunque comparta \
palabras, destinatario u organismo con sus contratos.

No decidas por el territorio ni por el organismo: solo por lo que se \
contrata. Ante duda razonable entre "quizas" y "no", elige "quizas".

Devuelve EXCLUSIVAMENTE JSON:
{"veredicto": "si|quizas|no", "motivo": "una frase breve que cite el \
contrato ganado que más se parece, o por qué ninguno encaja"}"""


def ficha(l: dict) -> str:
    partes = [f"Título: {l['titulo']}"]
    if l["organo"]:
        partes.append(f"Órgano: {l['organo']}")
    if l["presupuesto"] is not None:
        partes.append(f"Presupuesto: {float(l['presupuesto']):,.0f} EUR".replace(",", "."))
    if l["cpvs"]:
        partes.append(f"CPV: {', '.join(l['cpvs'][:8])}")
    return "\n".join(partes)


def main(modo: str, volumen: float) -> None:
    base, muestra = preparar()
    lic = base["lic"]
    ts = titulos()
    fila = {t: i for i, t in enumerate(ts)}
    emb = np.load(DATOS / "emb.npy", mmap_mode="r")
    puntos = json.load(open(DATOS / "puntos.json"))
    comb = combinada_loco(puntos)
    cache = Cache("juez_ejemplos")

    tareas = []
    for emp in muestra["empresas"]:
        et = emp["etiqueta"]
        filas = puntos[et]
        y = np.array([f["y"] for f in filas])
        s = comb[et]
        u = umbral_de(s, y, volumen)
        elegidas = [f["id"] for f, sc in zip(filas, s) if sc >= u]

        propias = sorted({a[0] for a in base["por_cif"][emp["cif"]] if a[2] and a[2] < CORTE})
        # Un ejemplo por título: los repetidos no enseñan nada nuevo.
        por_titulo = {}
        for i in propias:
            por_titulo.setdefault(normal(lic[i]["titulo"]), i)
        ids_e = [i for t, i in por_titulo.items() if t in fila]
        E = np.asarray(emb[[fila[normal(lic[i]["titulo"])] for i in ids_e]], np.float32)
        for idl in elegidas:
            r = fila.get(normal(lic[idl]["titulo"]))
            v = np.asarray(emb[r], np.float32) if r is not None else np.zeros(E.shape[1], np.float32)
            top = np.argsort(-(E @ v))[:EJEMPLOS]
            ejemplos = "\n".join(
                f"- {lic[ids_e[j]]['titulo']}" +
                (f" (CPV {', '.join(lic[ids_e[j]]['cpvs'][:3])})" if lic[ids_e[j]]["cpvs"] else "")
                for j in top)
            msgs = [{"role": "system", "content": INSTRUCCIONES},
                    {"role": "user", "content":
                     f"CONTRATOS GANADOS MÁS PARECIDOS:\n{ejemplos}\n\n"
                     f"CONTRATO NUEVO:\n{ficha(lic[idl])}"}]
            tareas.append((et, idl, msgs))

    if modo == "estimar":
        tok = sum(sum(tokens_aprox((m["content"])) for m in t[2]) + 10 for t in tareas)
        log(f"juez con ejemplos a {volumen}/1000: {len(tareas)} llamadas, {tok} tokens → "
            f"{coste('gpt-4o-mini', tok, len(tareas) * 60):.3f} $")
        return

    veredictos = defaultdict(dict)

    def juzgar(t):
        et, idl, msgs = t
        try:
            contenido, _ = chat("juez_ejemplos", cache, msgs, "gpt-4o-mini", 150)
            v = cribador.sin_tildes(str(json.loads(contenido).get("veredicto", ""))).strip().lower()
        except ParadaPresupuesto:
            raise
        except Exception:
            v = "error"
        return et, idl, v

    log(f"juez con ejemplos: {len(tareas)} llamadas")
    with ThreadPoolExecutor(16) as ex:
        for n, (et, idl, v) in enumerate(ex.map(juzgar, tareas), 1):
            veredictos[et][idl] = v
            if n % 1000 == 0:
                log(f"{n}/{len(tareas)} · gasto {gasto_total():.3f} $")
    json.dump({"volumen": volumen, "veredictos": veredictos},
              open(DATOS / "veredictos_ejemplos.json", "w"))
    log(f"hecho. Gasto acumulado: {gasto_total():.4f} $")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "estimar",
         float(sys.argv[2]) if len(sys.argv) > 2 else 100.0)
