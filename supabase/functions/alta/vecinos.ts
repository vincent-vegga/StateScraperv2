// ============================================================
// STATE SCRAPER · Contratos parecidos a una descripción
// ============================================================
//
// La entrada por NIF construye el filtro con ejemplos: los contratos que
// la empresa ha ganado. Sin NIF, esos ejemplos se buscan: de lo
// adjudicado en sus familias (tabla `muestra_adjudicada`), los que más se
// parecen EN SIGNIFICADO a lo que ha escrito. Hacen de historial:
//
//   - el criterio se genera con su descripción y esos contratos como
//     ejemplos de lo que le interesa;
//   - se capturan los códigos donde caen muchos de los más parecidos
//     (el "vecindario"), no las familias enteras.
//
// Simulado con los perfiles que tienen NIF (decisión 38): con los
// ejemplos el criterio acierta más (precisión), y capturando por
// vecindario no se pierde lo que la descripción sola sí encontraba.
// ============================================================

import { OPENAI, llamarModelo } from "./modelo.ts";

const EMBEDDINGS = OPENAI.replace("/chat/completions", "/embeddings");

// Franjas de tamaño, las mismas que marca el cliente.
export const FRANJAS = ["<15k", "15-100k", "100k-1M", ">1M"];
export function franja(importe: number | null | undefined): string | null {
  if (importe == null || !(importe > 0)) return null;
  if (importe < 15_000) return "<15k";
  if (importe < 100_000) return "15-100k";
  if (importe < 1_000_000) return "100k-1M";
  return ">1M";
}

export type Adjudicada = {
  id_licitacion: string; prefijo_principal: string; titulo: string;
  organo: string | null; presupuesto: number | null; importe: number | null;
  adjudicatario: string | null; adjudicatario_cif: string | null;
  cpvs: string[] | null;
};

// text-embedding-3-small a 256 dimensiones: suficiente para títulos y
// cuatro veces más ligero de mover que el tamaño completo.
async function incrustar(textos: string[]): Promise<number[][]> {
  const clave = Deno.env.get("OPENAI_API_KEY");
  if (!clave) throw new Error("Falta OPENAI_API_KEY en la función.");
  const tandas: string[][] = [];
  for (let i = 0; i < textos.length; i += 1000) {
    tandas.push(textos.slice(i, i + 1000).map((t) => t.slice(0, 500) || "-"));
  }
  const resultados = await Promise.all(tandas.map(async (tanda) => {
    for (let intento = 0; ; intento++) {
      const r = await fetch(EMBEDDINGS, {
        method: "POST",
        headers: { "Authorization": `Bearer ${clave}`, "Content-Type": "application/json" },
        body: JSON.stringify({ model: "text-embedding-3-small", input: tanda, dimensions: 256 }),
      });
      if (r.ok) {
        const d = await r.json();
        return (d.data as { embedding: number[] }[]).map((e) => e.embedding);
      }
      await r.body?.cancel();
      if (intento >= 2 || (r.status !== 429 && r.status < 500)) {
        throw new Error(`embeddings respondió ${r.status}`);
      }
      await new Promise((ok) => setTimeout(ok, 1000 * 2 ** intento));
    }
  }));
  return resultados.flat();
}

// Vienen normalizados: el producto escalar es el coseno.
const coseno = (a: number[], b: number[]) => {
  let s = 0;
  for (let i = 0; i < a.length; i++) s += a[i] * b[i];
  return s;
};

export type Parecidos = {
  // Todos, del más al menos parecido.
  ordenados: { l: Adjudicada; s: number }[];
  // Los que hacen de ejemplos del criterio en prosa (con diversidad).
  vecinos: Adjudicada[];
  // Los más parecidos, sin diversidad: de donde sale el historial
  // sintético del motor de huellas (historialSintetico).
  puros: Adjudicada[];
};

/**
 * Los contratos de `filas` más parecidos a la descripción.
 *
 * Los vecinos: de los 200 más parecidos, los de sus franjas si hay al
 * menos 15 (si no, todos), y de ahí 40 con diversidad. Sin diversidad, a
 * quien vende mobiliario y material de oficina le salían cuarenta
 * variaciones de "suministro de mobiliario de oficina".
 */
export async function buscarParecidos(descripcion: string, filas: Adjudicada[],
                                      franjas: string[]): Promise<Parecidos> {
  // Un título repetido se incrusta una vez.
  const porTitulo = new Map<string, number>();
  const titulos: string[] = [];
  for (const l of filas) {
    const t = l.titulo.trim().toLowerCase();
    if (!porTitulo.has(t)) { porTitulo.set(t, titulos.length); titulos.push(l.titulo); }
  }
  const [consulta, ...vectores] = await incrustar([descripcion, ...titulos]);
  const vector = (l: Adjudicada) => vectores[porTitulo.get(l.titulo.trim().toLowerCase())!];

  const ordenados = filas.map((l) => ({ l, s: coseno(consulta, vector(l)) }))
    .sort((a, b) => b.s - a.s);

  const top = ordenados.slice(0, 200);
  const enFranjas = franjas.length
    ? top.filter(({ l }) => franjas.includes(franja(l.importe ?? l.presupuesto) ?? ""))
    : [];
  const candidatos = enFranjas.length >= 15 ? enFranjas : top;

  // MMR: cada vecino nuevo tiene que parecerse a la descripción y
  // aportar algo que no tengan ya los elegidos.
  const elegidos: { l: Adjudicada; v: number[] }[] = [];
  const quedan = candidatos.map(({ l, s }) => ({ l, s, v: vector(l), max: 0 }));
  while (elegidos.length < 40 && quedan.length) {
    let mejor = 0;
    for (let i = 1; i < quedan.length; i++) {
      if (0.7 * quedan[i].s - 0.3 * quedan[i].max > 0.7 * quedan[mejor].s - 0.3 * quedan[mejor].max) {
        mejor = i;
      }
    }
    const [e] = quedan.splice(mejor, 1);
    elegidos.push(e);
    for (const q of quedan) q.max = Math.max(q.max, coseno(q.v, e.v));
  }
  return { ordenados, vecinos: elegidos.map((e) => e.l),
           puros: candidatos.slice(0, 80).map(({ l }) => l) };
}

// Para el historial sintético del motor de huellas (decisión 41), cada
// contrato se contrasta con lo que la empresa dice que hace: el juez lo
// tomará como algo que ella ha ganado, y un intruso le hace decir "sí" a
// lo que no es suyo. A una empresa de jardinería se le colaron una
// depuradora, desratización y capturas de animales, y su lista acabó con
// depuradoras y colonias felinas.
const FILTRO = `\
Eres un analista de contratación pública española. Te damos lo que una \
empresa dice que hace y el título de un contrato público ya adjudicado. \
¿Podría esta empresa haber sido la adjudicataria, haciendo lo que dice \
que hace?

- "si": es su tipo de trabajo o de producto.
- "no": es otro oficio, aunque sea del mismo ámbito o para el mismo tipo \
de cliente (limpiar un parque no es gestionar su depuradora).

Devuelve EXCLUSIVAMENTE JSON: {"encaja": "si|no"}`;

/**
 * El historial sintético para el motor de huellas: de los más parecidos
 * (sin diversidad, que aquí empuja a coger contratos de los bordes), los
 * que encajan con lo que dice que hace; los 40 primeros. Si pasan menos
 * de 10, los 40 más parecidos sin filtrar. Medido con 14 empresas: la
 * parte buena de lo que se enseña sube del 44 % al 57 % (con el juez
 * viendo la descripción), y la cobertura baja del 62 % al 55 %.
 */
export async function historialSintetico(descripcion: string, p: Parecidos): Promise<Adjudicada[]> {
  const encaja = async (l: Adjudicada) => {
    try {
      const r = await llamarModelo([
        { role: "system", content: FILTRO },
        { role: "user", content: `LO QUE DICE QUE HACE:\n${descripcion}\n\nCONTRATO:\n${l.titulo}` },
      ], 30);
      return String(r.encaja ?? "").normalize("NFD").replace(/[\u0300-\u036f]/g, "")
        .trim().toLowerCase() === "si";
    } catch {
      return false;
    }
  };
  const juicios: boolean[] = new Array(p.puros.length);
  let siguiente = 0;
  await Promise.all(Array.from({ length: 8 }, async () => {
    while (siguiente < p.puros.length) {
      const i = siguiente++;
      juicios[i] = await encaja(p.puros[i]);
    }
  }));
  const buenos = p.puros.filter((_, i) => juicios[i]);
  return (buenos.length >= 10 ? buenos : p.puros).slice(0, 40);
}

/**
 * Los códigos que se capturan: los de los vecinos que salen al menos dos
 * veces, y los de 4 dígitos donde caen al menos tres de los 200 más
 * parecidos. Capturar solo los de los vecinos se quedaba corto con las
 * empresas más amplias que su descripción; las familias enteras traían
 * demasiado.
 */
export function codigosDelVecindario(p: Parecidos): string[] {
  const cuenta = (ls: Adjudicada[]) => {
    const m = new Map<string, number>();
    for (const l of ls) m.set(l.prefijo_principal, (m.get(l.prefijo_principal) ?? 0) + 1);
    return m;
  };
  const deVecinos = [...cuenta(p.vecinos).entries()].filter(([, n]) => n >= 2).map(([c]) => c);
  const deVecindario = [...cuenta(p.ordenados.slice(0, 200).map(({ l }) => l)).entries()]
    .filter(([, n]) => n >= 3).map(([c]) => c);
  return [...new Set([...deVecinos, ...deVecindario])];
}

/**
 * Los más parecidos de cada familia, para enseñárselos. Solo los que
 * están entre los 200 más parecidos de toda la búsqueda (el vecindario):
 * con una descripción vaga, lo "más parecido" de una familia que no es
 * la suya puede no parecerse en nada (a un suministrador de centros
 * educativos le salían hemoderivados bajo material sanitario), y es
 * mejor que esa familia se quede sin ejemplos.
 */
export function ejemplosPorFamilia(p: Parecidos, familias: string[], cuantos = 3) {
  const vecindario = p.ordenados.slice(0, 200);
  return Object.fromEntries(familias.map((f) => {
    const vistos = new Set<string>();
    return [f, vecindario
      .filter(({ l }) => l.prefijo_principal.startsWith(f) || f.startsWith(l.prefijo_principal))
      // Sin repetir título: hay expedientes con varios lotes iguales.
      .filter(({ l }) => {
        const t = l.titulo.trim().toLowerCase();
        return !vistos.has(t) && !!vistos.add(t);
      })
      .slice(0, cuantos)
      .map(({ l }) => ({
        titulo: l.titulo, organo: l.organo ?? "", importe: l.importe ?? l.presupuesto,
        adjudicatario: l.adjudicatario ?? "",
      }))];
  }));
}

// Nombres de las divisiones CPV (vocabulario común de 2008), para el
// catálogo de `proponer`. Sin ellos el modelo solo veía "18: 12.917" y,
// con "prefiere divisiones con volumen alto", escogía las más grandes:
// a una empresa de ropa y equipo le propuso obras, servicios a empresas,
// material médico y mantenimiento. Con nombres acertó la familia en
// todos los perfiles simulados.
export const DIVISIONES: Record<string, string> = {
  "03": "Productos de la agricultura, ganadería, pesca y silvicultura",
  "09": "Derivados del petróleo, combustibles, electricidad y otras fuentes de energía",
  "14": "Productos de la minería, metales de base y productos conexos",
  "15": "Alimentos, bebidas, tabaco y productos afines",
  "16": "Maquinaria agrícola",
  "18": "Prendas de vestir, calzado, artículos de viaje y accesorios",
  "19": "Piel, textiles, plástico y caucho",
  "22": "Impresos y productos relacionados",
  "24": "Productos químicos",
  "30": "Máquinas, equipo y artículos de oficina y de informática",
  "31": "Máquinas, aparatos, equipo y productos consumibles eléctricos; iluminación",
  "32": "Equipos de radio, televisión, comunicaciones y telecomunicaciones",
  "33": "Equipamiento y artículos médicos, farmacéuticos y de higiene personal",
  "34": "Equipos de transporte y productos auxiliares",
  "35": "Equipo de seguridad, extinción de incendios, policía y defensa",
  "37": "Instrumentos musicales, artículos deportivos, juegos, juguetes, artesanía y material artístico",
  "38": "Equipo de laboratorio, óptico y de precisión",
  "39": "Mobiliario, enseres domésticos, aparatos electrodomésticos y productos de limpieza",
  "41": "Agua recogida y depurada",
  "42": "Maquinaria industrial",
  "43": "Maquinaria para la minería y la construcción",
  "44": "Estructuras y materiales de construcción; productos auxiliares",
  "45": "Trabajos de construcción (obras)",
  "48": "Paquetes de software y sistemas de información",
  "50": "Servicios de reparación y mantenimiento",
  "51": "Servicios de instalación (excepto software)",
  "55": "Servicios comerciales al por menor de hostelería y restauración",
  "60": "Servicios de transporte (excluido el transporte de residuos)",
  "63": "Servicios de transporte complementarios y auxiliares; agencias de viajes",
  "64": "Servicios de correos y telecomunicaciones",
  "65": "Servicios públicos (agua, gas, electricidad)",
  "66": "Servicios financieros y de seguros",
  "70": "Servicios inmobiliarios",
  "71": "Servicios de arquitectura, construcción, ingeniería e inspección",
  "72": "Servicios TI: consultoría, desarrollo de software, Internet y apoyo",
  "73": "Servicios de investigación y desarrollo y servicios de consultoría conexos",
  "75": "Administración pública, defensa y servicios de seguridad social",
  "76": "Servicios relacionados con la industria del gas y del petróleo",
  "77": "Servicios agrícolas, forestales, hortícolas, acuícolas y apícolas",
  "79": "Servicios a empresas: legislación, mercadotecnia, asesoría, selección, impresión y seguridad",
  "80": "Servicios de enseñanza y formación",
  "85": "Servicios de salud y asistencia social",
  "90": "Servicios de alcantarillado, basura, limpieza y medio ambiente",
  "92": "Servicios de esparcimiento, culturales y deportivos",
  "98": "Otros servicios comunitarios, sociales o personales",
};
