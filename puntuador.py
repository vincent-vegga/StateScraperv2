#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Puntuación de licitaciones para empresas con historial
======================================================================

Sustituye, para los perfiles dados de alta con NIF y con historial
suficiente, a la puerta CPV + juez con criterio en prosa. Medido en el
banco de pruebas (docs/afinar-seleccion/RESULTADOS.md, 40 empresas):

    hoy:    enseña 28 de cada 1.000 y recupera el 76 % de lo que la
            empresa acaba ganando (la peor de cada diez, el 48 %)
    nuevo:  enseña 55 de cada 1.000 y recupera el 95 % (la peor, el 83 %)

Cómo decide, para cada perfil y cada licitación viva:

  1. PUNTUACIÓN (sin modelo de lenguaje). Con las «huellas» de los
     títulos (huellas.py) calcula siete rasgos: parecido con lo que la
     empresa ha ganado (knn1, knn5), afinidad CPV como peso y no como
     puerta (cpv4, cpv2, sin_cpv), cuánto de lo parecido ganó ella
     (propio) y cuánto sus pares (pares). Los combina con los pesos del
     banco (puntuacion_pesos.json).
  2. GRUPO. Se queda con las mejor puntuadas: 100 de cada 1.000 vivas.
  3. JUEZ CON EJEMPLOS. gpt-4o-mini ve cada una junto a los 8 contratos
     ganados más parecidos (y las correcciones del cliente más parecidas)
     y dice si / quizas / no. Se enseñan si («Para mí») y quizas («Puede
     ser para mí»). Sin criterio en prosa.

Modos:
    python puntuador.py --sombra             # calcula y juzga, guarda en
                                             # Storage (sombra/), NO toca la base
    python puntuador.py --sombra --perfil X  # solo un perfil
    python puntuador.py --ensayo             # puntúa sin llamar al juez

Variables: SUPABASE_URL, SUPABASE_KEY, OPENAI_API_KEY,
    CACHE_HUELLAS (carpeta; por defecto ~/.cache/huellas),
    MAX_GASTO_PASADA (dólares; por defecto 3).
"""
from __future__ import annotations

import argparse
import json
import logging
import math
import os
import sys
import threading
import time
import unicodedata
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import requests

import huellas

AQUI = Path(__file__).resolve().parent
PESOS = json.loads((AQUI / "puntuacion_pesos.json").read_text())
MODELO_JUEZ = os.environ.get("MODELO_JUEZ", "gpt-4o-mini")
VERSION = "puntuacion-v1"
M_VECINOS = 50          # vecinos pasados por licitación viva
M_PARES = 20            # vecinos por contrato propio para hallar pares
MAX_PROPIOS = 400       # contratos propios usados para hallar pares
EJEMPLOS = 8            # contratos ganados que ve el juez
CORRECCIONES = 5        # correcciones del cliente que ve el juez, como mucho
SIM_CORRECCION = 0.55   # parecido mínimo para enseñarle una corrección
SIMULTANEAS = 16
PRECIO = {"gpt-4o-mini": (0.15, 0.60)}     # $ por millón de tokens

# Las instrucciones del juez son las del banco de pruebas, sin tocar:
# con ellas se midieron los números de arriba.
INSTRUCCIONES_JUEZ = """\
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

# Lo que el cliente ha corregido pesa más que lo que dedujo el modelo:
# se le enseña al juez como hechos, con su motivo si lo escribió.
AVISO_CORRECCIONES = """

Además, el cliente ha corregido a mano contratos parecidos. Sus \
correcciones mandan: si el contrato nuevo es del mismo tipo que uno que \
marcó como "no me interesa", responde "no" salvo que el motivo que dio no \
se aplique a este."""


# ==============================================================
# Lectura de la base (solo lectura, PostgREST en paralelo)
# ==============================================================
# Cortes de tramo: cualquier lista ordenada cubre todos los id (el primer
# tramo no tiene suelo y el último no tiene techo); estos, tomados cada
# 50.000 filas el 24/09/2026, solo sirven para repartir el trabajo.
_CORTES = [
    *(f"https://contrataciondelestado.es/sindicacion/datosAbiertosMenores/{n}" for n in
      (16595929, 16827391, 17081075, 17300895, 17529814, 17720360, 17946500,
       18165138, 18365641, 18575983)),
    *(f"https://contrataciondelestado.es/sindicacion/licitacionesPerfilContratante/{n}" for n in
      (12083103, 14376232, 15103396, 15794312, 16607582, 17329196, 17922331,
       18561144, 19404116, 20015196)),
    *(f"https://contrataciondelestado.es/sindicacion/PlataformasAgregadasSinMenores/{n}" for n in
      (13052432, 15805925, 17960277, 19983237)),
]
_TRAMOS = list(zip([None] + _CORTES, _CORTES + [None]))


def _rest() -> tuple[str, dict]:
    base, cab = huellas._base()
    return base.replace("/storage/v1", "/rest/v1"), cab


def leer(tabla: str, params: dict) -> list[dict]:
    url, cab = _rest()
    err = ""
    for intento in range(6):
        try:
            r = requests.get(f"{url}/{tabla}", params=params, headers=cab, timeout=60)
            if r.status_code == 200:
                return r.json()
            err = f"{r.status_code} {r.text[:200]}"
        except requests.RequestException as e:
            err = str(e)
        time.sleep(2 ** intento)
    raise RuntimeError(f"PostgREST {tabla}: {err}")


def _q(v: str) -> str:
    return '"' + v.replace('"', '\\"') + '"'


def _tramo(tabla: str, campos: str, orden: str, desde, hasta) -> list[dict]:
    salida, ultimo = [], desde
    while True:
        conds = []
        if ultimo:
            conds.append(f"id_licitacion.gt.{_q(ultimo)}")
        if hasta:
            conds.append(f"id_licitacion.lte.{_q(hasta)}")
        params = {"select": campos, "order": orden, "limit": "1000"}
        if conds:
            params["and"] = "(" + ",".join(conds) + ")"
        filas = leer(tabla, params)
        completa = len(filas) < 1000
        if not completa and orden != "id_licitacion":
            # Paginación solo por id: la última licitación puede venir
            # cortada y se deja entera para la página siguiente.
            final = filas[-1]["id_licitacion"]
            filas = [x for x in filas if x["id_licitacion"] != final] or filas
        salida += filas
        if completa:
            return salida
        ultimo = filas[-1]["id_licitacion"]


def leer_tabla(tabla: str, campos: str, orden: str) -> list[dict]:
    with ThreadPoolExecutor(8) as ex:
        partes = ex.map(lambda t: _tramo(tabla, campos, orden, *t), _TRAMOS)
        return [f for p in partes for f in p]


# ==============================================================
# Datos
# ==============================================================
class Datos:
    def __init__(self, cache: Path):
        t0 = time.time()
        lic = leer_tabla("licitaciones",
                         "id_licitacion,titulo,cpvs,organo,presupuesto,"
                         "estado_licitacion,fecha_limite,sustituida", "id_licitacion")
        self.lic = {d["id_licitacion"]: d for d in lic}
        adj = leer_tabla("adjudicaciones_empresa", "id_licitacion,cif", "id_licitacion,cif")
        self.por_cif = defaultdict(set)
        self.ganadores = defaultdict(set)
        for a in adj:
            if a["cif"] and a["id_licitacion"] in self.lic:
                self.por_cif[a["cif"]].add(a["id_licitacion"])
                self.ganadores[a["id_licitacion"]].add(a["cif"])
        logging.info("Base: %d licitaciones, %d adjudicaciones (%.0f s)",
                     len(self.lic), len(adj), time.time() - t0)

        ahora = datetime.now(timezone.utc).isoformat()
        # Lo vivo, con la misma regla que pendientes_de_perfil.
        self.vivas = sorted(
            i for i, l in self.lic.items()
            if (l["estado_licitacion"] or "") == "PUB"
            and (l["fecha_limite"] is None or l["fecha_limite"] >= ahora)
            and not l["sustituida"])

        self.titulos, self.emb = huellas.cargar(cache)
        self.fila = {t: k for k, t in enumerate(self.titulos)}
        self._completar_huellas()
        logging.info("Huellas: %d; vivas: %d", len(self.titulos), len(self.vivas))

    def _completar_huellas(self) -> None:
        """Las licitaciones nuevas traen títulos sin huella: se calculan y
        se guardan en Storage para las pasadas siguientes."""
        necesarias = set(self.vivas) | set(self.ganadores)
        faltan = sorted({huellas.normal(self.lic[i]["titulo"]) for i in necesarias}
                        - set(self.fila) - {""})
        if not faltan:
            return
        logging.info("Huellas nuevas: %d títulos", len(faltan))
        v = huellas.calcular(faltan, os.environ["OPENAI_API_KEY"])
        huellas.anadir(faltan, v)
        base = len(self.titulos)
        self.titulos += faltan
        self.emb = np.concatenate([self.emb, v])
        self.fila.update({t: base + k for k, t in enumerate(faltan)})

    def fila_de(self, idl: str):
        return self.fila.get(huellas.normal(self.lic[idl]["titulo"]))


# ==============================================================
# Puntuación
# ==============================================================
def top_m(q: np.ndarray, P: np.ndarray, m: int, bloque: int = 256):
    idx = np.empty((len(q), m), np.int64)
    sim = np.empty((len(q), m), np.float32)
    for a in range(0, len(q), bloque):
        s = q[a:a + bloque] @ P.T
        part = np.argpartition(-s, m, axis=1)[:, :m]
        ps = np.take_along_axis(s, part, 1)
        orden = np.argsort(-ps, axis=1)
        idx[a:a + bloque] = np.take_along_axis(part, orden, 1)
        sim[a:a + bloque] = np.take_along_axis(ps, orden, 1)
    return idx, sim


class Pasado:
    """Títulos adjudicados (sin las vivas) y quién los ganó."""

    def __init__(self, d: Datos):
        vivas = set(d.vivas)
        self.ganadores = defaultdict(Counter)
        for idl, cifs in d.ganadores.items():
            if idl in vivas:
                continue
            r = d.fila_de(idl)
            if r is not None:
                for c in cifs:
                    self.ganadores[r][c] += 1
        self.filas = np.array(sorted(self.ganadores), np.int64)
        self.P = np.asarray(d.emb[self.filas], np.float32)
        logging.info("Pasado: %d títulos adjudicados", len(self.filas))
        filas_v = [d.fila_de(i) for i in d.vivas]
        Q = np.asarray(d.emb[[r if r is not None else 0 for r in filas_v]], np.float32)
        self.vi, self.vs = top_m(Q, self.P, M_VECINOS)
        self.sin_huella = {i for i, r in zip(d.vivas, filas_v) if r is None}
        self.pos = {i: k for k, i in enumerate(d.vivas)}


def rasgos_perfil(d: Datos, pasado: Pasado, cif: str) -> tuple[np.ndarray, list[int]]:
    """Los siete rasgos de cada licitación viva para esta empresa."""
    propias = sorted(d.por_cif[cif])
    filas_propias = sorted({d.fila_de(i) for i in propias} - {None})
    E = np.asarray(d.emb[filas_propias], np.float32)

    c4, c2 = Counter(), Counter()
    for i in propias:
        cp = [str(c) for c in (d.lic[i]["cpvs"] or [])] if isinstance(d.lic[i]["cpvs"], list) else []
        for p in {c[:4] for c in cp if len(c) >= 4}:
            c4[p] += 1
        for p in {c[:2] for c in cp if len(c) >= 2}:
            c2[p] += 1
    n = max(len(propias), 1)

    recientes = filas_propias if len(filas_propias) <= MAX_PROPIOS else \
        list(np.random.default_rng(0).choice(filas_propias, MAX_PROPIOS, replace=False))
    pi, ps = top_m(np.asarray(d.emb[recientes], np.float32), pasado.P, M_PARES + 1)
    pares = Counter()
    for q, fi, fs in zip(recientes, pi, ps):
        for j, s in zip(fi, fs):
            if pasado.filas[j] == q:
                continue
            for otro in pasado.ganadores[pasado.filas[j]]:
                if otro != cif:
                    pares[otro] += float(s)
    tot = sum(pares.values()) or 1.0
    peso_par = {o: v / tot for o, v in pares.most_common(200)}

    X = np.zeros((len(d.vivas), 7))
    for k, idl in enumerate(d.vivas):
        l = d.lic[idl]
        r = d.fila_de(idl)
        if r is not None and len(E):
            s = np.sort(E @ np.asarray(d.emb[r], np.float32))
            X[k, 0], X[k, 1] = s[-1], s[-5:].mean()
        cp = [str(c) for c in l["cpvs"]] if isinstance(l["cpvs"], list) else []
        p4 = {c[:4] for c in cp if len(c) >= 4}
        p2 = {c[:2] for c in cp if len(c) >= 2}
        X[k, 2] = max((c4[p] / n for p in p4), default=0.0)
        X[k, 3] = max((c2[p] / n for p in p2), default=0.0)
        X[k, 4] = float(not p4)
        if idl not in pasado.sin_huella:
            w = np.maximum(pasado.vs[k], 0) ** 4
            ws = float(w.sum()) or 1.0
            propio = par = 0.0
            for j, wj in zip(pasado.vi[k], w):
                g = pasado.ganadores[pasado.filas[j]]
                tg = sum(g.values())
                if cif in g:
                    propio += wj * g[cif] / tg
                par += wj * sum(peso_par.get(o, 0.0) * v for o, v in g.items()) / tg
            X[k, 5], X[k, 6] = propio / ws, par / ws
    return X, filas_propias


def combinar(X: np.ndarray) -> np.ndarray:
    Z = X.copy()
    Z[:, 5] = np.log1p(50 * Z[:, 5])
    Z[:, 6] = np.log1p(50 * Z[:, 6])
    Z = (Z - np.array(PESOS["media"])) / np.array(PESOS["desviacion"])
    return Z @ np.array(PESOS["pesos"]) + PESOS["constante"]


# ==============================================================
# Juez con ejemplos
# ==============================================================
class Gasto:
    def __init__(self, tope: float):
        self.tope, self.total, self.c = tope, 0.0, threading.Lock()

    def apuntar(self, uso: dict) -> None:
        pin, pout = PRECIO.get(MODELO_JUEZ, (0.15, 0.60))
        with self.c:
            self.total += (uso.get("prompt_tokens", 0) * pin
                           + uso.get("completion_tokens", 0) * pout) / 1e6

    def agotado(self) -> bool:
        with self.c:
            return self.total >= self.tope


def sin_tildes(texto: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", texto)
                   if unicodedata.category(c) != "Mn")


def ficha(l: dict) -> str:
    partes = [f"Título: {l['titulo']}"]
    if l.get("organo"):
        partes.append(f"Órgano: {l['organo']}")
    if l.get("presupuesto") is not None:
        partes.append(f"Presupuesto: {float(l['presupuesto']):,.0f} EUR".replace(",", "."))
    cp = l["cpvs"] if isinstance(l.get("cpvs"), list) else []
    if cp:
        partes.append(f"CPV: {', '.join(str(c) for c in cp[:8])}")
    return "\n".join(partes)


def mensajes_juez(d: Datos, idl: str, ejemplos: list[str], correcciones: list[dict]) -> list:
    sistema = INSTRUCCIONES_JUEZ + (AVISO_CORRECCIONES if correcciones else "")
    texto = "CONTRATOS GANADOS MÁS PARECIDOS:\n" + "\n".join(ejemplos)
    if correcciones:
        texto += "\n\nCORRECCIONES DEL CLIENTE EN CONTRATOS PARECIDOS:\n" + "\n".join(
            f"- {c['titulo']} → {'SÍ le interesa' if c['interesa'] else 'NO le interesa'}"
            + (f" (motivo: {c['motivo']})" if c.get("motivo") else "") for c in correcciones)
    texto += f"\n\nCONTRATO NUEVO:\n{ficha(d.lic[idl])}"
    return [{"role": "system", "content": sistema}, {"role": "user", "content": texto}]


def juzgar(mensajes: list, gasto: Gasto) -> dict | None:
    if gasto.agotado():
        return None
    clave = os.environ["OPENAI_API_KEY"]
    espera = 2.0
    for _ in range(6):
        try:
            r = requests.post("https://api.openai.com/v1/chat/completions", timeout=60,
                              headers={"Authorization": f"Bearer {clave}"},
                              json={"model": MODELO_JUEZ, "messages": mensajes,
                                    "response_format": {"type": "json_object"},
                                    "temperature": 0, "max_tokens": 150})
            if r.status_code == 200:
                datos = r.json()
                gasto.apuntar(datos.get("usage", {}))
                salida = json.loads(datos["choices"][0]["message"]["content"] or "{}")
                v = sin_tildes(str(salida.get("veredicto", ""))).strip().lower()
                if v in ("si", "quizas", "no"):
                    return {"veredicto": v, "motivo": str(salida.get("motivo", ""))[:300]}
            elif r.status_code == 429 and "insufficient_quota" in r.text:
                return None
        except (requests.RequestException, ValueError, KeyError):
            pass
        time.sleep(espera)
        espera *= 2
    return None


# ==============================================================
# Por perfil
# ==============================================================
def procesar_perfil(d: Datos, pasado: Pasado, perfil: dict, previos: dict,
                    correcciones: list[dict], gasto: Gasto, ensayo: bool) -> dict:
    X, filas_propias = rasgos_perfil(d, pasado, perfil["cif"])
    punt = combinar(X)
    k = math.ceil(PESOS["grupo_por_mil"] / 1000 * len(d.vivas))
    orden = np.argsort(-punt)[:k]
    grupo = [(d.vivas[j], float(punt[j])) for j in orden]

    # Ejemplos: un contrato ganado por título, los más parecidos.
    E = np.asarray(d.emb[filas_propias], np.float32)
    # Correcciones con huella (su título está en el almacén si la
    # licitación existe; si no, se busca por texto normalizado).
    corr = [c for c in correcciones if huellas.normal(c["titulo"]) in d.fila]
    C = np.asarray(d.emb[[d.fila[huellas.normal(c["titulo"])] for c in corr]], np.float32) \
        if corr else np.zeros((0, E.shape[1]), np.float32)

    tareas = []
    for idl, p in grupo:
        if idl in previos:
            continue
        r = d.fila_de(idl)
        v = np.asarray(d.emb[r], np.float32) if r is not None else np.zeros(E.shape[1], np.float32)
        ejemplos = []
        for j in np.argsort(-(E @ v))[:EJEMPLOS]:
            t = d.titulos[filas_propias[j]]
            ejemplos.append(f"- {t}")
        cerca = []
        if len(C):
            sc = C @ v
            cerca = [corr[j] for j in np.argsort(-sc)[:CORRECCIONES] if sc[j] >= SIM_CORRECCION]
        tareas.append((idl, mensajes_juez(d, idl, ejemplos, cerca)))

    nuevos = {}
    if not ensayo and tareas:
        with ThreadPoolExecutor(SIMULTANEAS) as ex:
            for (idl, _), res in zip(tareas, ex.map(lambda t: juzgar(t[1], gasto), tareas)):
                if res:
                    nuevos[idl] = res
    return {"grupo": grupo, "nuevos": nuevos, "pendientes": len(tareas) - len(nuevos)}


# ==============================================================
# Sombra: todo a Storage, nada a la base
# ==============================================================
def sombra_leer(perfil_id: str) -> dict:
    crudo = huellas._get(f"sombra/{perfil_id}.json")
    return json.loads(crudo) if crudo else {"veredictos": {}}


def sombra_guardar(perfil_id: str, datos: dict) -> None:
    huellas._put(f"sombra/{perfil_id}.json",
                 json.dumps(datos, ensure_ascii=False).encode(), "application/json")


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        datefmt="%H:%M:%S")
    ap = argparse.ArgumentParser()
    ap.add_argument("--sombra", action="store_true", help="guardar en Storage, no en la base")
    ap.add_argument("--ensayo", action="store_true", help="puntuar sin llamar al juez")
    ap.add_argument("--perfil", help="uuid (o sus primeras cifras) de un perfil")
    args = ap.parse_args()
    if not args.sombra:
        logging.error("Solo está permitido --sombra hasta que se apruebe el cambio.")
        return 2

    gasto = Gasto(float(os.environ.get("MAX_GASTO_PASADA", "3")))
    cache = Path(os.environ.get("CACHE_HUELLAS", Path.home() / ".cache" / "huellas"))
    d = Datos(cache)
    pasado = Pasado(d)

    perfiles = leer("perfiles", {"select": "id,cif", "activo": "is.true",
                                 "cif": "not.is.null"})
    perfiles = [p for p in perfiles if p["cif"]
                and len(d.por_cif[p["cif"]]) >= PESOS["minimo_ganados"]]
    if args.perfil:
        perfiles = [p for p in perfiles if p["id"].startswith(args.perfil)]
    correcciones = defaultdict(list)
    for c in leer("correcciones", {"select": "perfil_id,titulo,interesa,motivo"}):
        correcciones[c["perfil_id"]].append(c)
    logging.info("Perfiles con historial suficiente: %d", len(perfiles))

    for p in perfiles:
        et = p["id"][:8]
        previo = sombra_leer(p["id"])
        res = procesar_perfil(d, pasado, p, previo["veredictos"],
                              correcciones[p["id"]], gasto, args.ensayo)
        veredictos = {**previo["veredictos"], **res["nuevos"]}
        en_grupo = {i for i, _ in res["grupo"]}
        cuenta = Counter(v["veredicto"] for i, v in veredictos.items() if i in en_grupo)
        logging.info("%s: grupo %d · juzgadas hoy %d · si %d · quizas %d · no %d%s",
                     et, len(en_grupo), len(res["nuevos"]), cuenta["si"], cuenta["quizas"],
                     cuenta["no"], f" · SIN JUZGAR {res['pendientes']}" if res["pendientes"] else "")
        if not args.ensayo:
            sombra_guardar(p["id"], {
                "version": VERSION, "fecha": datetime.now(timezone.utc).isoformat(),
                "vivas": len(d.vivas),
                "grupo": [[i, round(s, 4)] for i, s in res["grupo"]],
                "veredictos": veredictos})
        if gasto.agotado():
            logging.warning("Tope de gasto de la pasada alcanzado (%.2f $): se sigue mañana.",
                            gasto.total)
            break
    logging.info("Gasto de la pasada: %.3f $", gasto.total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
