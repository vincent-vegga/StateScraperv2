// ============================================================
// Simular el alta sin NIF con empresas que sí tienen NIF
// ============================================================
//
// Para decidir cómo entra quien no tiene contratos ganados. Se toma cada
// perfil con NIF, se hace como si hubiera entrado describiendo su
// negocio, y se compara el filtro que saldría con el suyo real.
//
// Variantes, todas desde la misma descripción (y con las familias que el
// cliente deja marcadas):
//
//   solo_descripcion    Criterio de la descripción y captura por familias
//                       (catálogo con nombres, DIVISIONES).
//   vecinos_vecindario  Lo que hay en producción desde el 24/09/2026: los
//                       40 adjudicados más parecidos a la descripción
//                       (embeddings, con diversidad, de su tamaño) como
//                       ejemplos del criterio; se capturan sus códigos y
//                       los de 4 dígitos donde caen al menos tres de los
//                       200 más parecidos.
//   titulos_vecindario  Lo mismo, buscando con títulos típicos de la
//                       empresa que escribe el modelo (titulosTipicos, en
//                       vecinos.ts) en vez de con la descripción.
//
// Medidas en vueltas anteriores y retiradas: tarjetas, referentes, que el
// cliente revise los ejemplos, capturar solo los códigos de los vecinos o
// las familias enteras, y esconder lo que pasa de su tamaño. Sin
// contratos menores.
//
// Las respuestas del "cliente" (familias, tarjetas, franjas, referentes,
// la empresa que conoce por su nombre)
// las da un oráculo con sus datos reales: es la cota de lo que cada
// camino puede dar si el cliente contesta bien, no lo que dará siempre.
//
// SOLO LEE. No escribe en ninguna tabla. Lo que sale:
//   - En la consola y en el resumen de la ejecución, solo cifras y
//     perfiles anónimos (P01, P02...): el repositorio es público y los
//     registros de Actions también.
//   - El detalle, con nombres, en `simulacion/detalle.json`, que el
//     workflow cifra antes de subir.
//
//   deno run -A scripts/simular_sin_nif.ts [--solo=P03,P08] [--muestra=100]
//
// Variables: SUPABASE_URL, SUPABASE_KEY (clave secreta), OPENAI_API_KEY.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { llamarModelo } from "../supabase/functions/alta/modelo.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_KEY")!,
  { auth: { persistSession: false } });

const arg = (nombre: string) =>
  Deno.args.find((a) => a.startsWith(`--${nombre}=`))?.split("=")[1];
const SOLO = arg("solo");
// Licitaciones por estrato en la evaluación: dentro de sus prefijos
// reales y fuera de ellos.
const MUESTRA = Number(arg("muestra") ?? 100);
const SALIDA = "simulacion";
// MODO=exportar: solo las empresas que ya van por huellas, y en vez de
// evaluar se guarda lo que les daría el alta sin NIF (vecinos, criterio,
// códigos) en simulacion/sinteticos.json, para medir_sintetico.py.
const EXPORTAR = Deno.env.get("MODO") === "exportar";
const exportados: Record<string, unknown>[] = [];

// ------------------------------------------------------------
// Las mismas instrucciones que en producción
// ------------------------------------------------------------
//
// Se leen del código de la función de alta y del cribador en vez de
// copiarlas: si alguien las cambia, la simulación mide las nuevas.
// index.ts no se puede importar (arranca el servidor al cargarse).

const fuenteAlta = await Deno.readTextFile(
  new URL("../supabase/functions/alta/index.ts", import.meta.url));
const fuenteCribador = await Deno.readTextFile(
  new URL("../cribador.py", import.meta.url));

function constante(nombre: string): string {
  const m = fuenteAlta.match(new RegExp(`const ${nombre} = (\`[\\s\\S]*?\`);`));
  if (!m) throw new Error(`No encuentro ${nombre} en alta/index.ts`);
  return new Function(`return ${m[1]};`)();
}
const INSTRUCCIONES_CPV = constante("INSTRUCCIONES_CPV");
const INSTRUCCIONES_CRITERIO = constante("INSTRUCCIONES_CRITERIO");
const CUANTAS = 30;

const FORMATO = fuenteCribador.match(/FORMATO = """([\s\S]*?)"""/)?.[1];
if (!FORMATO) throw new Error("No encuentro FORMATO en cribador.py");

// ------------------------------------------------------------
// Utilidades
// ------------------------------------------------------------

const sinTildes = (s: string) =>
  s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();

// Azar con semilla: dos ejecuciones con los mismos datos enseñan las
// mismas tarjetas y evalúan las mismas licitaciones.
function azar(semilla: number) {
  return () => {
    semilla |= 0; semilla = semilla + 0x6D2B79F5 | 0;
    let t = Math.imul(semilla ^ semilla >>> 15, 1 | semilla);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
function barajar<T>(lista: T[], r: () => number) {
  for (let i = lista.length - 1; i > 0; i--) {
    const j = Math.floor(r() * (i + 1));
    [lista[i], lista[j]] = [lista[j], lista[i]];
  }
  return lista;
}

async function enParalelo<T, R>(xs: T[], n: number, f: (x: T) => Promise<R>) {
  const salida: R[] = new Array(xs.length);
  let siguiente = 0;
  await Promise.all(Array.from({ length: Math.min(n, xs.length) }, async () => {
    while (siguiente < xs.length) {
      const i = siguiente++;
      salida[i] = await f(xs[i]);
    }
  }));
  return salida;
}

const mediana = (xs: number[]) => {
  if (!xs.length) return null;
  const o = [...xs].sort((a, b) => a - b);
  return o[Math.floor(o.length / 2)];
};

// Franjas cerradas, las mismas que vería el cliente.
const FRANJAS = ["<15k", "15-100k", "100k-1M", ">1M"] as const;
function franja(importe: number | null): string | null {
  if (importe == null || !(importe > 0)) return null;
  if (importe < 15_000) return "<15k";
  if (importe < 100_000) return "15-100k";
  if (importe < 1_000_000) return "100k-1M";
  return ">1M";
}

// ------------------------------------------------------------
// Datos
// ------------------------------------------------------------

// Si el scraper tiene algo bloqueado (recalcula resúmenes mientras
// corre), la lectura espera y reintenta: se le cede el paso en vez de
// fallar. 55P03 = lock timeout; 57014 = tiempo agotado.
async function leer<T extends { error: unknown }>(consulta: () => PromiseLike<T>): Promise<T> {
  let r = await consulta();
  for (let intento = 1; intento <= 8 && r.error; intento++) {
    const codigo = (r.error as { code?: string }).code;
    if (codigo !== "55P03" && codigo !== "57014") break;
    await new Promise((ok) => setTimeout(ok, 15_000 * intento));
    r = await consulta();
  }
  return r;
}

type Lic = {
  id_licitacion: string; titulo: string; organo: string | null;
  presupuesto: number | null; presupuesto_base: number | null;
  importe_adjudicacion: number | null; procedimiento: string | null;
  adjudicatario_cif: string | null; adjudicatario: string | null;
  prefijo_principal: string; prefijos: string[] | null; cpvs: string[] | null;
  fecha_actualizacion: string;
};
const COLUMNAS = "id_licitacion,titulo,organo,presupuesto,presupuesto_base," +
  "importe_adjudicacion,procedimiento,adjudicatario_cif,adjudicatario," +
  "prefijo_principal,prefijos,cpvs,fecha_actualizacion";
const esMenor = (l: Lic) => l.procedimiento === "Contrato menor";
const importeDe = (l: Lic) =>
  l.importe_adjudicacion != null ? Number(l.importe_adjudicacion)
    : l.presupuesto_base != null ? Number(l.presupuesto_base) : null;

// Prefijos de 4 dígitos que existen, con su volumen: para desplegar una
// familia de 2 en lo que de verdad cuelga de ella, y para pesar los
// estratos de la evaluación.
const volumen4 = new Map<string, number>();
for (let desde = 0; ; desde += 1000) {
  const { data, error } = await leer(() => db.from("resumen_cpv_total")
    .select("prefijo, licitaciones").like("prefijo", "____")
    .range(desde, desde + 999));
  if (error) throw error;
  for (const r of data ?? []) volumen4.set(r.prefijo, Number(r.licitaciones ?? 0));
  if ((data ?? []).length < 1000) break;
}

function desplegar(prefijos: string[]): string[] {
  const salida = new Set<string>();
  for (const p of prefijos) {
    if (p.length >= 4) {
      if (volumen4.has(p.slice(0, 4))) salida.add(p.slice(0, 4));
    } else {
      for (const q of volumen4.keys()) if (q.startsWith(p)) salida.add(q);
    }
  }
  return [...salida];
}

// Lo último adjudicado de cada prefijo, uno a uno: así usa el índice
// (prefijo_principal, fecha_actualizacion). Pedirlo todo junto con
// `in (...)` o con `prefijos && ...` pasaba de 6 s y competía con el
// scraper. Se guarda: los perfiles comparten prefijos.
const POR_PREFIJO = 300;
const cache = new Map<string, Promise<Lic[]>>();
const tiempos: number[] = [];
function delPrefijo(p4: string): Promise<Lic[]> {
  if (!cache.has(p4)) {
    cache.set(p4, (async () => {
      for (let intento = 0; intento < 3; intento++) {
        const t0 = Date.now();
        const { data, error } = await leer(() => db.from("licitaciones").select(COLUMNAS)
          .eq("prefijo_principal", p4).not("adjudicatario_cif", "is", null)
          .order("fecha_actualizacion", { ascending: false }).limit(POR_PREFIJO));
        tiempos.push(Date.now() - t0);
        if (!error) return (data ?? []) as unknown as Lic[];
        await new Promise((r) => setTimeout(r, 2000 * (intento + 1)));
      }
      console.log(`   aviso: no se pudo leer un prefijo tras 3 intentos`);
      return [];
    })());
  }
  return cache.get(p4)!;
}
async function deLosPrefijos(p4s: string[]): Promise<Lic[]> {
  return (await enParalelo(p4s, 4, delPrefijo)).flat();
}

// ------------------------------------------------------------
// Modelo
// ------------------------------------------------------------

let llamadas = 0;
const modelo = (...a: Parameters<typeof llamarModelo>) => { llamadas++; return llamarModelo(...a); };

// El mismo mensaje que construye cribador.py cada noche.
function ficha(l: Lic) {
  const partes = [`Título: ${l.titulo ?? ""}`];
  if (l.organo) partes.push(`Órgano: ${l.organo}`);
  if (l.presupuesto != null) {
    const importe = Number(l.presupuesto).toLocaleString("es-ES",
      { minimumFractionDigits: 2, maximumFractionDigits: 2, useGrouping: "always" });
    partes.push(`Presupuesto: ${importe} EUR`);
  }
  const cpvs = l.cpvs ?? [];
  if (cpvs.length) partes.push(`CPV: ${cpvs.slice(0, 8).join(", ")}`);
  return partes.join("\n");
}

async function veredicto(criterio: string, l: Lic): Promise<string | null> {
  try {
    const r = await modelo([
      { role: "system", content: criterio + FORMATO },
      { role: "user", content: ficha(l) },
    ], 150);
    const v = sinTildes(String(r.veredicto ?? "")).trim();
    return ["si", "quizas", "no"].includes(v) ? v : null;
  } catch {
    return null;
  }
}

async function describirComoCliente(actividad: string): Promise<string> {
  const r = await modelo([
    { role: "system", content:
      "Reescribe a qué se dedica esta empresa como lo contaría su dueño en " +
      "un formulario, con sus palabras: una o dos frases, en primera persona " +
      "del plural, sin códigos CPV, sin nombre de empresa, sin organismos " +
      "concretos y sin cifras. Como alguien que aún no ha trabajado con la " +
      "administración. Devuelve EXCLUSIVAMENTE JSON: {\"descripcion\":\"...\"}" },
    { role: "user", content: actividad },
  ], 200);
  return String(r.descripcion ?? actividad).trim();
}

// Nombres de las divisiones CPV (vocabulario común de 2008). El
// catálogo de `proponer` en producción solo lleva número y volumen, y
// con "prefiere divisiones con volumen alto" el modelo, que no sabe de
// memoria qué es la 18 o la 35, escoge las más grandes: para una
// descripción de ropa y equipo propuso obras, servicios a empresas,
// material médico y mantenimiento. Con `conNombres` se mide la corrección.
const DIVISIONES: Record<string, string> = {
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

// Réplica de `proponer` en alta/index.ts.
async function proponer(descripcion: string, conNombres: boolean) {
  const { data: divisiones } = await leer(() => db.from("resumen_cpv_total")
    .select("prefijo, licitaciones").gt("licitaciones", 50)
    .order("licitaciones", { ascending: false }).limit(400));
  const catalogo = (divisiones ?? []).filter((d) => d.prefijo.length === 2)
    .map((d) => conNombres && DIVISIONES[d.prefijo]
      ? `${d.prefijo} (${DIVISIONES[d.prefijo]}): ${d.licitaciones}`
      : `${d.prefijo}: ${d.licitaciones}`).join("\n");

  const salida = await modelo([
    { role: "system", content: INSTRUCCIONES_CPV },
    { role: "system", content: `Divisiones CPV con contenido en la base de datos, ` +
      `con su número de licitaciones. Elige SOLO de esta lista:\n${catalogo}` },
    { role: "user", content: descripcion },
  ]);
  let prefijos = ((salida.prefijos ?? []) as Record<string, unknown>[])
    .map((p) => String(p.prefijo ?? "").replace(/\D/g, ""))
    .filter((p) => p.length >= 2 && p.length <= 6);
  const limpiar = (xs: unknown) => (Array.isArray(xs) ? xs : [])
    .map((p) => sinTildes(String(p)).replace(/[^a-z0-9ñ]/g, ""))
    .filter((p) => p.length >= 4).slice(0, 12);
  let producto = limpiar(salida.producto);
  let destinatario = limpiar(salida.destinatario);

  const { data: resumen } = await leer(() => db.from("resumen_cpv_total")
    .select("prefijo, licitaciones").in("prefijo", prefijos));
  const vol = Object.fromEntries((resumen ?? []).map((r) => [r.prefijo, r.licitaciones]));
  const conVolumen = prefijos.filter((p) => (vol[p] ?? 0) > 0);
  if (conVolumen.length) prefijos = conVolumen;

  const util = async (palabras: string[], tope: number) => {
    if (!palabras.length) return [];
    const { data } = await leer(() => db.rpc("utilidad_palabras", { palabras }));
    if (!data) return palabras;
    const buenas = (data as { palabra: string; porcentaje: number }[])
      .filter((d) => d.porcentaje <= tope).map((d) => d.palabra);
    return buenas.length ? buenas : palabras;
  };
  producto = await util(producto, 8);
  destinatario = await util(destinatario, 4);
  return { prefijos, producto, destinatario };
}

// Réplica de `generarCriterio` en alta/index.ts.
async function generarCriterio(descripcion: string, ejemplos: {
  titulo: string; organo: string; cpvs: string; interesa: boolean;
}[]) {
  const lista = (xs: typeof ejemplos) =>
    xs.map((e) => `- ${e.titulo}${e.organo ? ` (${e.organo})` : ""} [CPV ${e.cpvs}]`).join("\n");
  const si = ejemplos.filter((e) => e.interesa);
  const no = ejemplos.filter((e) => !e.interesa);
  const r = await modelo([
    { role: "system", content: INSTRUCCIONES_CRITERIO },
    { role: "user", content: `NEGOCIO:\n${descripcion}\n\n` +
      `LE INTERESAN (${si.length}):\n${lista(si)}\n\n` +
      `NO LE INTERESAN (${no.length}):\n${lista(no)}` },
  ], 1400);
  return String(r.criterio ?? "");
}

// ------------------------------------------------------------
// Caminos
// ------------------------------------------------------------

type Resultado = {
  criterio: string; prefijos: string[]; usadas: string[];
  detalle: Record<string, unknown>;
};

// Las tarjetas se escogen como en `material` (sin NIF): mitad claras
// (dicen lo que vende y a quién), mitad frontera (lo que vende, a otro).
function escogerTarjetas(claras: Lic[], dudosas: Lic[], r: () => number) {
  barajar(claras, r); barajar(dudosas, r);
  const mitad = Math.floor(CUANTAS / 2);
  const deClaras = Math.min(mitad, claras.length);
  const escogidas = [...claras.slice(0, deClaras), ...dudosas.slice(0, CUANTAS - deClaras)];
  if (escogidas.length < CUANTAS) {
    escogidas.push(...claras.slice(deClaras, deClaras + CUANTAS - escogidas.length));
  }
  const vistas = new Set<string>();
  return barajar(escogidas.filter((f) => !vistas.has(f.id_licitacion) &&
    !!vistas.add(f.id_licitacion)).slice(0, CUANTAS), r);
}

async function contestarTarjetas(descripcion: string, familias: string[],
                                 tarjetas: Lic[], criterioReal: string,
                                 extra: Record<string, unknown>): Promise<Resultado> {
  // El oráculo: le interesa lo que su filtro real daría por "sí".
  const respuestas = await enParalelo(tarjetas, 5, async (t) => ({
    titulo: t.titulo, organo: t.organo ?? "", cpvs: (t.cpvs ?? []).join(","),
    interesa: (await veredicto(criterioReal, t)) === "si",
  }));
  const criterio = await generarCriterio(descripcion, respuestas);
  return {
    criterio, prefijos: familias, usadas: tarjetas.map((t) => t.id_licitacion),
    detalle: { ...extra, tarjetas: respuestas.length,
               les_interesa: respuestas.filter((x) => x.interesa).length,
               titulos_si: respuestas.filter((x) => x.interesa).map((x) => x.titulo).slice(0, 10) },
  };
}

async function tarjetasHoy(descripcion: string, prop: Awaited<ReturnType<typeof proponer>>,
                           familias: string[], criterioReal: string, r: () => number) {
  const args = { prefijos_buscados: familias, producto: prop.producto,
                 destinatario: prop.destinatario, solo_vivas: false, tope: 60 };
  const [encajan, frontera] = await Promise.all([
    prop.producto.length ? leer(() => db.rpc("licitaciones_del_vecindario", { ...args, con_destinatario: true }))
      : Promise.resolve({ data: [] }),
    prop.producto.length ? leer(() => db.rpc("licitaciones_del_vecindario", { ...args, con_destinatario: false }))
      : Promise.resolve({ data: [] }),
  ]);
  const claras = (encajan.data ?? []) as Lic[];
  let dudosas = (frontera.data ?? []) as Lic[];
  const delVecindario = claras.length + dudosas.length;
  if (delVecindario < CUANTAS) {
    const { data: sueltas } = await leer(() => db.rpc("licitaciones_por_prefijo",
      { prefijos: familias, solo_vivas: false, tope: 300 }));
    dudosas = [...dudosas, ...((sueltas ?? []) as Lic[])];
  }
  const tarjetas = escogerTarjetas([...claras], dudosas, r);
  return contestarTarjetas(descripcion, familias, tarjetas, criterioReal,
    { del_vecindario: delVecindario });
}

// Sin tarjetas ni ejemplos: el criterio sale solo de la descripción y
// captura por las familias. Es el suelo del camino nuevo: lo que queda
// si no reconoce a nadie ni conoce ninguna empresa del sector.
async function soloDescripcion(descripcion: string, familias: string[]): Promise<Resultado> {
  return { criterio: await generarCriterio(descripcion, []), prefijos: familias,
           usadas: [], detalle: {} };
}

type Candidata = {
  cif: string; nombre: string; contratos: number; importe_mediano: number | null;
  de_su_tamano: boolean; competidora: boolean; ejemplos: string[]; ls: Lic[];
};

// El camino nuevo: descripción → referentes → franjas.
//
// Devuelve dos resultados con el mismo criterio y distinta captura:
//   medio   Los prefijos de los referentes y los de 4 dígitos donde más
//           aparece lo que describe (el vecindario).
//   amplio  Los prefijos de los referentes y las familias enteras.
// En la primera vuelta la captura eran solo los prefijos de los
// referentes, y salía estrecha: su especialidad, no todo lo suyo.
//
// Si con la lista no llega al mínimo (3 referentes o 15 contratos
// prestados), busca por nombre una empresa que conozca. Si ni así,
// se queda con el criterio de la descripción.
async function porReferentes(descripcion: string, prop: Awaited<ReturnType<typeof proponer>>,
                             familias: string[], franjas: string[], cifPropio: string,
                             prefijosReales: string[], criterioReal: string, suelo: Resultado) {
  const t0 = Date.now();
  const todas = (await deLosPrefijos(desplegar(familias))).filter((l) => !esMenor(l));
  const msLectura = Date.now() - t0;

  const dice = (l: Lic) => {
    const t = sinTildes(l.titulo ?? "");
    return prop.producto.some((p) => t.includes(p));
  };
  // Solo lo que se parece a su descripción: de una empresa que lo hace
  // todo, la parte que coincide con lo suyo.
  const coinciden = prop.producto.length ? todas.filter(dice) : todas;

  const porEmpresa = new Map<string, Lic[]>();
  for (const l of coinciden) {
    const cif = String(l.adjudicatario_cif ?? "");
    if (!cif || cif === cifPropio) continue;
    porEmpresa.set(cif, [...(porEmpresa.get(cif) ?? []), l]);
  }

  const enFranja = (l: Lic) => franjas.includes(franja(importeDe(l)) ?? "");
  const describir = (cif: string, ls: Lic[]): Candidata => ({
    cif, nombre: ls[0]?.adjudicatario ?? "", contratos: ls.length,
    importe_mediano: mediana(ls.map(importeDe).filter((x): x is number => x != null)),
    de_su_tamano: ls.filter(enFranja).length / (ls.length || 1) >= 0.5,
    competidora: false,
    ejemplos: ls.slice(0, 3).map((l) => l.titulo), ls,
  });
  // El oráculo la "reconoce" si hace lo mismo que él: al menos la mitad
  // de cinco contratos suyos pasan su filtro real. En la primera vuelta
  // bastaba con ganar en sus mismos prefijos, y a una empresa de
  // servicios educativos le daba por competidoras academias de
  // formación marítima: mismo código, otro oficio.
  const reconocer = async (c: Candidata) => {
    const vistos = await enParalelo(c.ls.slice(0, 5), 5, (l) => veredicto(criterioReal, l));
    c.competidora = vistos.filter((v) => v === "si" || v === "quizas").length * 2 >= vistos.length;
    return c;
  };
  const candidatas = [...porEmpresa.entries()].filter(([, ls]) => ls.length >= 2)
    .map(([cif, ls]) => describir(cif, ls)).sort((a, b) => b.contratos - a.contratos);

  const suTamano = candidatas.filter((c) => c.de_su_tamano).slice(0, 12);
  const grandes = candidatas.filter((c) => !c.de_su_tamano).slice(0, 6);
  await enParalelo([...suTamano, ...grandes], 2, reconocer);
  const elegidas = [...suTamano, ...grandes].filter((c) => c.competidora).slice(0, 5);

  // El historial prestado: lo de sus referentes que coincide con lo suyo
  // y cae en sus franjas. Si en sus franjas hay muy poco, todo lo que
  // coincide: mejor un historial algo grande que uno de tres contratos.
  const prestar = (es: Candidata[]) => {
    const coincidentes = es.flatMap((c) => c.ls);
    const enFranjas = coincidentes.filter(enFranja);
    return (enFranjas.length >= 8 ? enFranjas : coincidentes)
      .sort((a, b) => b.fecha_actualizacion.localeCompare(a.fecha_actualizacion)).slice(0, 40);
  };
  const llega = (es: Candidata[]) => es.length >= 3 || prestar(es).length >= 15;

  let salida = "lista";
  let porNombre: string | null = null;
  if (!llega(elegidas)) {
    // "¿Conoces alguna empresa que haga lo mismo que tú?". El oráculo
    // conoce las que más ganan en sus prefijos reales, que son las que
    // cualquiera del sector sabría nombrar, y da la primera que
    // reconoce. Sus contratos se toman por NIF (índice
    // idx_licitaciones_cif), cruzados con lo que describe.
    const reales = await deLosPrefijos(desplegar(prefijosReales));
    const cuenta = new Map<string, number>();
    for (const l of reales) {
      const c = String(l.adjudicatario_cif ?? "");
      if (c && c !== cifPropio && !esMenor(l)) cuenta.set(c, (cuenta.get(c) ?? 0) + 1);
    }
    const conocidas = [...cuenta.entries()].sort((a, b) => b[1] - a[1])
      .map(([c]) => c).filter((c) => !elegidas.some((e) => e.cif === c)).slice(0, 5);
    for (const conocida of conocidas) {
      const { data } = await leer(() => db.from("licitaciones").select(COLUMNAS)
        .eq("adjudicatario_cif", conocida).order("fecha_actualizacion", { ascending: false })
        .limit(300));
      const suyas = ((data ?? []) as unknown as Lic[]).filter((l) => !esMenor(l));
      const cruzadas = prop.producto.length ? suyas.filter(dice) : suyas;
      const c = await reconocer(describir(conocida, cruzadas.length >= 8 ? cruzadas : suyas));
      if (c.contratos && c.competidora) {
        elegidas.push(c); porNombre = c.nombre; salida = "por_nombre"; break;
      }
    }
  }

  const resumenCandidatas = [...suTamano, ...grandes].map(({ ls: _, ...c }) => c);
  const base = { candidatas: candidatas.length, enseñadas: resumenCandidatas,
                 elegidas: elegidas.map((c) => c.nombre), por_nombre: porNombre, ms_lectura: msLectura };

  // Con la empresa que conoce basta un historial algo más corto.
  if (!elegidas.length || (!llega(elegidas) && prestar(elegidas).length < 8)) {
    const d = { ...base, salida: "solo_descripcion" };
    return { medio: { ...suelo, detalle: d }, amplio: { ...suelo, detalle: d } };
  }

  const prestados = prestar(elegidas);
  const cuentaP = new Map<string, number>();
  for (const l of prestados) cuentaP.set(l.prefijo_principal, (cuentaP.get(l.prefijo_principal) ?? 0) + 1);
  const prefijos = [...cuentaP.entries()].map(([prefijo, contratos]) => ({ prefijo, contratos }));

  // El criterio parte de SU descripción, con lo de sus referentes como
  // ejemplos de lo que le interesa: igual que el alta con NIF suma lo
  // ganado a las tarjetas. En la primera versión salía de leerHistorial,
  // que no ve la descripción, y describía a los referentes: a quien
  // hace sonido para eventos le salió "suministro de instrumentos
  // musicales".
  const criterio = await generarCriterio(descripcion, prestados.map((l) => ({
    titulo: l.titulo, organo: l.organo ?? "", cpvs: (l.cpvs ?? []).join(","), interesa: true,
  })));
  // Sus prefijos: los que aparecen al menos dos veces en lo prestado.
  const deReferentes = prefijos.filter((p) => p.contratos >= 2).map((p) => p.prefijo);

  // El vecindario en 4 dígitos: donde aparece lo que describe al menos
  // tres veces, los diez que más.
  const porP4 = new Map<string, number>();
  for (const l of coinciden) porP4.set(l.prefijo_principal, (porP4.get(l.prefijo_principal) ?? 0) + 1);
  const vecindario = [...porP4.entries()].filter(([, n]) => n >= 3)
    .sort((a, b) => b[1] - a[1]).slice(0, 10).map(([p]) => p);

  const detalle = { ...base, salida, prestados: prestados.length, de_referentes: deReferentes,
                    vecindario };
  const usadas = prestados.map((l) => l.id_licitacion);
  return {
    medio: { criterio, usadas, detalle, prefijos: [...new Set([...deReferentes, ...vecindario])] },
    amplio: { criterio, usadas, detalle, prefijos: [...new Set([...deReferentes, ...familias])] },
  };
}

// ------------------------------------------------------------
// Historial sintético: los contratos más parecidos a su descripción
// ------------------------------------------------------------
//
// Lo que tiene la entrada por NIF y no tiene la descripción son
// EJEMPLOS: contratos concretos de los que sacar el criterio y los
// códigos. Aquí se buscan: de lo adjudicado en sus familias, los que más
// se parecen en significado a lo que ha escrito (embeddings, no palabras
// sueltas), dentro de su tamaño. Hacen de historial, como si fueran
// suyos, y quienes los ganaron son sus competidores.

const EMBEDDINGS = "https://api.openai.com/v1/embeddings";
const incrustados = new Map<string, number[]>();
let tokensEmbedding = 0;

async function incrustar(textos: string[]): Promise<number[][]> {
  const salida: number[][] = [];
  for (let i = 0; i < textos.length; i += 1000) {
    const tanda = textos.slice(i, i + 1000).map((t) => t.slice(0, 500) || "-");
    for (let intento = 0; ; intento++) {
      const r = await fetch(EMBEDDINGS, {
        method: "POST",
        headers: { "Authorization": `Bearer ${Deno.env.get("OPENAI_API_KEY")}`,
                   "Content-Type": "application/json" },
        body: JSON.stringify({ model: "text-embedding-3-small", input: tanda, dimensions: 256 }),
      });
      if (r.ok) {
        const d = await r.json();
        tokensEmbedding += d.usage?.total_tokens ?? 0;
        for (const e of d.data) salida.push(e.embedding);
        break;
      }
      await r.body?.cancel();
      if (intento >= 4) throw new Error(`embeddings ${r.status}`);
      await new Promise((ok) => setTimeout(ok, 2000 * (intento + 1)));
    }
  }
  return salida;
}

// Vienen normalizados: el producto escalar es el coseno.
const coseno = (a: number[], b: number[]) => a.reduce((s, x, i) => s + x * b[i], 0);

async function vectoresDe(ls: Lic[]) {
  const faltan = ls.filter((l) => !incrustados.has(l.id_licitacion));
  const vs = await incrustar(faltan.map((l) => l.titulo ?? ""));
  faltan.forEach((l, i) => incrustados.set(l.id_licitacion, vs[i]));
  return ls.map((l) => incrustados.get(l.id_licitacion)!);
}

const techoDe = (franjas: string[]) =>
  franjas.includes(">1M") ? Infinity : franjas.includes("100k-1M") ? 1_000_000
    : franjas.includes("15-100k") ? 100_000 : 15_000;
// Lo que se licita, no lo adjudicado: es lo que verá en sus alertas.
const presupuestoDe = (l: Lic) =>
  l.presupuesto_base != null ? Number(l.presupuesto_base)
    : l.presupuesto != null ? Number(l.presupuesto) : importeDe(l);

async function buscarVecinos(descripcion: string, familias: string[], franjas: string[],
                             cifPropio: string, buscadas: string[] = []) {
  const pool = (await deLosPrefijos(desplegar(familias)))
    .filter((l) => !esMenor(l) && l.adjudicatario_cif !== cifPropio && l.titulo);
  const vistos = new Set<string>();
  const unicos = pool.filter((l) => !vistos.has(l.id_licitacion) && !!vistos.add(l.id_licitacion));
  // Con títulos típicos de la empresa, cuenta el más parecido de ellos.
  const consultas = await incrustar(buscadas.length ? buscadas : [descripcion]);
  const vs = await vectoresDe(unicos);
  const ordenados = unicos.map((l, i) => ({ l, s: Math.max(...consultas.map((c) => coseno(c, vs[i]))) }))
    .sort((a, b) => b.s - a.s);

  // Dentro de su tamaño si hay con qué: de los 200 más parecidos, los
  // de sus franjas; si son menos de 15, los más parecidos sin más.
  const top = ordenados.slice(0, 200);
  const enFranjas = top.filter(({ l }) => franjas.includes(franja(importeDe(l)) ?? ""));
  const candidatos = enFranjas.length >= 15 ? enFranjas : top;

  // Con diversidad (MMR): cada vecino nuevo tiene que parecerse a la
  // descripción y aportar algo que no tengan ya los elegidos. Sin esto,
  // a quien vende mobiliario y material de oficina le salían cuarenta
  // variaciones de "suministro de mobiliario de oficina".
  const vec = (l: Lic) => incrustados.get(l.id_licitacion)!;
  const vecinos: typeof candidatos = [];
  const quedan = [...candidatos];
  while (vecinos.length < 40 && quedan.length) {
    let mejor = 0, puntos = -Infinity;
    quedan.forEach(({ l, s }, i) => {
      const parecido = vecinos.length ? Math.max(...vecinos.map((v) => coseno(vec(l), vec(v.l)))) : 0;
      const p = 0.7 * s - 0.3 * parecido;
      if (p > puntos) { puntos = p; mejor = i; }
    });
    vecinos.push(quedan.splice(mejor, 1)[0]);
  }
  return { ordenados, vecinos, en_franjas: enFranjas.length >= 15, pool: unicos.length };
}

// Criterio y códigos a partir de un historial (sintético): lo mismo que
// hace el alta con NIF, con la descripción como base.
async function desdeHistorial(descripcion: string, familias: string[],
                              si: Lic[], no: Lic[]): Promise<Resultado> {
  const ejemplo = (l: Lic, interesa: boolean) => ({
    titulo: l.titulo, organo: l.organo ?? "", cpvs: (l.cpvs ?? []).join(","), interesa });
  const criterio = await generarCriterio(descripcion,
    [...si.map((l) => ejemplo(l, true)), ...no.map((l) => ejemplo(l, false))]);
  const cuenta = new Map<string, number>();
  for (const l of si) cuenta.set(l.prefijo_principal, (cuenta.get(l.prefijo_principal) ?? 0) + 1);
  const prefijos = [...cuenta.entries()].filter(([, n]) => n >= 2).map(([p]) => p);
  return {
    criterio, prefijos: prefijos.length ? prefijos : familias,
    usadas: [...si, ...no].map((l) => l.id_licitacion),
    detalle: {
      positivos: si.length, negativos: no.length,
      // Los referentes que salen solos: quién ganó lo que se le parece.
      competidores: [...new Set(si.map((l) => l.adjudicatario).filter(Boolean))].slice(0, 12),
    },
  };
}

// La pantalla de familias con ejemplos: bajo cada familia, los tres
// contratos más parecidos a lo que ha escrito, marcados. El oráculo
// desmarca los que su filtro real no daría por buenos.
async function vecinosRevisados(descripcion: string, familias: string[],
                                v: Awaited<ReturnType<typeof buscarVecinos>>, criterioReal: string) {
  const enseñados = familias.flatMap((f) =>
    v.ordenados.filter(({ l }) => l.prefijo_principal.startsWith(f.slice(0, 4)))
      .slice(0, 3).map(({ l }) => l));
  const juicios = await enParalelo(enseñados, 5, (l) => veredicto(criterioReal, l));
  const desmarcados = enseñados.filter((_, i) => juicios[i] === "no");
  const fuera = new Set(desmarcados.map((l) => l.id_licitacion));
  // Un código cuyos ejemplos desmarcó todos, y ninguno marcó, no se
  // captura: es la familia que "no era suya" vista contrato a contrato.
  const marcadosP = new Set(enseñados.filter((l) => !fuera.has(l.id_licitacion)).map((l) => l.prefijo_principal));
  const vetados = new Set(desmarcados.map((l) => l.prefijo_principal).filter((p) => !marcadosP.has(p)));
  const si = [...enseñados.filter((l) => !fuera.has(l.id_licitacion)),
              ...v.vecinos.filter((l) => !fuera.has(l.l.id_licitacion) && !vetados.has(l.l.prefijo_principal))
                .map(({ l }) => l)];
  const vistos = new Set<string>();
  const unicos = si.filter((l) => !vistos.has(l.id_licitacion) && !!vistos.add(l.id_licitacion)).slice(0, 45);
  const res = await desdeHistorial(descripcion, familias, unicos, desmarcados);
  res.detalle = { ...res.detalle, enseñados: enseñados.length, desmarcados: desmarcados.length,
                  titulos_enseñados: enseñados.map((l, i) => `${juicios[i]} · ${l.titulo}`) };
  return res;
}

// ------------------------------------------------------------
// Evaluación
// ------------------------------------------------------------
//
// Dos estratos: licitaciones de sus prefijos reales y del resto de
// prefijos que alguna variante mira. Cada estrato pesa lo que su
// volumen en el catálogo; así la precisión y la cobertura estimadas
// valen para todo el volumen, no para la muestra.

const POSITIVOS = { si: ["si"], si_quizas: ["si", "quizas"] };

async function evaluar(real: { criterio: string; prefijos: string[] },
                       variantes: Record<string, Resultado | null>,
                       usadas: Set<string>, r: () => number, franjas: string[],
                       conTope: string[]) {
  const p4Reales = new Set(desplegar(real.prefijos));
  const p4Todos = new Set(p4Reales);
  for (const v of Object.values(variantes)) for (const p of desplegar(v?.prefijos ?? [])) p4Todos.add(p);

  // Lo que se evalúa es lo que llegaría como alerta: sin menores, que no
  // se anuncian, y 40 por prefijo para que ninguno domine.
  const filas = (await enParalelo([...p4Todos], 4, async (p) =>
    (await delPrefijo(p)).filter((l) => !esMenor(l) && !usadas.has(l.id_licitacion)).slice(0, 40)))
    .flat();
  const vistas = new Set<string>();
  const unicas = filas.filter((l) => !vistas.has(l.id_licitacion) && !!vistas.add(l.id_licitacion));

  const dentro = barajar(unicas.filter((l) => p4Reales.has(l.prefijo_principal)), r).slice(0, MUESTRA);
  const fuera = barajar(unicas.filter((l) => !p4Reales.has(l.prefijo_principal)), r).slice(0, MUESTRA);
  const poblacion = (reales: boolean) => [...p4Todos]
    .filter((p) => p4Reales.has(p) === reales)
    .reduce((n, p) => n + (volumen4.get(p) ?? 0), 0);
  const peso = {
    dentro: dentro.length ? poblacion(true) / dentro.length : 0,
    fuera: fuera.length ? poblacion(false) / fuera.length : 0,
  };

  const pasa = (l: Lic, prefijos: string[]) => (l.prefijos ?? []).some((p) => prefijos.includes(p));
  const muestra = [...dentro.map((l) => ({ l, w: peso.dentro })),
                   ...fuera.map((l) => ({ l, w: peso.fuera }))];

  const veredictos = await enParalelo(muestra, 6, async ({ l, w }) => {
    const fila: Record<string, string | null> = {};
    fila.real = pasa(l, real.prefijos) ? await veredicto(real.criterio, l) : "fuera";
    for (const [nombre, v] of Object.entries(variantes)) {
      fila[nombre] = v && v.criterio && pasa(l, v.prefijos) ? await veredicto(v.criterio, l) : "fuera";
    }
    return { id: l.id_licitacion, titulo: l.titulo, w, fila, presupuesto: presupuestoDe(l) };
  });

  // El tope no cambia el criterio: esconde lo que pasa de su techo (con
  // margen: lo que se pasa poco se enseña igual). Se mide sin llamadas
  // nuevas, como una variante más: lo que tiene precio por encima cuenta
  // como "no". El filtro real no sabe de tamaños, así que esto mide
  // cuánto relevante se pierde, y `volumen` cuánto adelgaza la lista.
  // Por debajo de 15.000 € casi todo son menores, que no se licitan: el
  // techo más bajo es el del abierto simplificado, unos 100.000 €.
  const techo = Math.max(techoDe(franjas) * 1.5, 100_000);
  for (const nombre of conTope) {
    for (const v of veredictos) {
      v.fila[`${nombre}+tope`] = v.fila[nombre] && v.fila[nombre] !== "fuera" &&
        (v.presupuesto ?? 0) > techo ? "tope" : v.fila[nombre];
    }
  }
  const metricas: Record<string, Record<string, unknown>> = {};
  for (const nombre of [...Object.keys(variantes), ...conTope.map((n) => `${n}+tope`)]) {
    metricas[nombre] = {};
    for (const [def, pos] of Object.entries(POSITIVOS)) {
      let vp = 0, fp = 0, fn = 0, nReal = 0, nVar = 0;
      for (const { w, fila } of veredictos) {
        if (fila.real === null || fila[nombre] === null) continue; // sin respuesta del modelo
        const esReal = pos.includes(fila.real!);
        const esVar = pos.includes(fila[nombre]!);
        if (esReal) nReal++;
        if (esVar) nVar++;
        if (esReal && esVar) vp += w;
        else if (esVar) fp += w;
        else if (esReal) fn += w;
      }
      const precision = vp + fp ? vp / (vp + fp) : null;
      const cobertura = vp + fn ? vp / (vp + fn) : null;
      const f1 = precision && cobertura ? 2 * precision * cobertura / (precision + cobertura) : 0;
      // Volumen estimado de la lista (pesado), para ver lo que adelgaza.
      const volumen = vp + fp;
      metricas[nombre][def] = { precision, cobertura, f1, volumen, positivos_reales_muestra: nReal,
                                positivos_variante_muestra: nVar };
    }
  }
  return { metricas, muestra: { dentro: dentro.length, fuera: fuera.length, peso }, veredictos };
}

// ------------------------------------------------------------
// Principal
// ------------------------------------------------------------

const { data: perfilesCrudos, error: fallo } = await leer(() => db.from("perfiles")
  .select("id, cif, descripcion, criterio, cpv_prefijos, contratos_ganados, criterio_version, sistema")
  .not("cif", "is", null).eq("paso_alta", "listo")
  .order("contratos_ganados", { ascending: false }));
if (fallo) throw fallo;

// Un perfil por NIF: dos cuentas de la misma empresa no son dos casos.
const porCif = new Map<string, Record<string, unknown>>();
for (const p of perfilesCrudos ?? []) {
  if (!p.cif || !p.criterio || !p.cpv_prefijos) continue;
  if (EXPORTAR && p.sistema !== "huellas") continue;
  const previo = porCif.get(p.cif);
  if (!previo || (p.criterio_version ?? 0) > (previo.criterio_version as number ?? 0)) porCif.set(p.cif, p);
}
const casos = [...porCif.values()].map((p, i) => ({ codigo: `P${String(i + 1).padStart(2, "0")}`, p }));

await Deno.mkdir(SALIDA, { recursive: true });
const detalle: Record<string, unknown>[] = [];
const resumen: Record<string, unknown>[] = [];

// No se espera a que el scraper esté parado: se lanza en cadena, uno
// detrás de otro con segundos de diferencia, y esa espera no acababa
// nunca. Convive con él (la primera vuelta coincidió con tres
// ejecuciones suyas y acabaron bien) con poca simultaneidad: seis
// llamadas al modelo a la vez y lecturas de cuatro en cuatro por índice,
// con reintento si encuentra algo bloqueado.

for (const { codigo, p } of casos) {
  if (SOLO && !SOLO.split(",").includes(codigo)) continue;
  const inicio = Date.now();
  const llamadasAntes = llamadas;
  const r = azar(Number.parseInt(codigo.slice(1)) * 7919);
  const cif = String(p.cif);
  const real = {
    criterio: String(p.criterio),
    prefijos: String(p.cpv_prefijos).split(",").map((x) => x.trim()).filter(Boolean),
  };

  try {
    const descripcion = await describirComoCliente(String(p.descripcion ?? ""));
    // Desmarca las familias que no tienen nada que ver con lo suyo. Si
    // las desmarcara todas no podría seguir: se quedan todas.
    const marcar = (prefijos: string[]) => {
      const deLoSuyo = prefijos.filter((f) =>
        real.prefijos.some((q) => q.startsWith(f) || f.startsWith(q)));
      return { familias: deLoSuyo.length ? deLoSuyo : prefijos, acierta: deLoSuyo.length > 0 };
    };
    // El camino de hoy con el catálogo de hoy; los demás, con nombres.
    const propHoy = await proponer(descripcion, false);
    const prop = await proponer(descripcion, true);
    const hoy = marcar(propHoy.prefijos);
    const { familias, acierta } = marcar(prop.prefijos);

    // Sus franjas: las que suman al menos el 15 % de lo que ha ganado.
    const { data: suyos } = await leer(() => db.from("licitaciones")
      .select("importe_adjudicacion, presupuesto_base, procedimiento")
      .eq("adjudicatario_cif", cif).limit(1000));
    const cuentaFranjas = new Map<string, number>();
    for (const l of (suyos ?? []) as Lic[]) {
      const f = franja(importeDe(l));
      if (f) cuentaFranjas.set(f, (cuentaFranjas.get(f) ?? 0) + 1);
    }
    const totalFr = [...cuentaFranjas.values()].reduce((a, b) => a + b, 0);
    let franjas = FRANJAS.filter((f) => (cuentaFranjas.get(f) ?? 0) / (totalFr || 1) >= 0.15) as string[];
    if (!franjas.length) {
      franjas = [[...cuentaFranjas.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? "15-100k"];
    }

    const variantes: Record<string, Resultado | null> = {};
    variantes.solo_descripcion = await soloDescripcion(descripcion, familias);
    // Los vecinos con captura por vecindario (lo que hay en producción
    // desde el 24/09/2026), buscados con la descripción o con títulos
    // típicos de la empresa que escribe el modelo (vecinos.ts).
    const conVecindario = async (buscadas: string[]) => {
      const v = await buscarVecinos(descripcion, familias, franjas, cif, buscadas);
      const base = await desdeHistorial(descripcion, familias, v.vecinos.map(({ l }) => l), []);
      const cuenta200 = new Map<string, number>();
      for (const { l } of v.ordenados.slice(0, 200)) {
        cuenta200.set(l.prefijo_principal, (cuenta200.get(l.prefijo_principal) ?? 0) + 1);
      }
      return { ...base, prefijos: [...new Set([...base.prefijos,
        ...[...cuenta200.entries()].filter(([, n]) => n >= 3).map(([p]) => p)])],
        detalle: { ...base.detalle, buscadas, titulos: v.vecinos.slice(0, 10).map(({ l }) => l.titulo),
                   filas: v.vecinos.map(({ l }) => ({ id_licitacion: l.id_licitacion, titulo: l.titulo,
                                                      cpvs: l.cpvs ?? [] })) } };
    };
    variantes.vecinos_vecindario = await conVecindario([]);
    const salida = "—";

    if (EXPORTAR) {
      const vv = variantes.vecinos_vecindario!;
      exportados.push({ codigo, perfil_id: p.id, cif, descripcion, familias,
                        vecinos: vv.detalle.filas, criterio: vv.criterio, prefijos: vv.prefijos });
      await Deno.writeTextFile(`${SALIDA}/sinteticos.json`, JSON.stringify(exportados));
      console.log(`${codigo}: exportado (${(vv.detalle.filas as unknown[]).length} vecinos, ` +
                  `${vv.prefijos.length} códigos)`);
      continue;
    }
    const usadas = new Set(Object.values(variantes).flatMap((v) => v?.usadas ?? []));
    const ev = await evaluar(real, variantes, usadas, r, franjas, []);

    const segundos = Math.round((Date.now() - inicio) / 1000);
    const filaResumen = {
      codigo,
      contratos: Number(p.contratos_ganados ?? 0) >= 20 ? "20+" : Number(p.contratos_ganados ?? 0) >= 5 ? "5-19" : "1-4",
      franjas: franjas.join(" "),
      familias_hoy_aciertan: hoy.acierta,
      familias_con_nombres_aciertan: acierta,
      salida,
      prefijos: Object.fromEntries(Object.entries(variantes).map(([k, v]) => [k, v?.prefijos.length ?? 0])),
      muestra: ev.muestra,
      metricas: ev.metricas,
      llamadas: llamadas - llamadasAntes,
      segundos,
    };
    resumen.push(filaResumen);
    detalle.push({
      ...filaResumen, empresa_cif: cif, descripcion_simulada: descripcion, propuesta_hoy: propHoy, propuesta: prop,
      prefijos_reales: real.prefijos,
      variantes: Object.fromEntries(Object.entries(variantes).map(([k, v]) =>
        [k, v && { criterio: v.criterio, prefijos: v.prefijos, detalle: v.detalle }])),
      veredictos: ev.veredictos,
    });

    const f1 = (n: string) => {
      const m = (ev.metricas[n]?.si_quizas as Record<string, number | null>) ?? {};
      return m.f1 == null ? "—" : m.f1.toFixed(2);
    };
    console.log(`${codigo}: F1 descripción ${f1("solo_descripcion")} · ` +
                `vecinos ${f1("vecinos_vecindario")} ` +
                `(${segundos} s, ${filaResumen.llamadas} llamadas)`);
  } catch (e) {
    // Solo el tipo de fallo: el mensaje podría llevar datos del cliente.
    console.log(`${codigo}: falló (${(e as Error).name})`);
    resumen.push({ codigo, fallo: (e as Error).name });
    detalle.push({ codigo, empresa_cif: cif, fallo: String((e as Error).message ?? e) });
  }
  // Se va guardando: si la ejecución se corta, lo hecho no se pierde.
  await Deno.writeTextFile(`${SALIDA}/detalle.json`, JSON.stringify(detalle, null, 1));
  await Deno.writeTextFile(`${SALIDA}/resumen.json`, JSON.stringify(resumen, null, 1));
}

// ------------------------------------------------------------
// Resumen público: solo cifras
// ------------------------------------------------------------

const VARIANTES = ["solo_descripcion", "vecinos_vecindario"];
const celda = (fila: Record<string, unknown>, v: string, campo: string) => {
  const m = ((fila.metricas as Record<string, Record<string, Record<string, number | null>>>)?.[v]?.si_quizas) ?? {};
  return m[campo] == null ? "—" : (m[campo] as number).toFixed(2);
};
const lineas = [
  "## Simulación del alta sin NIF",
  "",
  "F1 frente al filtro real (sí + quizás). Precisión / cobertura entre paréntesis.",
  "",
  `| Perfil | Contratos | Familias hoy / con nombres | ${VARIANTES.join(" | ")} | Salida |`,
  `|---|---|---|${VARIANTES.map(() => "---").join("|")}|---|`,
  ...resumen.map((f) => f.fallo
    ? `| ${f.codigo} | — | — | ${VARIANTES.map(() => "falló").join(" | ")} | |`
    : `| ${f.codigo} | ${f.contratos} | ${f.familias_hoy_aciertan ? "✓" : "✗"} / ${f.familias_con_nombres_aciertan ? "✓" : "✗"} | ${VARIANTES.map((v) =>
        `${celda(f, v, "f1")} (${celda(f, v, "precision")} / ${celda(f, v, "cobertura")})`).join(" | ")} | ${f.salida} |`),
  "",
  `Lectura por prefijo: mediana ${mediana(tiempos) ?? "—"} ms, máximo ${tiempos.length ? Math.max(...tiempos) : "—"} ms ` +
  `(${tiempos.length} consultas). Llamadas al modelo: ${llamadas}. ` +
  `Tokens de embeddings: ${tokensEmbedding}.`,
];
const informe = lineas.join("\n");
console.log("\n" + informe);
const resumenGh = Deno.env.get("GITHUB_STEP_SUMMARY");
if (resumenGh) await Deno.writeTextFile(resumenGh, informe + "\n", { append: true });
