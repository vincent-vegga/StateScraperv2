"""
Compara, perfil a perfil, lo que se enseña hoy (veredictos si/quizas de
las licitaciones vivas) con lo que enseñaría la puntuación en sombra
(Storage, sombra/<perfil>.json). Solo lectura.

Escribe dos cosas:
  - por pantalla, un resumen con perfiles anónimos (8 cifras del id);
  - en la carpeta que se le pase (fuera del repo), un informe con
    títulos de ejemplo para revisarlo a mano: lleva datos de clientes.

Uso: python3 comparar_sombra.py [carpeta_informe]
"""
from __future__ import annotations

import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
import huellas  # noqa: E402
import puntuador  # noqa: E402


def vivas_con_veredicto(perfil_id: str) -> dict[str, str]:
    filas = puntuador.leer("veredictos", {"select": "id_licitacion,veredicto",
                                          "perfil_id": f"eq.{perfil_id}"})
    return {f["id_licitacion"]: f["veredicto"] for f in filas}


def vivas_de(ids: list[str]) -> set[str]:
    """De estas, las vivas (regla de pendientes_de_perfil). Por clave
    primaria: los índices de vivas son parciales y PostgREST no los usa."""
    from datetime import datetime, timezone
    ahora = datetime.now(timezone.utc).isoformat()
    out = set()
    for a in range(0, len(ids), 100):
        filtro = "(" + ",".join(puntuador._q(i) for i in ids[a:a + 100]) + ")"
        for f in puntuador.leer("licitaciones", {
                "select": "id_licitacion,estado_licitacion,fecha_limite,sustituida",
                "id_licitacion": f"in.{filtro}"}):
            if (f["estado_licitacion"] or "") == "PUB" and not f["sustituida"] and \
                    (f["fecha_limite"] is None or f["fecha_limite"] >= ahora):
                out.add(f["id_licitacion"])
    return out


def titulos(ids: list[str]) -> dict[str, dict]:
    out = {}
    for a in range(0, len(ids), 100):
        lote = ids[a:a + 100]
        filtro = "(" + ",".join(puntuador._q(i) for i in lote) + ")"
        for f in puntuador.leer("licitaciones", {"select": "id_licitacion,titulo,organo",
                                                 "id_licitacion": f"in.{filtro}"}):
            out[f["id_licitacion"]] = f
    return out


def main() -> None:
    carpeta = Path(sys.argv[1]) if len(sys.argv) > 1 else None
    perfiles = puntuador.leer("perfiles", {"select": "id,empresa,cif", "activo": "is.true",
                                           "cif": "not.is.null"})
    informe = ["# Sombra frente a lo actual (PRIVADO: datos de clientes)", ""]
    print(f"{'perfil':9s} {'vivas':>5s} {'hoy':>5s} {'nuevo':>5s} {'ambos':>5s} "
          f"{'solo hoy':>8s} {'solo nuevo':>10s} {'P.mí':>5s} {'Puede':>5s}")
    for p in perfiles:
        crudo = huellas._get(f"sombra/{p['id']}.json")
        if not crudo:
            continue
        s = json.loads(crudo)
        grupo = [i for i, _ in s["grupo"]]
        v = s["veredictos"]
        nuevo = {i for i in grupo if v.get(i, {}).get("veredicto") in ("si", "quizas")}
        si = {i for i in grupo if v.get(i, {}).get("veredicto") == "si"}
        vivas = set(grupo)
        actuales = vivas_con_veredicto(p["id"])
        # Lo que hoy se enseña de lo vivo: se cruza con el conjunto de
        # vivas de la pasada (grupo ⊂ vivas; para el resto, se pregunta).
        mostradas = [i for i, x in actuales.items() if x in ("si", "quizas")]
        vivas_hoy = vivas_de(mostradas)
        hoy_ids = [i for i in mostradas if i in vivas_hoy]
        info = titulos(hoy_ids + sorted(nuevo - set(hoy_ids)))
        hoy = set(hoy_ids)
        ambos, solo_hoy, solo_nuevo = hoy & nuevo, hoy - nuevo, nuevo - hoy
        print(f"{p['id'][:8]:9s} {s['vivas']:5d} {len(hoy):5d} {len(nuevo):5d} {len(ambos):5d} "
              f"{len(solo_hoy):8d} {len(solo_nuevo):10d} {len(si):5d} {len(nuevo - si):5d}")
        if carpeta:
            rnd = random.Random(0)
            informe += [f"## {p['empresa']} ({p['id'][:8]})", "",
                        f"Hoy {len(hoy)} · nuevo {len(nuevo)} (Para mí {len(si)}, "
                        f"Puede ser {len(nuevo - si)}) · en ambos {len(ambos)}", "",
                        "**Solo en el nuevo (muestra):**", ""]
            for i in rnd.sample(sorted(solo_nuevo), min(12, len(solo_nuevo))):
                t = info.get(i, {})
                informe.append(f"- [{v[i]['veredicto']}] {t.get('titulo', i)[:140]} — "
                               f"_{v[i]['motivo'][:140]}_")
            informe += ["", "**Solo en el actual (muestra):**", ""]
            for i in rnd.sample(sorted(solo_hoy), min(12, len(solo_hoy))):
                t = info.get(i, {})
                estado = "fuera del grupo" if i not in vivas else f"juez: {v.get(i, {}).get('veredicto')}"
                informe.append(f"- [{actuales[i]} · {estado}] {t.get('titulo', i)[:140]}")
            informe.append("")
    if carpeta:
        carpeta.mkdir(parents=True, exist_ok=True)
        (carpeta / "sombra_frente_a_actual.md").write_text("\n".join(informe))
        print(f"informe: {carpeta / 'sombra_frente_a_actual.md'}")


if __name__ == "__main__":
    main()
