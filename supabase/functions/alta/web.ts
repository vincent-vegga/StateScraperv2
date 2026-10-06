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

// Palabras de los títulos de página que no son un nombre.
const NO_ES_NOMBRE = /^(inicio|home|portada|bienvenid[oa]s?|p[aá]gina principal|web oficial|sitio oficial|index)$/i;

/**
 * Cómo se llama la empresa, según su propia web: el nombre del sitio
 * (og:site_name, application-name), los trozos cortos del <title> y la
 * palabra principal del dominio. Para que no salga en lo que se le enseña
 * (el modelo lo escribía aunque se le pidiera que no: «En el Grupo
 * Tragsa nos dedicamos…»).
 */
export function nombresDe(html: string, url: URL): string[] {
  const plano = (t: string) => t.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
    .toLowerCase().replace(/[^a-z0-9]/g, "");
  const meta = (n: string) => html.match(new RegExp(
    `<meta[^>]+(?:property|name)=["']${n}["'][^>]*content=["']([^"']+)["']`, "i"))?.[1]
    ?? html.match(new RegExp(
      `<meta[^>]+content=["']([^"']+)["'][^>]*(?:property|name)=["']${n}["']`, "i"))?.[1];
  const limpio = (x: unknown) => textoDeHtml(String(x ?? "")).trim();
  const corto = (n: string) => !!n && n.length <= 40 && n.split(/\s+/).length <= 5
    && !NO_ES_NOMBRE.test(n);
  const dominio = url.hostname.replace(/^www\./, "").split(".")[0];
  const dom = plano(dominio);

  const nombres = new Set<string>();
  // El nombre que el sitio dice de sí mismo vale tal cual.
  for (const x of [meta("og:site_name"), meta("application-name")]) {
    const n = limpio(x);
    if (corto(n)) nombres.add(n);
  }
  // Un trozo del <title> solo si casa con el dominio («Grupo Tragsa» y
  // tragsa.es): si no, puede ser un lema («Mantenimiento de jardines») y
  // quitarlo estropearía la descripción. Casar es que uno contenga al
  // otro y sea al menos la mitad: «Mantenimiento de jardines en
  // Zaragoza» contiene «jardines», pero no se llama así.
  const casa = (n: string) => {
    const p = plano(n);
    return !!p && (p.includes(dom) ? dom.length * 2 >= p.length
      : dom.includes(p) && p.length * 2 >= dom.length);
  };
  const titulo = limpio(html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]);
  for (const trozo of titulo.split(/\s+[|\-–—:·]\s+/)) {
    const n = trozo.trim();
    if (corto(n) && dom.length >= 4 && casa(n)) nombres.add(n);
  }
  // La palabra del dominio, solo si el sitio o el título la confirman
  // como nombre (una web jardines.es no se llama «jardines»).
  if (dom.length >= 4 && [...nombres].some(casa)) nombres.add(dominio);
  // Sin la forma jurídica ni «Grupo»: así también se quita «Tragsa» solo.
  for (const n of [...nombres]) {
    const nucleo = n.replace(/^(grupo|empresa)\s+/i, "")
      .replace(/[,\s]+(s\.?\s?a\.?\s?u?\.?|s\.?\s?l\.?\s?u?\.?)$/i, "").trim();
    if (nucleo.length >= 3) nombres.add(nucleo);
  }
  // Los largos primero: «Grupo Tragsa» antes que «Tragsa».
  return [...nombres].sort((a, b) => b.length - a.length);
}

const escapar = (t: string) => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * El texto sin el nombre de la empresa, ni lo que suele llevar delante
 * («en el Grupo X», «la empresa X»), ni su forma jurídica. Después se
 * arreglan los espacios y las mayúsculas que quedan sueltos.
 */
export function quitarNombres(texto: string, nombres: string[]): string {
  let t = texto;
  for (const n of nombres) {
    const nombre = escapar(n).replace(/\s+/g, "\\s+");
    t = t.replace(new RegExp(
      "(?<![\\p{L}\\d])(?:(?:en|de|desde|con|para|por)\\s+)?(?:(?:el|la|los|las|nuestro|nuestra)\\s+)?" +
      "(?:(?:grupo|empresa|compa[ñn][ií]a|equipo)\\s+)?" + nombre +
      "(?:,?\\s+(?:s\\.?\\s?a\\.?\\s?u?\\.?|s\\.?\\s?l\\.?\\s?u?\\.?))?(?![\\p{L}\\d])", "giu"), " ");
  }
  // «Somos X, una empresa…» queda «Somos, una empresa…».
  return t.replace(/(^|[.!?]\s+)(somos|soy)\s*,\s*/giu, "$1$2 ").replace(/\s+([,.;:])/g, "$1").replace(/([,;:])(?=[,.;:])/g, "")
    .replace(/\s{2,}/g, " ").replace(/^[\s,.;:]+/, "").trim()
    .replace(/(^|[.!?]\s+)(\p{Ll})/gu, (_m, a, b) => a + b.toUpperCase());
}

/** El texto de la portada y de hasta seis páginas suyas, y su nombre. */
export async function leerWeb(url: URL): Promise<{ texto: string; nombres: string[] }> {
  const portada = await pagina(url.href);
  if (!portada) return { texto: "", nombres: [] };
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
  return { texto: frases.join(" ").slice(0, 15_000).toWellFormed(), nombres: nombresDe(portada, url) };
}

/**
 * A qué se dedica y sus líneas, según su web. Solo el «qué»: ni
 * clientes, ni organismos, ni zonas (el «dónde / a quién» no alimenta la
 * similitud). Null si no deja ver a qué se dedica.
 */
export async function webComoCliente(texto: string, nombres: string[] = []):
    Promise<{ descripcion: string; lineas: string[] } | null> {
  if (texto.length < 300) return null;
  const seLlama = nombres.length
    ? `La empresa se llama ${nombres.map((n) => `«${n}»`).join(" o ")}: no lo escribas.\n` : "";
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
      "vacías y descripcion vacía.\n" + seLlama +
      "Devuelve EXCLUSIVAMENTE JSON: {\"descripcion\":\"...\",\"lineas\":[\"...\"]}" },
    { role: "user", content: texto },
  ], 500);
  // Y por si aun así lo escribe, se quita.
  const descripcion = quitarNombres(String(r.descripcion ?? ""), nombres);
  if (descripcion.length < 15) return null;
  const lineas = (Array.isArray(r.lineas) ? r.lineas : [])
    .map((x: unknown) => quitarNombres(String(x), nombres))
    .filter((x: string) => x.length >= 3).slice(0, 8);
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
