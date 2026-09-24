// ============================================================
// Probar los contratos parecidos del alta sin NIF (vecinos.ts)
// ============================================================
//
// Con descripciones inventadas: nada de clientes. Lee lo adjudicado de
// unas familias prefijo a prefijo (como hará refrescar_muestra_adjudicada)
// y pasa por las mismas funciones que la función de alta. Enseña los
// títulos más parecidos, los códigos que se capturarían y cuánto tarda.
// Solo lee.
//
//   deno run -A scripts/probar_vecinos.ts
//
// Variables: SUPABASE_URL, SUPABASE_KEY (clave secreta), OPENAI_API_KEY.
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  type Adjudicada, buscarParecidos, codigosDelVecindario, ejemplosPorFamilia,
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
];

async function adjudicadas(familias: string[]): Promise<Adjudicada[]> {
  const codigos = familias.flatMap((f) => Array.from({ length: 100 }, (_, i) => f + String(i).padStart(2, "0")));
  const filas: Adjudicada[] = [];
  for (let i = 0; i < codigos.length; i += 4) {
    const tanda = await Promise.all(codigos.slice(i, i + 4).map(async (c) => {
      const { data } = await db.from("licitaciones")
        .select("id_licitacion, prefijo_principal, titulo, organo, presupuesto, presupuesto_base, importe_adjudicacion, adjudicatario, adjudicatario_cif, cpvs, procedimiento")
        .eq("prefijo_principal", c).not("adjudicatario_cif", "is", null)
        .order("fecha_actualizacion", { ascending: false }).limit(100);
      return (data ?? []).filter((l) => l.procedimiento !== "Contrato menor" && l.titulo)
        .map((l) => ({ ...l, presupuesto: l.presupuesto_base ?? l.presupuesto,
                       importe: l.importe_adjudicacion }) as unknown as Adjudicada);
    }));
    filas.push(...tanda.flat());
  }
  return filas;
}

for (const caso of CASOS) {
  const filas = await adjudicadas(caso.familias);
  const t0 = performance.now();
  const p = await buscarParecidos(caso.descripcion, filas, caso.franjas);
  const ms = Math.round(performance.now() - t0);
  const codigos = codigosDelVecindario(p);
  const ejemplos = ejemplosPorFamilia(p, caso.familias);
  console.log(`\n${caso.descripcion}`);
  console.log(`  ${filas.length} adjudicados · ${p.vecinos.length} vecinos · ${ms} ms (embeddings incluidos)`);
  console.log(`  códigos: ${codigos.join(", ")}`);
  for (const l of p.vecinos.slice(0, 8)) console.log(`   · ${l.titulo.slice(0, 110)}`);
  for (const [f, es] of Object.entries(ejemplos)) {
    console.log(`  ejemplos ${f}: ${es.map((e) => e.titulo.slice(0, 60)).join(" | ")}`);
  }
}
