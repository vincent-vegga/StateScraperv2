"""
Paso 2 · Muestra de empresas y universo. Sin coste de OpenAI.

- Carga lo descargado en `datos/base.pkl` (licitaciones indexadas).
- Empresas elegibles: >= 15 licitaciones ganadas antes de T (todas, como
  ve el alta) y >= 5 desde T sin menores ni homologaciones.
- 40 empresas estratificadas por tamaño de historial (10 por cuartil).
- Universo: muestra fija de licitaciones con fecha_actualizacion >= T,
  sin menores ni homologaciones, la misma para todas las empresas.
"""
from __future__ import annotations

import glob
import json
import pickle
import random
import sys
from collections import defaultdict

from comun import CORTE, DATOS, HOY, etiqueta, log

SEMILLA = 20260924
N_EMPRESAS = 40
N_UNIVERSO = 4000


def es_homologacion(sistema, importe) -> bool:
    return sistema in ("Acuerdo marco", "Sistema dinámico de adquisición") and importe is None


def prefijos(cpvs) -> set[str]:
    """calcular_prefijos: 2 y 4 cifras de todos los CPV de 4+ cifras."""
    out = set()
    for c in cpvs or []:
        c = str(c)
        if len(c) >= 4:
            out.add(c[:2])
            out.add(c[:4])
    return out


def cargar_base() -> dict:
    ruta = DATOS / "base.pkl"
    if ruta.exists():
        return pickle.load(open(ruta, "rb"))
    lic = {}
    for fich in sorted(glob.glob(str(DATOS / "licitaciones_*.jsonl"))):
        for linea in open(fich):
            d = json.loads(linea)
            cpvs = d["cpvs"] if isinstance(d["cpvs"], list) else []
            lic[d["id_licitacion"]] = {
                "titulo": d["titulo"] or "", "organo": d["organo"] or "",
                "presupuesto": d["presupuesto"], "cpvs": [str(c) for c in cpvs],
                "fa": d["fecha_actualizacion"] or "",
                "menor": d["procedimiento"] == "Contrato menor",
                "homol": es_homologacion(d["sistema"], d["importe_adjudicacion"]),
                "estado": d["estado_licitacion"],
            }
    adj = []
    for fich in sorted(glob.glob(str(DATOS / "adjudicaciones_empresa_*.jsonl"))):
        for linea in open(fich):
            d = json.loads(linea)
            if d["cif"] and d["id_licitacion"] in lic:
                adj.append((d["id_licitacion"], d["cif"], d["fecha"] or "",
                            d["importe"], d["es_menor"], d["es_homologacion"]))
    base = {"lic": lic, "adj": adj}
    pickle.dump(base, open(ruta, "wb"))
    log(f"base: {len(lic)} licitaciones, {len(adj)} adjudicaciones")
    return base


def main() -> None:
    global N_EMPRESAS, N_UNIVERSO
    if len(sys.argv) > 2:
        N_EMPRESAS, N_UNIVERSO = int(sys.argv[1]), int(sys.argv[2])
    base = cargar_base()
    lic, adj = base["lic"], base["adj"]

    antes = defaultdict(set)
    despues = defaultdict(set)
    for idl, cif, fecha, _imp, menor, homol in adj:
        if not fecha:
            continue
        if fecha < CORTE:
            antes[cif].add(idl)
        elif fecha < HOY and not menor and not homol:
            despues[cif].add(idl)
    elegibles = [c for c in antes if len(antes[c]) >= 15 and len(despues[c]) >= 5]
    log(f"elegibles (>=15 antes, >=5 después): {len(elegibles)}")

    # Cuartiles de tamaño de historial, 10 de cada.
    rnd = random.Random(SEMILLA)
    elegibles.sort(key=lambda c: (len(antes[c]), c))
    q = len(elegibles) // 4
    estratos = [elegibles[i * q:(i + 1) * q if i < 3 else None] for i in range(4)]
    empresas = []
    for i, e in enumerate(estratos):
        elegidas = rnd.sample(e, N_EMPRESAS // 4)
        log(f"estrato {i}: {len(antes[e[0]])}-{len(antes[e[-1]])} ganados antes")
        empresas += [{"cif": c, "estrato": i, "etiqueta": etiqueta(c),
                      "n_antes": len(antes[c]), "positivos": sorted(despues[c])}
                     for c in elegidas]

    candidatas = sorted(i for i, l in lic.items()
                        if l["fa"] >= CORTE and not l["menor"] and not l["homol"])
    universo = rnd.sample(candidatas, N_UNIVERSO)
    log(f"universo: {len(universo)} de {len(candidatas)} licitaciones desde T")

    json.dump({"empresas": empresas, "universo": universo,
               "n_candidatas": len(candidatas)},
              open(DATOS / "muestra.json", "w"), ensure_ascii=False)
    for e in empresas:
        log(e["etiqueta"], "estrato", e["estrato"], "antes", e["n_antes"],
            "positivos", len(e["positivos"]))


if __name__ == "__main__":
    main()
