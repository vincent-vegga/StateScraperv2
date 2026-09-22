// ============================================================
// Regenerar la lectura de las empresas ya dadas de alta
// ============================================================
//
// Para cuando cambian las instrucciones con que el modelo lee el
// historial de una empresa (22/09/2026: fuera los ejemplos de
// uniformidad policial, que el modelo copiaba como si fueran datos del
// cliente). Los perfiles nuevos ya salen con la lectura buena; los
// antiguos conservan la vieja hasta que se regeneran con esto.
//
// Usa las MISMAS funciones que la función de alta (modelo.ts), así que
// un perfil regenerado queda igual que si se diera de alta hoy.
//
// Por perfil:
//   1. Lectura nueva del modelo: criterio, prefijos, lo que se enseña.
//   2. Si el cliente había corregido ("sí/no me interesa"), esas
//      correcciones se vuelven a aplicar sobre el criterio nuevo: no se
//      pierde lo que el sistema había aprendido de él.
//   3. Se borran sus veredictos MENOS los de contratos que marcó a
//      mano, para que el cribador los rehaga con el criterio nuevo. Sus
//      sectores caen solos (disparador sobre cpv_prefijos).
//
// El cribado NO lo hace esto: el workflow llama a cribador.py para cada
// perfil justo después, para que su lista no se quede vacía más que un
// par de minutos.
//
//   deno run -A scripts/regenerar_perfiles.ts --listar
//   deno run -A scripts/regenerar_perfiles.ts --perfil=<uuid> [--ensayo]
//
// Variables: SUPABASE_URL, SUPABASE_KEY (clave secreta), OPENAI_API_KEY.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  leerHistorial, prefijosDeLectura, regenerarCriterio,
} from "../supabase/functions/alta/modelo.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_KEY")!,
  { auth: { persistSession: false } });

const arg = (nombre: string) =>
  Deno.args.find((a) => a.startsWith(`--${nombre}=`))?.split("=")[1];
const ensayo = Deno.args.includes("--ensayo");

// Solo empresas identificadas por NIF y con el alta terminada (o a
// punto): las que describieron su negocio no tienen historial que leer.
if (Deno.args.includes("--listar")) {
  const { data, error } = await db.from("perfiles").select("id")
    .not("cif", "is", null).in("paso_alta", ["listo", "cribando"])
    .order("fecha_alta");
  if (error) throw error;
  console.log((data ?? []).map((p) => p.id).join("\n"));
  Deno.exit(0);
}

const id = arg("perfil");
if (!id) throw new Error("Falta --perfil=<uuid> (o --listar)");

const { data: perfil, error: fallo } = await db.from("perfiles").select("*")
  .eq("id", id).single();
if (fallo || !perfil) throw fallo ?? new Error("Perfil no encontrado");

const cif = String(perfil.cif);
const [{ data: ganados }, { data: prefijosCrudos }] = await Promise.all([
  db.rpc("ultimos_ganados", { cif_buscado: cif, tope: 40 }),
  db.rpc("prefijos_de_empresa", { cif_buscado: cif, minimo: 1 }),
]);
const contratos = ((ganados ?? []) as Record<string, unknown>[]).map((g) => ({
  titulo: String(g.titulo ?? ""),
  organo: String(g.organo ?? ""),
  importe: g.importe ? Number(g.importe) : null,
}));
const prefijos = (prefijosCrudos ?? []) as { prefijo: string; contratos: number }[];
if (!contratos.length) {
  console.log(`${perfil.empresa}: sin contratos ganados, no se toca`);
  Deno.exit(0);
}

// Misma empresa, misma lectura, también aquí: dos cuentas con el mismo NIF
// (Mare Nostrum) salieron con 114 y 245 contratos porque se leyeron por
// separado. Si ese NIF se ha leído en esta misma tanda, se reutiliza.
const { data: reciente } = await db.from("lecturas_empresa").select("datos, creado")
  .eq("cif", cif).maybeSingle();
const deEstaTanda = reciente && Date.now() - Date.parse(reciente.creado) < 2 * 3600 * 1000;
const lectura = (deEstaTanda
  ? reciente.datos
  : await leerHistorial(contratos, prefijos)) as Record<string, unknown>;
if (deEstaTanda) console.log(`   lectura reutilizada del ${reciente.creado}`);
const finales = prefijosDeLectura(lectura, prefijos);

// Salvaguarda: regenerar nunca puede encontrar MENOS de lo que la
// empresa ha ganado. En el ensayo del 22/09/2026 el modelo podaba de más
// en dos empresas (GMG del 83 al 67 %, Red2Red del 79 al 74 %). Si pasa,
// se recuperan los prefijos antiguos que tapan el hueco, el que más
// recupera primero, hasta igualar la cobertura de antes.
const antiguos = String(perfil.cpv_prefijos ?? "").split(",").map((x) => x.trim()).filter(Boolean);
const { data: suyos } = await db.from("licitaciones").select("prefijos")
  .eq("adjudicatario_cif", cif).not("cpvs", "eq", "[]");
const ganadosPref = (suyos ?? []).map((l) => (l.prefijos ?? []) as string[]);
const cubre = (lista: string[]) =>
  ganadosPref.filter((lp) => lp.some((p) => lista.includes(p))).length;
const objetivo = cubre(antiguos);
const recuperados: string[] = [];
while (cubre(finales) < objetivo) {
  const candidatos = antiguos.filter((p) => !finales.includes(p))
    .map((p) => ({ p, gana: cubre([...finales, p]) - cubre(finales) }))
    .filter((c) => c.gana > 0).sort((a, b) => b.gana - a.gana);
  if (!candidatos.length) break;
  finales.push(candidatos[0].p);
  recuperados.push(candidatos[0].p);
}
if (!finales.length) {
  console.log(`${perfil.empresa}: la lectura no da prefijos, no se toca`);
  Deno.exit(0);
}

let criterio = String(lectura.criterio ?? "");
let queBuscamos = Array.isArray(lectura.que_buscamos)
  ? lectura.que_buscamos.map((x: unknown) => String(x)).slice(0, 5) : [];

// Sus correcciones, TODAS (también las ya aplicadas al criterio viejo):
// el criterio nuevo parte de cero y tiene que volver a aprenderlas.
const { data: correcciones } = await db.from("correcciones")
  .select("id, id_licitacion, titulo, organo, interesa, motivo")
  .eq("perfil_id", perfil.id);
if (correcciones?.length) {
  const ajustado = await regenerarCriterio(
    criterio,
    contratos.slice(0, 25).map((c) => ({ titulo: c.titulo })),
    correcciones.map((c) => ({
      titulo: String(c.titulo), organo: String(c.organo ?? ""),
      interesa: Boolean(c.interesa), motivo: c.motivo ? String(c.motivo) : null,
    })),
  );
  criterio = String(ajustado.criterio ?? criterio);
  if (Array.isArray(ajustado.que_buscamos)) {
    queBuscamos = ajustado.que_buscamos.map((x: unknown) => String(x)).slice(0, 5);
  }
}

console.log([
  `== ${perfil.empresa} (${cif})${ensayo ? " · ENSAYO, no se escribe nada" : ""}`,
  `   prefijos: ${perfil.cpv_prefijos}  ->  ${finales.join(",")}` +
    (recuperados.length ? `  (recuperados para no perder cobertura: ${recuperados.join(",")})` : ""),
  `   cobertura de lo ganado: ${objetivo}/${ganadosPref.length} antes, ${cubre(finales)}/${ganadosPref.length} ahora`,
  `   correcciones reaplicadas: ${correcciones?.length ?? 0}`,
  `   antes: ${String(perfil.criterio ?? "").slice(0, 400)}`,
  `   ahora: ${criterio.slice(0, 400)}`,
  `   qué buscamos: ${queBuscamos.join(" | ")}`,
].join("\n"));

if (ensayo) Deno.exit(0);

if (!deEstaTanda) {
  await db.from("lecturas_empresa").upsert({
    cif, datos: lectura, creado: new Date().toISOString(),
  });
}

const { error: alGuardar } = await db.from("perfiles").update({
  cpv_prefijos: finales.join(","),
  descripcion: String(lectura.actividad ?? perfil.descripcion ?? ""),
  criterio,
  que_buscamos: queBuscamos,
  criterio_version: (perfil.criterio_version ?? 0) + 1,
  criterio_fecha: new Date().toISOString(),
  // "listo" también para los que se quedaron en "cribando": el cribador
  // les rellena la lista justo después.
  paso_alta: "listo",
}).eq("id", perfil.id);
if (alGuardar) throw alGuardar;

if (correcciones?.length) {
  await db.from("correcciones").update({ aplicada: true })
    .in("id", correcciones.map((c) => c.id));
}

// Veredictos fuera, salvo los de contratos que el cliente marcó a mano:
// si no, un "sí me interesa" suyo podría desaparecer de su lista.
const marcados = (correcciones ?? []).map((c) => c.id_licitacion);
let borrar = db.from("veredictos").delete().eq("perfil_id", perfil.id);
if (marcados.length) {
  borrar = borrar.not("id_licitacion", "in",
    `(${marcados.map((m) => `"${String(m).replace(/"/g, '\\"')}"`).join(",")})`);
}
const { error: alBorrar } = await borrar;
if (alBorrar) throw alBorrar;

console.log("   guardado; veredictos borrados salvo los marcados a mano");
