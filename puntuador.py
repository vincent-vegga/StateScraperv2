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
    python puntuador.py --real               # pasada diaria: lee toda la base,
                                             # guarda la instantánea y escribe
                                             # en `veredictos`
    python puntuador.py --real --instantanea --perfil X [--rehacer]
                                             # un perfil (alta, correcciones),
                                             # con la instantánea del día: ~3 min
    python puntuador.py --sombra             # igual, pero a Storage (sombra/)
    ... --ensayo                             # puntúa sin llamar al juez

Un perfil pasa a este sistema (perfiles.sistema = 'huellas') la primera
vez que se juzga entero su grupo. Desde entonces el cribado antiguo lo
deja en paz: `pendientes_de_perfil` no le devuelve nada.

Variables: SUPABASE_URL, SUPABASE_KEY, OPENAI_API_KEY,
    CACHE_HUELLAS (carpeta; por defecto ~/.cache/huellas),
    MAX_GASTO_PASADA (dólares; por defecto 3).
"""
from __future__ import annotations

import argparse
import gzip
import io
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
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import requests

import huellas

AQUI = Path(__file__).resolve().parent
PESOS = json.loads((AQUI / "puntuacion_pesos.json").read_text())
MODELO_JUEZ = os.environ.get("MODELO_JUEZ", "gpt-4o-mini")
VERSION = "puntuacion-v3"   # v3: como v2, con instrucciones sin nada de ningún sector (24/09/2026)
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

Mira dos cosas: QUÉ se contrata y PARA QUIÉN.
- El destinatario cuenta cuando cambia lo que se suministra en la \
práctica. Si sus contratos parecidos son todos para un mismo tipo de \
destinatario, un contrato del mismo producto para un destinatario \
distinto, con el que cambia lo que se suministra, NO es lo suyo, salvo \
que alguno de sus contratos ganados sea para ese otro destinatario.
- El destinatario no cuenta cuando el trabajo es el mismo se destine a \
quien se destine.
- Un mismo destinatario puede llamarse de formas distintas según el lugar \
o el idioma: compara lo que es, no cómo se llama.

Ejemplos DE FORMA, de sectores que no tienen nada que ver con esta empresa \
(no juzgues por parecido con ellos): en restauración, un comedor escolar \
diario y un catering para un acto puntual son comida los dos, pero no el \
mismo servicio: ahí el destinatario cuenta. El mantenimiento de ascensores \
de un hospital y el de un colegio son el mismo trabajo: ahí no cuenta.

- "si": el mismo tipo de producto o servicio que sus contratos ganados, \
para el mismo tipo de destinatario (o uno para el que da igual).
- "quizas": un producto vecino para su mismo tipo de destinatario, o un \
título demasiado genérico para saberlo (por ejemplo, un sistema dinámico \
de adquisición o un acuerdo marco amplio).
- "no": otro producto o servicio, o el mismo para un destinatario que sus \
contratos no incluyen y con el que cambia lo que se suministra.

No decidas por el territorio ni por el organismo convocante en sí: un \
mismo organismo contrata para destinatarios muy distintos, y lo que \
cuenta es para quién es.

Devuelve EXCLUSIVAMENTE JSON:
{"veredicto": "si|quizas|no", "motivo": "una frase breve que cite el \
contrato ganado que más se parece, o por qué ninguno encaja"}"""

# Lo que el cliente ha dicho al corregir su lista. Los motivos escritos son
# reglas suyas y se le enseñan todos al juez, en cada contrato: una regla
# sobre un organismo vale para cualquier contrato de ese organismo, no solo
# para los parecidos al que corrigió.
#
# NINGÚN ejemplo de estas instrucciones puede ser del sector de un cliente:
# son comunes a todos, y un ejemplo sacado de uno empuja a los demás (un
# ejemplo sobre ciertos cuerpos policiales pondría del revés a quien vende
# justo a esos cuerpos). Se usan ejemplos de otros sectores, marcados como
# ejemplos de forma.
AVISO_CORRECCIONES = """

El cliente ha corregido su lista y te damos lo que ha dicho. Sus reglas \
mandan sobre lo que deduzcas de sus contratos:
- Una regla sobre un organismo, colectivo o tipo de destinatario vale para \
cualquier contrato de ese organismo, colectivo o destinatario, lo convoque \
quien lo convoque.
- Una regla sobre un producto concreto vale solo para ese producto.
- Un descarte sin motivo no es una regla: solo dice que ese contrato \
concreto no le interesa.
- Lo que marcó como "SÍ le interesa" es tan fuerte como un contrato ganado.
(Ejemplos de forma, de otro sector: "no trabajamos con hospitales \
privados" vale para todo hospital privado; "no hacemos cocina sin gluten" \
vale solo para eso.)"""


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
# Escritura (solo en modo real)
# ==============================================================
def _escribir(metodo: str, tabla: str, params: dict | None = None, cuerpo=None,
              prefer: str = "return=minimal") -> None:
    url, cab = _rest()
    err = ""
    for intento in range(6):
        try:
            r = requests.request(metodo, f"{url}/{tabla}", params=params, json=cuerpo,
                                 timeout=120, headers={**cab, "Prefer": prefer})
            if r.status_code in (200, 201, 204):
                return
            err = f"{r.status_code} {r.text[:300]}"
            if 400 <= r.status_code < 500 and r.status_code != 429:
                break
        except requests.RequestException as e:
            err = str(e)
        time.sleep(2 ** intento)
    raise RuntimeError(f"PostgREST {metodo} {tabla}: {err}")


# ==============================================================
# Contexto: lo vivo, lo pasado y sus vecinos
# ==============================================================
# Se calcula entero una vez al día (modo diario, tras el scraper: ~7 min)
# y se guarda en Storage como «instantánea». Las pasadas de un solo perfil
# (alta nueva, correcciones) la reutilizan y tardan ~3 min en lugar de ~8.
ESTADO = "estado"


class Contexto:
    titulos: list[str]
    emb: np.ndarray
    fila: dict[str, int]
    vivas: list[str]                 # ids
    ficha_viva: dict[str, dict]      # id -> titulo, organo, presupuesto, cpvs
    pasado_filas: np.ndarray         # filas de huella de lo adjudicado
    gan_ptr: np.ndarray              # ganadores de cada título pasado (CSR)
    gan_cif: np.ndarray
    gan_n: np.ndarray
    cifs: list[str]
    vi: np.ndarray                   # vecinos pasados de cada viva
    vs: np.ndarray
    fecha: str

    # ---------- huellas ----------
    def _huellas(self, cache: Path) -> None:
        self.titulos, self.emb = huellas.cargar(cache)
        self.fila = {t: k for k, t in enumerate(self.titulos)}

    def completar_huellas(self, textos: set[str], guardar: bool = True) -> None:
        """Títulos sin huella (licitaciones nuevas): se calculan y, en la
        pasada diaria, se guardan en Storage para las siguientes. Las
        pasadas de un perfil no guardan: si coincidieran con la diaria, las
        dos escribirían la misma parte y el mismo manifiesto."""
        faltan = sorted({huellas.normal(t) for t in textos} - set(self.fila) - {""})
        if not faltan:
            return
        logging.info("Huellas nuevas: %d títulos", len(faltan))
        v = huellas.calcular(faltan, os.environ["OPENAI_API_KEY"])
        if guardar:
            huellas.anadir(faltan, v)
        base = len(self.titulos)
        self.titulos += faltan
        self.emb = np.concatenate([self.emb, v])
        self.fila.update({t: base + k for k, t in enumerate(faltan)})

    def fila_de_titulo(self, titulo: str | None):
        return self.fila.get(huellas.normal(titulo))

    def P(self) -> np.ndarray:
        if not hasattr(self, "_P"):
            self._P = np.asarray(self.emb[self.pasado_filas], np.float32)
        return self._P

    def ganadores(self, j: int) -> dict[str, int]:
        a, b = self.gan_ptr[j], self.gan_ptr[j + 1]
        return {self.cifs[c]: int(n) for c, n in zip(self.gan_cif[a:b], self.gan_n[a:b])}

    # ---------- construcción completa (una vez al día) ----------
    @classmethod
    def completo(cls, cache: Path) -> "Contexto":
        c = cls()
        t0 = time.time()
        lic = {d["id_licitacion"]: d for d in leer_tabla(
            "licitaciones", "id_licitacion,titulo,cpvs,organo,presupuesto,"
            "estado_licitacion,fecha_limite,fecha_actualizacion,sustituida", "id_licitacion")}
        adj = leer_tabla("adjudicaciones_empresa", "id_licitacion,cif", "id_licitacion,cif")
        logging.info("Base: %d licitaciones, %d adjudicaciones (%.0f s)",
                     len(lic), len(adj), time.time() - t0)
        ahora = datetime.now(timezone.utc).isoformat()
        hace_14 = (datetime.now(timezone.utc) - timedelta(days=14)).isoformat()
        # Lo vivo, con la misma regla que la lista de la web
        # (mis_oportunidades): sin fecha límite, solo si se ha movido en los
        # últimos 14 días. Contarlas todas metía ~600 licitaciones que la web
        # no enseña nunca en el grupo de cada cliente (hasta un 10 %).
        c.vivas = sorted(i for i, l in lic.items()
                         if (l["estado_licitacion"] or "") == "PUB"
                         and not l["sustituida"]
                         and (l["fecha_limite"] >= ahora if l["fecha_limite"]
                              else (l["fecha_actualizacion"] or "") >= hace_14))
        c.ficha_viva = {i: {k: lic[i][k] for k in ("titulo", "organo", "presupuesto", "cpvs")}
                        for i in c.vivas}
        ganadores = defaultdict(set)
        for a in adj:
            if a["cif"] and a["id_licitacion"] in lic:
                ganadores[a["id_licitacion"]].add(a["cif"])

        c._huellas(cache)
        c.completar_huellas({lic[i]["titulo"] for i in set(c.vivas) | set(ganadores)})

        # Pasado: títulos adjudicados (sin las vivas) -> quién los ganó.
        vivas = set(c.vivas)
        por_fila = defaultdict(Counter)
        for idl, cifs in ganadores.items():
            if idl in vivas:
                continue
            r = c.fila_de_titulo(lic[idl]["titulo"])
            if r is not None:
                for x in cifs:
                    por_fila[r][x] += 1
        c.pasado_filas = np.array(sorted(por_fila), np.int64)
        c.cifs = sorted({x for g in por_fila.values() for x in g})
        indice = {x: k for k, x in enumerate(c.cifs)}
        ptr, cc, nn = [0], [], []
        for r in c.pasado_filas:
            for x, n in por_fila[r].items():
                cc.append(indice[x])
                nn.append(n)
            ptr.append(len(cc))
        c.gan_ptr = np.array(ptr, np.int64)
        c.gan_cif = np.array(cc, np.int32)
        c.gan_n = np.array(nn, np.int32)
        logging.info("Pasado: %d títulos adjudicados", len(c.pasado_filas))
        c._vecinos()
        c.fecha = ahora
        return c

    def _vecinos(self) -> None:
        filas_v = [self.fila_de_titulo(self.ficha_viva[i]["titulo"]) for i in self.vivas]
        Q = np.asarray(self.emb[[r if r is not None else 0 for r in filas_v]], np.float32)
        self.vi, self.vs = top_m(Q, self.P(), M_VECINOS)
        self.vi[[k for k, r in enumerate(filas_v) if r is None]] = -1

    # ---------- instantánea en Storage ----------
    def guardar(self) -> None:
        buf = io.BytesIO()
        np.savez_compressed(buf, pasado_filas=self.pasado_filas, gan_ptr=self.gan_ptr,
                            gan_cif=self.gan_cif, gan_n=self.gan_n,
                            vi=self.vi.astype(np.int32), vs=self.vs.astype(np.float16))
        huellas._put(f"{ESTADO}/pasado.npz", buf.getvalue(), "application/octet-stream")
        huellas._put(f"{ESTADO}/cifs.json.gz", gzip.compress(json.dumps(self.cifs).encode()),
                     "application/gzip")
        huellas._put(f"{ESTADO}/vivas.json.gz", gzip.compress(json.dumps(
            {"vivas": self.vivas, "fichas": self.ficha_viva}, ensure_ascii=False).encode()),
            "application/gzip")
        # El índice de huellas cambia al añadir partes: se guarda cuántas
        # había, para saber que la instantánea encaja con ellas.
        huellas._put(f"{ESTADO}/meta.json", json.dumps(
            {"fecha": self.fecha, "huellas": len(self.titulos)}).encode(), "application/json")

    @classmethod
    def desde_instantanea(cls, cache: Path) -> "Contexto":
        c = cls()
        meta = json.loads(huellas._get(f"{ESTADO}/meta.json") or b"null")
        if not meta:
            raise RuntimeError("No hay instantánea: hace falta una pasada diaria antes.")
        c._huellas(cache)
        if len(c.titulos) < meta["huellas"]:
            raise RuntimeError("Las huellas bajadas son más viejas que la instantánea.")
        z = np.load(io.BytesIO(huellas._get(f"{ESTADO}/pasado.npz")))
        for k in ("pasado_filas", "gan_ptr", "gan_cif", "gan_n", "vi", "vs"):
            setattr(c, k, z[k])
        c.vi = c.vi.astype(np.int64)
        c.cifs = json.loads(gzip.decompress(huellas._get(f"{ESTADO}/cifs.json.gz")))
        v = json.loads(gzip.decompress(huellas._get(f"{ESTADO}/vivas.json.gz")))
        c.vivas, c.ficha_viva = v["vivas"], v["fichas"]
        c.fecha = meta["fecha"]
        logging.info("Instantánea del %s: %d vivas, %d títulos pasados",
                     c.fecha[:16], len(c.vivas), len(c.pasado_filas))
        return c


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


# ==============================================================
# Puntuación
# ==============================================================
def ganados_de(cif: str) -> list[dict]:
    """Lo que ha ganado la empresa: título y CPV de cada licitación."""
    ids = sorted({f["id_licitacion"] for f in leer(
        "adjudicaciones_empresa", {"select": "id_licitacion", "cif": f"eq.{cif}"})})
    return licitaciones_de(ids)


def ganados_del_perfil(p: dict) -> list[dict]:
    """Con NIF, lo que ha ganado. Sin NIF, su historial sintético: los 40
    contratos adjudicados más parecidos a su descripción que guardó el alta
    (perfiles.ganados_sinteticos, decisión 40). Sin `cif`, el rasgo
    `propio` sale a cero y los pares cuentan a todos los ganadores."""
    if p.get("cif"):
        return ganados_de(p["cif"])
    return licitaciones_de(sorted(set(p.get("ganados_sinteticos") or [])))


def licitaciones_de(ids: list[str]) -> list[dict]:
    out = []
    for a in range(0, len(ids), 100):
        filtro = "(" + ",".join(_q(i) for i in ids[a:a + 100]) + ")"
        out += leer("licitaciones", {"select": "id_licitacion,titulo,cpvs",
                                     "id_licitacion": f"in.{filtro}"})
    return out


def _cpvs(x) -> list[str]:
    return [str(c) for c in x] if isinstance(x, list) else []


def rasgos_perfil(c: Contexto, cif: str, ganados: list[dict]) -> tuple[np.ndarray, list[int]]:
    """Los siete rasgos de cada licitación viva para esta empresa (los
    mismos que se midieron en el banco, docs/afinar-seleccion/banco/p5)."""
    filas_propias = sorted({c.fila_de_titulo(g["titulo"]) for g in ganados} - {None})
    E = np.asarray(c.emb[filas_propias], np.float32)

    c4, c2 = Counter(), Counter()
    for g in ganados:
        cp = _cpvs(g["cpvs"])
        for p in {x[:4] for x in cp if len(x) >= 4}:
            c4[p] += 1
        for p in {x[:2] for x in cp if len(x) >= 2}:
            c2[p] += 1
    n = max(len(ganados), 1)

    # Pares: quién gana lo parecido a lo que ella ganó.
    recientes = filas_propias if len(filas_propias) <= MAX_PROPIOS else \
        list(np.random.default_rng(0).choice(filas_propias, MAX_PROPIOS, replace=False))
    pares = Counter()
    if recientes:
        pi, ps = top_m(np.asarray(c.emb[recientes], np.float32), c.P(), M_PARES + 1)
        for q, fi, fs in zip(recientes, pi, ps):
            for j, s in zip(fi, fs):
                if c.pasado_filas[j] == q:
                    continue           # su propio título
                for otro in c.ganadores(j):
                    if otro != cif:
                        pares[otro] += float(s)
    tot = sum(pares.values()) or 1.0
    peso_par = {o: v / tot for o, v in pares.most_common(200)}

    X = np.zeros((len(c.vivas), 7))
    for k, idl in enumerate(c.vivas):
        f = c.ficha_viva[idl]
        r = c.fila_de_titulo(f["titulo"])
        if r is not None and len(E):
            s = np.sort(E @ np.asarray(c.emb[r], np.float32))
            X[k, 0], X[k, 1] = s[-1], s[-5:].mean()
        cp = _cpvs(f["cpvs"])
        p4 = {x[:4] for x in cp if len(x) >= 4}
        p2 = {x[:2] for x in cp if len(x) >= 2}
        X[k, 2] = max((c4[p] / n for p in p4), default=0.0)
        X[k, 3] = max((c2[p] / n for p in p2), default=0.0)
        X[k, 4] = float(not p4)
        if c.vi[k, 0] >= 0:
            w = np.maximum(c.vs[k].astype(np.float32), 0) ** 4
            ws = float(w.sum()) or 1.0
            propio = par = 0.0
            for j, wj in zip(c.vi[k], w):
                g = c.ganadores(j)
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
    cp = _cpvs(l.get("cpvs"))
    if cp:
        partes.append(f"CPV: {', '.join(cp[:8])}")
    return "\n".join(partes)


def mensajes_juez(f: dict, ejemplos: list[str], cercanas: list[dict],
                  reglas: list[dict] | None = None) -> list:
    """`reglas`: todas sus correcciones con motivo; `cercanas`: las
    correcciones más parecidas a este contrato (con o sin motivo)."""
    reglas = reglas or []
    sistema = INSTRUCCIONES_JUEZ + (AVISO_CORRECCIONES if (reglas or cercanas) else "")
    texto = "CONTRATOS GANADOS MÁS PARECIDOS:\n" + "\n".join(ejemplos)
    if reglas:
        texto += "\n\nLO QUE EL CLIENTE NOS HA DICHO:\n" + "\n".join(
            f"- {'Le interesa' if x['interesa'] else 'No le interesa'} "
            f"«{x['titulo']}»" + (f" ({x['organo']})" if x.get("organo") else "")
            + f": {x['motivo']}" for x in reglas)
    otras = [x for x in cercanas if x not in reglas]
    if otras:
        texto += "\n\nCONTRATOS PARECIDOS QUE HA CORREGIDO SIN EXPLICAR:\n" + "\n".join(
            f"- {x['titulo']}" + (f" ({x['organo']})" if x.get("organo") else "")
            + f" → {'SÍ le interesa' if x['interesa'] else 'NO le interesa'}" for x in otras)
    texto += f"\n\nCONTRATO NUEVO:\n{ficha(f)}"
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
def procesar_perfil(c: Contexto, perfil: dict, ganados: list[dict], previos: dict,
                    correcciones: list[dict], gasto: Gasto, ensayo: bool) -> dict:
    X, filas_propias = rasgos_perfil(c, perfil["cif"], ganados)
    punt = combinar(X)
    k = math.ceil(PESOS["grupo_por_mil"] / 1000 * len(c.vivas))
    grupo = [(c.vivas[j], float(punt[j])) for j in np.argsort(-punt)[:k]]

    E = np.asarray(c.emb[filas_propias], np.float32)
    corr = [x for x in correcciones if c.fila_de_titulo(x["titulo"]) is not None]
    C = np.asarray(c.emb[[c.fila_de_titulo(x["titulo"]) for x in corr]], np.float32) \
        if corr else np.zeros((0, E.shape[1]), np.float32)

    # Todas las correcciones con motivo, sin repetir el mismo motivo.
    reglas, vistos = [], set()
    for x in correcciones:
        clave = (x.get("motivo") or "").strip().lower()
        if clave and clave not in vistos:
            vistos.add(clave)
            reglas.append(x)

    tareas = []
    for idl, _ in grupo:
        if idl in previos:
            continue
        f = c.ficha_viva[idl]
        r = c.fila_de_titulo(f["titulo"])
        v = np.asarray(c.emb[r], np.float32) if r is not None else np.zeros(E.shape[1], np.float32)
        ejemplos = [f"- {c.titulos[filas_propias[j]]}" for j in np.argsort(-(E @ v))[:EJEMPLOS]]
        cerca = []
        if len(C):
            sc = C @ v
            cerca = [corr[j] for j in np.argsort(-sc)[:CORRECCIONES] if sc[j] >= SIM_CORRECCION]
        tareas.append((idl, mensajes_juez(f, ejemplos, cerca, reglas)))

    nuevos = {}
    if not ensayo and tareas:
        with ThreadPoolExecutor(SIMULTANEAS) as ex:
            for (idl, _), res in zip(tareas, ex.map(lambda t: juzgar(t[1], gasto), tareas)):
                if res:
                    nuevos[idl] = res
    return {"grupo": grupo, "nuevos": nuevos, "pendientes": len(tareas) - len(nuevos)}


# ==============================================================
# Sombra (Storage) y real (tabla veredictos)
# ==============================================================
def sombra_leer(perfil_id: str) -> dict:
    crudo = huellas._get(f"sombra/{perfil_id}.json")
    return json.loads(crudo) if crudo else {"veredictos": {}}


def sombra_guardar(perfil_id: str, datos: dict) -> None:
    huellas._put(f"sombra/{perfil_id}.json",
                 json.dumps(datos, ensure_ascii=False).encode(), "application/json")


def previos_reales(perfil_id: str) -> dict:
    """Lo ya juzgado por este sistema. Al pasar un perfil por primera vez,
    se aprovecha lo juzgado en sombra en los dos últimos días (mismas
    instrucciones, no se paga dos veces)."""
    filas = leer("veredictos", {"select": "id_licitacion,veredicto,motivo",
                                "perfil_id": f"eq.{perfil_id}", "modelo": f"eq.{VERSION}"})
    previos = {f["id_licitacion"]: {"veredicto": f["veredicto"], "motivo": f["motivo"]}
               for f in filas}
    if not previos:
        s = sombra_leer(perfil_id)
        fecha = s.get("fecha")
        if fecha and datetime.now(timezone.utc) - datetime.fromisoformat(fecha) < \
                timedelta(days=2) and s.get("version") == VERSION:
            previos = s["veredictos"]
            logging.info("%s: se reutilizan %d veredictos de la sombra", perfil_id[:8], len(previos))
    return previos


def guardar_real(perfil: dict, grupo: list, veredictos: dict, vivas: list[str],
                 completo: bool = True) -> int:
    """Escribe los veredictos del grupo y, la primera vez, retira los del
    sistema anterior para lo vivo (lo vencido se queda como estaba)."""
    en_grupo = [i for i, _ in grupo if i in veredictos]
    filas = [{"id_licitacion": i, "perfil_id": perfil["id"],
              "veredicto": veredictos[i]["veredicto"], "motivo": veredictos[i]["motivo"],
              "criterio_version": perfil.get("criterio_version"), "modelo": VERSION}
             for i in en_grupo]
    for a in range(0, len(filas), 500):
        _escribir("POST", "veredictos", {"on_conflict": "id_licitacion,perfil_id"},
                  filas[a:a + 500], prefer="resolution=merge-duplicates,return=minimal")
    if perfil.get("sistema") != "huellas":
        viejos = [f["id_licitacion"] for f in leer("veredictos", {
            "select": "id_licitacion", "perfil_id": f"eq.{perfil['id']}",
            "modelo": f"neq.{VERSION}"})]
        vivas_s = set(vivas)
        quitar = [i for i in viejos if i in vivas_s]
        for a in range(0, len(quitar), 100):
            filtro = "(" + ",".join(_q(i) for i in quitar[a:a + 100]) + ")"
            _escribir("DELETE", "veredictos", {"perfil_id": f"eq.{perfil['id']}",
                                               "modelo": f"neq.{VERSION}",
                                               "id_licitacion": f"in.{filtro}"})
        logging.info("%s: pasa al sistema nuevo (%d veredictos antiguos de lo vivo retirados)",
                     perfil["id"][:8], len(quitar))
    # Versiones anteriores de este mismo sistema: lo vivo se retira, porque
    # el grupo se acaba de juzgar entero con la versión en vigor. Si NO se ha
    # juzgado entero (tope de gasto), no se toca: retirarlo vaciaría la lista
    # del cliente de lo que aún no se ha vuelto a juzgar.
    anteriores = [] if not completo else [f["id_licitacion"] for f in leer("veredictos", {
        "select": "id_licitacion", "perfil_id": f"eq.{perfil['id']}",
        "and": f"(modelo.like.puntuacion-*,modelo.neq.{VERSION})"})]
    vivas_s, juzgadas = set(vivas), set(en_grupo)
    quitar = [i for i in anteriores if i in vivas_s and i not in juzgadas]
    for a in range(0, len(quitar), 100):
        filtro = "(" + ",".join(_q(i) for i in quitar[a:a + 100]) + ")"
        _escribir("DELETE", "veredictos", {"perfil_id": f"eq.{perfil['id']}",
                                           "and": f"(modelo.like.puntuacion-*,modelo.neq.{VERSION})",
                                           "id_licitacion": f"in.{filtro}"})
    _escribir("PATCH", "perfiles", {"id": f"eq.{perfil['id']}"},
              {"sistema": "huellas", "puntuado_en": datetime.now(timezone.utc).isoformat()})
    return len(filas)


# ==============================================================
# Principal
# ==============================================================
def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        datefmt="%H:%M:%S")
    ap = argparse.ArgumentParser()
    modo = ap.add_mutually_exclusive_group(required=True)
    modo.add_argument("--sombra", action="store_true", help="guardar en Storage, no en la base")
    modo.add_argument("--real", action="store_true", help="escribir en la tabla veredictos")
    ap.add_argument("--ensayo", action="store_true", help="puntuar sin llamar al juez")
    ap.add_argument("--perfil", help="uuid (o sus primeras cifras) de un perfil; varios, con comas")
    ap.add_argument("--rehacer", action="store_true",
                    help="volver a juzgar todo el grupo, sin reutilizar veredictos")
    ap.add_argument("--instantanea", action="store_true",
                    help="usar la instantánea del día en vez de leer toda la base")
    args = ap.parse_args()

    gasto = Gasto(float(os.environ.get("MAX_GASTO_PASADA", "3")))
    cache = Path(os.environ.get("CACHE_HUELLAS", Path.home() / ".cache" / "huellas"))
    if args.instantanea:
        c = Contexto.desde_instantanea(cache)
    else:
        c = Contexto.completo(cache)
        if not args.ensayo:
            c.guardar()

    try:
        # Con NIF, o sin NIF con historial sintético (alta sin NIF).
        perfiles = leer("perfiles", {
            "select": "id,cif,sistema,criterio_version,puntuado_en,ganados_sinteticos",
            "activo": "is.true", "or": "(cif.not.is.null,ganados_sinteticos.not.is.null)"})
    except RuntimeError as error:
        # Sin la migración 20260924200000 no hay columna `sistema`: solo
        # vale para la sombra, que no la necesita.
        if "sistema" not in str(error) or not args.sombra:
            raise
        perfiles = leer("perfiles", {"select": "id,cif,criterio_version",
                                     "activo": "is.true", "cif": "not.is.null"})
    if args.perfil:
        elegidos = [x.strip() for x in args.perfil.split(",") if x.strip()]
        perfiles = [p for p in perfiles if any(p["id"].startswith(x) for x in elegidos)]
    correcciones = defaultdict(list)
    for x in leer("correcciones", {"select": "perfil_id,titulo,organo,interesa,motivo,fecha"}):
        correcciones[x["perfil_id"]].append(x)

    hechos = 0
    for p in perfiles:
        et = p["id"][:8]
        if not p.get("cif") and not p.get("ganados_sinteticos"):
            continue
        ganados = ganados_del_perfil(p)
        if len(ganados) < PESOS["minimo_ganados"]:
            # Poco historial: sigue con el criterio en prosa. Si se le había
            # marcado para este sistema, se le devuelve (y se da por hecha la
            # pasada, para que la web no se quede esperando).
            if p.get("sistema") == "huellas" and args.real and not args.ensayo:
                _escribir("PATCH", "perfiles", {"id": f"eq.{p['id']}"},
                          {"sistema": "criterio",
                           "puntuado_en": datetime.now(timezone.utc).isoformat()})
                logging.info("%s: menos de %d contratos, vuelve al criterio", et,
                             PESOS["minimo_ganados"])
            continue
        # Un motivo escrito es una regla para toda su lista: si ha llegado
        # alguno desde la última pasada, se rejuzga su grupo entero (~0,09 $).
        nuevas_reglas = any(x.get("motivo") and p.get("puntuado_en")
                            and x["fecha"] > p["puntuado_en"] for x in correcciones[p["id"]])
        if args.rehacer or (args.real and nuevas_reglas):
            previos = {}
        elif args.sombra:
            previos = sombra_leer(p["id"])["veredictos"]
        else:
            previos = previos_reales(p["id"])
        c.completar_huellas({g["titulo"] for g in ganados} |
                            {x["titulo"] for x in correcciones[p["id"]]},
                            guardar=not args.instantanea)
        res = procesar_perfil(c, p, ganados, previos, correcciones[p["id"]], gasto, args.ensayo)
        veredictos = {**previos, **res["nuevos"]}
        en_grupo = {i for i, _ in res["grupo"]}
        cuenta = Counter(v["veredicto"] for i, v in veredictos.items() if i in en_grupo)
        logging.info("%s: grupo %d · juzgadas hoy %d · si %d · quizas %d · no %d%s",
                     et, len(en_grupo), len(res["nuevos"]), cuenta["si"], cuenta["quizas"],
                     cuenta["no"], f" · SIN JUZGAR {res['pendientes']}" if res["pendientes"] else "")
        if args.ensayo:
            continue
        if args.sombra:
            sombra_guardar(p["id"], {
                "version": VERSION, "fecha": datetime.now(timezone.utc).isoformat(),
                "vivas": len(c.vivas), "grupo": [[i, round(s, 4)] for i, s in res["grupo"]],
                "veredictos": veredictos})
        elif res["pendientes"] and p.get("sistema") != "huellas":
            # Sin juzgar entero (tope de gasto, caída de OpenAI) no se
            # cambia de sistema: se queda con lo que tenía y sigue mañana.
            logging.warning("%s: grupo sin completar; sigue con el sistema anterior", et)
            continue
        else:
            guardar_real(p, res["grupo"], veredictos, c.vivas, completo=not res["pendientes"])
        hechos += 1
        if gasto.agotado():
            logging.warning("Tope de gasto de la pasada alcanzado (%.2f $): se sigue mañana.",
                            gasto.total)
            break
    logging.info("Perfiles hechos: %d · gasto de la pasada: %.3f $", hechos, gasto.total)
    return 0


if __name__ == "__main__":
    sys.exit(main())
