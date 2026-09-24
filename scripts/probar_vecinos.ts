// ============================================================
// Probar los contratos parecidos del alta sin NIF (vecinos.ts)
// ============================================================
//
// Con descripciones inventadas: nada de clientes. Lee la muestra por el
// mismo camino que la función de alta (muestra_de_familias_json) y compara
// buscar con la descripción tal cual y con títulos típicos de la empresa.
// Enseña los títulos buscados, los vecinos, los códigos, los ejemplos que
// vería y cómo se reparten los parecidos. Solo lee.
//
//   deno run -A scripts/probar_vecinos.ts
//
// Variables: SUPABASE_URL, SUPABASE_KEY (clave secreta), OPENAI_API_KEY.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type Adjudicada, buscarParecidos, codigosDelVecindario, ejemplosPorFamilia, titulosTipicos,
} from "../supabase/functions/alta/vecinos.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_KEY")!,
  { auth: { persistSession: false } });

const CASOS = [
  { descripcion: "Somos una consultora pequeña de informática: desarrollamos aplicaciones web y damos soporte técnico a ayuntamientos.",
    familias: ["72", "48"], franjas: ["15-100k"] },
  { descripcion: "Vendemos uniformes, calzado y equipo de protección para policías locales.",
    familias: ["18", "35"], franjas: ["<15k", "15-100k"] },
  { descripcion: "Hacemos la limpieza de edificios públicos, colegios y centros de salud.",
    familias: ["90"], franjas: ["100k-1M"] },
  // Vaga a propósito: dice cómo vende, no qué.
  { descripcion: "Empresa especializada de forma exclusiva en el suministro integral B2G para centros educativos de titularidad pública. No vendemos al por menor: trabajamos por licitaciones, concursos públicos y acuerdos marco con las Consejerías de Educación y el Ministerio.",
    familias: ["80", "55", "39", "90", "71", "18", "33", "92"], franjas: ["<15k", "15-100k", "100k-1M"] },
  { descripcion: "Vendemos e instalamos mobiliario escolar y de oficina: mesas y sillas para aulas, armarios, estanterías de biblioteca y mobiliario de laboratorio para institutos. También el montaje y la retirada del mobiliario viejo.",
    familias: ["39", "51"], franjas: ["15-100k", "100k-1M"] },
];

const pct = (xs: number[], p: number) => xs.length ? xs[Math.floor((xs.length - 1) * p)].toFixed(2) : "—";

for (const caso of CASOS) {
  const { data, error } = await db.rpc("muestra_de_familias_json", { familias: caso.familias });
  if (error) throw error;
  const filas = (data ?? []) as Adjudicada[];
  console.log(`\n=== ${caso.descripcion.slice(0, 100)}`);
  console.log(`  ${filas.length} adjudicados en la muestra`);

  const titulos = await titulosTipicos(caso.descripcion);
  console.log(`  títulos típicos: ${titulos.join(" | ")}`);

  for (const [modo, buscados] of [["descripción", []], ["títulos", titulos]] as const) {
    const t0 = performance.now();
    const p = await buscarParecidos(caso.descripcion, filas, caso.franjas, [...buscados]);
    const ms = Math.round(performance.now() - t0);
    const sims = p.ordenados.map((o) => o.s);
    const codigos = codigosDelVecindario(p);
    const divisiones = [...new Set(codigos.map((c) => c.slice(0, 2)))].map((d) =>
      `${d}:${codigos.filter((c) => c.startsWith(d)).length}`).join(" ");
    console.log(`\n  -- con ${modo} (${ms} ms)`);
    console.log(`     parecido: máx ${pct(sims, 0)} · top10 ${pct(sims, 10 / sims.length)} · top200 ${pct(sims, 200 / sims.length)} · mediana ${pct(sims, 0.5)}`);
    console.log(`     códigos (${codigos.length}) por división: ${divisiones}`);
    for (const l of p.vecinos.slice(0, 8)) console.log(`      · ${l.titulo.slice(0, 105)}`);
    const ejemplos = ejemplosPorFamilia(p, caso.familias);
    for (const [f, es] of Object.entries(ejemplos)) {
      console.log(`     ejemplos ${f}: ${es.length ? es.map((e) => e.titulo.slice(0, 55)).join(" | ") : "(ninguno)"}`);
    }
  }
}
