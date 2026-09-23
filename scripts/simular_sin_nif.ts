// ============================================================
// Simular el alta sin NIF con empresas que sí tienen NIF
// ============================================================
//
// Para decidir cómo entra quien no tiene contratos ganados. Se toma cada
// perfil con NIF, se hace como si hubiera entrado describiendo su
// negocio, y se compara el filtro que saldría con el suyo real.
//
// Variantes, todas desde la misma descripción:
//
//   tarjetas_hoy         El camino actual, tal cual: familias CPV y
//                        treinta tarjetas. El vecindario busca por
//                        `prefijo_principal` (4 dígitos) con divisiones
//                        de 2, no encuentra nada y las tarjetas salen del
//                        relleno sin ordenar de `licitaciones_por_prefijo`.
//   tarjetas_arregladas  Lo mismo, con el vecindario buscando en los
//                        prefijos de 4 dígitos que cuelgan de cada familia.
//   referentes           Empresas que ganan lo que describe, de su tamaño
//                        primero. Con las que marca se arma un historial
//                        prestado y se lee con `leerHistorial`, como si
//                        fuera suyo. Sin contratos menores.
//   referentes_menores   Igual, contando los menores de 2025.
//
// Las respuestas del "cliente" (familias, tarjetas, franjas, referentes)
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
//   deno run -A scripts/simular_sin_nif.ts [--solo=P03] [--muestra=100]
//
// Variables: SUPABASE_URL, SUPABASE_KEY (clave secreta), OPENAI_API_KEY.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  llamarModelo, leerHistorial, prefijosDeLectura,
} from "../supabase/functions/alta/modelo.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_KEY")!,
  { auth: { persistSession: false } });

const arg = (nombre: string) =>
  Deno.args.find((a) => a.startsWith(`--${nombre}=`))?.split("=")[1];
const SOLO = arg("solo");
// Licitaciones por estrato en la evaluación: dentro de sus prefijos
// reales y fuera de ellos.
const MUESTRA = Number(arg("muestra") ?? 100);
const SALIDA = "simulacion";

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
  const { data, error } = await db.from("resumen_cpv_total")
    .select("prefijo, licitaciones").like("prefijo", "____")
    .range(desde, desde + 999);
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
        const { data, error } = await db.from("licitaciones").select(COLUMNAS)
          .eq("prefijo_principal", p4).not("adjudicatario_cif", "is", null)
          .order("fecha_actualizacion", { ascending: false }).limit(POR_PREFIJO);
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

// Réplica de `proponer` en alta/index.ts.
async function proponer(descripcion: string) {
  const { data: divisiones } = await db.from("resumen_cpv_total")
    .select("prefijo, licitaciones").gt("licitaciones", 50)
    .order("licitaciones", { ascending: false }).limit(400);
  const catalogo = (divisiones ?? []).filter((d) => d.prefijo.length === 2)
    .map((d) => `${d.prefijo}: ${d.licitaciones}`).join("\n");

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

  const { data: resumen } = await db.from("resumen_cpv_total")
    .select("prefijo, licitaciones").in("prefijo", prefijos);
  const vol = Object.fromEntries((resumen ?? []).map((r) => [r.prefijo, r.licitaciones]));
  const conVolumen = prefijos.filter((p) => (vol[p] ?? 0) > 0);
  if (conVolumen.length) prefijos = conVolumen;

  const util = async (palabras: string[], tope: number) => {
    if (!palabras.length) return [];
    const { data } = await db.rpc("utilidad_palabras", { palabras });
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
  const respuestas = await enParalelo(tarjetas, 10, async (t) => ({
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
    prop.producto.length ? db.rpc("licitaciones_del_vecindario", { ...args, con_destinatario: true })
      : Promise.resolve({ data: [] }),
    prop.producto.length ? db.rpc("licitaciones_del_vecindario", { ...args, con_destinatario: false })
      : Promise.resolve({ data: [] }),
  ]);
  const claras = (encajan.data ?? []) as Lic[];
  let dudosas = (frontera.data ?? []) as Lic[];
  const delVecindario = claras.length + dudosas.length;
  if (delVecindario < CUANTAS) {
    const { data: sueltas } = await db.rpc("licitaciones_por_prefijo",
      { prefijos: familias, solo_vivas: false, tope: 300 });
    dudosas = [...dudosas, ...((sueltas ?? []) as Lic[])];
  }
  const tarjetas = escogerTarjetas([...claras], dudosas, r);
  return contestarTarjetas(descripcion, familias, tarjetas, criterioReal,
    { del_vecindario: delVecindario });
}

async function tarjetasArregladas(descripcion: string, prop: Awaited<ReturnType<typeof proponer>>,
                                  familias: string[], criterioReal: string, r: () => number) {
  const todas = await deLosPrefijos(desplegar(familias));
  const dice = (l: Lic, palabras: string[]) => {
    const t = sinTildes(l.titulo ?? "");
    return palabras.some((p) => t.includes(p));
  };
  const vecindario = todas.filter((l) => dice(l, prop.producto));
  const claras = vecindario.filter((l) => dice(l, prop.destinatario));
  let dudosas = vecindario.filter((l) => !dice(l, prop.destinatario));
  const delVecindario = claras.length + dudosas.length;
  if (delVecindario < CUANTAS) dudosas = [...dudosas, ...barajar([...todas], r).slice(0, 300)];
  const tarjetas = escogerTarjetas(claras, dudosas, r);
  return contestarTarjetas(descripcion, familias, tarjetas, criterioReal,
    { del_vecindario: delVecindario });
}

async function porReferentes(prop: Awaited<ReturnType<typeof proponer>>, familias: string[],
                             franjas: string[], cifPropio: string, prefijosReales: string[],
                             conMenores: boolean): Promise<Resultado | null> {
  const t0 = Date.now();
  const todas = (await deLosPrefijos(desplegar(familias)))
    .filter((l) => conMenores || !esMenor(l));
  const msLectura = Date.now() - t0;

  // Solo lo que se parece a su descripción: de una empresa que lo hace
  // todo, la parte que coincide con lo suyo.
  const coinciden = prop.producto.length
    ? todas.filter((l) => {
        const t = sinTildes(l.titulo ?? "");
        return prop.producto.some((p) => t.includes(p));
      })
    : todas;

  const porEmpresa = new Map<string, Lic[]>();
  for (const l of coinciden) {
    const cif = String(l.adjudicatario_cif ?? "");
    if (!cif || cif === cifPropio) continue;
    porEmpresa.set(cif, [...(porEmpresa.get(cif) ?? []), l]);
  }

  const encaja = (p4: string) => prefijosReales.some((p) => p4.startsWith(p.slice(0, 4)));
  const candidatas = [...porEmpresa.entries()]
    .filter(([, ls]) => ls.length >= 2)
    .map(([cif, ls]) => {
      const importes = ls.map(importeDe).filter((x): x is number => x != null);
      const enFranja = ls.filter((l) => franjas.includes(franja(importeDe(l)) ?? "")).length;
      return {
        cif, nombre: ls[0].adjudicatario ?? "", contratos: ls.length,
        importe_mediano: mediana(importes),
        de_su_tamano: enFranja / ls.length >= 0.5,
        // Lo que el oráculo mira para "reconocerla" como competidora: que
        // la mayor parte de lo que gana caiga en sus prefijos reales.
        competidora: ls.filter((l) => encaja(l.prefijo_principal)).length / ls.length >= 0.5,
        ejemplos: ls.slice(0, 3).map((l) => l.titulo),
        ls,
      };
    })
    .sort((a, b) => b.contratos - a.contratos);

  const suTamano = candidatas.filter((c) => c.de_su_tamano).slice(0, 12);
  const grandes = candidatas.filter((c) => !c.de_su_tamano).slice(0, 6);
  const elegidas = [...suTamano, ...grandes].filter((c) => c.competidora).slice(0, 5);

  const resumenCandidatas = [...suTamano, ...grandes].map(({ ls: _, ...c }) => c);
  if (!elegidas.length) {
    return { criterio: "", prefijos: [], usadas: [], detalle: {
      sin_referentes: true, candidatas: candidatas.length, enseñadas: resumenCandidatas,
      ms_lectura: msLectura } };
  }

  // El historial prestado: lo de sus referentes que coincide con lo suyo
  // y cae en sus franjas. Si en sus franjas hay muy poco, todo lo que
  // coincide: mejor un historial algo grande que uno de tres contratos.
  const coincidentes = elegidas.flatMap((c) => c.ls);
  const enFranjas = coincidentes.filter((l) => franjas.includes(franja(importeDe(l)) ?? ""));
  const prestados = (enFranjas.length >= 8 ? enFranjas : coincidentes)
    .sort((a, b) => b.fecha_actualizacion.localeCompare(a.fecha_actualizacion))
    .slice(0, 40);

  const cuenta = new Map<string, number>();
  for (const l of prestados) cuenta.set(l.prefijo_principal, (cuenta.get(l.prefijo_principal) ?? 0) + 1);
  const prefijos = [...cuenta.entries()].map(([prefijo, contratos]) => ({ prefijo, contratos }));

  const lectura = await leerHistorial(prestados.map((l) => ({
    titulo: l.titulo, organo: l.organo ?? "", importe: importeDe(l),
  })), prefijos) as Record<string, unknown>;
  llamadas++;

  return {
    criterio: String(lectura.criterio ?? ""),
    prefijos: prefijosDeLectura(lectura, prefijos),
    usadas: prestados.map((l) => l.id_licitacion),
    detalle: {
      candidatas: candidatas.length, enseñadas: resumenCandidatas,
      elegidas: elegidas.map((c) => c.nombre), prestados: prestados.length,
      prestados_en_franja: enFranjas.length >= 8, ms_lectura: msLectura,
      actividad: lectura.actividad,
    },
  };
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
                       usadas: Set<string>, r: () => number) {
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

  const veredictos = await enParalelo(muestra, 12, async ({ l, w }) => {
    const fila: Record<string, string | null> = {};
    fila.real = pasa(l, real.prefijos) ? await veredicto(real.criterio, l) : "fuera";
    for (const [nombre, v] of Object.entries(variantes)) {
      fila[nombre] = v && v.criterio && pasa(l, v.prefijos) ? await veredicto(v.criterio, l) : "fuera";
    }
    return { id: l.id_licitacion, titulo: l.titulo, w, fila };
  });

  const metricas: Record<string, Record<string, unknown>> = {};
  for (const nombre of Object.keys(variantes)) {
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
      metricas[nombre][def] = { precision, cobertura, f1, positivos_reales_muestra: nReal,
                                positivos_variante_muestra: nVar };
    }
  }
  return { metricas, muestra: { dentro: dentro.length, fuera: fuera.length, peso }, veredictos };
}

// ------------------------------------------------------------
// Principal
// ------------------------------------------------------------

const { data: perfilesCrudos, error: fallo } = await db.from("perfiles")
  .select("id, cif, descripcion, criterio, cpv_prefijos, contratos_ganados, criterio_version")
  .not("cif", "is", null).eq("paso_alta", "listo")
  .order("contratos_ganados", { ascending: false });
if (fallo) throw fallo;

// Un perfil por NIF: dos cuentas de la misma empresa no son dos casos.
const porCif = new Map<string, Record<string, unknown>>();
for (const p of perfilesCrudos ?? []) {
  if (!p.cif || !p.criterio || !p.cpv_prefijos) continue;
  const previo = porCif.get(p.cif);
  if (!previo || (p.criterio_version ?? 0) > (previo.criterio_version as number ?? 0)) porCif.set(p.cif, p);
}
const casos = [...porCif.values()].map((p, i) => ({ codigo: `P${String(i + 1).padStart(2, "0")}`, p }));

await Deno.mkdir(SALIDA, { recursive: true });
const detalle: Record<string, unknown>[] = [];
const resumen: Record<string, unknown>[] = [];

for (const { codigo, p } of casos) {
  if (SOLO && SOLO !== codigo) continue;
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
    const prop = await proponer(descripcion);

    // Desmarca las familias que no tienen nada que ver con lo suyo. Si
    // las desmarcara todas no podría seguir: se quedan todas.
    const deLoSuyo = prop.prefijos.filter((f) =>
      real.prefijos.some((q) => q.startsWith(f) || f.startsWith(q)));
    const familias = deLoSuyo.length ? deLoSuyo : prop.prefijos;

    // Sus franjas: las que suman al menos el 15 % de lo que ha ganado.
    const { data: suyos } = await db.from("licitaciones")
      .select("importe_adjudicacion, presupuesto_base, procedimiento")
      .eq("adjudicatario_cif", cif).limit(1000);
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
    variantes.tarjetas_hoy = await tarjetasHoy(descripcion, prop, familias, real.criterio, r);
    variantes.tarjetas_arregladas = await tarjetasArregladas(descripcion, prop, familias, real.criterio, r);
    variantes.referentes = await porReferentes(prop, familias, franjas, cif, real.prefijos, false);
    variantes.referentes_menores = await porReferentes(prop, familias, franjas, cif, real.prefijos, true);

    // Si nadie de la lista le suena, en producción iría a las tarjetas:
    // se mide así, y se cuenta aparte cuántas veces pasa.
    const sinReferentes: string[] = [];
    for (const nombre of ["referentes", "referentes_menores"]) {
      if (variantes[nombre]?.detalle.sin_referentes) {
        sinReferentes.push(nombre);
        variantes[nombre] = { ...variantes.tarjetas_arregladas!,
          detalle: { ...variantes[nombre]!.detalle, recurre_a_tarjetas: true } };
      }
    }

    const usadas = new Set(Object.values(variantes).flatMap((v) => v?.usadas ?? []));
    const ev = await evaluar(real, variantes, usadas, r);

    const segundos = Math.round((Date.now() - inicio) / 1000);
    const filaResumen = {
      codigo,
      contratos: Number(p.contratos_ganados ?? 0) >= 20 ? "20+" : Number(p.contratos_ganados ?? 0) >= 5 ? "5-19" : "1-4",
      franjas: franjas.join(" "),
      familias: familias.length,
      tarjetas_hoy_del_vecindario: variantes.tarjetas_hoy?.detalle.del_vecindario,
      tarjetas_arregladas_del_vecindario: variantes.tarjetas_arregladas?.detalle.del_vecindario,
      referentes_elegidos: (variantes.referentes?.detalle.elegidas as string[] | undefined)?.length ?? 0,
      referentes_menores_elegidos: (variantes.referentes_menores?.detalle.elegidas as string[] | undefined)?.length ?? 0,
      sin_referentes: sinReferentes.join(" "),
      muestra: ev.muestra,
      metricas: ev.metricas,
      llamadas: llamadas - llamadasAntes,
      segundos,
    };
    resumen.push(filaResumen);
    detalle.push({
      ...filaResumen, empresa_cif: cif, descripcion_simulada: descripcion, propuesta: prop,
      prefijos_reales: real.prefijos,
      variantes: Object.fromEntries(Object.entries(variantes).map(([k, v]) =>
        [k, v && { criterio: v.criterio, prefijos: v.prefijos, detalle: v.detalle }])),
      veredictos: ev.veredictos,
    });

    const f1 = (n: string) => {
      const m = (ev.metricas[n]?.si_quizas as Record<string, number | null>) ?? {};
      return m.f1 == null ? "—" : m.f1.toFixed(2);
    };
    console.log(`${codigo}: F1 hoy ${f1("tarjetas_hoy")} · arregladas ${f1("tarjetas_arregladas")} · ` +
                `referentes ${f1("referentes")} · con menores ${f1("referentes_menores")} ` +
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

const VARIANTES = ["tarjetas_hoy", "tarjetas_arregladas", "referentes", "referentes_menores"];
const celda = (fila: Record<string, unknown>, v: string, campo: string) => {
  const m = ((fila.metricas as Record<string, Record<string, Record<string, number | null>>>)?.[v]?.si_quizas) ?? {};
  return m[campo] == null ? "—" : (m[campo] as number).toFixed(2);
};
const lineas = [
  "## Simulación del alta sin NIF",
  "",
  "F1 frente al filtro real (sí + quizás). Precisión / cobertura entre paréntesis.",
  "",
  `| Perfil | Contratos | ${VARIANTES.join(" | ")} | Sin referentes |`,
  `|---|---|${VARIANTES.map(() => "---").join("|")}|---|`,
  ...resumen.map((f) => f.fallo
    ? `| ${f.codigo} | — | ${VARIANTES.map(() => "falló").join(" | ")} | |`
    : `| ${f.codigo} | ${f.contratos} | ${VARIANTES.map((v) =>
        `${celda(f, v, "f1")} (${celda(f, v, "precision")} / ${celda(f, v, "cobertura")})`).join(" | ")} | ${f.sin_referentes || ""} |`),
  "",
  `Lectura por prefijo: mediana ${mediana(tiempos) ?? "—"} ms, máximo ${tiempos.length ? Math.max(...tiempos) : "—"} ms ` +
  `(${tiempos.length} consultas). Llamadas al modelo: ${llamadas}.`,
];
const informe = lineas.join("\n");
console.log("\n" + informe);
const resumenGh = Deno.env.get("GITHUB_STEP_SUMMARY");
if (resumenGh) await Deno.writeTextFile(resumenGh, informe + "\n", { append: true });
