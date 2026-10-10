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
// Dentro de un ZIP, primero lo que parece el pliego, el cuadro o los
// criterios, y al final los modelos y declaraciones para rellenar (en un
// ZIP catalán de 27 ficheros, 12 eran formularios).
const PATRON_PLIEGO = /pliego|pcap|ppt|prescrip|cuadro|quadre|caracter|car[aà]tula|criteri|cl[aà]usul|plec|memoria/i;
const PATRON_FORMULARIO = /model|declaraci|compromi|submissi|encarregat|certificat|protecci|confidencial|\bute\b|plantilla|formulari/i;

// Cuánto interesa un fichero de dentro de un ZIP, para ordenarlos.
export function interes(nombre: string, ext: string): number {
  let nota = 0;
  if (!nombre.includes(" › ")) nota += 2;          // primer nivel
  // Solo el nombre del fichero: el del ZIP que lo contiene ("ANNEXOS
  // PCAP.zip") daba a todos sus anexos la nota del pliego.
  const propio = nombre.split(" › ").pop() ?? nombre;
  if (PATRON_PLIEGO.test(propio)) nota += 3;
  if (PATRON_FORMULARIO.test(propio)) nota -= 3;
  if (ext === "pdf") nota += 1;                    // los .docx suelen ser plantillas
  return nota;
}
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

// Cuántos niveles de ZIP dentro de ZIP se abren: el portal catalán, por
// ejemplo, mete los anexos del PCAP en otro ZIP dentro del primero.
const NIVELES = 2;

type Entrada = { nombre: string; contenido: Uint8Array<ArrayBuffer>; ext: string };

// Lo legible de dentro de un ZIP (y de los ZIP que lleve dentro): nombre,
// contenido y extensión, lo que parece el pliego primero. El nombre de lo
// que viene de un ZIP interior lleva delante ese ZIP ("anexos.zip ›
// anexo I.pdf"). Los nombres pueden venir en otra codificación; da igual,
// solo se usan para decir de dónde sale una respuesta.
export function abrirZip(nombreZip: string, contenido: Uint8Array,
                         legibles: Set<string>, maxDocumento: number): Entrada[] {
  // Lo descomprimido se cuenta entre todos los niveles: la memoria es una.
  const presupuesto = { total: 0 };
  return abrir(nombreZip, contenido, legibles, maxDocumento, presupuesto, 1)
    .sort((x, y) => interes(y.nombre, y.ext) - interes(x.nombre, x.ext));
}

function abrir(nombreZip: string, contenido: Uint8Array, legibles: Set<string>,
               maxDocumento: number, presupuesto: { total: number }, nivel: number): Entrada[] {
  let dentro: Record<string, Uint8Array>;
  try {
    dentro = unzipSync(contenido, {
      filter: (f) => {
        const ext = (f.name.split(".").pop() ?? "").toLowerCase();
        const esZip = ext === "zip" && nivel < NIVELES;
        if ((!legibles.has(ext) && !esZip) || PATRON_FUERA.test(f.name)) return false;
        if (f.originalSize > maxDocumento
            || presupuesto.total + f.originalSize > MAX_DESCOMPRIMIDO) return false;
        presupuesto.total += f.originalSize;
        return true;
      },
    });
  } catch (error) {
    console.error(`No se pudo abrir ${nombreZip}:`, String(error).slice(0, 200));
    return [];
  }
  const salida: Entrada[] = [];
  for (const [ruta, datos] of Object.entries(dentro)) {
    const nombre = ruta.split("/").pop() || ruta;
    if (nombre.toLowerCase().endsWith(".zip")) {
      // El ZIP interior se abre y deja de ocupar: cuenta lo que saca.
      presupuesto.total -= datos.length;
      for (const e of abrir(nombre, datos, legibles, maxDocumento, presupuesto, nivel + 1)) {
        salida.push({ ...e, nombre: `${nombre} › ${e.nombre}` });
      }
      continue;
    }
    const copia = new Uint8Array(datos.length);
    copia.set(datos);
    const ext = extensionPorContenido(copia) ?? (nombre.split(".").pop() ?? "").toLowerCase();
    if (legibles.has(ext)) salida.push({ nombre, contenido: copia, ext });
  }
  return salida;
}
