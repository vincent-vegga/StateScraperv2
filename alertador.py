#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
STATE SCRAPER · Paso 5 — Alerta diaria
======================================

Envía por correo las oportunidades que el robot ha detectado en su última
pasada. Cierra el circuito: leer, filtrar, cribar y avisar.

Dos decisiones que gobiernan este paso:

  · SOLO SI HAY NOVEDADES. Un correo diario que a veces dice "hoy no hay
    nada" acaba en la papelera sin abrir, y con él los días en que sí
    había algo. El silencio también informa.

  · LOS PLAZOS DE LA CARTERA también son novedad. Lo que el cliente lleva
    como "Me interesa" o "Preparo la oferta" se le recuerda 7, 3 y 1 día
    antes de que cierre (Decisión 53). Es una tarea con fecha, así que
    justifica el correo aunque ese día no haya contratos nuevos.

  · LO QUE SIGUE (Decisión 56). La nueva licitación de un contrato que
    vigila en "Lo que viene" y lo que publican en su ramo los organismos
    que sigue son licitaciones abiertas: cuentan como novedad. Lo que
    gana la competencia no caduca: va con lo demás y, si no hay nada
    más, en un resumen como mucho semanal.

  · NOVEDAD ES LO DE LA ÚLTIMA PASADA, no lo de hoy según el calendario.
    Si el robot se cae un día, al volver detecta lo acumulado y todo eso
    se envía. Así no se pierde ninguna oportunidad por una avería. Es la
    misma definición que usa la web, para que nadie reciba por correo
    algo que ya vio marcado como nuevo en la página.

Uso:
    python alertador.py                # envía si hay novedades
    python alertador.py --simulacro    # muestra el correo, NO lo envía

Variables de entorno:
    SUPABASE_URL, SUPABASE_KEY   -> obligatorias
    RESEND_API_KEY               -> obligatoria (salvo en simulacro)
    REMITENTE_ALERTA             -> por defecto onboarding@resend.dev
    URL_INTERFAZ                 -> enlace a la web que se incluye
    HORAS_NOVEDAD                -> ventana de novedad (por defecto 26)
"""

from __future__ import annotations

import argparse
import html
import json
import logging
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

# ==============================================================
# 1. CONFIGURACIÓN
# ==============================================================

API_RESEND = "https://api.resend.com/emails"

REMITENTE = os.environ.get("REMITENTE_ALERTA", "onboarding@resend.dev")
URL_INTERFAZ = os.environ.get(
    "URL_INTERFAZ", "https://statescraper.com"
)
# La pestaña de la cartera: la web la abre al entrar con este ancla.
URL_CARTERA = URL_INTERFAZ.rstrip("/") + "/#cartera"
# Holgura sobre la última detección. Una pasada tarda minutos, no horas,
# pero el margen absorbe ejecuciones que se solapen o se retrasen.
# Ventana de novedad. Mayor que un día a propósito: el cron de GitHub
# Actions se retrasa con frecuencia, y repetir una licitación un día es
# mucho menos grave que perderla por un arranque tardío.
HORAS_NOVEDAD = int(os.environ.get("HORAS_NOVEDAD", "26"))

PROVINCIAS: dict[str, str] = {
    "01": "Álava", "02": "Albacete", "03": "Alicante", "04": "Almería",
    "05": "Ávila", "06": "Badajoz", "07": "Illes Balears", "08": "Barcelona",
    "09": "Burgos", "10": "Cáceres", "11": "Cádiz", "12": "Castellón",
    "13": "Ciudad Real", "14": "Córdoba", "15": "A Coruña", "16": "Cuenca",
    "17": "Girona", "18": "Granada", "19": "Guadalajara", "20": "Gipuzkoa",
    "21": "Huelva", "22": "Huesca", "23": "Jaén", "24": "León",
    "25": "Lleida", "26": "La Rioja", "27": "Lugo", "28": "Madrid",
    "29": "Málaga", "30": "Murcia", "31": "Navarra", "32": "Ourense",
    "33": "Asturias", "34": "Palencia", "35": "Las Palmas",
    "36": "Pontevedra", "37": "Salamanca", "38": "S. C. de Tenerife",
    "39": "Cantabria", "40": "Segovia", "41": "Sevilla", "42": "Soria",
    "43": "Tarragona", "44": "Teruel", "45": "Toledo", "46": "Valencia",
    "47": "Valladolid", "48": "Bizkaia", "49": "Zamora", "50": "Zaragoza",
    "51": "Ceuta", "52": "Melilla",
}


def configurar_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stdout,
    )


# ==============================================================
# 2. LECTURA
# ==============================================================

def obtener_cliente():
    from supabase import create_client

    url = os.environ.get("SUPABASE_URL", "").strip().rstrip("/")
    for sufijo in ("/rest/v1", "/rest"):
        if url.endswith(sufijo):
            url = url[: -len(sufijo)].rstrip("/")
    clave = os.environ.get("SUPABASE_KEY", "").strip()

    if not url or not clave:
        logging.error("Faltan SUPABASE_URL o SUPABASE_KEY.")
        sys.exit(1)
    try:
        return create_client(url, clave)
    except Exception as error:
        logging.error("No se pudo conectar con Supabase: %s", error)
        sys.exit(1)


# Los plazos españoles se publican en hora peninsular. Asumir UTC cuando
# falta la zona desplaza un vencimiento de las 23:59 al día siguiente.
try:
    from zoneinfo import ZoneInfo
    ZONA_ESPANA = ZoneInfo("Europe/Madrid")
except Exception:
    ZONA_ESPANA = timezone.utc


def a_fecha(valor: str | None) -> datetime | None:
    if not valor:
        return None
    try:
        fecha = datetime.fromisoformat(valor.replace("Z", "+00:00"))
    except ValueError:
        return None
    return fecha if fecha.tzinfo else fecha.replace(tzinfo=ZONA_ESPANA)


def clientes_a_avisar(cliente) -> list[dict]:
    """
    Perfiles activos con correo y filtro listo.

    Antes había una lista fija de direcciones en los secrets, herencia de
    cuando el destinatario era uno solo. Con clientes de verdad cada uno
    recibe LO SUYO, así que la lista sale de la base.
    """
    try:
        respuesta = cliente.rpc("perfiles_con_novedades",
                                {"horas": HORAS_NOVEDAD}).execute()
        return respuesta.data or []
    except Exception as error:
        logging.error("No se pudo leer la lista de clientes: %s", error)
        sys.exit(1)


def novedades_de_seguimiento(cliente, perfil_id: str) -> dict:
    """
    Lo que hay que contar de lo que sigue y aún no se le ha contado
    (Decisión 56): lo que han ganado las empresas que sigue, lo que han
    publicado en su ramo los organismos que sigue y la nueva licitación
    de los contratos que vigila en "Lo que viene".

    Un fallo aquí no tumba el correo de novedades: sin la función en la
    base simplemente no hay nada de esto.
    """
    try:
        respuesta = cliente.rpc("novedades_de_seguimiento",
                                {"perfil": perfil_id}).execute()
        return respuesta.data or {}
    except Exception as error:
        logging.warning("No se pudo leer lo que sigue: %s", error)
        return {}


def marcar_avisos_seguimiento(cliente, perfil_id: str, avisos: list[dict]) -> None:
    """
    Deja constancia de lo ya contado, para no repetirlo mañana. Solo se
    llama si el correo ha salido.
    """
    if not avisos:
        return
    try:
        cliente.rpc("marcar_avisos_seguimiento",
                    {"perfil": perfil_id, "avisos": avisos}).execute()
    except Exception as error:
        logging.error("No se pudo marcar lo avisado de lo que sigue: %s", error)


def novedades(cliente, perfil_id: str) -> list[dict]:
    """
    Lo que ha entrado para este cliente desde la última pasada.

    La ventana es algo mayor que un día para absorber los retrasos del
    cron, que no es puntual. Es preferible repetir una licitación un día
    a que se pierda por un arranque tardío.
    """
    try:
        respuesta = cliente.rpc("novedades_de_perfil",
                                {"perfil": perfil_id,
                                 "horas": HORAS_NOVEDAD}).execute()
        return respuesta.data or []
    except Exception as error:
        logging.error("No se pudieron leer las novedades del perfil: %s", error)
        return []


# A cuántos días del cierre se recuerda un plazo de la cartera. Como
# Licitandum: una semana para organizarse, tres días para cerrar la
# oferta y la víspera. Más avisos serían ruido; uno solo, poco margen.
DIAS_AVISO_PLAZO = (7, 3, 1)

# Lo que gana la competencia, cuando no hay nada más que contar, sale
# como mucho una vez cada tantos días (Decisión 56).
DIAS_RESUMEN_COMPETENCIA = 7
# Tope de licitaciones de lo que sigue por correo, por si un organismo
# grande publica muchas el mismo día. Lo que no cabe sale al día siguiente.
MAX_SEGUIMIENTO = 30


def dias_para(limite: str | None) -> int | None:
    """
    Días de calendario peninsular hasta el plazo, o None si ya pasó.

    Un plazo a las 00:00 en punto es el final del día anterior (casi
    siempre el organismo publicó solo la fecha), igual que en la web: si
    no, "mañana" sería en realidad "esta noche".
    """
    fecha = a_fecha(limite)
    if not fecha:
        return None
    ahora = datetime.now(timezone.utc)
    if fecha < ahora:
        return None
    local = fecha.astimezone(ZONA_ESPANA)
    if local.hour == 0 and local.minute == 0:
        local -= timedelta(minutes=1)
    return (local.date() - ahora.astimezone(ZONA_ESPANA).date()).days


def plazos_de_cartera(cliente, perfil_id: str) -> list[dict]:
    """
    Lo de su cartera cuyo plazo cierra justo dentro de 7, 3 o 1 día.

    Un fallo aquí no tumba el correo de novedades: sin la función en la
    base (la migración aún no aplicada) simplemente no hay plazos.
    """
    try:
        respuesta = cliente.rpc("plazos_de_cartera", {"perfil": perfil_id}).execute()
    except Exception as error:
        logging.warning("No se pudieron leer los plazos de la cartera: %s", error)
        return []
    plazos = []
    for it in respuesta.data or []:
        dias = dias_para(it.get("fecha_limite"))
        if dias in DIAS_AVISO_PLAZO:
            plazos.append({**it, "dias": dias})
    return plazos


# ==============================================================
# 3. EL CORREO
# ==============================================================

ESTADO_CARTERA = {"interesa": "Te interesa", "preparando": "Preparas la oferta"}


def cuando_cierra(dias: int) -> str:
    return "mañana" if dias == 1 else f"en {dias} días"


def hasta(limite: str | None) -> str:
    """
    "hasta el 07/10 a las 14:00", o "hasta el 08/10 a medianoche" para un
    plazo a las 00:00: "el 09/10 a las 00:00" se leía como que quedaba
    todo el día 9.
    """
    fecha = a_fecha(limite)
    if not fecha:
        return ""
    local = fecha.astimezone(ZONA_ESPANA)
    if local.hour == 0 and local.minute == 0:
        return f"hasta el {(local - timedelta(minutes=1)).strftime('%d/%m')} a medianoche"
    return f"hasta el {local.strftime('%d/%m a las %H:%M')}"


def euros(valor) -> str:
    if valor is None:
        return "sin importe publicado"
    entero = f"{float(valor):,.0f}".replace(",", ".")
    return f"{entero} €"


def dias_restantes(limite: str | None) -> str:
    """Días restantes y hora exacta de cierre, en hora peninsular."""
    fecha = a_fecha(limite)
    if not fecha:
        return "sin plazo publicado"
    local = fecha.astimezone(ZONA_ESPANA)
    ahora = datetime.now(timezone.utc)
    cuando = local.strftime("%d/%m a las %H:%M")
    if fecha < ahora:
        return f"vencido ({cuando})"
    # Días de CALENDARIO peninsular, no tramos de 24 horas. Con `.days`,
    # un plazo de mañana a las 10:00 leído hoy a mediodía daba 0 y el
    # correo decía "vence hoy, 10:00": alguien podía dar por perdido un
    # contrato que aún estaba a tiempo de presentar.
    dias = (local.date() - ahora.astimezone(ZONA_ESPANA).date()).days
    if dias == 0:
        return f"vence hoy, {local.strftime('%H:%M')}"
    plazo = "queda 1 día" if dias == 1 else f"quedan {dias} días"
    return f"{plazo} · hasta el {cuando}"


# Algunos órganos, sobre todo catalanes, ponen como título el encabezado
# entero del pliego: un párrafo con el objeto, los fines y hasta los
# objetivos del contrato. En una lista se lee mal; en un correo, peor.
_ARRANQUES = (
    "l'objecte del present contracte és la prestació del servei de",
    "l'objecte del present contracte és la prestació de",
    "l'objecte del present contracte és el",
    "l'objecte del present contracte és la",
    "l'objecte d'aquest contracte el constitueix el",
    "l'objecte d'aquest contracte és",
    "el present contracte té per objecte la prestació de",
    "el present contracte té per objecte",
    "es objeto del presente contrato la prestación del servicio de",
    "es objeto del presente contrato la",
    "es objeto del presente contrato el",
    "el objeto del presente contrato es la prestación de",
    "el objeto del presente contrato es",
    "constituye el objeto del presente contrato la",
    "constituye el objeto del presente contrato",
)
LARGO_MAXIMO = 130


def acortar(titulo: str) -> str:
    """
    Deja el título en algo legible sin perder de qué va el contrato.

    Primero quita el preámbulo jurídico ("l'objecte del present contracte
    és..."), que no aporta nada y se repite igual en todos. Después corta
    por la primera frase, y si aún es largo, por palabra entera.
    """
    limpio = " ".join((titulo or "").split())
    bajo = limpio.lower()
    # Se prueban de más largo a más corto, y el prefijo debe terminar en
    # límite de palabra: si no, "la prestació de" recortaba dentro de "la
    # prestació dels serveis" y se comía una letra.
    for arranque in sorted(_ARRANQUES, key=len, reverse=True):
        if not bajo.startswith(arranque):
            continue
        siguiente = limpio[len(arranque):len(arranque) + 1]
        if siguiente and siguiente not in " :,;":
            continue
        limpio = limpio[len(arranque):].lstrip(" :,;")
        if limpio:
            limpio = limpio[0].upper() + limpio[1:]
        break

    if len(limpio) <= LARGO_MAXIMO:
        return limpio

    # Cortar por el final de la primera frase, si cae en un sitio razonable.
    punto = limpio.find(". ")
    if 40 <= punto <= LARGO_MAXIMO:
        return limpio[:punto + 1]

    corte = limpio[:LARGO_MAXIMO].rsplit(" ", 1)[0]
    return corte.rstrip(" ,;:.") + "…"


def acortar_a(titulo: str, largo: int) -> str:
    """El título ya limpio, cortado por palabra entera para un asunto."""
    limpio = acortar(titulo)
    if len(limpio) <= largo:
        return limpio
    return limpio[:largo].rsplit(" ", 1)[0].rstrip(" ,;:.") + "…"


def provincia_de(codigo_postal: str | None) -> str:
    cp = "".join(c for c in (codigo_postal or "") if c.isdigit())
    if len(cp) == 4:
        cp = "0" + cp
    return PROVINCIAS.get(cp[:2], "") if len(cp) >= 2 else ""


def componer(items: list[dict], seguidas: list[dict] | None = None,
             empresa: str = "", plazos: list[dict] | None = None,
             organismos: list[dict] | None = None,
             vigilados: list[dict] | None = None) -> tuple[str, str, str]:
    """
    Devuelve (asunto, cuerpo HTML, cuerpo en texto plano).

    Se envían las dos versiones: hay clientes de correo que no muestran
    HTML, y un mensaje que llega en blanco es peor que no llegar.

    `seguidas` son adjudicaciones ganadas por empresas que el cliente
    sigue. Van en el mismo correo y no en uno aparte: dos correos al día
    del mismo remitente se convierten en uno que se ignora.

    `plazos` son contratos de su cartera a punto de cerrar. Van arriba:
    son lo único del correo que caduca en días.

    `vigilados` son nuevas licitaciones de contratos que vigila en "Lo que
    viene", y `organismos`, lo que han publicado en su ramo los organismos
    que sigue (Decisión 56). Son licitaciones abiertas, como las novedades.
    """
    seguidas = seguidas or []
    plazos = plazos or []
    organismos = organismos or []
    vigilados = vigilados or []
    n = len(items)

    if plazos and not (n or vigilados or organismos):
        # El asunto dice cuál y cuándo: es lo que hace abrirlo.
        if len(plazos) == 1:
            p = plazos[0]
            asunto = (f"Cierra {cuando_cierra(p['dias'])}: "
                      f"{acortar_a(p.get('titulo') or '', 70)}")
        else:
            asunto = f"{len(plazos)} plazos de tu cartera cierran pronto"
    elif vigilados:
        # Lo más concreto: un contrato que esperaba ha vuelto a salir.
        if len(vigilados) == 1:
            asunto = ("Ya ha salido la nueva licitación de un contrato que vigilas"
                      if vigilados[0].get("seguro") else
                      "Puede haber salido la nueva licitación de un contrato que vigilas")
        else:
            asunto = f"{len(vigilados)} licitaciones nuevas de contratos que vigilas"
        if n:
            asunto += (" · 1 contrato nuevo para ti" if n == 1
                       else f" · {n} contratos nuevos para ti")
    elif n and seguidas:
        asunto = (f"{n} {'contrato nuevo' if n == 1 else 'contratos nuevos'} "
                  f"y movimientos de tu competencia")
    elif n:
        asunto = (f"{n} contrato nuevo para ti" if n == 1
                  else f"{n} contratos nuevos para ti")
    elif organismos:
        asunto = ("Un organismo que sigues ha publicado un contrato de tu sector"
                  if len(organismos) == 1 else
                  f"{len(organismos)} contratos nuevos de organismos que sigues")
    else:
        asunto = ("Tu competencia ha ganado un contrato" if len(seguidas) == 1
                  else f"Tu competencia ha ganado {len(seguidas)} contratos")
    if plazos and (n or vigilados or organismos):
        asunto += (" · 1 plazo de tu cartera cierra pronto" if len(plazos) == 1
                   else f" · {len(plazos)} plazos de tu cartera cierran pronto")

    # ---- Los plazos de su cartera ----
    bloque_plazos_html = bloque_plazos_texto = ""
    enlace_cartera_html = (f'<p style="margin:14px 0 0;font-size:14px;">'
                           f'<a href="{html.escape(URL_CARTERA)}" style="color:#17171A;">'
                           f'Ver tu cartera</a></p>')
    if plazos:
        filas = []
        for it in plazos:
            titulo = acortar(it.get("titulo") or "") or "(sin título)"
            organo = it.get("organo") or ""
            cierra = hasta(it.get("fecha_limite"))
            estado = ESTADO_CARTERA.get(it.get("estado") or "", "")
            enlace = it.get("enlace") or URL_CARTERA
            urge = it["dias"] == 1
            filas.append(f"""
            <tr><td style="padding:16px 0;border-bottom:1px solid #E4E2DD;">
              <div style="color:{'#B65347' if urge else '#17171A'};font-size:13px;font-weight:600;">
                Cierra {cuando_cierra(it['dias'])} · {html.escape(estado)}</div>
              <a href="{html.escape(enlace, quote=True)}"
                 style="color:#17171A;font-size:15px;font-weight:600;text-decoration:none;
                        line-height:1.45;display:block;margin-top:4px;">{html.escape(titulo)}</a>
              <div style="color:#6E6E75;font-size:13px;margin-top:5px;">
                {html.escape(organo)} · {html.escape(cierra)}</div>
            </td></tr>""")
            bloque_plazos_texto += (
                f"- Cierra {cuando_cierra(it['dias'])} ({estado.lower()}): {titulo}\n"
                f"  {organo} · {cierra}\n"
                f"  {enlace}\n"
            )
        bloque_plazos_html = f"""
    <tr><td style="padding-top:18px;">
      <h2 style="margin:0 0 4px;font-size:16px;font-weight:600;color:#17171A;">
        Plazos de tu cartera</h2>
      <p style="margin:0 0 4px;color:#6E6E75;font-size:14px;line-height:1.6;">
        Contratos que guardaste y cuyo plazo para presentar oferta termina pronto.</p>
      <table width="100%" cellpadding="0" cellspacing="0">{''.join(filas)}</table>
      {enlace_cartera_html}
    </td></tr>"""
        bloque_plazos_texto = ("PLAZOS DE TU CARTERA\n\n" + bloque_plazos_texto
                               + f"\nVer tu cartera: {URL_CARTERA}\n\n")

    filas_html, filas_texto = [], []
    for it in items:
        # Se escapa UNA sola vez, al insertar en la plantilla. Escapar el
        # órgano aquí y el contexto después convertía "X & Y" en
        # "X &amp;amp; Y" en el correo.
        titulo = acortar(it.get("titulo") or "") or "(sin título)"
        organo = it.get("organo") or ""
        prov = provincia_de(it.get("codigo_postal"))
        plazo = dias_restantes(it.get("fecha_limite"))
        importe = euros(it.get("presupuesto"))
        enlace = it.get("enlace") or URL_INTERFAZ
        contexto = " · ".join(x for x in (organo, prov) if x)

        filas_html.append(f"""
        <tr><td style="padding:20px 0;border-bottom:1px solid #E4E2DD;">
          <a href="{html.escape(enlace, quote=True)}"
             style="color:#17171A;font-size:16px;font-weight:600;
                    text-decoration:none;line-height:1.45;">{html.escape(titulo)}</a>
          <div style="color:#6E6E75;font-size:14px;margin-top:6px;">{html.escape(contexto)}</div>
          <div style="color:#17171A;font-size:14px;margin-top:8px;">
            <strong>{importe}</strong>
            <span style="color:#6E6E75;">· {plazo}</span>
          </div>
        </td></tr>""")

        # La versión en texto NO se escapa: no es HTML.
        filas_texto.append(
            f"- {titulo}\n"
            f"  {contexto}\n"
            f"  {importe} · {plazo}\n"
            f"  {enlace}\n"
        )

    # ---- Licitaciones abiertas de lo que sigue ----
    #
    # Una fila como las de las novedades, con una línea encima que dice
    # por qué sale (de qué contrato vigilado viene, o de qué organismo).
    def fila_abierta(it: dict, encima: str, encima_color: str = "#6E6E75") -> tuple[str, str]:
        titulo = acortar(it.get("titulo") or "") or "(sin título)"
        organo = it.get("organo") or ""
        prov = provincia_de(it.get("codigo_postal"))
        contexto = " · ".join(x for x in (organo, prov) if x)
        enlace = it.get("enlace") or URL_INTERFAZ
        importe = euros(it.get("presupuesto"))
        plazo = dias_restantes(it.get("fecha_limite"))
        linea_encima = (f'<div style="color:{encima_color};font-size:13px;line-height:1.5;'
                        f'margin-bottom:4px;">{html.escape(encima)}</div>') if encima else ""
        fila_html = f"""
            <tr><td style="padding:16px 0;border-bottom:1px solid #E4E2DD;">
              {linea_encima}
              <a href="{html.escape(enlace, quote=True)}"
                 style="color:#17171A;font-size:15px;font-weight:600;text-decoration:none;
                        line-height:1.45;display:block;">{html.escape(titulo)}</a>
              <div style="color:#6E6E75;font-size:13px;margin-top:5px;">{html.escape(contexto)}</div>
              <div style="color:#17171A;font-size:14px;margin-top:6px;">
                <strong>{importe}</strong>
                <span style="color:#6E6E75;">· {plazo}</span>
              </div>
            </td></tr>"""
        fila_texto = ((f"- {encima}\n  {titulo}\n" if encima else f"- {titulo}\n")
                      + f"  {contexto}\n  {importe} · {plazo}\n  {enlace}\n")
        return fila_html, fila_texto

    def seccion(titulo: str, guia: str, filas: list[str], arriba: str = "30px") -> str:
        return f"""
    <tr><td style="padding-top:{arriba};">
      <h2 style="margin:0 0 4px;font-size:16px;font-weight:600;color:#17171A;">
        {titulo}</h2>
      <p style="margin:0 0 4px;color:#6E6E75;font-size:14px;line-height:1.6;">
        {guia}</p>
      <table width="100%" cellpadding="0" cellspacing="0">{''.join(filas)}</table>
    </td></tr>"""

    # Lo vigilado: lo seguro dice que es la nueva; lo posible, que puede
    # serlo. Nunca se afirma lo que no se ha emparejado (Decisión 52).
    bloque_vigilados_html = bloque_vigilados_texto = ""
    if vigilados:
        filas, texto = [], ""
        for it in vigilados:
            antes = acortar_a(it.get("anterior_titulo") or "", 90) or "un contrato que vigilas"
            if it.get("seguro"):
                encima = f"Nueva licitación de «{antes}»"
            else:
                encima = (f"Mismo organismo y mismo tipo de contrato: puede ser "
                          f"la nueva licitación de «{antes}»")
            h, t = fila_abierta(it, encima, "#17171A" if it.get("seguro") else "#6E6E75")
            filas.append(h)
            texto += t
        bloque_vigilados_html = seccion(
            "Contratos que vigilas",
            "Contratos que guardaste en «Lo que viene» y que han vuelto a licitarse.",
            filas, "30px" if plazos else "18px")
        bloque_vigilados_texto = "CONTRATOS QUE VIGILAS\n\n" + texto + "\n"

    bloque_organismos_html = bloque_organismos_texto = ""
    if organismos:
        filas, texto = [], ""
        for it in organismos:
            # El órgano ya va debajo del título: encima no hace falta nada.
            h, t = fila_abierta(it, "")
            filas.append(h)
            texto += t
        bloque_organismos_html = seccion(
            "De los organismos que sigues",
            "Contratos de tu sector publicados por organismos que sigues, "
            "aunque no estén entre los que te elegimos.",
            filas)
        bloque_organismos_texto = ("\nDE LOS ORGANISMOS QUE SIGUES\n\n" + texto)

    # ---- Lo que ha ganado la competencia ----
    #
    # Debajo de las oportunidades: lo primero es a qué puede presentarse
    # él; esto es contexto de mercado, no una tarea. Por empresa: un rival
    # grande gana varios a la semana, y uno debajo de otro taparían el
    # resto. Las tres de más importe de cada una y cuántas más.
    bloque_seguidas_html = bloque_seguidas_texto = ""
    if seguidas:
        por_empresa: dict[str, list[dict]] = {}
        for it in seguidas:
            por_empresa.setdefault(it.get("cif") or it.get("empresa") or "?", []).append(it)
        grupos = sorted(por_empresa.values(),
                        key=lambda g: (-len(g), -sum(float(x.get("importe") or 0) for x in g)))
        MAX_EMPRESAS, MAX_CONTRATOS = 8, 3
        filas = []
        for grupo in grupos[:MAX_EMPRESAS]:
            quien = grupo[0].get("empresa") or "?"
            cuantos = (f"{len(grupo)} contrato" if len(grupo) == 1
                       else f"{len(grupo)} contratos")
            mejores = sorted(grupo, key=lambda x: -float(x.get("importe") or 0))[:MAX_CONTRATOS]
            lineas_html, lineas_texto = [], ""
            for it in mejores:
                titulo = acortar(it.get("titulo") or "") or "(sin título)"
                organo = it.get("organo") or ""
                importe = euros(it.get("importe"))
                enlace = it.get("enlace") or URL_INTERFAZ
                lineas_html.append(f"""
                <a href="{html.escape(enlace, quote=True)}"
                   style="color:#17171A;font-size:15px;text-decoration:none;
                          line-height:1.45;display:block;margin-top:8px;">{html.escape(titulo)}</a>
                <div style="color:#6E6E75;font-size:13px;margin-top:3px;">
                  {html.escape(organo)} · <strong style="color:#17171A;">{importe}</strong></div>""")
                lineas_texto += f"  · {titulo}\n    {organo} · {importe}\n    {enlace}\n"
            resto = len(grupo) - len(mejores)
            mas = (f'<div style="color:#6E6E75;font-size:13px;margin-top:8px;">'
                   f'y {resto} más</div>') if resto else ""
            filas.append(f"""
            <tr><td style="padding:16px 0;border-bottom:1px solid #E4E2DD;">
              <div style="color:#17171A;font-size:14px;font-weight:600;">
                {html.escape(quien)} <span style="color:#6E6E75;font-weight:400;">· {cuantos}</span></div>
              {''.join(lineas_html)}{mas}
            </td></tr>""")
            bloque_seguidas_texto += (f"- {quien} · {cuantos}\n{lineas_texto}"
                                      + (f"  y {resto} más\n" if resto else ""))
        otras = len(grupos) - MAX_EMPRESAS
        guia = "Adjudicaciones de las empresas que sigues desde el último aviso."
        if otras > 0:
            guia += f" Y {otras} empresas más: las ves en su ficha."
        bloque_seguidas_html = seccion("Lo que ha ganado tu competencia", guia, filas)
        bloque_seguidas_texto = (
            "\nLO QUE HA GANADO TU COMPETENCIA\n"
            "(empresas que sigues, desde el último aviso)\n\n" + bloque_seguidas_texto)

    # Las partes que dependen de si hay una cosa u otra se preparan aquí:
    # meterlas dentro de la plantilla con condicionales la vuelve
    # ilegible.
    intro_html = ""
    lista_html = ""
    # Con algo delante (plazos o vigilados), las novedades llevan su propio
    # título: si no, la frase de arriba parecía hablar de lo de arriba.
    hay_antes = bool(plazos or vigilados)
    if items:
        quien = html.escape(empresa) if empresa else "tu negocio"
        intro_html = (
            '<p style="margin:0 0 8px;color:#6E6E75;font-size:15px;'
            'line-height:1.6;">Licitaciones abiertas que encajan con '
            f'{quien}, detectadas esta madrugada.</p>'
        )
        titulo_lista = ('<h2 style="margin:0 0 4px;font-size:16px;font-weight:600;'
                        'color:#17171A;">Contratos nuevos</h2>') if hay_antes else ""
        if hay_antes:
            # La frase va con su lista, debajo de lo de arriba.
            titulo_lista += intro_html
            intro_html = ""
        lista_html = (f'<tr><td style="padding-top:{"30px" if hay_antes else "0"};">'
                      f'{titulo_lista}<table width="100%" cellpadding="0" '
                      f'cellspacing="0">{"".join(filas_html)}</table></td></tr>')

    # Sin contratos nuevos y con plazos, el botón lleva a la cartera, que
    # es de lo que habla el correo; y el enlace de la sección sobra.
    if items or vigilados or organismos or not plazos:
        boton_texto, boton_url = "Ver todos los contratos abiertos", URL_INTERFAZ
    else:
        boton_texto, boton_url = "Ver tu cartera", URL_CARTERA
        bloque_plazos_html = bloque_plazos_html.replace(enlace_cartera_html, "")
        # Igual en el texto plano: el pie ya dice "Ver tu cartera".
        bloque_plazos_texto = bloque_plazos_texto.replace(
            f"\nVer tu cartera: {URL_CARTERA}\n\n", "")

    cuerpo_html = f"""<!DOCTYPE html>
<html lang="es"><body style="margin:0;padding:0;background:#F5F4F1;">
<table width="100%" cellpadding="0" cellspacing="0" style="background:#F5F4F1;padding:32px 16px;">
<tr><td align="center">
  <table width="100%" cellpadding="0" cellspacing="0"
         style="max-width:560px;background:#FFFFFF;border-radius:4px;padding:36px 32px;
                font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">
    <tr><td>
      <h1 style="margin:0 0 8px;font-size:22px;font-weight:600;color:#17171A;line-height:1.3;">
        {html.escape(asunto)}
      </h1>
      {intro_html}
    </td></tr>
    {bloque_plazos_html}
    {bloque_vigilados_html}
    {lista_html}
    {bloque_organismos_html}
    {bloque_seguidas_html}
    <tr><td style="padding-top:28px;">
      <a href="{html.escape(boton_url)}"
         style="display:inline-block;background:#17171A;color:#FFFFFF;
                padding:12px 22px;border-radius:3px;text-decoration:none;
                font-size:15px;font-weight:500;">{boton_texto}</a>
    </td></tr>
    <tr><td style="padding-top:26px;color:#8B8B92;font-size:12px;line-height:1.6;">
      Datos de la Plataforma de Contratación del Sector Público y de las
      plataformas autonómicas agregadas. Solo recibes este correo los días
      que hay novedades, se acerca un plazo de tu cartera o hay algo de lo
      que sigues.
    </td></tr>
  </table>
</td></tr></table>
</body></html>"""

    intro_texto = ""
    if items:
        intro_texto = (("CONTRATOS NUEVOS\n" if hay_antes else "")
                       + "Licitaciones abiertas que encajan con tu negocio,\n"
                       "detectadas esta madrugada.\n\n"
                       + "\n".join(filas_texto))

    cuerpo_texto = (
        f"{asunto}\n\n"
        + bloque_plazos_texto
        + bloque_vigilados_texto
        + intro_texto
        + bloque_organismos_texto
        + bloque_seguidas_texto
        + f"\n{boton_texto}: {boton_url}\n"
    )

    return asunto, cuerpo_html, cuerpo_texto


# ==============================================================
# 4. ENVÍO
# ==============================================================

def enviar(asunto: str, cuerpo_html: str, cuerpo_texto: str,
           destinatarios: list[str]) -> bool:
    """
    Envía por Resend. Se usa urllib y no una librería nueva: es una sola
    petición HTTP y no compensa otra dependencia que mantener.
    """
    clave = os.environ.get("RESEND_API_KEY", "").strip()
    if not clave:
        logging.error("Falta RESEND_API_KEY en los secrets del repositorio.")
        return False

    cuerpo = json.dumps({
        "from": REMITENTE,
        "to": destinatarios,
        "subject": asunto,
        "html": cuerpo_html,
        "text": cuerpo_texto,
    }).encode("utf-8")

    peticion = urllib.request.Request(
        API_RESEND, data=cuerpo, method="POST",
        headers={
            "Authorization": f"Bearer {clave}",
            "Content-Type": "application/json",
            # Sin User-Agent, la petición sale identificándose como
            # urllib y el cortafuegos que hay delante de la API la
            # rechaza con un 403 antes de que llegue a Resend. El
            # intento ni siquiera aparece en su panel.
            "User-Agent": "StateScraper/1.0 (alertas de contratacion publica)",
            "Accept": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(peticion, timeout=30) as respuesta:
            datos = json.loads(respuesta.read().decode("utf-8"))
            logging.info("Correo aceptado por Resend (id %s).",
                         datos.get("id", "desconocido"))
            return True
    except urllib.error.HTTPError as error:
        detalle = error.read().decode("utf-8", "replace")[:600]
        logging.error("Resend rechazó el envío (HTTP %s): %s", error.code, detalle)
        if error.code == 403:
            logging.error(
                "Un 403 suele ser una de estas tres: la clave no tiene "
                "permiso de envío; el destinatario no es la dirección con "
                "la que te registraste (obligatorio sin dominio propio); o "
                "la petición fue bloqueada antes de llegar a la API."
            )
        elif error.code == 422:
            logging.error("Un 422 apunta al remitente o al destinatario.")
        return False
    except Exception as error:
        logging.error("No se pudo enviar el correo: %s", error)
        return False


# ==============================================================
# 5. ORQUESTACIÓN
# ==============================================================

def main() -> int:
    argumentos = argparse.ArgumentParser(
        description="State Scraper · Paso 5, alerta diaria por correo."
    )
    argumentos.add_argument("--simulacro", action="store_true",
                            help="Muestra los correos por pantalla y NO los envía.")
    argumentos.add_argument("--solo", metavar="CIF",
                            help="Envía únicamente a la empresa con ese CIF.")
    opciones = argumentos.parse_args()

    configurar_logging()
    logging.info("=" * 62)
    logging.info("ALERTA DIARIA POR CLIENTE%s",
                 "  ·  SIMULACRO" if opciones.simulacro else "")
    logging.info("=" * 62)

    cliente = obtener_cliente()
    perfiles = clientes_a_avisar(cliente)

    if opciones.solo:
        # Para probar con un cliente concreto sin escribir a los demás.
        buscado = opciones.solo.strip().upper()
        try:
            fila = (cliente.table("perfiles").select("id")
                    .eq("cif", buscado).limit(1).execute().data)
            ids = {f["id"] for f in (fila or [])}
        except Exception as error:
            logging.error("No se pudo buscar ese CIF: %s", error)
            return 1
        perfiles = [p for p in perfiles if p["id"] in ids]
        logging.info("Filtrado por CIF %s: %d perfil(es).", buscado, len(perfiles))

    if not perfiles:
        logging.info("No hay clientes activos con filtro listo.")
        return 0

    logging.info("Clientes con alerta activa: %d", len(perfiles))

    enviados = fallidos = sin_novedades = 0

    for perfil in perfiles:
        nombre = perfil.get("empresa") or perfil.get("nombre") or "?"
        # Para el registro, nunca el nombre de la empresa: los registros de
        # Actions son públicos en un repositorio público. El nombre sí va
        # dentro del correo, que es suyo.
        etiqueta = "perfil " + str(perfil["id"])[:8]
        items = novedades(cliente, perfil["id"])
        plazos = plazos_de_cartera(cliente, perfil["id"])

        # Lo que sigue (Decisión 56). Cada licitación sale una sola vez:
        # lo vigilado manda sobre las novedades (dice de qué contrato
        # viene), y las novedades sobre lo de los organismos.
        seg = novedades_de_seguimiento(cliente, perfil["id"])
        vigilados = (seg.get("vigilado") or [])[:MAX_SEGUIMIENTO]
        ya = {v.get("id_licitacion") for v in vigilados}
        items = [it for it in items if it.get("id_licitacion") not in ya]
        ya |= {it.get("id_licitacion") for it in items}
        organismos = [o for o in (seg.get("organismo") or [])
                      if o.get("id_licitacion") not in ya][:MAX_SEGUIMIENTO]

        # Lo que gana la competencia no caduca: va con lo demás, y solo,
        # como mucho una vez por semana (el 10/09/2026 se sacó del correo
        # diario por eso mismo).
        seguidas = seg.get("gana") or []
        hay_mas = bool(items or plazos or vigilados or organismos)
        if seguidas and not hay_mas:
            ultimo = a_fecha(seg.get("ultimo_gana"))
            if ultimo and datetime.now(timezone.utc) - ultimo < timedelta(days=DIAS_RESUMEN_COMPETENCIA):
                seguidas = []

        if not hay_mas and not seguidas:
            # Silencio deliberado: un correo que dice "hoy no hay nada"
            # enseña a ignorar el remitente, y con él los días que sí
            # importan.
            sin_novedades += 1
            continue

        logging.info("[%s] %d novedades, %d plazos de cartera, %d vigilados, "
                     "%d de organismos, %d de la competencia.",
                     etiqueta, len(items), len(plazos), len(vigilados),
                     len(organismos), len(seguidas))
        asunto, cuerpo_html, cuerpo_texto = componer(
            items, seguidas, nombre, plazos, organismos, vigilados)
        avisados = (
            [{"tipo": "vigilado", "id_licitacion": v["id_licitacion"],
              "referencia": v.get("anterior")} for v in vigilados]
            + [{"tipo": "organismo", "id_licitacion": o["id_licitacion"],
                "referencia": o.get("organo")} for o in organismos]
            + [{"tipo": "gana", "id_licitacion": g["id_licitacion"],
                "referencia": g.get("cif")} for g in seguidas])

        if opciones.simulacro:
            logging.info("  Asunto: %s", asunto)
            logging.info("  --- versión en texto ---\n%s", cuerpo_texto)
            continue

        destino = perfil.get("email", "").strip()
        if not destino:
            logging.warning("[%s] Sin correo. Se salta.", etiqueta)
            fallidos += 1
            continue

        # Se enmascara: el registro de Actions es visible para quien tenga
        # acceso al repositorio, y ahí hay correos de clientes.
        visible = destino[:2] + "***@" + destino.split("@")[-1] \
            if "@" in destino else "???"
        logging.info("  Enviando a %s", visible)

        if enviar(asunto, cuerpo_html, cuerpo_texto, [destino]):
            enviados += 1
            marcar_avisos_seguimiento(cliente, perfil["id"], avisados)
        else:
            fallidos += 1

    logging.info("--- RESUMEN ---")
    logging.info("Enviados: %d | sin novedades: %d | fallidos: %d",
                 enviados, sin_novedades, fallidos)

    ruta = os.environ.get("GITHUB_STEP_SUMMARY")
    if ruta:
        try:
            with open(ruta, "a", encoding="utf-8") as fichero:
                fichero.write(f"\n## Alerta diaria\n\n"
                              f"**{enviados}** enviados · {sin_novedades} sin "
                              f"novedades · {fallidos} fallidos\n")
        except OSError:
            pass

    # Fallar en rojo si algún envío se cayó: un fallo silencioso deja al
    # cliente sin su aviso y nadie se entera.
    return 1 if fallidos else 0


if __name__ == "__main__":
    sys.exit(main())
