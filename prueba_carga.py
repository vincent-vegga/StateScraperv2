"""
Prueba de carga con usuarios sintéticos.

Hace lo mismo que la web, por los mismos caminos (API de la base,
función `alta`, inicio de sesión), con varios usuarios a la vez:

  1. PREPARAR  Crea N usuarios de prueba y un código de acceso propio.
  2. ALTA      Cada usuario canjea el código y da de alta E empresas con
               NIF reales, una tras otra, cribado inicial incluido. Los
               usuarios van todos a la vez: es el momento más caro del
               sistema (modelo de lenguaje + escrituras).
  3. NAVEGAR   D "dispositivos" (varios por usuario, cada uno en una de
               sus empresas) recorren pantallas al azar con pausas de
               persona, en etapas de concurrencia creciente.
  4. LIMPIAR   Borra usuarios y código. Sus perfiles, veredictos, etc.
               caen en cascada. Se ejecuta SIEMPRE, también si algo falla.

Además de tiempos, comprueba lo que la carga puede romper sin dar error:
que cada respuesta sea de la empresa que se pidió (con varias empresas
por cuenta, una mezcla sería enseñarle a un cliente datos de otra).

Necesita la clave secreta (crear y borrar usuarios), así que está
pensada para correr en GitHub Actions: .github/workflows/prueba-carga.yml

    SUPABASE_URL, SUPABASE_KEY   -> obligatorias (clave secreta)

    python prueba_carga.py --usuarios 3 --empresas 3 --etapas 5,15,30
    python prueba_carga.py --usuarios 1 --empresas 2 --etapas "" --nifs B06392302,B53994695
    python prueba_carga.py --solo-limpiar
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import logging
import os
import random
import secrets
import statistics
import sys
import time
from collections import defaultdict

import httpx

# La misma clave pública que lleva la web: lo que se mide es lo que
# puede hacer un navegador, con sus mismos permisos.
ANON = "sb_publishable_asxZq0hsC7OjJ7_F5hcefA_QngjLLQk"
PREFIJO = "prueba-carga-"
DOMINIO = "statescraper.com"

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(message)s",
                    datefmt="%H:%M:%S")


# ============================================================
# Medición
# ============================================================

class Medidor:
    def __init__(self):
        self.filas: list[tuple[str, str, float, bool]] = []
        self.errores: dict[str, list[str]] = defaultdict(list)
        self.mezclas: list[str] = []

    def anotar(self, fase, nombre, ms, ok, detalle=""):
        self.filas.append((fase, nombre, ms, ok))
        if not ok and len(self.errores[nombre]) < 5:
            self.errores[nombre].append(detalle[:300])

    def informe(self, inicio_etapas: dict[str, float]) -> str:
        grupos = defaultdict(list)
        for fase, nombre, ms, ok in self.filas:
            grupos[(fase, nombre)].append((ms, ok))

        def pct(v, p):
            v = sorted(v)
            return v[min(len(v) - 1, int(len(v) * p))] if v else 0

        lineas = ["# Prueba de carga", ""]
        fases = sorted({f for f, _ in grupos}, key=lambda f: (f != "alta", f))
        for fase in fases:
            filas = [(n, v) for (f, n), v in grupos.items() if f == fase]
            total = sum(len(v) for _, v in filas)
            fallos = sum(1 for _, v in filas for _, ok in v if not ok)
            titulo = f"## {fase}"
            if fase in inicio_etapas:
                dur = inicio_etapas[fase]
                titulo += f" · {total / dur:.1f} peticiones/s durante {dur:.0f} s"
            lineas += [titulo, "",
                       f"{total} peticiones, {fallos} fallidas "
                       f"({100 * fallos / max(total, 1):.1f} %)", "",
                       "| Llamada | n | fallos | p50 ms | p95 ms | máx ms |",
                       "|---|---:|---:|---:|---:|---:|"]
            for nombre, v in sorted(filas, key=lambda x: -pct([m for m, _ in x[1]], .95)):
                ms = [m for m, _ in v]
                lineas.append(
                    f"| {nombre} | {len(v)} | {sum(1 for _, ok in v if not ok)} | "
                    f"{statistics.median(ms):.0f} | {pct(ms, .95):.0f} | {max(ms):.0f} |")
            lineas.append("")

        lineas += ["## Datos cruzados entre empresas", ""]
        if self.mezclas:
            lineas += [f"**{len(self.mezclas)} respuestas con datos de otra empresa.**", ""]
            lineas += [f"- {m}" for m in self.mezclas[:20]]
        else:
            lineas.append("Ninguna: cada respuesta era de la empresa pedida.")
        lineas.append("")

        if self.errores:
            lineas += ["## Muestras de error", ""]
            for nombre, muestras in self.errores.items():
                lineas.append(f"**{nombre}**")
                lineas += [f"- `{m}`" for m in muestras]
                lineas.append("")
        return "\n".join(lineas)


M = Medidor()


# ============================================================
# Llamadas, igual que las hace la web
# ============================================================

class Api:
    def __init__(self, url: str, secreta: str, http: httpx.AsyncClient):
        self.url = url.rstrip("/")
        self.secreta = secreta
        self.http = http

    def _cab(self, token=None, perfil=None, clave=ANON):
        c = {"apikey": clave, "Authorization": f"Bearer {token or clave}",
             "Content-Type": "application/json"}
        if perfil:
            c["x-perfil"] = perfil
        return c

    async def _medir(self, fase, nombre, peticion):
        t = time.perf_counter()
        try:
            r = await peticion
            ms = (time.perf_counter() - t) * 1000
            ok = r.status_code < 400
            M.anotar(fase, nombre, ms, ok, f"{r.status_code} {r.text}")
            return r if ok else None
        except Exception as e:  # tiempo agotado, conexión cortada...
            M.anotar(fase, nombre, (time.perf_counter() - t) * 1000, False,
                     f"{type(e).__name__}: {e}")
            return None

    async def rpc(self, fase, fn, args, token, perfil=None):
        r = await self._medir(fase, fn, self.http.post(
            f"{self.url}/rest/v1/rpc/{fn}", json=args,
            headers=self._cab(token, perfil)))
        return r.json() if r is not None and r.content else None

    async def tabla(self, fase, nombre, ruta, token, perfil=None):
        r = await self._medir(fase, nombre, self.http.get(
            f"{self.url}/rest/v1/{ruta}", headers=self._cab(token, perfil)))
        return r.json() if r is not None else None

    async def alta(self, fase, accion, token, perfil, **cuerpo):
        r = await self._medir(fase, f"alta:{accion}", self.http.post(
            f"{self.url}/functions/v1/alta",
            json={"accion": accion, "perfil_id": perfil, **cuerpo},
            headers=self._cab(token), timeout=200))
        return r.json() if r is not None else None

    # --- Con la clave secreta: solo preparar y limpiar ---

    def _admin(self):
        return self._cab(clave=self.secreta)

    async def crear_usuario(self, email, clave):
        r = await self.http.post(f"{self.url}/auth/v1/admin/users",
                                 headers=self._admin(),
                                 json={"email": email, "password": clave,
                                       "email_confirm": True})
        r.raise_for_status()
        return r.json()["id"]

    async def entrar(self, email, clave):
        r = await self._medir("preparar", "auth:entrar", self.http.post(
            f"{self.url}/auth/v1/token?grant_type=password",
            headers=self._cab(), json={"email": email, "password": clave}))
        if r is None:
            raise RuntimeError(f"No se pudo iniciar sesión con {email}")
        return r.json()["access_token"]

    async def usuarios_de_prueba(self):
        ids, pagina = [], 1
        while True:
            r = await self.http.get(f"{self.url}/auth/v1/admin/users",
                                    headers=self._admin(),
                                    params={"page": pagina, "per_page": 200})
            r.raise_for_status()
            lote = r.json().get("users", [])
            ids += [u["id"] for u in lote
                    if (u.get("email") or "").startswith(PREFIJO)]
            if len(lote) < 200:
                return ids
            pagina += 1

    async def borrar_usuario(self, uid):
        r = await self.http.delete(f"{self.url}/auth/v1/admin/users/{uid}",
                                   headers=self._admin())
        return r.status_code < 400

    async def servicio(self, metodo, ruta, **kw):
        r = await self.http.request(metodo, f"{self.url}/rest/v1/{ruta}",
                                    headers={**self._admin(),
                                             "Prefer": "return=minimal"}, **kw)
        r.raise_for_status()
        return r.json() if r.content else None


# ============================================================
# 1 · Preparar
# ============================================================

async def empresas_reales(api: Api, cuantas: int) -> list[dict]:
    """NIF reales con historial suficiente para que el alta funcione."""
    salto = random.randint(0, 9000)
    filas = await api.servicio(
        "GET", "empresas",
        params={"select": "cif,nombre,contratos", "contratos": "gte.15",
                "and": "(contratos.lte.150)", "limit": "600",
                "offset": str(salto)})
    random.shuffle(filas)
    return filas[: cuantas * 3]   # de sobra: algunas no tendrán historial legible


async def limpiar(api: Api, codigo: str | None):
    ids = await api.usuarios_de_prueba()
    borrados = sum(await asyncio.gather(*(api.borrar_usuario(u) for u in ids)))
    if codigo:
        await api.servicio("DELETE", "codigos_acceso", params={"codigo": f"eq.{codigo}"})
    logging.info("Limpieza: %d/%d usuarios de prueba borrados", borrados, len(ids))
    return borrados == len(ids)


# ============================================================
# 2 · Alta
# ============================================================

async def alta_usuario(api: Api, u: dict, codigo: str, reserva: list[dict],
                       n_empresas: int, max_vueltas: int):
    r = await api.rpc("alta", "canjear_codigo", {"codigo_entrada": codigo}, u["token"])
    if not r or not r.get("ok"):
        logging.error("%s: no pudo canjear el código (%s)", u["email"], r)
        return
    perfil = r["perfil_id"]

    for k in range(n_empresas):
        if k:
            r = await api.rpc("alta", "nueva_empresa", {}, u["token"])
            if not r or not r.get("ok"):
                logging.error("%s: nueva_empresa falló (%s)", u["email"], r)
                return
            perfil = r["perfil_id"]

        # Como una persona: si su NIF no sirve, prueba con otro.
        while reserva:
            empresa = reserva.pop()
            b = await api.alta("alta", "buscar_empresa", u["token"], perfil,
                               cif=empresa["cif"])
            if not b or not b.get("empresas"):
                continue
            c = await api.alta("alta", "confirmar_empresa", u["token"], perfil,
                               cif=empresa["cif"])
            if c and c.get("ok"):
                logging.info("%s: %s → prefijos %s · %s", u["email"], empresa["cif"],
                             ",".join(c.get("prefijos", [])), c.get("actividad", ""))
                break
        else:
            logging.error("%s: se acabaron los NIF de reserva", u["email"])
            return

        inicio, hechas, sin_avance = time.perf_counter(), 0, 0
        for _ in range(max_vueltas):
            r = await api.alta("alta", "cribar", u["token"], perfil)
            if not r:
                sin_avance += 1
            else:
                hechas += r.get("hechas", 0)
                if r.get("terminado"):
                    break
                sin_avance = 0 if r.get("hechas") else sin_avance + 1
            if sin_avance >= 2:
                break
        segundos = time.perf_counter() - inicio
        M.anotar("alta", "empresa completa (cribado inicial)", segundos * 1000, True)

        # Lo que hace la web al abrir la lista por primera vez.
        r = await api.alta("alta", "sectores", u["token"], perfil)
        if r and r.get("sectores"):
            logging.info("%s · sectores: %s", empresa["cif"], " | ".join(
                f"{x['nombre']} ({','.join(x['prefijos'])})" for x in r["sectores"]))
        u["empresas"].append({"perfil": perfil, "cif": empresa["cif"]})
        logging.info("%s · empresa %d/%d: %s, %d clasificadas en %.0f s",
                     u["email"], k + 1, n_empresas, empresa["cif"], hechas, segundos)


# ============================================================
# 3 · Navegar
# ============================================================

def comprobar(dueno_esperado, filas, campo, fase, pantalla):
    """Cualquier fila de otra empresa es un fallo grave aunque no dé error."""
    if isinstance(filas, list):
        ajenas = [f for f in filas if isinstance(f, dict)
                  and f.get(campo) not in (None, dueno_esperado)]
        if ajenas:
            M.mezclas.append(f"{fase} · {pantalla}: {len(ajenas)} filas de "
                             f"{ajenas[0].get(campo)} pedidas como {dueno_esperado}")


async def pantalla_contratos(api, fase, d):
    filas, _, _ = await asyncio.gather(
        api.tabla(fase, "mis_oportunidades",
                  f"mis_oportunidades?select=*&perfil_id=eq.{d['perfil']}",
                  d["token"], d["perfil"]),
        api.rpc(fase, "marcar_visita", {}, d["token"], d["perfil"]),
        api.rpc(fase, "pendientes_de_perfil", {"perfil": d["perfil"], "tope": 1},
                d["token"], d["perfil"]))
    comprobar(d["perfil"], filas, "perfil_id", fase, "contratos")


async def pantalla_movimientos(api, fase, d):
    await asyncio.gather(
        api.rpc(fase, "movimientos_mercado", {"dias": 30}, d["token"], d["perfil"]),
        api.rpc(fase, "pulso_mercado", {"dias": 30}, d["token"], d["perfil"]))


async def pantalla_empresas(api, fase, d):
    competencia, _ = await asyncio.gather(
        api.rpc(fase, "competencia", {}, d["token"], d["perfil"]),
        api.rpc(fase, "mi_seguimiento", {}, d["token"], d["perfil"]))
    cifs = [f["cif"] for f in (competencia if isinstance(competencia, list) else [])
            if isinstance(f, dict) and f.get("cif")]
    if cifs:
        await api.rpc(fase, "ficha_empresa", {"cif_buscado": random.choice(cifs[:20])},
                      d["token"], d["perfil"])


async def pantalla_organismos(api, fase, d):
    lista = await api.rpc(fase, "buscar_organismo",
                          {"texto": "", "salto": 0, "cuantos": 400},
                          d["token"], d["perfil"])
    organos = [f.get("organo") for f in (lista if isinstance(lista, list) else [])
               if isinstance(f, dict) and f.get("organo")]
    if not organos:
        return
    organo = random.choice(organos[:30])
    anios = await api.rpc(fase, "anios_de_organismo", {"organo_buscado": organo},
                          d["token"], d["perfil"])
    anios = sorted(a["anio"] for a in (anios or []) if isinstance(a, dict) and "anio" in a)
    await api.rpc(fase, "ficha_organismo",
                  {"organo_buscado": organo,
                   "desde": anios[0] if anios else None,
                   "hasta": anios[-1] if anios else None},
                  d["token"], d["perfil"])


async def pantalla_panel(api, fase, d):
    p = await api.rpc(fase, "mi_panel", {}, d["token"], d["perfil"])
    if isinstance(p, dict) and p.get("cif") and p["cif"] != d["cif"]:
        M.mezclas.append(f"{fase} · mi_panel: devolvió {p['cif']} "
                         f"pedido como {d['cif']}")


async def cambiar_empresa(api, fase, d):
    otras = [e for e in d["usuario"]["empresas"] if e["perfil"] != d["perfil"]]
    if otras:
        e = random.choice(otras)
        d["perfil"], d["cif"] = e["perfil"], e["cif"]
    await pantalla_contratos(api, fase, d)


# Pesos a ojo de cómo se usa: la lista de contratos es con diferencia lo
# más visitado; cambiar de empresa, lo menos.
PANTALLAS = [(pantalla_contratos, 40), (pantalla_movimientos, 15),
             (pantalla_empresas, 15), (pantalla_organismos, 15),
             (pantalla_panel, 10), (cambiar_empresa, 5)]


async def dispositivo(api, fase, d, hasta):
    await asyncio.sleep(random.uniform(0, 3))   # que no entren todos en el mismo ms
    while time.monotonic() < hasta:
        pantalla = random.choices([p for p, _ in PANTALLAS],
                                  weights=[w for _, w in PANTALLAS])[0]
        await pantalla(api, fase, d)
        await asyncio.sleep(random.uniform(1, 4))   # lo que tarda una persona en mirar


# ============================================================
# Orquestación
# ============================================================

async def principal(op):
    url = os.environ.get("SUPABASE_URL", "").strip()
    secreta = os.environ.get("SUPABASE_KEY", "").strip()
    if not url or not secreta:
        sys.exit("Faltan SUPABASE_URL o SUPABASE_KEY.")

    limites = httpx.Limits(max_connections=400, max_keepalive_connections=100)
    async with httpx.AsyncClient(timeout=60, limits=limites) as http:
        api = Api(url, secreta, http)

        if op.solo_limpiar:
            ok = await limpiar(api, None)
            sys.exit(0 if ok else 1)

        # Restos de una prueba anterior interrumpida.
        await limpiar(api, None)

        marca = dt.datetime.now(dt.timezone.utc).strftime("%m%d%H%M")
        codigo = f"CARGA-{marca}-{secrets.token_hex(3)}"
        tiempos_etapa: dict[str, float] = {}
        try:
            # --- 1. Preparar ---
            await api.servicio("POST", "codigos_acceso", json={
                "codigo": codigo, "nota": "prueba de carga (se borra al terminar)",
                "usos_maximos": op.usuarios, "usos": 0,
                "caduca": (dt.datetime.now(dt.timezone.utc)
                           + dt.timedelta(hours=2)).isoformat()})
            usuarios = []
            for i in range(op.usuarios):
                email = f"{PREFIJO}{marca}-{i:02d}@{DOMINIO}"
                clave = secrets.token_urlsafe(24)   # no se guarda ni se imprime
                uid = await api.crear_usuario(email, clave)
                usuarios.append({"id": uid, "email": email, "clave": clave,
                                 "empresas": []})
            tokens = await asyncio.gather(*(api.entrar(u["email"], u["clave"])
                                            for u in usuarios))
            for u, t in zip(usuarios, tokens):
                u["token"] = t
                del u["clave"]
            logging.info("Preparados %d usuarios de prueba", len(usuarios))

            # --- 2. Alta, todos a la vez ---
            # Con --nifs se prueban empresas concretas (un caso raro que
            # se quiere ver de punta a punta) en vez de una muestra al azar.
            reserva = ([{"cif": c} for c in reversed(op.nifs)] if op.nifs
                       else await empresas_reales(api, op.usuarios * op.empresas))
            logging.info("ALTA: %d usuarios × %d empresas, a la vez",
                         op.usuarios, op.empresas)
            t0 = time.perf_counter()
            await asyncio.gather(*(alta_usuario(api, u, codigo, reserva, op.empresas,
                                                op.max_vueltas) for u in usuarios))
            tiempos_etapa["alta"] = time.perf_counter() - t0
            listos = [u for u in usuarios if u["empresas"]]
            logging.info("ALTA terminada en %.0f s: %d empresas listas",
                         tiempos_etapa["alta"],
                         sum(len(u["empresas"]) for u in usuarios))
            if not listos:
                raise RuntimeError("Ninguna empresa llegó al final del alta")

            # --- 3. Navegar, en etapas crecientes ---
            for n in op.etapas:
                fase = f"navegar · {n} dispositivos"
                dispositivos = []
                for k in range(n):
                    u = listos[k % len(listos)]
                    e = u["empresas"][(k // len(listos)) % len(u["empresas"])]
                    dispositivos.append({"usuario": u, "token": u["token"],
                                         "perfil": e["perfil"], "cif": e["cif"]})
                logging.info("ETAPA %s: %d s (inicio %s UTC)", fase, op.duracion,
                             dt.datetime.now(dt.timezone.utc).strftime("%H:%M:%S"))
                t0 = time.perf_counter()
                hasta = time.monotonic() + op.duracion
                await asyncio.gather(*(dispositivo(api, fase, d, hasta)
                                       for d in dispositivos))
                tiempos_etapa[fase] = time.perf_counter() - t0
        finally:
            await limpiar(api, codigo)

    informe = M.informe(tiempos_etapa)
    print(informe)
    with open("informe_carga.md", "w", encoding="utf-8") as f:
        f.write(informe)
    resumen = os.environ.get("GITHUB_STEP_SUMMARY")
    if resumen:
        with open(resumen, "a", encoding="utf-8") as f:
            f.write(informe)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--usuarios", type=int, default=3)
    p.add_argument("--empresas", type=int, default=3, choices=[1, 2, 3])
    p.add_argument("--etapas", default="5,15,30",
                   help="Dispositivos simultáneos por etapa, separados por comas")
    p.add_argument("--duracion", type=int, default=90, help="Segundos por etapa")
    p.add_argument("--max-vueltas", type=int, default=40,
                   help="Tope de lotes de cribado por empresa (60 contratos cada uno)")
    p.add_argument("--nifs", default="",
                   help="NIF concretos para el alta, separados por comas")
    p.add_argument("--solo-limpiar", action="store_true")
    op = p.parse_args()
    op.etapas = [int(x) for x in op.etapas.split(",") if x.strip()]
    op.nifs = [x.strip().upper() for x in op.nifs.split(",") if x.strip()]
    asyncio.run(principal(op))


if __name__ == "__main__":
    main()
