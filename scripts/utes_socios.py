#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Socios de las UTE
=================================

Rellena `ute_socios`: qué sociedades forman cada UTE que ha ganado algo.
La plataforma no publica ni los socios ni su porcentaje; solo el nombre de
la UTE. De ahí se sacan los socios, y solo cuando el cruce es fiable:

  nif_en_nombre   el NIF de una sociedad viene escrito en el nombre
                  ("FCC Aqualia, S.A. (CIF: A26019992) - ...").
  nombre_exacto   un trozo del nombre, sin forma jurídica, coincide con el
                  de UNA sola sociedad con NIF del catálogo `empresas`.

Lo que NO se hace, a propósito (medido el 01/10/2026 en una muestra
revisada a mano):

  - Casar por el principio del nombre ("COPISA" -> "COPISA INFRASTRUCTURES"):
    ~72 % de aciertos. Falla con nombres genéricos ("VILLANUEVA") y con
    entradas del catálogo que son otra UTE con NIF de sociedad.
  - Casar si el nombre del catálogo está contenido en el trozo: ~60 %.
    Confunde filiales (Telefónica Móviles -> Telefónica SA) y topónimos.
  - Palabras sueltas muy repetidas ("SISTEMA"): falso socio seguro.

El cruce exacto acertó 24 de 25. Cobertura: algún socio en el 36 % de las
UTEs, dos o más en el 11 %.

Uso:
    python scripts/utes_socios.py            # mide y enseña ejemplos
    python scripts/utes_socios.py --real     # además escribe en la base

Necesita SUPABASE_URL y SUPABASE_KEY (clave de servicio). Lee unas 15.000
adjudicaciones y 220.000 empresas: 1-2 minutos.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import os
import random
import re
import sys
import time
import unicodedata

import requests

URL = os.environ.get("SUPABASE_URL", "").rstrip("/")
CLAVE = os.environ.get("SUPABASE_KEY", "")
CABECERAS = {"apikey": CLAVE, "Authorization": f"Bearer {CLAVE}"}

# Una adjudicación es de una UTE si su NIF es de UTE o su nombre lo dice.
ES_UTE = re.compile(r"(\bUTE\b|U\.T\.E|UNI[OÓ]N? TEMPORAL)", re.I)
# Clave de la UTE: su NIF (U...) o el número que pone la plataforma cuando
# no hay NIF. Si en el campo viene el NIF de una sociedad, la adjudicación
# ya cuenta para esa sociedad y no se trata como UTE.
CLAVE_UTE = re.compile(r"^(U\d{8}|\d+)$")
NIF_SOCIEDAD = re.compile(r"^[A-HJ-NP-SVW]\d{7}[0-9A-J]$")
NIF_EN_TEXTO = re.compile(r"(?<![A-Z0-9])([A-HJ-NP-SVW]\d{7}[0-9A-J])(?![A-Z0-9])")
# Entradas del catálogo que en realidad son agrupaciones con el NIF de un
# socio: casar contra ellas devolvería otra UTE como socio.
PARECE_GRUPO = re.compile(r"(\bUTE\b|U\.T\.E|TEMPORAL|\s[-–]\s|;|\s/\s)", re.I)

FORMAS = ("S L U|S L P|S L L|S A U|S A L|S L|S A|SLU|SLP|SLL|SAU|SAL|SL|SA|"
          "SOCIEDAD LIMITADA|SOCIEDAD ANONIMA|SOCIEDAD COOPERATIVA|UNIPERSONAL|"
          "SOCIEDAD|LIMITADA|ANONIMA|SCCL|COOP|SCP|CB|SLNE|EN LIQUIDACION|S COOP|SC")
RE_FORMAS = re.compile(r" (?:%s)(?= )" % FORMAS)


def sin_tildes(s: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", s)
                   if unicodedata.category(c) != "Mn")


def nucleo(s: str) -> str:
    """El nombre sin tildes, puntuación ni forma jurídica."""
    s = sin_tildes(s).upper().replace("·", " ").replace(".", " ")
    s = " " + re.sub(r"[^A-Z0-9 ]", " ", s) + " "
    s = re.sub(r"\s+", " ", s)
    # Varias pasadas: "S A U" deja "S A" detrás si se quita "U" antes.
    for _ in range(3):
        s = re.sub(r"\s+", " ", RE_FORMAS.sub(" ", s))
    return s.strip()


def trozos(nombre: str) -> list[str]:
    """Las partes del nombre de una UTE que pueden ser un socio."""
    s = sin_tildes(nombre).upper()
    s = re.sub(r"[“”\"«»]", " ", s)
    s = re.sub(r"UNIO?N? TEMPORAL D.*$|LEY 18/1982.*$|DENOMINADA.*$|"
               r"ABREVIADAMENTE.*$|COMPROMISO DE|EN COMPROMISO", " ", s)
    s = re.sub(r"\bU\.?\s?T\.?\s?E\.?(?=\W|$)", " ", s)
    s = re.sub(r"\bLOTE\b.*$", " ", s)
    partes = re.split(r"\s*[-–—;,/+&()]\s*|\s+Y\s+|\s+I\s+|\s+E\s+", s)
    return [n for n in (nucleo(p) for p in partes) if len(n) >= 3]


# ------------------------------------------------------------
# Lectura y escritura (PostgREST, clave de servicio)
# ------------------------------------------------------------
def pedir(metodo: str, ruta: str, cabeceras: dict | None = None, **kw) -> requests.Response:
    for intento in range(6):
        try:
            r = requests.request(metodo, f"{URL}/rest/v1/{ruta}",
                                 headers={**CABECERAS, **(cabeceras or {})},
                                 timeout=120, **kw)
            if r.status_code < 500:
                r.raise_for_status()
                return r
        except requests.ConnectionError:
            pass
        time.sleep(2 ** intento)
    raise RuntimeError(f"{metodo} {ruta}: sin respuesta tras 6 intentos")


def leer_por_clave(tabla: str, columnas: str, clave: str, filtros: dict) -> list[dict]:
    """Toda la tabla, por tandas ordenadas por `clave` (sin OFFSET)."""
    filas, ultimo = [], None
    while True:
        params = {"select": columnas, "order": clave, "limit": "1000", **filtros}
        if ultimo is not None:
            params[clave] = f"gt.{ultimo}"
        d = pedir("GET", tabla, params=params).json()
        filas += d
        if len(d) < 1000:
            return filas
        ultimo = d[-1][clave]


def leer_utes() -> list[dict]:
    """Adjudicaciones de UTE que cuentan (las mismas que `ficha_empresa`)."""
    filas, ultimo = [], None
    while True:
        params = {"select": "id_licitacion,cif,nombre", "order": "id_licitacion",
                  "limit": "1000", "es_menor": "eq.false", "es_homologacion": "eq.false",
                  "or": "(cif.like.U*,nombre.ilike.*UTE*,nombre.ilike.*temporal*,"
                        "nombre.ilike.*U.T.E*)"}
        if ultimo is not None:
            params["id_licitacion"] = f"gt.{ultimo}"
        d = pedir("GET", "adjudicaciones_empresa", params=params).json()
        filas += d
        if len(d) < 1000:
            break
        ultimo = d[-1]["id_licitacion"]
    return [a for a in filas
            if CLAVE_UTE.match(a["cif"] or "")
            and ((a["cif"] or "").startswith("U") or ES_UTE.search(a["nombre"] or ""))]


# ------------------------------------------------------------
# Cruce
# ------------------------------------------------------------
class Catalogo:
    def __init__(self, empresas: list[dict]):
        self.por_nucleo: dict[str, set[str]] = collections.defaultdict(set)
        self.nombre: dict[str, str] = {}
        for e in empresas:
            cif, nombre = e["cif"] or "", e["nombre"] or ""
            if not NIF_SOCIEDAD.match(cif):
                continue
            self.nombre[cif] = nombre
            if PARECE_GRUPO.search(nombre):
                continue
            n = nucleo(nombre)
            if len(n) >= 3:
                self.por_nucleo[n].add(cif)
        # Una palabra suelta que encabeza muchas empresas es genérica.
        self.primeras = collections.Counter(n.split()[0] for n in self.por_nucleo)

    def exacto(self, trozo: str) -> str | None:
        cifs = self.por_nucleo.get(trozo)
        if not cifs or len(cifs) != 1:
            return None
        if " " not in trozo and (len(trozo) < 5 or self.primeras[trozo] > 20):
            return None
        return next(iter(cifs))


def socios_de(nombre: str, ute_cif: str, cat: Catalogo) -> dict[str, tuple[str, str]]:
    """{socio_cif: (metodo, trozo)} para un nombre de UTE."""
    out: dict[str, tuple[str, str]] = {}
    for nif in NIF_EN_TEXTO.findall(sin_tildes(nombre).upper()):
        if nif != ute_cif:
            out[nif] = ("nif_en_nombre", nif)
    for t in trozos(nombre):
        cif = cat.exacto(t)
        if cif and cif != ute_cif and cif not in out:
            out[cif] = ("nombre_exacto", t)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--real", action="store_true", help="escribir en ute_socios")
    args = ap.parse_args()
    if not URL or not CLAVE:
        print("Faltan SUPABASE_URL y SUPABASE_KEY.", file=sys.stderr)
        return 1

    inicio = dt.datetime.now(dt.timezone.utc)
    adj = leer_utes()
    cat = Catalogo(leer_por_clave("empresas", "cif,nombre", "cif", {}))
    print(f"{len(adj)} adjudicaciones de UTE; {len(cat.nombre)} sociedades en el catálogo")

    nombres: dict[str, set[str]] = collections.defaultdict(set)
    por_ute: collections.Counter = collections.Counter()
    for a in adj:
        nombres[a["cif"]].add(a["nombre"] or "")
        por_ute[a["cif"]] += 1

    filas = []
    con_socios = collections.Counter()
    for ute, ns in nombres.items():
        socios: dict[str, tuple[str, str]] = {}
        for n in ns:
            for cif, x in socios_de(n, ute, cat).items():
                socios.setdefault(cif, x)
        con_socios["2+" if len(socios) >= 2 else str(len(socios))] += 1
        for cif, (metodo, trozo) in socios.items():
            filas.append({"ute_cif": ute, "socio_cif": cif, "metodo": metodo,
                          "trozo": trozo, "calculado": inicio.isoformat()})

    total = len(nombres)
    print(f"UTEs: {total}  ·  con 2+ socios {con_socios['2+']} "
          f"({con_socios['2+'] / total:.0%})  ·  con 1 {con_socios['1']} "
          f"({con_socios['1'] / total:.0%})  ·  sin ninguno {con_socios['0']} "
          f"({con_socios['0'] / total:.0%})")
    print(f"Parejas UTE-socio: {len(filas)}  ·  "
          f"socios distintos: {len({f['socio_cif'] for f in filas})}  ·  "
          f"por método: {dict(collections.Counter(f['metodo'] for f in filas))}")
    for f in random.Random(1).sample(filas, min(15, len(filas))):
        print(f"  {next(iter(nombres[f['ute_cif']]))[:60]:60} -> "
              f"{cat.nombre.get(f['socio_cif'], f['socio_cif'])[:45]} ({f['metodo']})")

    if not args.real:
        print("Sin --real: no se escribe nada.")
        return 0

    for i in range(0, len(filas), 500):
        pedir("POST", "ute_socios", json=filas[i:i + 500],
              params={"on_conflict": "ute_cif,socio_cif"},
              cabeceras={"Prefer": "resolution=merge-duplicates,return=minimal"})
    # Lo que no ha salido en esta pasada ya no se sostiene (p. ej. el
    # catálogo ganó otra sociedad con el mismo nombre y ahora es ambiguo).
    pedir("DELETE", "ute_socios",
          params={"calculado": f"lt.{inicio.isoformat()}"},
          cabeceras={"Prefer": "return=minimal"})
    print(f"Escritas {len(filas)} parejas en ute_socios.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
