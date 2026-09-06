#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Cribado diario por perfil
=========================================

Clasifica lo que ha entrado nuevo, una vez por cada cliente y con SU
criterio. Complementa al cribado inicial, que se ejecuta en el momento
del alta y recorre todo lo vivo de golpe.

Por qué son dos procesos y no uno:

  · El INICIAL da la experiencia inmediata: al terminar de configurarse,
    el cliente ve sus oportunidades. Son cientos de licitaciones, se
    hace por lotes desde la función de Supabase y muestra progreso,
    porque hay alguien esperando delante de una pantalla.

  · El DIARIO mantiene el servicio: solo mira lo que ha entrado desde
    la última pasada. Son pocas licitaciones por muchos perfiles, y va
    aquí porque no hay nadie esperando.

Y este actúa además de red de seguridad: si el cribado inicial se cortó
a mitad —porque el cliente cerró el navegador—, esta pasada lo termina.
Por eso recorre todo lo pendiente de cada perfil, no solo lo de hoy.

Tres salidas, nunca dos:

    si     -> es una oportunidad
    quizas -> podría serlo; NO se descarta, se muestra igual
    no     -> no lo es

El "quizas" no es indecisión, es diseño. Una llamada al modelo cuesta
céntimos; una oportunidad perdida cuesta un cliente. Ante la duda, el
cribado deja pasar y decide la persona.

Uso:
    python cribador.py                    # todos los perfiles activos
    python cribador.py --perfil <uuid>    # solo uno
    python cribador.py --muestra 20       # prueba, sin guardar nada

Variables de entorno:
    SUPABASE_URL, SUPABASE_KEY   -> obligatorias
    OPENAI_API_KEY               -> obligatoria (salvo en --muestra vacía)
    MODELO_CRIBADO               -> por defecto gpt-4o-mini
    MAX_CRIBADO_POR_PERFIL       -> tope por perfil y pasada (300)
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from collections import Counter
from datetime import datetime, timezone
from typing import Any

# ==============================================================
# 1. CONFIGURACIÓN
# ==============================================================

MODELO = os.environ.get("MODELO_CRIBADO", "gpt-4o-mini")

TABLA_VEREDICTOS = "veredictos"
VISTA_PENDIENTES = "pendientes_por_perfil"

MAX_POR_PERFIL = int(os.environ.get("MAX_CRIBADO_POR_PERFIL", "300"))
TAMANO_LOTE = 50
REINTENTOS = 3
ESPERA_REINTENTO = 4

VEREDICTOS_VALIDOS = {"si", "quizas", "no"}

# El criterio de cada cliente se genera durante su alta y vive en su
# perfil. Aquí solo se le añade el formato de respuesta: mezclar el
# criterio con instrucciones técnicas al generarlo lo haría más difícil
# de leer y de corregir a mano.
FORMATO = """

Devuelve EXCLUSIVAMENTE un objeto JSON, sin texto alrededor ni marcas de
código, con esta forma:
{"veredicto": "si|quizas|no", "motivo": "una frase breve en español"}"""


def configurar_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%H:%M:%S", stream=sys.stdout,
    )


def dividir_en_lotes(elementos, tamano):
    for inicio in range(0, len(elementos), tamano):
        yield elementos[inicio:inicio + tamano]


# ==============================================================
# 2. CONEXIONES
# ==============================================================

def obtener_cliente_supabase():
    from supabase import create_client

    url = os.environ.get("SUPABASE_URL", "").strip().rstrip("/")
    for sufijo in ("/rest/v1", "/rest"):
        if url.endswith(sufijo):
            url = url[: -len(sufijo)].rstrip("/")
    clave = os.environ.get("SUPABASE_KEY", "").strip()

    if not url or not clave:
        logging.error("Faltan SUPABASE_URL o SUPABASE_KEY en los secrets.")
        sys.exit(1)
    try:
        cliente = create_client(url, clave)
        cliente.table("perfiles").select("id").limit(1).execute()
        return cliente
    except Exception as error:
        logging.error("No se pudo conectar con Supabase: %s", error)
        sys.exit(1)


def obtener_cliente_openai():
    from openai import OpenAI

    clave = os.environ.get("OPENAI_API_KEY", "").strip()
    if not clave:
        logging.error("Falta OPENAI_API_KEY en los secrets del repositorio.")
        sys.exit(1)
    return OpenAI(api_key=clave)


# ==============================================================
# 3. CLASIFICACIÓN
# ==============================================================

def construir_mensajes(criterio: str, licitacion: dict[str, Any]) -> list[dict]:
    cpvs = licitacion.get("cpvs") or []
    if isinstance(cpvs, str):
        try:
            cpvs = json.loads(cpvs)
        except json.JSONDecodeError:
            cpvs = [cpvs]

    ficha = [f"Título: {licitacion.get('titulo', '')}"]
    if licitacion.get("organo"):
        ficha.append(f"Órgano: {licitacion['organo']}")
    presupuesto = licitacion.get("presupuesto")
    if presupuesto is not None:
        importe = f"{float(presupuesto):,.2f}".replace(",", "@").replace(".", ",").replace("@", ".")
        ficha.append(f"Presupuesto: {importe} EUR")
    if cpvs:
        ficha.append(f"CPV: {', '.join(str(c) for c in cpvs[:8])}")

    return [
        {"role": "system", "content": criterio + FORMATO},
        {"role": "user", "content": "\n".join(ficha)},
    ]


def clasificar(cliente_ia, criterio: str, licitacion: dict) -> dict | None:
    """
    Pide un veredicto para una licitación, con el criterio de su cliente.

    Devuelve None si tras los reintentos no hay respuesta válida. Un
    fallo puntual no debe tumbar la pasada: esa licitación se queda sin
    veredicto y se reintenta mañana, que es exactamente lo que hace
    falta que pase.
    """
    espera = ESPERA_REINTENTO
    for intento in range(1, REINTENTOS + 1):
        try:
            respuesta = cliente_ia.chat.completions.create(
                model=MODELO,
                messages=construir_mensajes(criterio, licitacion),
                response_format={"type": "json_object"},
                temperature=0, max_tokens=150,
            )
            datos = json.loads((respuesta.choices[0].message.content or "").strip())
            veredicto = str(datos.get("veredicto", "")).strip().lower()
            if veredicto not in VEREDICTOS_VALIDOS:
                raise ValueError(f"veredicto no reconocido: {veredicto!r}")
            return {"veredicto": veredicto,
                    "motivo": str(datos.get("motivo", "")).strip()[:300]}

        except json.JSONDecodeError as error:
            logging.warning("Respuesta no interpretable (%d/%d): %s",
                            intento, REINTENTOS, error)
        except Exception as error:
            logging.warning("Error del modelo (%d/%d): %s",
                            intento, REINTENTOS, error)

        if intento < REINTENTOS:
            time.sleep(espera)
            espera *= 2

    logging.error("Sin veredicto tras %d intentos: %s",
                  REINTENTOS, licitacion.get("titulo", "")[:70])
    return None


# ==============================================================
# 4. LECTURA Y ESCRITURA
# ==============================================================

def leer_perfiles(cliente, solo: str | None) -> list[dict]:
    """Perfiles activos que ya tienen criterio. Sin criterio no hay nada que aplicar."""
    try:
        consulta = (cliente.table("perfiles")
                    .select("id, nombre, criterio, criterio_version")
                    .eq("activo", True).not_.is_("criterio", "null"))
        if solo:
            consulta = consulta.eq("id", solo)
        return consulta.execute().data or []
    except Exception as error:
        logging.error("No se pudieron leer los perfiles: %s", error)
        sys.exit(1)


def leer_pendientes(cliente, perfil_id: str, limite: int) -> list[dict]:
    """
    Lo que le falta clasificar a este perfil.

    Va por función y no por vista: la vista calculaba la cola de TODOS
    los perfiles y filtraba después, y con 220.000 licitaciones eso
    agotaba el tiempo de consulta. La función acota por perfil antes de
    recorrer nada.
    """
    try:
        respuesta = cliente.rpc("pendientes_de_perfil",
                                {"perfil": perfil_id, "tope": limite}).execute()
        return respuesta.data or []
    except Exception as error:
        logging.error("No se pudo leer la cola del perfil: %s", error)
        return []


def guardar_veredictos(cliente, resultados: list[dict]) -> int:
    """
    Escribe los veredictos.

    Se usa `upsert` sobre la clave compuesta (licitación, perfil): si dos
    pasadas se solapan, la segunda actualiza en vez de reventar con un
    error de clave duplicada.
    """
    if not resultados:
        return 0

    ahora = datetime.now(timezone.utc).isoformat()
    filas = [
        {
            "id_licitacion": r["id_licitacion"],
            "perfil_id": r["perfil_id"],
            "veredicto": r["veredicto"],
            "motivo": r["motivo"],
            "criterio_version": r["criterio_version"],
            "modelo": MODELO,
            "fecha": ahora,
        }
        for r in resultados
    ]

    guardados = 0
    for lote in dividir_en_lotes(filas, TAMANO_LOTE):
        try:
            (cliente.table(TABLA_VEREDICTOS)
             .upsert(list(lote), on_conflict="id_licitacion,perfil_id")
             .execute())
            guardados += len(lote)
        except Exception as error:
            logging.error("Fallo al guardar un lote de %d: %s", len(lote), error)

    return guardados


# ==============================================================
# 5. INFORME
# ==============================================================

def publicar_informe(por_perfil: dict[str, Counter], fallos: int) -> None:
    total = sum(sum(c.values()) for c in por_perfil.values())

    logging.info("--- RESUMEN ---")
    for nombre, reparto in por_perfil.items():
        n = sum(reparto.values())
        logging.info("  %-28s %4d  ·  sí %d · quizás %d · no %d",
                     nombre[:28], n, reparto.get("si", 0),
                     reparto.get("quizas", 0), reparto.get("no", 0))
    if fallos:
        logging.warning("  %d licitaciones sin veredicto. Se reintentarán mañana.", fallos)

    ruta = os.environ.get("GITHUB_STEP_SUMMARY")
    if not ruta or not total:
        return
    try:
        with open(ruta, "a", encoding="utf-8") as fichero:
            fichero.write(f"\n## Cribado diario ({MODELO})\n\n")
            fichero.write("| Perfil | Clasificadas | Sí | Quizás | No |\n|---|---|---|---|---|\n")
            for nombre, reparto in por_perfil.items():
                fichero.write(f"| {nombre.replace('|', '/')} | {sum(reparto.values())} | "
                              f"{reparto.get('si', 0)} | {reparto.get('quizas', 0)} | "
                              f"{reparto.get('no', 0)} |\n")
    except OSError as error:
        logging.warning("No se pudo escribir el informe: %s", error)


# ==============================================================
# 6. ORQUESTACIÓN
# ==============================================================

def main() -> int:
    argumentos = argparse.ArgumentParser(
        description="State Scraper · Cribado diario por perfil."
    )
    argumentos.add_argument("--perfil", help="UUID de un perfil concreto.")
    argumentos.add_argument("--muestra", type=int, metavar="N",
                            help="Clasifica N por perfil y las imprime SIN guardar.")
    argumentos.add_argument("--limite", type=int, metavar="N",
                            help="Tope de clasificaciones por perfil.")
    opciones = argumentos.parse_args()

    configurar_logging()
    es_prueba = opciones.muestra is not None
    limite = min(opciones.muestra or opciones.limite or MAX_POR_PERFIL, MAX_POR_PERFIL)

    logging.info("=" * 62)
    logging.info("CRIBADO DIARIO POR PERFIL · modelo %s", MODELO)
    logging.info("Modo: %s | Tope por perfil: %d",
                 "PRUEBA (no guarda)" if es_prueba else "normal", limite)
    logging.info("=" * 62)

    cliente = obtener_cliente_supabase()
    perfiles = leer_perfiles(cliente, opciones.perfil)

    if not perfiles:
        logging.info("No hay perfiles activos con criterio. Nada que hacer.")
        return 0

    logging.info("Perfiles a procesar: %d", len(perfiles))
    cliente_ia = None
    por_perfil: dict[str, Counter] = {}
    fallos = 0
    guardados_total = 0

    for perfil in perfiles:
        pendientes = leer_pendientes(cliente, perfil["id"], limite)
        if not pendientes:
            logging.info("[%s] Sin novedades que clasificar.", perfil["nombre"])
            continue

        logging.info("[%s] %d pendientes.", perfil["nombre"], len(pendientes))
        if cliente_ia is None:
            cliente_ia = obtener_cliente_openai()

        resultados: list[dict] = []
        reparto = Counter()

        for indice, licitacion in enumerate(pendientes, 1):
            veredicto = clasificar(cliente_ia, perfil["criterio"], licitacion)
            if veredicto is None:
                fallos += 1
                continue

            reparto[veredicto["veredicto"]] += 1
            resultados.append({
                "id_licitacion": licitacion["id_licitacion"],
                "perfil_id": perfil["id"],
                "criterio_version": perfil.get("criterio_version"),
                **veredicto,
            })

            if es_prueba or indice % 50 == 0:
                logging.info("  [%3d/%d] %-6s · %s", indice, len(pendientes),
                             veredicto["veredicto"],
                             licitacion.get("titulo", "")[:70])

        por_perfil[perfil["nombre"]] = reparto

        if not es_prueba:
            guardados = guardar_veredictos(cliente, resultados)
            guardados_total += guardados
            if resultados and guardados == 0:
                logging.error("[%s] Se clasificaron %d y no se guardó ninguna.",
                              perfil["nombre"], len(resultados))

    publicar_informe(por_perfil, fallos)

    if es_prueba:
        logging.info("MODO PRUEBA: no se ha guardado nada.")
        return 0

    clasificadas = sum(sum(c.values()) for c in por_perfil.values())
    logging.info("Guardados %d de %d veredictos.", guardados_total, clasificadas)

    # Si se clasificó y no se guardó nada, la ejecución DEBE fallar: un
    # resumen tranquilizador sobre un guardado fallido es peor que un
    # error, porque el trabajo se pierde y nadie se entera.
    if clasificadas and guardados_total == 0:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
