// ============================================================
// La web de la empresa en el alta sin NIF (decisión 49)
// ============================================================
//
// Lo que dice su web, además de lo que escribe en un minuto. Medido el
// 04/10/2026 (docs/alta-sin-nif/TRASPASO.md): junto a la descripción, el
// F1 medio pasa de 0,52 a 0,60 en las empresas con web legible; sola, la
// web es peor (un catálogo enorme lo trae todo). Por eso acompaña a la
// descripción y nunca la sustituye.
//
// La lectura es la de `leerWeb` en scripts/simular_sin_nif.ts: la portada
// y hasta seis páginas propias que parecen contar qué hace, con agente de
// navegador (con uno propio, algunas webs responden 403), hasta 15.000
// caracteres. Menos de 300 caracteres (webs hechas con JavaScript, sin
// texto) es como no tener web.

import { llamarModelo } from "./modelo.ts";

const PAGINAS_UTILES = /servicio|producto|soluci|actividad|quien|qui[eé]n|nosotros|empresa|cat[aá]logo|sector|que-hacemos|about|services|products/i;
const AGENTE = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0 Safari/537.36";

/**
 * La dirección que escribe el cliente, si es una web pública: con o sin
 * `https://`, y nunca una dirección interna (la lee el servidor, no su
 * navegador).
 */
export function direccionWeb(entrada: unknown): URL | null {
  let texto = String(entrada ?? "").trim();
  if (!texto) return null;
  if (!/^https?:\/\//i.test(texto)) texto = `https://${texto}`;
  try {
    const url = new URL(texto);
    const host = url.hostname.toLowerCase();
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null;
    if (!host.includes(".") || host.endsWith(".local") || host.endsWith(".internal")
        || host === "localhost" || host.endsWith(".localhost")) return null;
    // Sin direcciones IP escritas a mano: una web de empresa tiene nombre.
    if (/^[\d.]+$/.test(host) || host.startsWith("[")) return null;
    return url;
  } catch {
    return null;
  }
}

function textoDeHtml(html: string): string {
  return html
    .replace(/<(script|style|noscript|svg|nav|footer)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&[a-z]+;|&#\d+;/gi, " ")
    .replace(/\s+/g, " ").trim();
}

async function pagina(url: string): Promise<string | null> {
  try {
    const r = await fetch(url, {
      signal: AbortSignal.timeout(10_000), redirect: "follow",
      headers: { "User-Agent": AGENTE, "Accept": "text/html,application/xhtml+xml",
                 "Accept-Language": "es-ES,es;q=0.9" },
    });
    // Una redirección a una dirección interna tampoco se lee.
    if (!r.ok || !direccionWeb(r.url) || !(r.headers.get("content-type") ?? "").includes("html")) {
      await r.body?.cancel();
      return null;
    }
    return (await r.text()).slice(0, 2_000_000);
  } catch {
    return null;
  }
}

/** El texto de la portada y de hasta seis páginas suyas. */
export async function leerWeb(url: URL): Promise<string> {
  const portada = await pagina(url.href);
  if (!portada) return "";
  const enlaces = new Set<string>();
  for (const m of portada.matchAll(/<a\s[^>]*href=["']([^"'#]+)["'][^>]*>([\s\S]*?)<\/a>/gi)) {
    try {
      const destino = new URL(m[1], url);
      if (destino.hostname.replace(/^www\./, "") !== url.hostname.replace(/^www\./, "")) continue;
      if (/\.(pdf|jpe?g|png|zip|docx?)$/i.test(destino.pathname)) continue;
      if (PAGINAS_UTILES.test(destino.pathname) || PAGINAS_UTILES.test(textoDeHtml(m[2]))) {
        enlaces.add(destino.origin + destino.pathname);
      }
    } catch { /* enlace roto: se salta */ }
  }
  const resto = await Promise.all([...enlaces].slice(0, 6).map(pagina));
  // Sin repetir frases (cabeceras y pies se repiten en cada página).
  const vistas = new Set<string>();
  const frases = [portada, ...resto].filter((x): x is string => !!x).map(textoDeHtml)
    .flatMap((t) => t.split(/(?<=[.!?])\s+/))
    .filter((f) => f.length > 3 && !vistas.has(f) && !!vistas.add(f));
  // Cortar puede partir un emoji: medio par sustituto hace inválido el
  // JSON que va a OpenAI.
  return frases.join(" ").slice(0, 15_000).toWellFormed();
}

/**
 * A qué se dedica y sus líneas, según su web. Solo el «qué»: ni
 * clientes, ni organismos, ni zonas (el «dónde / a quién» no alimenta la
 * similitud). Null si no deja ver a qué se dedica.
 */
export async function webComoCliente(texto: string):
    Promise<{ descripcion: string; lineas: string[] } | null> {
  if (texto.length < 300) return null;
  const r = await llamarModelo([
    { role: "system", content:
      "Te damos el texto de la web de una empresa española. Escribe a qué se " +
      "dedica y qué vende o hace, para buscarle contratos públicos parecidos:\n" +
      "- descripcion: dos a cuatro frases, en primera persona del plural.\n" +
      "- lineas: de 3 a 8 productos o servicios concretos que ofrece, cortos " +
      "(de dos a seis palabras).\n" +
      "Solo lo que la web dice que hace, sin inventar. Sin nombre de empresa, " +
      "sin nombres de clientes, sin organismos concretos, sin zonas ni ciudades " +
      "y sin cifras. Si el texto no deja ver a qué se dedica, devuelve listas " +
      "vacías y descripcion vacía.\n" +
      "Devuelve EXCLUSIVAMENTE JSON: {\"descripcion\":\"...\",\"lineas\":[\"...\"]}" },
    { role: "user", content: texto },
  ], 500);
  const descripcion = String(r.descripcion ?? "").trim();
  if (descripcion.length < 15) return null;
  const lineas = (Array.isArray(r.lineas) ? r.lineas : []).map((x: unknown) => String(x).trim())
    .filter(Boolean).slice(0, 8);
  return { descripcion, lineas };
}

/**
 * Lo que leen el filtro, el criterio y el juez: lo suyo y lo de su web,
 * seguidos, como en la medición (`descripcion_con_desc`). El juez lo
 * recibe igual desde puntuador.py.
 */
export function descripcionCompleta(perfil: Record<string, unknown>): string {
  return [perfil.descripcion, perfil.descripcion_web].map((x) => String(x ?? "").trim())
    .filter(Boolean).join(" ");
}
