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
              Es lo que hay en producción (decisión 41) y la base de las
              demás.
  limpio_desc_bis
              limpio_desc otra vez, desde el filtro y sin reutilizar
              veredictos: la diferencia entre las dos es el ruido del
              modelo, el listón que tiene que pasar cualquier mejora.
  web         en vez de la descripción, lo que el modelo saca de su web (a
              qué se dedica y sus líneas, sin clientes ni zonas): familias
              propuestas con eso y una búsqueda por línea. Sin web
              legible, igual que limpio_desc (lo que haría el alta).
  web_desc    la descripción y lo de la web juntos.
  corr10_hoy  el cliente marca 10 contratos de su lista (el oráculo:
              «me interesa» si están en su lista real) y el motor hace lo
              de hoy: las correcciones solo llegan al juez.
  corrN_nuevo lo mismo con 5, 10 o 20 marcas, y el motor cambiado
              (propuesta 3): los «me interesa» entran en el historial
              sintético, salen de él los ejemplos parecidos a un «no me
              interesa», y el grupo se rehace con lo corregido.
              Con correcciones, los contratos marcados no cuentan: ni en
              lo que enseña ni en la lista real.

Las líneas de producto y los referentes (medidos el 01/10/2026, sin
mejora) ya no se exportan.

Con MEDIR_ACTUAL=1 se mide también lo de antes (criterio en prosa), y con
MEDIR_ANTERIORES=1 sintetico y limpio.

Sin trampas: los vecinos ya salen sin los contratos de la propia empresa,
y en «sintetico» el rasgo `propio` (cuánto de lo parecido ganó ella) se
pone a cero: sin NIF no se sabe quién es.

Solo lee. Lo que sale:
  - consola y resumen de la ejecución: cifras y perfiles anónimos;
  - simulacion/sintetico.json (con ids), que el workflow cifra.

Gasto: se cuenta todo lo que va a OpenAI desde este proceso (juez,
filtro y huellas nuevas), más lo que dejó la exportación en
simulacion/gasto.json. Antes de cada empresa, si lo gastado más la
empresa más cara hasta ahora (con un 25 % de margen) pasaría MAX_GASTO,
se para. Una empresa que se queda a medias no cuenta en las medias.

Variables: SUPABASE_URL, SUPABASE_KEY, OPENAI_API_KEY, CACHE_HUELLAS,
    MAX_GASTO (dólares, total de las dos fases; por defecto 3).
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
# Cuántos contratos marca el cliente (propuesta 3), y con cuántos se mide
# también el motor de hoy (las correcciones solo llegan al juez).
N_MARCAS = (5, 10, 20)
MARCAS_HOY = 10


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


def contar_gasto(gasto) -> None:
    """Todo lo que va a OpenAI pasa por Session.request (también
    requests.post y las huellas): ahí se lee el uso de cada respuesta.
    Gasto.apuntar deja de contar, para no contar dos veces."""
    if P.MODELO_JUEZ != "gpt-4o-mini":
        raise SystemExit("El contador de gasto solo conoce los precios de gpt-4o-mini")
    original = P.requests.sessions.Session.request

    def request(self, method, url, *a, **kw):  # mismos nombres: requests los pasa así
        r = original(self, method, url, *a, **kw)
        if str(url).startswith("https://api.openai.com/") and r.status_code == 200:
            try:
                u = r.json().get("usage", {})
            except ValueError:
                u = {}
            d = (u.get("total_tokens", 0) * 0.02 if "/embeddings" in str(url)
                 else u.get("prompt_tokens", 0) * 0.15 + u.get("completion_tokens", 0) * 0.60) / 1e6
            with gasto.c:
                gasto.total += d
        return r
    P.requests.sessions.Session.request = request
    gasto.apuntar = lambda uso: None


def preguntar(mensajes: list, gasto) -> dict | None:
    if gasto.agotado():
        return None
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


def intercalar(*listas: list[dict]) -> list[dict]:
    """Uno de cada lista por turnos, sin repetir."""
    vistos, salida = set(), []
    for i in range(max((len(x) for x in listas), default=0)):
        for x in listas:
            if i < len(x) and x[i]["id_licitacion"] not in vistos:
                vistos.add(x[i]["id_licitacion"])
                salida.append(x[i])
    return salida


def con_motor(c, cif, ganados, k, gasto, descripcion=None, correcciones=(), recuerdo=None):
    """Grupo y lista del motor con un historial sintético (propio a cero).

    `correcciones`: lo que ha marcado el cliente, como en procesar_perfil:
    el juez ve las más parecidas a cada contrato (sin motivo no hay reglas).
    `recuerdo`: veredictos ya pedidos con el mismo mensaje exacto, para no
    pagarlos dos veces. Nunca en la repetición que mide el ruido."""
    gan = [{"id_licitacion": v["id_licitacion"], "titulo": v["titulo"], "cpvs": v["cpvs"]}
           for v in ganados]
    c.completar_huellas({v["titulo"] for v in gan}, guardar=False)
    X, filas = P.rasgos_perfil(c, cif, gan)
    X[:, 5] = 0.0
    grupo = [c.vivas[j] for j in np.argsort(-P.combinar(X))[:k]]
    E = np.asarray(c.emb[filas], np.float32)
    corr = [x for x in correcciones if c.fila_de_titulo(x["titulo"]) is not None]
    C = np.asarray(c.emb[[c.fila_de_titulo(x["titulo"]) for x in corr]], np.float32) \
        if corr else np.zeros((0, E.shape[1]), np.float32)
    tareas = []
    for idl in grupo:
        f = c.ficha_viva[idl]
        r = c.fila_de_titulo(f["titulo"])
        v = np.asarray(c.emb[r], np.float32) if r is not None else np.zeros(E.shape[1], np.float32)
        ejemplos = [f"- {c.titulos[filas[j]]}" for j in np.argsort(-(E @ v))[:P.EJEMPLOS]]
        cerca = []
        if len(C):
            sc = C @ v
            cerca = [corr[j] for j in np.argsort(-sc)[:P.CORRECCIONES] if sc[j] >= P.SIM_CORRECCION]
        m = P.mensajes_juez(f, ejemplos, cerca, [])
        if descripcion:
            m[0]["content"] += AVISO_SIN_NIF
            m[1]["content"] = f"LO QUE LA EMPRESA DICE QUE HACE:\n{descripcion}\n\n" + m[1]["content"]
        tareas.append((idl, m))

    def juicio(t):
        clave = json.dumps(t[1], ensure_ascii=False)
        if recuerdo is not None and clave in recuerdo:
            return recuerdo[clave]
        j = P.juzgar(t[1], gasto)
        if recuerdo is not None and j:
            recuerdo[clave] = j
        return j
    with ThreadPoolExecutor(8) as ex:
        juicios = list(ex.map(juicio, tareas))
    return {idl for (idl, _), j in zip(tareas, juicios) if j and j["veredicto"] in ("si", "quizas")}


def marcas(c, mostrados: set[str], reales: set[str], n: int, semilla: int) -> list[dict]:
    """El cliente marca `n` contratos de su lista: «me interesa» si están
    en su lista real, «no me interesa» si no (el oráculo: es una cota). Sin
    motivo, que es lo más frecuente. Al azar con semilla, no los primeros:
    no sabemos en qué orden los mira."""
    rng = np.random.default_rng(semilla)
    elegidos = rng.permutation(sorted(mostrados))[:n]
    return [{"id_licitacion": i, "titulo": c.ficha_viva[i]["titulo"],
             "cpvs": c.ficha_viva[i]["cpvs"], "organo": c.ficha_viva[i].get("organo"),
             "interesa": i in reales, "motivo": None} for i in elegidos]


def historial_corregido(c, ganados: list[dict], corr: list[dict]) -> list[dict]:
    """Lo que cambiaría en el motor (propuesta 3): los «me interesa» entran
    en el historial sintético, y sale de él el ejemplo que se parece a un
    «no me interesa» (con el mismo umbral con el que el juez ve una
    corrección) más que a cualquier «me interesa»."""
    def vec(t):
        r = c.fila_de_titulo(t)
        return None if r is None else np.asarray(c.emb[r], np.float32)
    si = [v for v in (vec(x["titulo"]) for x in corr if x["interesa"]) if v is not None]
    no = [v for v in (vec(x["titulo"]) for x in corr if not x["interesa"]) if v is not None]
    quedan = []
    for g in ganados:
        v = vec(g["titulo"])
        if v is not None and no:
            peor = max(float(v @ n) for n in no)
            mejor = max((float(v @ s) for s in si), default=-1.0)
            if peor >= P.SIM_CORRECCION and peor > mejor:
                continue
        quedan.append(g)
    vistos = {g["id_licitacion"] for g in quedan}
    return quedan + [{"id_licitacion": x["id_licitacion"], "titulo": x["titulo"], "cpvs": x["cpvs"]}
                     for x in corr if x["interesa"] and x["id_licitacion"] not in vistos]


def main() -> int:
    casos = json.loads((SALIDA / "sinteticos.json").read_text())
    c = P.Contexto.desde_instantanea(Path(os.environ.get("CACHE_HUELLAS",
                                                         "~/.cache/huellas")).expanduser())
    vivas = set(c.vivas)
    k = math.ceil(P.PESOS["grupo_por_mil"] / 1000 * len(c.vivas))
    gasto = P.Gasto(MAX_GASTO)
    contar_gasto(gasto)
    previo = SALIDA / "gasto.json"
    gasto.total = json.loads(previo.read_text())["dolares"] if previo.exists() else 0.0
    logging.info("Gasto de la exportación: %.2f $ (tope total %.2f $)", gasto.total, MAX_GASTO)
    mas_cara = 0.0
    a_medias = 0
    medir_actual = os.environ.get("MEDIR_ACTUAL") == "1"
    ia = cribador.obtener_cliente_openai() if medir_actual else None
    anteriores = os.environ.get("MEDIR_ANTERIORES") == "1"
    VARIANTES = ((["actual"] if medir_actual else []) + (["sintetico", "limpio"] if anteriores else [])
                 + ["limpio_desc", "limpio_desc_bis", "web", "web_desc"]
                 + [f"corr{MARCAS_HOY}_hoy"] + [f"corr{n}_nuevo" for n in N_MARCAS])
    resultados, resumen = [], []

    for caso in casos:
        if gasto.total + mas_cara * 1.25 > MAX_GASTO:
            logging.info("Se para antes de %s: %.2f $ gastados, la más cara costó %.2f $",
                         caso["codigo"], gasto.total, mas_cara)
            break
        antes = gasto.total
        cod, cif = caso["codigo"], caso["cif"]
        R = mostrados_reales(caso["perfil_id"], vivas)
        mostrados, extra = {}, {}

        desc = caso["descripcion"]
        if anteriores:
            mostrados["sintetico"] = con_motor(c, cif, caso["vecinos"], k, gasto)
        recuerdo: dict = {}
        limpios = limpiar(desc, caso["puros"], gasto)
        extra["limpios"] = len(limpios)
        extra["quitados"] = [v["titulo"] for v in caso["puros"][:len(limpios) + 20]
                             if v not in limpios][:10]
        if anteriores:
            mostrados["limpio"] = con_motor(c, cif, limpios, k, gasto)
        mostrados["limpio_desc"] = con_motor(c, cif, limpios, k, gasto, desc, recuerdo=recuerdo)
        # Lo mismo otra vez, desde el filtro y sin recuerdo: lo que cambia
        # entre las dos es el ruido del modelo, no el método.
        mostrados["limpio_desc_bis"] = con_motor(c, cif, limpiar(desc, caso["puros"], gasto),
                                                 k, gasto, desc)

        # La web. Sin web legible, el alta seguiría con la descripción.
        w = caso.get("web")
        extra["web"] = bool(w)
        if w:
            mostrados["web"] = con_motor(c, cif, limpiar(w["descripcion"], w["puros"], gasto),
                                         k, gasto, w["descripcion"])
            mostrados["web_desc"] = con_motor(c, cif, limpiar(w["descripcion_con_desc"],
                                                              w["puros_con_desc"], gasto),
                                              k, gasto, w["descripcion_con_desc"])
        else:
            mostrados["web"] = mostrados["web_desc"] = mostrados["limpio_desc"]

        # Correcciones sobre lo que enseña producción. Las marcas de 10
        # incluyen las de 5, y las de 20 las de 10: el mismo cliente que
        # sigue marcando.
        todas = marcas(c, mostrados["limpio_desc"], R, max(N_MARCAS), int(cod[1:]) * 7919)
        for n in N_MARCAS:
            corr = todas[:n]
            if n == MARCAS_HOY:
                mostrados[f"corr{n}_hoy"] = con_motor(c, cif, limpios, k, gasto, desc, corr, recuerdo)
            mostrados[f"corr{n}_nuevo"] = con_motor(c, cif, historial_corregido(c, limpios, corr),
                                                    k, gasto, desc, corr, recuerdo)
            extra[f"marcadas{n}"] = {i["id_licitacion"] for i in corr}
        extra["marcas_si"] = sum(x["interesa"] for x in todas)
        mas_cara = max(mas_cara, gasto.total - antes)
        if gasto.agotado():
            # Algo se quedó sin juzgar: sus cifras saldrían falsamente bajas.
            a_medias += 1
            logging.info("%s: tope alcanzado a medias, no cuenta", cod)
            break

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

        # Con correcciones, lo que marcó no cuenta (ni en lo que enseña ni
        # en su lista real): ya sabía qué era. Para comparar, producción
        # medida sin esos mismos contratos.
        def cifras(S, fuera=frozenset()):
            S, Rv = S - fuera, R - fuera
            acierto = len(S & Rv)
            return {"mostrados": len(S), "recupera": acierto / len(Rv) if Rv else None,
                    "precision": acierto / len(S) if S else None}
        fila = {"codigo": cod, "reales": len(R), "limpios": extra["limpios"], "web": extra["web"],
                "web_caracteres": caso.get("web_caracteres", 0), "marcas_si": extra["marcas_si"]}
        for v in VARIANTES:
            n = int(v[4:].split("_")[0]) if v.startswith("corr") else None
            fuera = frozenset(extra[f"marcadas{n}"]) if n else frozenset()
            fila[v] = cifras(mostrados[v], fuera)
            fila[v]["base"] = cifras(mostrados["limpio_desc"], fuera)
        resumen.append(fila)
        resultados.append({**fila, "perfil_id": caso["perfil_id"], "quitados": extra["quitados"],
                           "web_texto": caso.get("web"),
                           **{f"ids_{v}": sorted(mostrados[v]) for v in VARIANTES}})
        g = lambda x: "—" if x is None else f"{x:.2f}"
        logging.info("%s: reales %d · %s · gasto %.2f $", cod, len(R), " · ".join(
            f"{v} {fila[v]['mostrados']} (rec {g(fila[v]['recupera'])}, prec {g(fila[v]['precision'])})"
            for v in VARIANTES), gasto.total)
        (SALIDA / "sintetico.json").write_text(json.dumps(resultados))

    # ---- Resumen público: solo cifras
    def media(v, campo, filas=None):
        xs = [f[v][campo] for f in (resumen if filas is None else filas) if f[v][campo] is not None]
        return sum(xs) / len(xs) if xs else float("nan")
    con_web = [f for f in resumen if f["web"]]
    lineas = ["## Alta sin NIF: la web, el ruido y las correcciones", "",
              "Referencia: lo que el motor enseña hoy a cada empresa con su NIF. "
              "Con correcciones, sin contar los contratos marcados.", "",
              "| Variante | Enseña (media) | Recupera | De lo que enseña, bueno |",
              "|---|---|---|---|"]
    for v in VARIANTES:
        lineas.append(f"| {v} | {media(v, 'mostrados'):.0f} | {media(v, 'recupera'):.2f} | "
                      f"{media(v, 'precision'):.2f} |")
    lineas += ["", f"Solo las {len(con_web)} empresas con web legible:", "",
               "| Variante | Enseña (media) | Recupera | De lo que enseña, bueno |", "|---|---|---|---|"]
    for v in ("limpio_desc", "limpio_desc_bis", "web", "web_desc"):
        lineas.append(f"| {v} | {media(v, 'mostrados', con_web):.0f} | "
                      f"{media(v, 'recupera', con_web):.2f} | {media(v, 'precision', con_web):.2f} |")

    # Empresa por empresa, frente a lo que hay en producción (medido sin
    # los mismos contratos): una variante gana si recupera más sin enseñar
    # peor (o enseña mejor sin recuperar menos). Diferencias de menos de
    # 0,02 cuentan como empate. limpio_desc_bis dice cuánto «gana» o
    # «pierde» el azar solo: es el listón para las demás.
    def compara(v):
        gana = pierde = 0
        for f in resumen:
            a, b = f[v]["base"], f[v]
            if None in (a["recupera"], b["recupera"], a["precision"], b["precision"]):
                continue
            dr, dp = b["recupera"] - a["recupera"], b["precision"] - a["precision"]
            if (dr > 0.02 and dp > -0.02) or (dp > 0.02 and dr > -0.02):
                gana += 1
            elif (dr < -0.02 and dp < 0.02) or (dp < -0.02 and dr < 0.02):
                pierde += 1
        return gana, pierde
    lineas += ["", "| Frente a limpio_desc | Mejor en | Peor en |", "|---|---|---|"]
    for v in VARIANTES:
        if v != "limpio_desc":
            gana, pierde = compara(v)
            lineas.append(f"| {v} | {gana} | {pierde} |")

    def dif(f, campo):
        a, b = f["limpio_desc"][campo], f["limpio_desc_bis"][campo]
        return "—" if None in (a, b) else f"{abs(a - b):.2f}"
    lineas += ["", "Ruido: diferencia entre limpio_desc y limpio_desc_bis (recupera / bueno): "
               + ", ".join(f"{f['codigo']} {dif(f, 'recupera')} / {dif(f, 'precision')}" for f in resumen)]

    g = lambda x: "—" if x is None else f"{x:.2f}"
    lineas += ["", "| Perfil | Reales | Web (caracteres) | «Me interesa» de 20 | " +
               " | ".join(f"{v} rec / prec" for v in VARIANTES) + " |",
               "|---|---|---|---|" + "---|" * len(VARIANTES)]
    for f in resumen:
        lineas.append(f"| {f['codigo']} | {f['reales']} | {f['web_caracteres'] if f['web'] else 'no'} | "
                      f"{f['marcas_si']} | " +
                      " | ".join(f"{g(f[v]['recupera'])} / {g(f[v]['precision'])}" for v in VARIANTES)
                      + " |")
    lineas += ["", f"Perfiles: {len(resumen)} de {len(casos)} exportados"
               + (f" ({a_medias} a medias, fuera)" if a_medias else "")
               + f". Gasto contado, las dos fases: {gasto.total:.2f} $ (tope {MAX_GASTO:.2f} $)."]
    informe = "\n".join(lineas)
    print("\n" + informe)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write(informe + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
