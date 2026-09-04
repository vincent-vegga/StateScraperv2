// ============================================================
// STATE SCRAPER · Función de alta
// ============================================================
//
// Atiende el flujo de alta de un cliente, en tres acciones:
//
//   proponer  -> lee su descripción, propone prefijos CPV y cuenta
//                cuántas licitaciones trae cada uno
//   material  -> filtra el catálogo por esos prefijos y devuelve las
//                licitaciones que se le van a enseñar
//   guardar   -> recibe sus respuestas, genera su criterio y lo activa
//
// Va aquí y no en el navegador por dos motivos: la clave de OpenAI no
// puede salir del servidor, y el catálogo son ficheros de decenas de
// megas que no tiene sentido descargar en el cliente.
//
// Todas las acciones exigen sesión. La función se ejecuta en nombre de
// quien llama y solo toca su propio perfil.
//
// Despliegue:
//   supabase functions deploy alta
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const MODELO = Deno.env.get("MODELO_ALTA") ?? "gpt-4o-mini";
const OPENAI = "https://api.openai.com/v1/chat/completions";

// Cuántas licitaciones se le enseñan y cómo se reparten. El núcleo fija
// el centro del negocio; la frontera define el borde. Solo con frontera,
// el criterio sale sesgado hacia la excepción y rechaza el negocio
// principal; solo con núcleo, no aprende dónde termina.
const CUANTAS = 30;
const PROPORCION_NUCLEO = 0.4;

// Cribado por lotes. Una función de Supabase no puede tardar minutos, y
// un cliente nuevo puede tener cientos de licitaciones vivas que
// clasificar. Se procesa un lote por llamada y la página va pidiendo el
// siguiente: así hay progreso visible y, si se corta, se retoma donde
// iba en vez de empezar de cero.
const LOTE = 25;
const SIMULTANEAS = 5;



const cors = {
  "Access-Control-Allow-Origin": Deno.env.get("ORIGEN_PERMITIDO") ?? "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const responder = (cuerpo: unknown, estado = 200) =>
  new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...cors, "Content-Type": "application/json" },
  });

// ------------------------------------------------------------
// Propuesta de CPV
// ------------------------------------------------------------

const INSTRUCCIONES_CPV = `\
Eres un experto en contratación pública española y en el vocabulario CPV, \
la clasificación europea de los contratos.

Te dan la descripción de un negocio en lenguaje corriente. Propón los \
PREFIJOS CPV bajo los que ese negocio encontraría contratos públicos.

REGLAS:
1. Devuelve PREFIJOS, no códigos completos. Dos dígitos cubren una división \
entera; cuatro, un grupo. Elige la longitud según el alcance del negocio.
2. PECA DE AMPLIO. Este filtro solo delimita qué se captura; después hay un \
segundo filtro semántico que decide qué es relevante. Dejar fuera una \
familia es un error grave y silencioso: nadie se entera de lo que nunca \
llegó. Traer de más cuesta céntimos.
3. Máximo 8 prefijos. Si el negocio abarca más, usa prefijos más cortos.
4. Ordena de más a menos central.
5. Explica cada uno en UNA FRASE en lenguaje llano, sin jerga, para que \
alguien que no sabe qué es un CPV pueda juzgar si le sirve.
6. Añade un aviso cuando un prefijo vaya a traer bastante ruido ajeno.

Devuelve EXCLUSIVAMENTE JSON:
{"prefijos":[{"prefijo":"18","que_trae":"...","aviso":"..."}],"resumen":"..."}`;

async function llamarModelo(mensajes: unknown[], maxTokens = 900) {
  const clave = Deno.env.get("OPENAI_API_KEY");
  if (!clave) throw new Error("Falta OPENAI_API_KEY en la función.");

  const respuesta = await fetch(OPENAI, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${clave}`,
      "Content-Type": "application/json",
      "User-Agent": "StateScraper/1.0",
    },
    body: JSON.stringify({
      model: MODELO,
      messages: mensajes,
      response_format: { type: "json_object" },
      temperature: 0,
      max_tokens: maxTokens,
    }),
  });

  if (!respuesta.ok) {
    throw new Error(`El modelo respondió ${respuesta.status}: ${(await respuesta.text()).slice(0, 300)}`);
  }
  const datos = await respuesta.json();
  return JSON.parse(datos.choices[0].message.content);
}

async function proponerCpv(descripcion: string) {
  const salida = await llamarModelo([
    { role: "system", content: INSTRUCCIONES_CPV },
    { role: "user", content: descripcion },
  ]);

  // Se validan los prefijos: uno de un dígito abarcaría media
  // clasificación y uno de más de seis deja de ser un prefijo.
  const prefijos = (salida.prefijos ?? [])
    .map((p: Record<string, unknown>) => ({
      prefijo: String(p.prefijo ?? "").replace(/\D/g, ""),
      que_trae: String(p.que_trae ?? "").trim(),
      aviso: String(p.aviso ?? "").trim(),
    }))
    .filter((p: { prefijo: string }) => p.prefijo.length >= 2 && p.prefijo.length <= 6);

  if (!prefijos.length) throw new Error("No se ha obtenido ningún prefijo válido.");
  return { prefijos, resumen: String(salida.resumen ?? "").trim() };
}

// ------------------------------------------------------------
// Catálogo
// ------------------------------------------------------------

/**
 * Muestra aleatoria de tamaño fijo sin guardar el conjunto entero.
 *
 * Se queda con las primeras `tope` y, a partir de ahí, cada nueva fila
 * tiene una probabilidad decreciente de sustituir a una ya elegida. El
 * resultado es una muestra uniforme del total usando solo la memoria de
 * `tope` elementos.
 */
class Reservorio {
  vistas = 0;
  elegidas: Record<string, string>[] = [];
  constructor(private tope: number) {}

  ofrecer(fila: Record<string, string>) {
    this.vistas++;
    if (this.elegidas.length < this.tope) {
      this.elegidas.push(fila);
      return;
    }
    const j = Math.floor(Math.random() * this.vistas);
    if (j < this.tope) this.elegidas[j] = fila;
  }
}

// ------------------------------------------------------------
// Selección de la muestra
// ------------------------------------------------------------

function elegirMuestra(
  porFamilia: Record<string, Reservorio>,
  totales: Record<string, number>,
  cuantas: number,
) {
  const grupos: Record<string, Record<string, string>[]> = {};
  for (const familia of Object.keys(porFamilia)) {
    grupos[familia] = [...porFamilia[familia].elegidas];
    barajar(grupos[familia]);
  }

  // El orden depende de cuántas hay EN TOTAL de cada familia, no de
  // cuántas se guardaron en el reservorio: lo que define el núcleo es
  // el peso real en su negocio.
  const porTamano = Object.keys(grupos).sort((a, b) => totales[b] - totales[a]);
  const nNucleo = Math.max(1, Math.round(cuantas * PROPORCION_NUCLEO));

  const repartir = (orden: string[], tope: number) => {
    const sacadas: Record<string, string>[] = [];
    let movido = true;
    while (sacadas.length < tope && movido) {
      movido = false;
      for (const familia of orden) {
        if (grupos[familia]?.length) {
          sacadas.push(grupos[familia].pop()!);
          movido = true;
          if (sacadas.length >= tope) break;
        }
      }
    }
    return sacadas;
  };

  // Núcleo de las familias grandes; frontera de las raras. Y el núcleo
  // primero: las preguntas fáciles enseñan la mecánica, y si se empieza
  // por las dudosas esas respuestas son ruido.
  const nucleo = repartir(porTamano.slice(0, Math.max(1, Math.ceil(porTamano.length / 2))), nNucleo);
  const frontera = repartir([...porTamano].reverse(), cuantas - nucleo.length);
  barajar(nucleo); barajar(frontera);
  return [...nucleo, ...frontera];
}

function barajar<T>(lista: T[]) {
  for (let i = lista.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [lista[i], lista[j]] = [lista[j], lista[i]];
  }
}

// ------------------------------------------------------------
// Generación del criterio
// ------------------------------------------------------------

const INSTRUCCIONES_CRITERIO = `\
Eres un analista de contratación pública. Te dan la descripción de un \
negocio y una lista de contratos que su responsable ha marcado como "me \
interesa" o "no me interesa".

Escribe el CRITERIO que usará un clasificador automático para decidir, \
sobre contratos futuros, si le interesan a esta persona.

REGLAS:
1. Escribe en español, en segunda persona ("responde sí cuando...").
2. Estructura: qué es "sí", qué es "quizás", qué es "no".
3. Deduce el PRINCIPIO que separa los casos, no enumeres los ejemplos. Si \
marcó "no" a ropa de bomberos y "sí" a uniformidad policial, el principio \
es el destinatario, no la prenda.
4. Incluye la prueba decisiva: ¿podría esta empresa ser el proveedor \
principal de este contrato?
5. Ante duda razonable entre "quizás" y "no", elige "quizás". Perder una \
oportunidad es mucho más grave que mostrar una de más.
6. Máximo 400 palabras. Un criterio largo se aplica peor.

Devuelve EXCLUSIVAMENTE JSON:
{"criterio":"el texto del criterio","resumen":"una frase para el cliente"}`;

async function generarCriterio(descripcion: string, ejemplos: {
  titulo: string; organo: string; cpvs: string; interesa: boolean;
}[]) {
  const si = ejemplos.filter((e) => e.interesa);
  const no = ejemplos.filter((e) => !e.interesa);
  const lista = (xs: typeof ejemplos) =>
    xs.map((e) => `- ${e.titulo}${e.organo ? ` (${e.organo})` : ""} [CPV ${e.cpvs}]`).join("\n");

  return await llamarModelo([
    { role: "system", content: INSTRUCCIONES_CRITERIO },
    {
      role: "user",
      content: `NEGOCIO:\n${descripcion}\n\n` +
        `LE INTERESAN (${si.length}):\n${lista(si)}\n\n` +
        `NO LE INTERESAN (${no.length}):\n${lista(no)}`,
    },
  ], 1400);
}

// ------------------------------------------------------------
// Volcado de lo vivo
// ------------------------------------------------------------

/**
 * Trae al sistema las licitaciones del catálogo que encajan con los CPV
 * del cliente y siguen abiertas.
 *
 * Hace falta porque el scraper diario solo captura los sectores que
 * tiene configurados: cuando entra alguien de un sector nuevo, la tabla
 * no tiene nada suyo. Sin este paso, "todo lo vivo" estaría vacío.
 *
 * No pisa lo que ya existe: una licitación capturada en vivo conserva
 * sus datos y su estado.
 */
// ------------------------------------------------------------
// Cribado con el criterio del cliente
// ------------------------------------------------------------

function instruccionesCribado(criterio: string) {
  return `${criterio}

Devuelve EXCLUSIVAMENTE un objeto JSON, sin texto alrededor:
{"veredicto":"si|quizas|no","motivo":"una frase breve en español"}`;
}

async function clasificar(criterio: string, licitacion: {
  titulo: string; organo: string; presupuesto: number | null; cpvs: string[];
}) {
  const ficha = [
    `Título: ${licitacion.titulo}`,
    licitacion.organo ? `Órgano: ${licitacion.organo}` : "",
    licitacion.presupuesto ? `Presupuesto: ${licitacion.presupuesto} EUR` : "",
    licitacion.cpvs.length ? `CPV: ${licitacion.cpvs.slice(0, 8).join(", ")}` : "",
  ].filter(Boolean).join("\n");

  try {
    const salida = await llamarModelo([
      { role: "system", content: instruccionesCribado(criterio) },
      { role: "user", content: ficha },
    ], 150);
    const veredicto = String(salida.veredicto ?? "").toLowerCase();
    if (!["si", "quizas", "no"].includes(veredicto)) return null;
    return { veredicto, motivo: String(salida.motivo ?? "").slice(0, 300) };
  } catch (error) {
    console.error("Fallo al clasificar:", error);
    return null;
  }
}

// ------------------------------------------------------------
// Punto de entrada
// ------------------------------------------------------------

Deno.serve(async (peticion) => {
  if (peticion.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const autorizacion = peticion.headers.get("Authorization");
    if (!autorizacion) return responder({ error: "sin_sesion" }, 401);

    // Cliente en nombre del usuario: las políticas de acceso se aplican,
    // así que no puede tocar el perfil de otro aunque lo intente.
    const comoUsuario = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: autorizacion } } },
    );

    const { data: { user } } = await comoUsuario.auth.getUser();
    if (!user) return responder({ error: "sin_sesion" }, 401);

    // Cliente de servidor: solo para leer el catálogo de Storage, que no
    // pertenece a ningún usuario.
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    const { accion, descripcion, prefijos, respuestas } = await peticion.json();

    const { data: perfiles } = await comoUsuario.from("perfiles")
      .select("*").eq("usuario_id", user.id).limit(1);
    const perfil = perfiles?.[0];
    if (!perfil) return responder({ error: "sin_perfil" }, 403);

    // --- Proponer CPV a partir de la descripción ---
    if (accion === "proponer") {
      if (!descripcion || descripcion.trim().length < 15) {
        return responder({ error: "descripcion_corta" }, 400);
      }
      const propuesta = await proponerCpv(descripcion);

      // Cuántas trae cada prefijo. Sin ese número, confirmar la
      // propuesta sería a ciegas: uno que trae cero sobra y uno que
      // trae diez mil es demasiado ancho.
      //
      // Sale de una tabla de resumen calculada al procesar el histórico.
      // Contarlo aquí exigiría recorrer el catálogo entero —620.000
      // líneas de CSV— y eso agota el tiempo de cálculo de la función.
      const { data: resumen } = await admin.from("resumen_cpv")
        .select("prefijo, licitaciones, vivas")
        .in("prefijo", propuesta.prefijos.map((p) => p.prefijo));

      const porPrefijo = Object.fromEntries(
        (resumen ?? []).map((r) => [r.prefijo, r]));
      for (const p of propuesta.prefijos) {
        p.volumen = porPrefijo[p.prefijo]?.licitaciones ?? 0;
        p.vivas = porPrefijo[p.prefijo]?.vivas ?? 0;
      }

      await comoUsuario.from("perfiles").update({
        descripcion, paso_alta: "describiendo",
      }).eq("id", perfil.id);

      return responder({ ok: true, ...propuesta });
    }

    // --- Material de entrenamiento ---
    if (accion === "material") {
      const lista = (prefijos ?? []).map((p: string) => String(p).replace(/\D/g, ""))
        .filter((p: string) => p.length >= 2 && p.length <= 6);
      if (!lista.length) return responder({ error: "sin_prefijos" }, 400);

      // Sale de la base, no del catálogo: el procesado del histórico ya
      // volcó ahí todo lo vivo. Leer los ficheros del catálogo aquí
      // agotaría el tiempo de cálculo de la función.
      //
      // La búsqueda por prefijo la hace PostgreSQL a través de una
      // función: el operador de contención de PostgREST busca
      // coincidencia exacta, así que pedir "18" no encontraría
      // "18110000".
      const { data: encajan, error: fallo } = await admin
        .rpc("licitaciones_por_prefijo", { prefijos: lista, solo_vivas: true });

      if (fallo) {
        console.error("Fallo al buscar por prefijo:", fallo);
        return responder({ error: "error_interno" }, 500);
      }
      if (!encajan?.length) return responder({ error: "catalogo_vacio" }, 404);

      const porFamilia: Record<string, Reservorio> = {};
      const totales: Record<string, number> = {};
      for (const f of encajan) {
        const fila = {
          id_licitacion: f.id_licitacion, titulo: f.titulo,
          organo: f.organo ?? "", presupuesto: String(f.presupuesto ?? ""),
          adjudicatario: "", importe_adjudicacion: "",
          _cpvs: (f.cpvs ?? []).join("|"),
        } as Record<string, string>;
        const familia = (fila._cpvs.split("|")[0] ?? "otros").slice(0, 4);
        (porFamilia[familia] ??= new Reservorio(CUANTAS)).ofrecer(fila);
        totales[familia] = (totales[familia] ?? 0) + 1;
      }

      const muestra = elegirMuestra(porFamilia, totales, CUANTAS);

      await comoUsuario.from("perfiles").update({
        cpv_prefijos: lista.join(","), paso_alta: "entrenando",
      }).eq("id", perfil.id);

      return responder({
        ok: true,
        total_disponibles: encajan.length,
        licitaciones: muestra.map((f) => ({
          id_licitacion: f.id_licitacion,
          titulo: f.titulo,
          organo: f.organo,
          presupuesto: f.presupuesto ? Number(f.presupuesto) : null,
          cpvs: f._cpvs.split("|"),
          adjudicatario: f.adjudicatario || "",
          importe_adjudicacion: null,
        })),
      });
    }

    // --- Guardar respuestas y generar el criterio ---
    if (accion === "guardar") {
      if (!Array.isArray(respuestas) || respuestas.length < 5) {
        return responder({ error: "pocas_respuestas" }, 400);
      }

      await comoUsuario.from("ejemplos_entrenamiento").insert(
        respuestas.map((r: Record<string, unknown>) => ({
          perfil_id: perfil.id,
          id_licitacion: String(r.id_licitacion),
          titulo: String(r.titulo),
          organo: String(r.organo ?? ""),
          cpvs: String(r.cpvs ?? ""),
          presupuesto: r.presupuesto ?? null,
          interesa: Boolean(r.interesa),
        })),
      );

      const criterio = await generarCriterio(perfil.descripcion ?? "", respuestas);

      // No hace falta traer nada: el procesado del histórico ya volcó a
      // la base todas las licitaciones abiertas, de cualquier sector.
      // Por eso el alta de un cliente nuevo es instantánea.

      await comoUsuario.from("perfiles").update({
        criterio: criterio.criterio,
        criterio_version: (perfil.criterio_version ?? 0) + 1,
        criterio_fecha: new Date().toISOString(),
        paso_alta: "cribando",
      }).eq("id", perfil.id);

      return responder({ ok: true, resumen: criterio.resumen });
    }

    // --- Cribar un lote de lo pendiente ---
    if (accion === "cribar") {
      if (!perfil.criterio) return responder({ error: "sin_criterio" }, 400);

      // Cuánto queda en total, para poder enseñar progreso real en lugar
      // de un mensaje fijo que no dice nada.
      const { count: total } = await comoUsuario
        .from("pendientes_por_perfil")
        .select("id_licitacion", { count: "exact", head: true })
        .eq("perfil_id", perfil.id);

      if (!total) {
        await comoUsuario.from("perfiles").update({ paso_alta: "listo" })
          .eq("id", perfil.id);
        return responder({ ok: true, terminado: true, quedan: 0 });
      }

      const { data: pendientes } = await comoUsuario
        .from("pendientes_por_perfil")
        .select("id_licitacion, titulo, organo, presupuesto, cpvs")
        .eq("perfil_id", perfil.id).limit(LOTE);

      // En tandas pequeñas y no todas a la vez: el proveedor limita las
      // peticiones simultáneas, y saturarlo haría fallar el lote entero.
      const resultados: Record<string, unknown>[] = [];
      for (let i = 0; i < (pendientes ?? []).length; i += SIMULTANEAS) {
        const tanda = (pendientes ?? []).slice(i, i + SIMULTANEAS);
        const veredictos = await Promise.all(tanda.map((l) =>
          clasificar(perfil.criterio, {
            titulo: l.titulo, organo: l.organo ?? "",
            presupuesto: l.presupuesto, cpvs: l.cpvs ?? [],
          })
        ));
        tanda.forEach((l, n) => {
          const v = veredictos[n];
          if (v) {
            resultados.push({
              id_licitacion: l.id_licitacion, perfil_id: perfil.id,
              veredicto: v.veredicto, motivo: v.motivo,
              criterio_version: perfil.criterio_version, modelo: MODELO,
            });
          }
        });
      }

      if (resultados.length) {
        await admin.from("veredictos").upsert(resultados,
          { onConflict: "id_licitacion,perfil_id" });
      }

      const quedan = Math.max(0, total - resultados.length);
      if (quedan === 0) {
        await comoUsuario.from("perfiles").update({ paso_alta: "listo" })
          .eq("id", perfil.id);
      }

      return responder({
        ok: true,
        terminado: quedan === 0,
        hechas: resultados.length,
        quedan,
        total,
      });
    }

    return responder({ error: "accion_desconocida" }, 400);

  } catch (error) {
    // El detalle va al registro de la función, no al cliente: un mensaje
    // de error puede revelar cómo está montado el sistema.
    console.error("Error en la función de alta:", error);
    return responder({ error: "error_interno" }, 500);
  }
});
