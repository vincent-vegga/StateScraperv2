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
  limpio      contra el ruido: los más parecidos sin empujón a la variedad,
              y fuera los que el modelo dice que no encajan con la
              descripción (FILTRO).
  limpio_desc lo mismo, y el juez ve además la descripción (AVISO_SIN_NIF).

Con MEDIR_ACTUAL=1 se mide también lo de antes (criterio en prosa).

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


FILTRO = """\
Eres un analista de contratación pública española. Te damos lo que una \
empresa dice que hace y el título de un contrato público ya adjudicado. \
¿Podría esta empresa haber sido la adjudicataria, haciendo lo que dice \
que hace?

- "si": es su tipo de trabajo o de producto.
- "no": es otro oficio, aunque sea del mismo ámbito o para el mismo tipo \
de cliente (limpiar un parque no es gestionar su depuradora).

Devuelve EXCLUSIVAMENTE JSON: {"encaja": "si|no"}"""

AVISO_SIN_NIF = """

Esta empresa todavía no ha ganado contratos: los «contratos ganados más \
parecidos» son contratos adjudicados a otras empresas, parecidos a lo que \
dice que hace. Te damos también lo que dice que hace: si un ejemplo y su \
descripción no casan, manda la descripción."""


def preguntar(mensajes: list, gasto) -> dict | None:
    clave = os.environ["OPENAI_API_KEY"]
    for intento in range(5):
        try:
            r = P.requests.post("https://api.openai.com/v1/chat/completions", timeout=60,
                                headers={"Authorization": f"Bearer {clave}"},
                                json={"model": "gpt-4o-mini", "messages": mensajes,
                                      "response_format": {"type": "json_object"},
                                      "temperature": 0, "max_tokens": 30})
            if r.status_code == 200:
                d = r.json()
                gasto.apuntar(d.get("usage", {}))
                return json.loads(d["choices"][0]["message"]["content"] or "{}")
        except Exception:
            pass
        P.time.sleep(2 ** intento)
    return None


def limpiar(descripcion: str, puros: list[dict], gasto) -> list[dict]:
    """De los más parecidos (sin variedad), los que encajan con lo que dice
    que hace; los 40 primeros. Si pasan menos de 10, los 40 más parecidos."""
    def encaja(v):
        r = preguntar([{"role": "system", "content": FILTRO},
                       {"role": "user", "content": f"LO QUE DICE QUE HACE:\n{descripcion}\n\n"
                                                   f"CONTRATO:\n{v['titulo']}"}], gasto)
        return bool(r) and P.sin_tildes(str(r.get("encaja", ""))).strip().lower() == "si"
    with ThreadPoolExecutor(8) as ex:
        buenos = [v for v, ok in zip(puros, ex.map(encaja, puros)) if ok]
    return (buenos if len(buenos) >= 10 else puros)[:40]


def con_motor(c, cif, ganados, k, gasto, descripcion=None):
    """Grupo y lista del motor con un historial sintético (propio a cero)."""
    gan = [{"id_licitacion": v["id_licitacion"], "titulo": v["titulo"], "cpvs": v["cpvs"]}
           for v in ganados]
    c.completar_huellas({v["titulo"] for v in gan}, guardar=False)
    X, filas = P.rasgos_perfil(c, cif, gan)
    X[:, 5] = 0.0
    grupo = [c.vivas[j] for j in np.argsort(-P.combinar(X))[:k]]
    E = np.asarray(c.emb[filas], np.float32)
    tareas = []
    for idl in grupo:
        f = c.ficha_viva[idl]
        r = c.fila_de_titulo(f["titulo"])
        v = np.asarray(c.emb[r], np.float32) if r is not None else np.zeros(E.shape[1], np.float32)
        ejemplos = [f"- {c.titulos[filas[j]]}" for j in np.argsort(-(E @ v))[:P.EJEMPLOS]]
        m = P.mensajes_juez(f, ejemplos, [], [])
        if descripcion:
            m[0]["content"] += AVISO_SIN_NIF
            m[1]["content"] = f"LO QUE LA EMPRESA DICE QUE HACE:\n{descripcion}\n\n" + m[1]["content"]
        tareas.append((idl, m))
    with ThreadPoolExecutor(8) as ex:
        juicios = list(ex.map(lambda t: P.juzgar(t[1], gasto), tareas))
    return {idl for (idl, _), j in zip(tareas, juicios) if j and j["veredicto"] in ("si", "quizas")}


def main() -> int:
    casos = json.loads((SALIDA / "sinteticos.json").read_text())
    c = P.Contexto.desde_instantanea(Path(os.environ.get("CACHE_HUELLAS",
                                                         "~/.cache/huellas")).expanduser())
    vivas = set(c.vivas)
    k = math.ceil(P.PESOS["grupo_por_mil"] / 1000 * len(c.vivas))
    gasto = P.Gasto(MAX_GASTO)
    medir_actual = os.environ.get("MEDIR_ACTUAL") == "1"
    ia = cribador.obtener_cliente_openai() if medir_actual else None
    VARIANTES = (["actual"] if medir_actual else []) + ["sintetico", "limpio", "limpio_desc"]
    resultados, resumen = [], []

    for caso in casos:
        if gasto.agotado():
            logging.info("Tope de gasto alcanzado, se para")
            break
        cod, cif = caso["codigo"], caso["cif"]
        R = mostrados_reales(caso["perfil_id"], vivas)
        mostrados, extra = {}, {}

        mostrados["sintetico"] = con_motor(c, cif, caso["vecinos"], k, gasto)
        limpios = limpiar(caso["descripcion"], caso["puros"], gasto)
        extra["limpios"] = len(limpios)
        extra["quitados"] = [v["titulo"] for v in caso["puros"][:len(limpios) + 20]
                             if v not in limpios][:10]
        mostrados["limpio"] = con_motor(c, cif, limpios, k, gasto)
        mostrados["limpio_desc"] = con_motor(c, cif, limpios, k, gasto, caso["descripcion"])

        if medir_actual:
            puerta = set(caso["prefijos"])
            candidatas = [i for i in c.vivas if prefijos_de(c.ficha_viva[i]["cpvs"]) & puerta]
            def clasificar(idl):
                f = c.ficha_viva[idl]
                return cribador.clasificar(ia, caso["criterio"],
                                           {"titulo": f["titulo"], "organo": f.get("organo"),
                                            "presupuesto": f.get("presupuesto"), "cpvs": f.get("cpvs")})
            with ThreadPoolExecutor(8) as ex:
                vs = list(ex.map(clasificar, candidatas))
            mostrados["actual"] = {i for i, v in zip(candidatas, vs)
                                   if v and v["veredicto"] in ("si", "quizas")}
            gasto.total += len(candidatas) * (450 * 0.15 + 60 * 0.60) / 1e6

        fila = {"codigo": cod, "reales": len(R), "limpios": extra["limpios"]}
        for v in VARIANTES:
            S = mostrados[v]
            acierto = len(S & R)
            fila[v] = {"mostrados": len(S),
                       "recupera": acierto / len(R) if R else None,
                       "precision": acierto / len(S) if S else None}
        resumen.append(fila)
        resultados.append({**fila, "perfil_id": caso["perfil_id"], "quitados": extra["quitados"],
                           **{f"ids_{v}": sorted(mostrados[v]) for v in VARIANTES}})
        g = lambda x: "—" if x is None else f"{x:.2f}"
        logging.info("%s: reales %d · %s · gasto %.2f $", cod, len(R), " · ".join(
            f"{v} {fila[v]['mostrados']} (rec {g(fila[v]['recupera'])}, prec {g(fila[v]['precision'])})"
            for v in VARIANTES), gasto.total)
        (SALIDA / "sintetico.json").write_text(json.dumps(resultados))

    # ---- Resumen público: solo cifras
    def media(v, campo):
        xs = [f[v][campo] for f in resumen if f[v][campo] is not None]
        return sum(xs) / len(xs) if xs else float("nan")
    lineas = ["## Alta sin NIF con el motor de huellas: contra el ruido", "",
              "Referencia: lo que el motor enseña hoy a cada empresa con su NIF.", "",
              "| Variante | Enseña (media) | Recupera de la lista real | De lo que enseña, está en la lista real |",
              "|---|---|---|---|"]
    for v in VARIANTES:
        lineas.append(f"| {v} | {media(v, 'mostrados'):.0f} | {media(v, 'recupera'):.2f} | "
                      f"{media(v, 'precision'):.2f} |")
    lineas += ["", f"Perfiles: {len(resumen)}. Gasto: {gasto.total:.2f} $."]
    informe = "\n".join(lineas)
    print("\n" + informe)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write(informe + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
