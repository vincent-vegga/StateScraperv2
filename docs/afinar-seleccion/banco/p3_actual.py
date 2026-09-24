"""
Paso 3 · El sistema actual, reproducido con el código de producción.

- Lectura del historial: INSTRUCCIONES_HISTORIAL se lee tal cual de
  `supabase/functions/alta/modelo.ts` (gpt-4o, 1.600 tokens, semilla fija),
  con los 40 últimos ganados ANTES de T y los prefijos de 4 cifras de
  todo lo ganado antes de T.
- Puerta CPV: `calcular_prefijos` de la licitación && prefijos validados.
- Juez: `construir_mensajes` y FORMATO importados de `cribador.py`
  (gpt-4o-mini, 150 tokens), sobre todo lo que pasa la puerta.

Uso: python3 p3_actual.py estimar | lecturas | juez
"""
from __future__ import annotations

import json
import re
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor

from comun import (CORTE, DATOS, RAIZ, Cache, ParadaPresupuesto, chat, coste,
                   gasto_total, log, tokens_aprox)
from p2_muestra import cargar_base, prefijos

sys.path.insert(0, str(RAIZ))
import cribador  # noqa: E402  (FORMATO, construir_mensajes, sin_tildes)



def instrucciones_historial() -> str:
    ts = (RAIZ / "supabase/functions/alta/modelo.ts").read_text()
    m = re.search(r"const INSTRUCCIONES_HISTORIAL = `(.*?)`;", ts, re.S)
    # En una plantilla de JS, barra invertida + salto de línea no es nada.
    return m.group(1).replace("\\\n", "")


INSTRUCCIONES = instrucciones_historial()


def entrada_lectura(base, cif: str) -> tuple[list, list]:
    lic = base["lic"]
    suyas = {}
    for idl, c, fecha, imp, _m, _h in base["por_cif"][cif]:
        if fecha and fecha < CORTE:
            suyas[idl] = imp
    # ultimos_ganados(cif, 40): por fecha_actualizacion descendente.
    orden = sorted(suyas, key=lambda i: lic[i]["fa"], reverse=True)[:40]
    contratos = [{"titulo": lic[i]["titulo"], "organo": lic[i]["organo"],
                  "importe": suyas[i]} for i in orden]
    # prefijos_de_empresa(cif, 1)
    cuenta = Counter()
    for i in suyas:
        for p in {c[:4] for c in lic[i]["cpvs"] if len(c) >= 4}:
            cuenta[p] += 1
    pref = [{"prefijo": p, "contratos": n}
            for p, n in sorted(cuenta.items(), key=lambda x: (-x[1], x[0]))]
    return contratos, pref


def mensajes_lectura(contratos, pref) -> list:
    lista = "\n".join(f"- {c['titulo']}" + (f" ({c['organo']})" if c["organo"] else "")
                      for c in contratos)
    codigos = "\n".join(f"{p['prefijo']}: {p['contratos']} contratos" for p in pref)
    return [{"role": "system", "content": INSTRUCCIONES},
            {"role": "user", "content":
             f"CONTRATOS GANADOS ({len(contratos)}):\n{lista}\n\n" +
             (f"PREFIJOS CPV QUE APARECEN:\n{codigos}" if codigos else
              "PREFIJOS CPV QUE APARECEN: ninguno, los organismos no "
              "los publicaron. Dedúcelos de los títulos.")}]


def prefijos_de_lectura(lectura: dict, pref) -> list[str]:
    validos = [re.sub(r"\D", "", str(p)) for p in (lectura.get("prefijos_validos") or [])]
    validos = [p for p in validos if 2 <= len(p) <= 6]
    return validos or [p["prefijo"] for p in pref if p["contratos"] >= 2]


def preparar():
    base = cargar_base()
    por_cif = defaultdict(list)
    for fila in base["adj"]:
        por_cif[fila[1]].append(fila)
    base["por_cif"] = por_cif
    muestra = json.load(open(DATOS / "muestra.json"))
    return base, muestra


def universo_de(muestra, emp) -> tuple[list, set]:
    """Muestra fija sin sus positivos (para el volumen) y los positivos."""
    pos = set(emp["positivos"])
    return [i for i in muestra["universo"] if i not in pos], pos


def main(modo: str) -> None:
    base, muestra = preparar()
    lic = base["lic"]
    cache_lect = Cache("lecturas")
    cache_juez = Cache("juez_actual")
    resultados = {}
    ruta_res = DATOS / "actual.json"
    if ruta_res.exists():
        resultados = json.load(open(ruta_res))

    # ---- Lecturas del historial (gpt-4o)
    lecturas = {}
    tok_lect = 0
    for emp in muestra["empresas"]:
        contratos, pref = entrada_lectura(base, emp["cif"])
        msgs = mensajes_lectura(contratos, pref)
        tok_lect += sum(tokens_aprox((m["content"])) for m in msgs)
        if modo == "estimar":
            lecturas[emp["cif"]] = ({}, pref)
            continue
        contenido, _ = chat("lectura_actual", cache_lect, msgs, "gpt-4o", 1600, seed=20260922)
        lecturas[emp["cif"]] = (json.loads(contenido), pref)
    if modo == "estimar":
        log(f"lecturas: {tok_lect} tokens de entrada → "
            f"{coste('gpt-4o', tok_lect, 40 * 700):.3f} $ (con ~700 de salida cada una)")
    if modo == "lecturas":
        log(f"lecturas hechas. Gasto acumulado: {gasto_total():.4f} $")

    # ---- Puerta y juez
    tareas = []
    for emp in muestra["empresas"]:
        lectura, pref = lecturas[emp["cif"]]
        if modo == "estimar":
            mis = {p["prefijo"] for p in pref}          # cota: todos los prefijos
        else:
            mis = set(prefijos_de_lectura(lectura, pref))
        universo, pos = universo_de(muestra, emp)
        pasan = [i for i in universo if prefijos(lic[i]["cpvs"]) & mis]
        pasan_pos = [i for i in pos if prefijos(lic[i]["cpvs"]) & mis]
        r = resultados.setdefault(emp["etiqueta"], {})
        r.update({"estrato": emp["estrato"], "n_universo": len(universo),
                  "n_pos": len(pos), "prefijos": sorted(mis),
                  "puerta_vol": len(pasan), "puerta_pos": len(pasan_pos)})
        if modo != "estimar":
            r["criterio"] = lectura.get("criterio", "")
        for i in pasan + pasan_pos:
            tareas.append((emp, i, r.get("criterio", "")))

    if modo == "estimar":
        media_criterio = 500
        tok = sum(tokens_aprox((lic[i]["titulo"])) + 60 + media_criterio + 230
                  for _e, i, _c in tareas)
        log(f"juez: {len(tareas)} llamadas (cota con todos los prefijos), "
            f"~{tok} tokens → {coste('gpt-4o-mini', tok, len(tareas) * 60):.3f} $")
        for et, r in resultados.items():
            log(et, f"vol {r['puerta_vol']}/{r['n_universo']}",
                f"pos {r['puerta_pos']}/{r['n_pos']}")
        return

    if modo == "juez":
        veredictos = defaultdict(dict)

        def juzgar(t):
            emp, i, criterio = t
            l = lic[i]
            ficha = {"titulo": l["titulo"], "organo": l["organo"],
                     "presupuesto": l["presupuesto"], "cpvs": l["cpvs"]}
            msgs = cribador.construir_mensajes(criterio, ficha)
            try:
                contenido, _ = chat("juez_actual", cache_juez, msgs, "gpt-4o-mini", 150)
                v = cribador.sin_tildes(str(json.loads(contenido).get("veredicto", ""))).strip().lower()
            except ParadaPresupuesto:
                raise
            except Exception:
                v = "error"
            return emp["etiqueta"], i, v

        log(f"juez actual: {len(tareas)} llamadas")
        with ThreadPoolExecutor(16) as ex:
            for n, (et, i, v) in enumerate(ex.map(juzgar, tareas), 1):
                veredictos[et][i] = v
                if n % 1000 == 0:
                    log(f"{n}/{len(tareas)} · gasto {gasto_total():.3f} $")
        json.dump(veredictos, open(DATOS / "veredictos_actual.json", "w"))
        log(f"juez hecho. Gasto acumulado: {gasto_total():.4f} $")

    json.dump(resultados, open(ruta_res, "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "estimar")
