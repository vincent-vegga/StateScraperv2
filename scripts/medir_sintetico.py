#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Medir el alta sin NIF contra el motor de huellas
=================================================

Para cada empresa que ya va por huellas (perfiles.sistema = 'huellas'), su
lista real (lo que el motor le enseña hoy: veredictos si/quizas de lo vivo)
es la referencia. Se compara con lo que vería si hubiera entrado SIN NIF,
con la descripción que escribiría (simulacion/sinteticos.json, lo exporta
simular_sin_nif.ts con MODO=exportar):

  actual      lo que hay hoy para el alta sin NIF: puerta por los códigos
              del vecindario y criterio en prosa (con los vecinos como
              ejemplos), clasificado con cribador.clasificar.
  sintetico   los 40 vecinos como «ganados» en el motor de huellas:
              rasgos_perfil + combinar + grupo + juez con ejemplos, las
              mismas funciones de puntuador.py, sin tocarlas.

Sin trampas: los vecinos ya salen sin los contratos de la propia empresa,
y en «sintetico» el rasgo `propio` (cuánto de lo parecido ganó ella) se
pone a cero: sin NIF no se sabe quién es.

Solo lee. Lo que sale:
  - consola y resumen de la ejecución: cifras y perfiles anónimos;
  - simulacion/sintetico.json (con ids), que el workflow cifra.

Variables: SUPABASE_URL, SUPABASE_KEY, OPENAI_API_KEY, CACHE_HUELLAS,
    MAX_GASTO (dólares; por defecto 3).
"""
from __future__ import annotations

import json
import logging
import math
import os
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cribador        # noqa: E402  (solo se usa clasificar, como hace el cribado)
import puntuador as P  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(message)s")
SALIDA = Path("simulacion")
MAX_GASTO = float(os.environ.get("MAX_GASTO", "3"))


def prefijos_de(cpvs) -> set[str]:
    """Como calcular_prefijos en la base: 2 y 4 cifras de todos sus CPV."""
    out = set()
    for c in P._cpvs(cpvs):
        c = "".join(ch for ch in c if ch.isdigit())
        if len(c) >= 2:
            out.add(c[:2])
        if len(c) >= 4:
            out.add(c[:4])
    return out


def mostrados_reales(perfil_id: str, vivas: set[str]) -> set[str]:
    filas, desde = [], 0
    while True:
        lote = P.leer("veredictos", {"select": "id_licitacion,veredicto",
                                     "perfil_id": f"eq.{perfil_id}",
                                     "veredicto": "in.(si,quizas)",
                                     "order": "id_licitacion", "limit": "1000",
                                     "offset": str(desde)})
        filas += lote
        if len(lote) < 1000:
            break
        desde += 1000
    return {f["id_licitacion"] for f in filas if f["id_licitacion"] in vivas}


def main() -> int:
    casos = json.loads((SALIDA / "sinteticos.json").read_text())
    c = P.Contexto.desde_instantanea(Path(os.environ.get("CACHE_HUELLAS",
                                                         "~/.cache/huellas")).expanduser())
    vivas = set(c.vivas)
    k = math.ceil(P.PESOS["grupo_por_mil"] / 1000 * len(c.vivas))
    gasto = P.Gasto(MAX_GASTO)
    ia = cribador.obtener_cliente_openai()
    resultados, resumen = [], []

    for caso in casos:
        cod, cif = caso["codigo"], caso["cif"]
        R = mostrados_reales(caso["perfil_id"], vivas)

        # ---- Real (con NIF), para situar: su grupo con lo que ha ganado
        ganados = P.ganados_de(cif)
        Xr, _ = P.rasgos_perfil(c, cif, ganados)
        grupo_r = [c.vivas[j] for j in np.argsort(-P.combinar(Xr))[:k]]

        # ---- Sintético: los vecinos como ganados, sin `propio`
        gan_s = [{"id_licitacion": v["id_licitacion"], "titulo": v["titulo"],
                  "cpvs": v["cpvs"]} for v in caso["vecinos"]]
        c.completar_huellas({v["titulo"] for v in gan_s}, guardar=False)
        Xs, filas_s = P.rasgos_perfil(c, cif, gan_s)
        Xs[:, 5] = 0.0
        orden_s = np.argsort(-P.combinar(Xs))
        grupo_s = [c.vivas[j] for j in orden_s[:k]]

        E = np.asarray(c.emb[filas_s], np.float32)
        tareas = []
        for idl in grupo_s:
            f = c.ficha_viva[idl]
            r = c.fila_de_titulo(f["titulo"])
            v = np.asarray(c.emb[r], np.float32) if r is not None else np.zeros(E.shape[1], np.float32)
            ejemplos = [f"- {c.titulos[filas_s[j]]}" for j in np.argsort(-(E @ v))[:P.EJEMPLOS]]
            tareas.append((idl, P.mensajes_juez(f, ejemplos, [], [])))
        with ThreadPoolExecutor(8) as ex:
            juicios = list(ex.map(lambda t: P.juzgar(t[1], gasto), tareas))
        mostrados_s = {idl for (idl, _), j in zip(tareas, juicios)
                       if j and j["veredicto"] in ("si", "quizas")}

        # ---- Actual (alta sin NIF de hoy): puerta por códigos + criterio
        puerta = set(caso["prefijos"])
        candidatas = [i for i in c.vivas if prefijos_de(c.ficha_viva[i]["cpvs"]) & puerta]
        def clasificar(idl):
            f = c.ficha_viva[idl]
            return cribador.clasificar(ia, caso["criterio"],
                                       {"titulo": f["titulo"], "organo": f.get("organo"),
                                        "presupuesto": f.get("presupuesto"), "cpvs": f.get("cpvs")})
        if gasto.agotado():
            logging.info("%s: tope de gasto alcanzado, se para", cod)
            break
        with ThreadPoolExecutor(8) as ex:
            vs = list(ex.map(clasificar, candidatas))
        mostrados_a = {i for i, v in zip(candidatas, vs) if v and v["veredicto"] in ("si", "quizas")}
        # El cribador no lleva cuenta de gasto: se estima (unos 450 tokens).
        gasto.total += len(candidatas) * (450 * 0.15 + 60 * 0.60) / 1e6

        rec = lambda S: (len(S & R) / len(R)) if R else None
        fila = {
            "codigo": cod, "reales": len(R), "grupo": k,
            "grupo_real_cubre": rec(set(grupo_r)),
            "actual": {"mostrados": len(mostrados_a), "recupera": rec(mostrados_a),
                       "puerta": len(candidatas)},
            "sintetico": {"mostrados": len(mostrados_s), "recupera": rec(mostrados_s),
                          "grupo_recupera": rec(set(grupo_s)),
                          "grupo_comun": len(set(grupo_s) & set(grupo_r)) / k},
        }
        resumen.append(fila)
        resultados.append({**fila, "perfil_id": caso["perfil_id"],
                           "mostrados_sintetico": sorted(mostrados_s),
                           "mostrados_actual": sorted(mostrados_a), "reales_ids": sorted(R)})
        fmt = lambda x: "—" if x is None else f"{x:.2f}"
        logging.info("%s: reales %d · actual %d mostrados, recupera %s · sintético %d mostrados, "
                     "recupera %s (grupo %s) · gasto %.2f $", cod, len(R), len(mostrados_a),
                     fmt(fila["actual"]["recupera"]), len(mostrados_s),
                     fmt(fila["sintetico"]["recupera"]), fmt(fila["sintetico"]["grupo_recupera"]),
                     gasto.total)
        (SALIDA / "sintetico.json").write_text(json.dumps(resultados))

    # ---- Resumen público: solo cifras
    def media(xs):
        xs = [x for x in xs if x is not None]
        return f"{sum(xs) / len(xs):.2f}" if xs else "—"
    lineas = ["## Alta sin NIF frente al motor de huellas", "",
              "Referencia: lo que el motor enseña hoy a cada empresa con su NIF (sí + quizás, vivas).", "",
              "| Perfil | Reales | Actual: mostrados | Actual: recupera | Sintético: mostrados | Sintético: recupera |",
              "|---|---|---|---|---|---|"]
    for f in resumen:
        g = lambda x: "—" if x is None else f"{x:.2f}"
        lineas.append(f"| {f['codigo']} | {f['reales']} | {f['actual']['mostrados']} | "
                      f"{g(f['actual']['recupera'])} | {f['sintetico']['mostrados']} | "
                      f"{g(f['sintetico']['recupera'])} |")
    lineas += ["", f"Media recupera: actual {media([f['actual']['recupera'] for f in resumen])} · "
               f"sintético {media([f['sintetico']['recupera'] for f in resumen])}. "
               f"Mostrados medios: actual {media([f['actual']['mostrados'] for f in resumen])} · "
               f"sintético {media([f['sintetico']['mostrados'] for f in resumen])}. "
               f"Gasto estimado {gasto.total:.2f} $."]
    informe = "\n".join(lineas)
    print("\n" + informe)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write(informe + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
