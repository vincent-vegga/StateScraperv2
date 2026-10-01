#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Inspección de la duración del contrato en un mes de histórico de PLACSP.

Hace dos cosas, sin escribir nada en Supabase:
  1. Vuelca los bloques de duración/prórroga de los expedientes cuyo
     texto contenga --buscar (por ejemplo, el identificador de uno).
  2. Cuenta, sobre todo el mes, qué etiquetas de duración aparecen y en
     qué unidades, para saber la cobertura antes de escribir el extractor.

Uso: python scripts/ver_duracion.py --anio 2026 --mes 5 --buscar 16532957
"""
import argparse
import io
import os
import sys
import zipfile
from collections import Counter

from lxml import etree

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import lector_atom as lector
import procesar_historico as ph

ETIQUETAS = ("PlannedPeriod", "DurationMeasure", "ContractExtension",
             "OptionsDescription", "OptionValidityPeriod",
             "ContractExtensionOptionsDescription", "ExtensionsDescription")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--anio", type=int, required=True)
    p.add_argument("--mes", type=int, required=True)
    p.add_argument("--conjunto", default="643")
    p.add_argument("--buscar", default="")
    a = p.parse_args()
    ph.configurar_logging()
    contenido = ph.descargar(a.conjunto, a.anio, a.mes)
    if contenido is None:
        return 1

    ejemplos_ext = 0
    cont: Counter = Counter()
    entradas = con_periodo = con_duracion = con_prorroga = vistos = 0
    unidades: Counter = Counter()
    etiquetas: Counter = Counter()
    with zipfile.ZipFile(io.BytesIO(contenido)) as z:
        for nombre in sorted(n for n in z.namelist() if n.lower().endswith(".atom")):
            raiz = lector.parsear_xml(z.read(nombre))
            if raiz is None:
                continue
            for e in lector.localizar_entradas(raiz):
                if lector.buscar_hijos(e, "deleted-entry"):
                    continue
                entradas += 1
                for t in ETIQUETAS:
                    if lector.buscar_todos(e, t):
                        etiquetas[t] += 1
                medidas = lector.buscar_todos(e, "DurationMeasure")
                if medidas:
                    con_duracion += 1
                    for m in medidas:
                        unidades[m.get("unitCode") or "(sin unidad)"] += 1
                if lector.buscar_todos(e, "PlannedPeriod"):
                    con_periodo += 1
                if lector.buscar_todos(e, "ContractExtension"):
                    con_prorroga += 1
                # Cobertura de la duración a nivel de contrato frente a lote.
                ns = {'cac': 'urn:dgpe:names:draft:codice:schema:xsd:CommonAggregateComponents-2',
                      'cbc': 'urn:dgpe:names:draft:codice:schema:xsd:CommonBasicComponents-2'}
                gen = e.xpath('.//cac:ProcurementProject/cac:PlannedPeriod/cbc:DurationMeasure', namespaces=ns)
                lot = e.xpath('.//cac:ProcurementProjectLot/cac:ProcurementProject/cac:PlannedPeriod/cbc:DurationMeasure', namespaces=ns)
                # ProcurementProject dentro de Lot también casa con 'gen'; el de contrato es el hijo directo del folder.
                top = e.xpath('.//*[local-name()="ContractFolderStatus"]/cac:ProcurementProject/cac:PlannedPeriod/cbc:DurationMeasure', namespaces=ns)
                cont['top' if top else ('solo_lote' if lot else 'ninguna')] += 1
                fechas = e.xpath('.//cac:ProcurementProject/cac:PlannedPeriod/cbc:StartDate | .//cac:ProcurementProject/cac:PlannedPeriod/cbc:EndDate', namespaces=ns)
                if fechas and not top and not lot:
                    cont['solo_fechas'] += 1
                for x in e.xpath('.//cac:ContractExtension', namespaces=ns):
                    cont['ext'] += 1
                    if ejemplos_ext < 4:
                        ejemplos_ext += 1
                        print('--- ContractExtension ---')
                        print(etree.tostring(x, pretty_print=True, encoding='unicode')[:1500])
                if a.buscar and vistos < 3:
                    bruto = etree.tostring(e, encoding="unicode")
                    if a.buscar in bruto:
                        vistos += 1
                        print("=" * 60, "\nEXPEDIENTE con", a.buscar,
                              "\nID:", lector.primer_texto(e, "id", solo_hijos=True))
                        for t in ("ProcurementProject", "ContractExtension",
                                  "PlannedPeriod", "DurationMeasure"):
                            for x in lector.buscar_todos(e, t)[:2]:
                                print(f"--- {t} ---")
                                print(etree.tostring(x, pretty_print=True,
                                                     encoding="unicode")[:3500])
    print("=" * 60)
    print(f"Entradas: {entradas}")
    print(f"Con DurationMeasure: {con_duracion}  con PlannedPeriod: {con_periodo}"
          f"  con ContractExtension: {con_prorroga}")
    print("Unidades:", dict(unidades))
    print("Etiquetas:", dict(etiquetas))
    print("Cobertura:", dict(cont))
    return 0


if __name__ == "__main__":
    sys.exit(main())
