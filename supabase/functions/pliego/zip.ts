// ============================================================
// STATE SCRAPER · Abrir lo que publica el portal (Decisión 57)
// ============================================================
//
// Aparte de index.ts para poder probarlo en local con ZIP reales, sin
// sesión ni claves: `deno run -A prueba_zip.ts <fichero.zip>`.
// ============================================================

import { unzipSync } from "https://esm.sh/fflate@0.8.2";

// Lo descomprimido de un ZIP, en total: la función tiene 256 MB.
const MAX_DESCOMPRIMIDO = 40 * 1024 * 1024;
// Dentro de un ZIP, primero lo que parece el pliego o el cuadro.
const PATRON_PLIEGO = /pliego|pcap|ppt|cuadro|caracter|car[aà]tula|anexo|annex|prescrip|cl[aà]usul|plec|memoria/i;
// Lo que no se sube: el DEUC (un formulario sin contenido propio), la
// basura de macOS y los ocultos.
const PATRON_FUERA = /deuc|espd|__macosx|(^|\/)\./i;

// La extensión por los primeros bytes, o null si no se reconoce. El portal
// publica ".PDF" en mayúsculas (OpenAI lo rechaza, medido el 09/10/2026)
// y a veces un ZIP con nombre de PDF.
export function extensionPorContenido(contenido: Uint8Array): string | null {
  if (contenido.length < 4) return null;
  const inicio = new TextDecoder().decode(contenido.subarray(0, 4));
  if (inicio === "%PDF") return "pdf";
  if (inicio.startsWith("PK")) {
    const cabeza = new TextDecoder().decode(contenido.subarray(0, 4000));
    if (cabeza.includes("word/")) return "docx";
    if (cabeza.includes("ppt/")) return "pptx";
    if (cabeza.includes("opendocument.text")) return "odt";
    return "zip";
  }
  return null;
}

// Lo legible de dentro de un ZIP: nombre, contenido y extensión, lo que
// parece el pliego primero. Los nombres pueden venir en otra codificación;
// da igual, solo se usan para decir de dónde sale una respuesta.
export function abrirZip(nombreZip: string, contenido: Uint8Array,
                         legibles: Set<string>, maxDocumento: number):
    { nombre: string; contenido: Uint8Array<ArrayBuffer>; ext: string }[] {
  let total = 0;
  let dentro: Record<string, Uint8Array>;
  try {
    dentro = unzipSync(contenido, {
      filter: (f) => {
        const ext = (f.name.split(".").pop() ?? "").toLowerCase();
        if (!legibles.has(ext) || PATRON_FUERA.test(f.name)) return false;
        if (f.originalSize > maxDocumento || total + f.originalSize > MAX_DESCOMPRIMIDO) return false;
        total += f.originalSize;
        return true;
      },
    });
  } catch (error) {
    console.error(`No se pudo abrir ${nombreZip}:`, String(error).slice(0, 200));
    return [];
  }
  return Object.entries(dentro)
    .map(([ruta, datos]) => {
      const nombre = ruta.split("/").pop() || ruta;
      const copia = new Uint8Array(datos.length);
      copia.set(datos);
      const ext = extensionPorContenido(copia) ?? (nombre.split(".").pop() ?? "").toLowerCase();
      return { nombre, contenido: copia, ext };
    })
    .filter((e) => legibles.has(e.ext))
    .sort((x, y) => Number(!PATRON_PLIEGO.test(x.nombre)) - Number(!PATRON_PLIEGO.test(y.nombre)));
}
