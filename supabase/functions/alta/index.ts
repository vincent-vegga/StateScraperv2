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
// La lectura del historial define el producto de cada cliente y ocurre
// una sola vez en su vida. Compensa un modelo mejor que el del cribado
// diario: unos céntimos por cliente frente a un criterio mediocre para
// siempre.
const MODELO_HISTORIAL = Deno.env.get("MODELO_HISTORIAL") ?? "gpt-4o";
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
// Tamaño del lote y peticiones simultáneas. Con cinco a la vez, un
// cliente con miles de licitaciones esperaba veinte minutos delante de
// una pantalla. Y como la cola viene ordenada por plazo, lo primero que
// ve es lo que antes vence.
const LOTE = 60;
const SIMULTANEAS = 20;



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

2b. ELIGE SOLO DE LA LISTA que se te da a continuación, y prefiere \
divisiones de dos dígitos con volumen alto. Un prefijo que no esté en esa \
lista no traerá NADA: no existe en los datos. Si dudas entre una división \
concreta y otra más amplia que la contenga, elige la amplia.
3. Máximo 8 prefijos. Si el negocio abarca más, usa prefijos más cortos.
4. Ordena de más a menos central.
5. Explica cada uno en UNA FRASE en lenguaje llano, sin jerga, para que \
alguien que no sabe qué es un CPV pueda juzgar si le sirve.
6. Añade un aviso cuando un prefijo vaya a traer bastante ruido ajeno.

Devuelve además DOS LISTAS DE PALABRAS que sirven para reconocer sus \
contratos en un título:

- "producto": qué vende, en las palabras que aparecerían escritas en el \
título de un contrato público. Usa RAÍCES sin terminación, para que valgan \
en singular y plural: "uniform" cubre uniforme y uniformidad; "chalec" \
cubre chaleco y chalecos. Entre 5 y 12 palabras. Sin tildes.

- "destinatario": a quién se lo vende. Es lo que separa "uniformidad para \
policía" de "uniformidad para jardineros municipales", que es la \
distinción que de verdad importa. Entre 3 y 8 palabras, también en raíz y \
sin tildes. Si el negocio no tiene un destinatario característico, \
devuelve la lista vacía.

REGLA CRÍTICA SOBRE LAS PALABRAS: solo valen las que DISTINGUEN. Una \
palabra que aparece en muchos contratos no sirve de nada, y estropea el \
resultado más que ayudarlo.

  · NUNCA uses "equip", "material", "suministr", "servici", "product", \
"sistem", "element" ni parecidas: aparecen en todo tipo de contrato.
  · NUNCA uses como destinatario "ayunt", "diput", "municip", "public", \
"administr" ni parecidas: están en casi todos los contratos públicos, así \
que no separan nada.
  · El destinatario debe ser el COLECTIVO CONCRETO que usa lo que vende \
—"polic", "bomber", "sanitari", "escolar"—, no el organismo que firma el \
contrato.
  · Prefiere palabras específicas del oficio aunque cubran menos casos: \
más vale reconocer la mitad con precisión que todo sin criterio.

Devuelve EXCLUSIVAMENTE JSON:
{"prefijos":[{"prefijo":"18","que_trae":"...","aviso":"..."}],\
"producto":["uniform","chalec"],"destinatario":["polic","agente"],\
"resumen":"..."}`;

async function llamarModelo(mensajes: unknown[], maxTokens = 900,
                            modelo = MODELO) {
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
      model: modelo,
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

async function proponerCpv(descripcion: string, disponibles: string) {
  const salida = await llamarModelo([
    { role: "system", content: INSTRUCCIONES_CPV },
    // Se le enseña qué divisiones tienen volumen real antes de que
    // proponga. Sin este contexto elegía a ciegas: para "chalecos y
    // guantes" llegó a proponer la división 25, que es caucho y
    // plástico, y salía a cero en pantalla.
    { role: "system", content: `Divisiones CPV con contenido en la base de datos, ` +
      `con su número de licitaciones. Elige SOLO de esta lista:\n${disponibles}` },
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

  const limpiarPalabras = (xs: unknown) =>
    (Array.isArray(xs) ? xs : [])
      .map((p) => sinTildes(String(p)).replace(/[^a-z0-9ñ]/g, ""))
      .filter((p) => p.length >= 4)
      .slice(0, 12);

  return {
    prefijos,
    producto: limpiarPalabras(salida.producto),
    destinatario: limpiarPalabras(salida.destinatario),
    resumen: String(salida.resumen ?? "").trim(),
  };
}

// ------------------------------------------------------------
// Catálogo
// ------------------------------------------------------------

// ------------------------------------------------------------
// Selección de la muestra
// ------------------------------------------------------------

function barajar<T>(lista: T[]) {
  for (let i = lista.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [lista[i], lista[j]] = [lista[j], lista[i]];
  }
}

// ------------------------------------------------------------
// Lectura del historial
// ------------------------------------------------------------

const INSTRUCCIONES_HISTORIAL = `\
Eres un analista de contratación pública española. Te dan los títulos de \
los contratos públicos que una empresa ha GANADO. Son hechos, no \
opiniones: describen exactamente a qué se dedica.

Tu tarea es doble.

1. ESCRIBIR SU CRITERIO. El texto que usará un clasificador automático \
para decidir, sobre contratos futuros, si le interesan a esta empresa.

   · En español y en segunda persona: "responde sí cuando...".
   · Estructura: qué es "sí", qué es "quizás", qué es "no".
   · Deduce el PRINCIPIO que une sus contratos, no los enumeres. Si ha \
ganado vestuario para policía local, el principio es equipar a cuerpos de \
seguridad, no "vestuario de Valdemorillo".
   · Identifica primero QUÉ EJES distinguen sus contratos de los demás. \
Según el negocio pueden ser el producto, el destinatario, el ámbito \
geográfico o el tamaño del contrato. En uniformidad policial el eje es el \
destinatario; en material de oficina, donde el destinatario da igual, \
serán otros. Escribe el criterio en función de los ejes que de verdad \
separan, no de los que suenan bien.
   · DEFINE EL "NO" CON EL VECINO MÁS PARECIDO, no con lo lejano. Decir \
"no cuando sea software o maquinaria" no sirve de nada: nadie confunde eso. \
Lo que hay que nombrar es el caso que SÍ se parece y aun así no encaja \
—"vestuario para personal municipal que no pertenece a cuerpos de \
seguridad"—, porque es el único que un clasificador puede equivocar.
   · Incluye la prueba decisiva: ¿podría esta empresa ser el proveedor \
principal de este contrato?
   · Ante duda razonable entre "quizás" y "no", elige "quizás". Perder una \
oportunidad es mucho más grave que mostrar una de más.
   · Máximo 350 palabras.

2. VALIDAR SUS CÓDIGOS CPV. Se te dan los prefijos que aparecen en sus \
contratos, con su frecuencia. Algunos están MAL PUESTOS por el organismo \
que publicó el anuncio: es habitual. Un contrato titulado "Vestuario \
Policía Local" con el código de software lleva un error evidente.

   Devuelve solo los prefijos que encajan de verdad con lo que hace la \
empresa, según los títulos que has leído. Descarta los que solo pueden \
explicarse como un error de etiquetado.

Devuelve EXCLUSIVAMENTE JSON:
{"criterio":"...","prefijos_validos":["3581","1810"],\
"descartados":[{"prefijo":"4800","motivo":"..."}],\
"actividad":"una frase sobre a qué se dedica","resumen":"una frase para el cliente"}`;

async function leerHistorial(
  contratos: { titulo: string; organo: string; importe: number | null }[],
  prefijos: { prefijo: string; contratos: number }[],
) {
  const lista = contratos
    .map((c) => `- ${c.titulo}${c.organo ? ` (${c.organo})` : ""}`)
    .join("\n");
  const codigos = prefijos
    .map((p) => `${p.prefijo}: ${p.contratos} contratos`)
    .join("\n");

  return await llamarModelo([
    { role: "system", content: INSTRUCCIONES_HISTORIAL },
    {
      role: "user",
      content: `CONTRATOS GANADOS (${contratos.length}):\n${lista}\n\n` +
               `PREFIJOS CPV QUE APARECEN:\n${codigos}`,
    },
  ], 1600, MODELO_HISTORIAL);
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
// Equilibrio de la muestra
// ------------------------------------------------------------

// Palabras que no distinguen nada: aparecen en cualquier descripción de
// negocio y en la mitad de los títulos de contrato.
const VACIAS = new Set([
  "para", "con", "los", "las", "del", "que", "por", "una", "uno", "sus",
  "nuestro", "nuestra", "nuestros", "nuestras", "empresa", "vendemos",
  "vender", "venta", "servicio", "servicios", "suministro", "suministros",
  "todo", "tipo", "tipos", "otros", "otras", "sobre", "trabajamos",
  "completa", "completo", "material", "materiales", "equipamiento",
  "producto", "productos", "accesorios", "contrato", "contratos",
]);

const sinTildes = (s: string) =>
  s.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase();

/**
 * Palabras significativas de la descripción del cliente.
 *
 * Sirven para reconocer, sin llamar al modelo, qué contratos tienen
 * pinta de ser suyos. No es una clasificación: es un indicio barato
 * para equilibrar la muestra.
 */
function palabrasClave(descripcion: string): string[] {
  const palabras = sinTildes(descripcion)
    .replace(/[^a-z0-9ñ ]/g, " ")
    .split(/\s+/)
    .filter((p) => p.length >= 4 && !VACIAS.has(p));
  return [...new Set(palabras)];
}

/** Cuántas palabras clave aparecen en el título de una licitación. */
function afinidad(titulo: string, claves: string[]): number {
  const t = sinTildes(titulo);
  return claves.reduce((n, c) => n + (t.includes(c) ? 1 : 0), 0);
}

// ------------------------------------------------------------
// Cribado con el criterio del cliente
// ------------------------------------------------------------

function instruccionesCribado(criterio: string) {
  return `${criterio}

CÓMO APLICARLO

El "sí" exige que TODAS las condiciones de su cláusula estén en el texto \
del contrato. En el motivo, cita la palabra o frase concreta que satisface \
cada una. Si alguna condición la estás infiriendo en lugar de leerla, el \
veredicto es "quizás", no "sí".

Es el fallo habitual: ante un criterio como "vestuario para cuerpos de \
seguridad", un contrato de "vestuario para el personal del Ayuntamiento" \
cumple lo de vestuario pero NO lo de cuerpos de seguridad. Eso es "quizás".

Devuelve EXCLUSIVAMENTE un objeto JSON, sin texto alrededor:
{"veredicto":"si|quizas|no","motivo":"una frase breve en español que cite \
lo que has leído"}`;
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

    const { accion, descripcion, prefijos, respuestas, cif, empresa } =
      await peticion.json();

    const { data: perfiles } = await comoUsuario.from("perfiles")
      .select("*").eq("usuario_id", user.id).limit(1);
    const perfil = perfiles?.[0];
    if (!perfil) return responder({ error: "sin_perfil" }, 403);

    // --- Buscar la empresa por su CIF ---
    //
    // Adivinar a qué contratos se presenta un cliente, a partir de cómo
    // describe su negocio, resultó poco fiable: hicieron falta cuatro
    // rediseños y el mejor resultado fue que reconociera doce de treinta
    // ejemplos.
    //
    // Ese dato no hay que adivinarlo: está publicado. Los contratos que
    // ha ganado llevan su CIF, así que basta con que se identifique.
    if (accion === "buscar_empresa") {
      const { data, error: fallo } = await admin.rpc("buscar_empresa", {
        cif_buscado: cif ?? null,
        nombre_buscado: empresa ?? null,
      });
      if (fallo) {
        console.error("Fallo al buscar empresa:", fallo);
        return responder({ error: "error_interno" }, 500);
      }

      const encontradas = (data ?? []) as Record<string, unknown>[];
      if (!encontradas.length) return responder({ ok: true, empresas: [] });

      // De la primera se traen sus últimos contratos: enseñárselos es
      // lo que demuestra que el sistema sabe de qué habla, antes de
      // pedirle nada.
      const { data: ultimos } = await admin.rpc("ultimos_ganados", {
        cif_buscado: String(encontradas[0].cif), tope: 5,
      });

      return responder({ ok: true, empresas: encontradas, ultimos: ultimos ?? [] });
    }

    // --- Confirmar la empresa: se lee su historial y se genera todo ---
    //
    // Aquí desaparecen las tarjetas. No hacen falta: los contratos que ha
    // ganado dicen a qué se dedica mejor que treinta respuestas suyas, y
    // sin pedirle cinco minutos de trabajo.
    //
    // Además resuelve un problema que las tarjetas no podían: los códigos
    // CPV vienen a veces MAL PUESTOS por el organismo que publica. Una
    // empresa de uniformidad tenía dos contratos etiquetados como
    // software —"Vestuario Policía Local" con el código 48000000— y eso
    // le metía 6.071 licitaciones ajenas en el perfil. Leyendo los
    // títulos, el error salta a la vista.
    if (accion === "confirmar_empresa") {
      if (!cif) return responder({ error: "sin_cif" }, 400);

      const { data: empresas } = await admin.rpc("buscar_empresa",
        { cif_buscado: cif, nombre_buscado: null });
      const suya = (empresas ?? [])[0] as Record<string, unknown> | undefined;
      if (!suya) return responder({ error: "empresa_no_encontrada" }, 404);

      const [{ data: ganados }, { data: prefijosCrudos }] = await Promise.all([
        admin.rpc("ultimos_ganados", { cif_buscado: cif, tope: 40 }),
        admin.rpc("prefijos_de_empresa", { cif_buscado: cif, minimo: 1 }),
      ]);

      const contratos = ((ganados ?? []) as Record<string, unknown>[]).map((g) => ({
        titulo: String(g.titulo ?? ""),
        organo: String(g.organo ?? ""),
        importe: g.importe ? Number(g.importe) : null,
      }));
      const prefijos = (prefijosCrudos ?? []) as { prefijo: string; contratos: number }[];

      if (!contratos.length || !prefijos.length) {
        return responder({ error: "sin_historial" }, 404);
      }

      const lectura = await leerHistorial(contratos, prefijos);

      // Los prefijos que valida el modelo. Si no valida ninguno —cosa que
      // no debería pasar— se usan los que tengan al menos dos contratos,
      // que es el criterio anterior.
      const validos = (Array.isArray(lectura.prefijos_validos)
        ? lectura.prefijos_validos : [])
        .map((p: unknown) => String(p).replace(/\D/g, ""))
        .filter((p: string) => p.length >= 2 && p.length <= 6);
      const finales = validos.length
        ? validos
        : prefijos.filter((p) => p.contratos >= 2).map((p) => p.prefijo);

      const descartados = Array.isArray(lectura.descartados) ? lectura.descartados : [];
      if (descartados.length) {
        console.log("CPV descartados:", descartados
          .map((d: Record<string, unknown>) => `${d.prefijo} (${d.motivo})`).join(" · "));
      }

      await comoUsuario.from("perfiles").update({
        empresa: String(suya.nombre ?? ""),
        cif: String(suya.cif ?? ""),
        contratos_ganados: Number(suya.contratos ?? 0),
        cpv_prefijos: finales.join(","),
        nombre: String(suya.nombre ?? perfil.nombre),
        descripcion: String(lectura.actividad ?? ""),
        criterio: String(lectura.criterio ?? ""),
        criterio_version: (perfil.criterio_version ?? 0) + 1,
        criterio_fecha: new Date().toISOString(),
        // Directo a cribar: no hay tarjetas que deslizar.
        paso_alta: "cribando",
      }).eq("id", perfil.id);

      console.log(`Empresa ${suya.cif}: ${suya.contratos} contratos, ` +
                  `prefijos ${finales.join(",")}`);

      return responder({
        ok: true,
        prefijos: finales,
        descartados,
        actividad: String(lectura.actividad ?? ""),
        resumen: String(lectura.resumen ?? ""),
        contratos: Number(suya.contratos ?? 0),
      });
    }

    // --- Proponer CPV a partir de la descripción ---
    if (accion === "proponer") {
      if (!descripcion || descripcion.trim().length < 15) {
        return responder({ error: "descripcion_corta" }, 400);
      }
      // Las divisiones de dos dígitos con volumen. Es la lista de la
      // que puede elegir el modelo.
      const { data: divisiones } = await admin.from("resumen_cpv_total")
        .select("prefijo, licitaciones")
        .gt("licitaciones", 50)
        .order("licitaciones", { ascending: false })
        .limit(400);

      const catalogoDivisiones = (divisiones ?? [])
        .filter((d) => d.prefijo.length === 2)
        .map((d) => `${d.prefijo}: ${d.licitaciones}`)
        .join("\n");

      const propuesta = await proponerCpv(descripcion, catalogoDivisiones);

      // Cuántas trae cada prefijo. Sin ese número, confirmar la
      // propuesta sería a ciegas: uno que trae cero sobra y uno que
      // trae diez mil es demasiado ancho.
      //
      // Sale de una tabla de resumen calculada al procesar el histórico.
      // Contarlo aquí exigiría recorrer el catálogo entero —620.000
      // líneas de CSV— y eso agota el tiempo de cálculo de la función.
      const { data: resumen } = await admin.from("resumen_cpv_total")
        .select("prefijo, licitaciones, vivas")
        .in("prefijo", propuesta.prefijos.map((p) => p.prefijo));

      const porPrefijo = Object.fromEntries(
        (resumen ?? []).map((r) => [r.prefijo, r]));
      for (const p of propuesta.prefijos) {
        p.volumen = porPrefijo[p.prefijo]?.licitaciones ?? 0;
        p.vivas = porPrefijo[p.prefijo]?.vivas ?? 0;
      }

      console.log("Palabras:", propuesta.producto.join(","), "|",
                  propuesta.destinatario.join(","));
      console.log("Propuesta:", propuesta.prefijos
        .map((p) => `${p.prefijo}=${p.volumen}`).join(" "));

      // Los que no traen nada no se enseñan. Un cero sin explicación
      // desconcierta y no aporta: ofrecer una categoría que no va a dar
      // resultados es peor que no ofrecerla.
      const conVolumen = propuesta.prefijos.filter((p) => (p.volumen ?? 0) > 0);
      if (conVolumen.length) propuesta.prefijos = conVolumen;

      // Se descartan las palabras que no discriminan. El modelo no puede
      // saber cuáles son —depende de los datos— pero se mide en un
      // segundo: una palabra que aparece en un tercio de los contratos
      // no separa nada, y con "ayunt" como destinatario casi todo
      // contaba como del sector del cliente.
      const util = async (palabras: string[], tope: number) => {
        if (!palabras.length) return [];
        const { data } = await admin.rpc("utilidad_palabras", { palabras });
        if (!data) return palabras;
        const buenas = (data as { palabra: string; porcentaje: number }[])
          .filter((d) => d.porcentaje <= tope)
          .map((d) => d.palabra);
        const fuera = palabras.filter((p) => !buenas.includes(p));
        if (fuera.length) console.log("Palabras descartadas:", fuera.join(", "));
        return buenas.length ? buenas : palabras;
      };

      // El destinatario se exige más estricto: es lo que separa lo claro
      // de la frontera, y una palabra floja ahí arruina la muestra
      // entera.
      propuesta.producto = await util(propuesta.producto, 8);
      propuesta.destinatario = await util(propuesta.destinatario, 4);

      await comoUsuario.from("perfiles").update({
        descripcion,
        palabras_producto: propuesta.producto,
        palabras_destinatario: propuesta.destinatario,
        paso_alta: "describiendo",
      }).eq("id", perfil.id);

      return responder({ ok: true, ...propuesta });
    }

    // --- Material de entrenamiento ---
    if (accion === "material") {
      const lista = (prefijos ?? []).map((p: string) => String(p).replace(/\D/g, ""))
        .filter((p: string) => p.length >= 2 && p.length <= 6);
      if (!lista.length) return responder({ error: "sin_prefijos" }, 400);

      // Con historial, el material sale de sus sectores reales: lo que
      // NO ganó dentro de ellos. Puede que ni se presentara —y entonces
      // no le interesa— o que perdiera, y entonces sí. Esa distinción es
      // la que el historial no da y solo él sabe.
      if (perfil.cif) {
        // El reparto lo hace la base, en proporción a cuántos contratos
        // ha ganado en cada prefijo: si el 90% de su historial es
        // protección y ropa, el 90% de las tarjetas lo son.
        const { data: candidatas, error: falloEmpresa } = await admin
          .rpc("material_de_empresa",
               { cif_buscado: perfil.cif, prefijos: lista, tope: CUANTAS });

        if (falloEmpresa) {
          console.error("Fallo al buscar material de empresa:", falloEmpresa);
          return responder({ error: "error_interno" }, 500);
        }

        const todas = (candidatas ?? []) as Record<string, unknown>[];
        barajar(todas);
        const escogidas = todas.slice(0, CUANTAS);
        if (!escogidas.length) return responder({ error: "catalogo_vacio" }, 404);

        await comoUsuario.from("perfiles").update({
          cpv_prefijos: lista.join(","), paso_alta: "entrenando",
        }).eq("id", perfil.id);

        console.log(`Material de historial: ${escogidas.length} de ${(candidatas ?? []).length}`);

        return responder({
          ok: true,
          total_disponibles: (candidatas ?? []).length,
          licitaciones: escogidas.map((f) => ({
            id_licitacion: f.id_licitacion,
            titulo: f.titulo,
            organo: f.organo ?? "",
            presupuesto: f.presupuesto ? Number(f.presupuesto) : null,
            cpvs: (f.cpvs ?? []) as string[],
            adjudicatario: String(f.adjudicatario ?? ""),
            importe_adjudicacion: f.importe_adjudicacion
              ? Number(f.importe_adjudicacion) : null,
          })),
        });
      }

      const producto = (perfil.palabras_producto ?? []) as string[];
      const destinatario = (perfil.palabras_destinatario ?? []) as string[];

      // LA FRONTERA, DENTRO DEL VECINDARIO.
      //
      // Separar "menciona lo que vende" de "no lo menciona" llenaba la
      // mitad de las tarjetas de formación, obras o instalaciones
      // eléctricas: cosas que nadie confundiría con equipamiento
      // policial. El cliente rechazaba veintiocho de treinta y esos
      // rechazos no enseñaban nada.
      //
      // La frontera real está entre uniformidad PARA POLICÍA y
      // uniformidad para jardineros municipales. Así que ambos grupos
      // salen del vecindario —contratos que mencionan lo que vende— y
      // lo que los separa es el destinatario.
      const mitad = Math.floor(CUANTAS / 2);
      const argumentos = {
        prefijos: lista, producto, destinatario,
        solo_vivas: false, tope: 200,
      };

      const [encajan, frontera] = await Promise.all([
        producto.length
          ? admin.rpc("licitaciones_del_vecindario",
                      { ...argumentos, con_destinatario: true })
          : Promise.resolve({ data: [], error: null }),
        producto.length
          ? admin.rpc("licitaciones_del_vecindario",
                      { ...argumentos, con_destinatario: false })
          : Promise.resolve({ data: [], error: null }),
      ]);

      if (encajan.error || frontera.error) {
        console.error("Fallo al buscar material:", encajan.error ?? frontera.error);
        return responder({ error: "error_interno" }, 500);
      }

      let claras = (encajan.data ?? []) as Record<string, unknown>[];
      let dudosas = (frontera.data ?? []) as Record<string, unknown>[];

      // Si el negocio no tiene destinatario característico, o el
      // vecindario se queda corto, se recurre al conjunto entero: mejor
      // treinta tarjetas imperfectas que ninguna.
      if (claras.length + dudosas.length < CUANTAS) {
        const { data: sueltas } = await admin.rpc("licitaciones_por_prefijo",
          { prefijos: lista, solo_vivas: false, tope: 300 });
        dudosas = [...dudosas, ...((sueltas ?? []) as Record<string, unknown>[])];
      }
      if (!claras.length && !dudosas.length) {
        return responder({ error: "catalogo_vacio" }, 404);
      }

      barajar(claras);
      barajar(dudosas);

      const deClaras = Math.min(mitad, claras.length);
      const escogidas = [
        ...claras.slice(0, deClaras),
        ...dudosas.slice(0, CUANTAS - deClaras),
      ];
      if (escogidas.length < CUANTAS) {
        escogidas.push(...claras.slice(deClaras, deClaras + CUANTAS - escogidas.length));
      }

      // Sin repeticiones: una licitación puede aparecer en los dos
      // conjuntos si el vecindario se completó con el conjunto suelto,
      // y ver el mismo contrato dos veces desconcierta.
      const vistas = new Set<string>();
      const finales = escogidas.filter((f) => {
        const id = String(f.id_licitacion);
        if (vistas.has(id)) return false;
        vistas.add(id);
        return true;
      }).slice(0, CUANTAS);

      barajar(finales);
      console.log(`Material: ${claras.length} claras, ${dudosas.length} frontera, ` +
                  `${finales.length} enviadas`);

      await comoUsuario.from("perfiles").update({
        cpv_prefijos: lista.join(","), paso_alta: "entrenando",
      }).eq("id", perfil.id);

      return responder({
        ok: true,
        total_disponibles: claras.length + dudosas.length,
        licitaciones: finales.map((f) => ({
          id_licitacion: f.id_licitacion,
          titulo: f.titulo,
          organo: f.organo ?? "",
          presupuesto: f.presupuesto ? Number(f.presupuesto) : null,
          cpvs: (f.cpvs ?? []) as string[],
          adjudicatario: "",
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

      // Los contratos que ganó son ejemplos positivos seguros: no hay
      // opinión más fiable que un contrato adjudicado. Se suman a lo que
      // haya marcado, de forma que el criterio tenga base sólida aunque
      // en las tarjetas diga que sí a pocas.
      let ejemplos = respuestas;
      if (perfil.cif) {
        const { data: ganados } = await admin.rpc("ultimos_ganados",
          { cif_buscado: perfil.cif, tope: 25 });
        const positivos = ((ganados ?? []) as Record<string, unknown>[]).map((g) => ({
          titulo: String(g.titulo ?? ""),
          organo: String(g.organo ?? ""),
          cpvs: "",
          interesa: true,
        }));
        ejemplos = [...positivos, ...respuestas];
        console.log(`Criterio con ${positivos.length} contratos ganados ` +
                    `y ${respuestas.length} respuestas`);
      }

      const criterio = await generarCriterio(
        perfil.descripcion || `Empresa: ${perfil.empresa ?? ""}`, ejemplos);

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
      // Cuánto queda. Se pide un tope alto en lugar de contar: contar
      // sobre 220.000 filas agotaba el tiempo de consulta.
      const { data: cola } = await admin.rpc("pendientes_de_perfil",
        { perfil: perfil.id, tope: 2000 });
      const total = (cola ?? []).length;

      if (!total) {
        await comoUsuario.from("perfiles").update({ paso_alta: "listo" })
          .eq("id", perfil.id);
        return responder({ ok: true, terminado: true, quedan: 0 });
      }

      const pendientes = (cola ?? []).slice(0, LOTE) as Record<string, unknown>[];

      // En tandas pequeñas y no todas a la vez: el proveedor limita las
      // peticiones simultáneas, y saturarlo haría fallar el lote entero.
      const resultados: Record<string, unknown>[] = [];
      for (let i = 0; i < pendientes.length; i += SIMULTANEAS) {
        const tanda = pendientes.slice(i, i + SIMULTANEAS);
        const veredictos = await Promise.all(tanda.map((l) =>
          clasificar(perfil.criterio, {
            titulo: String(l.titulo ?? ""), organo: String(l.organo ?? ""),
            presupuesto: l.presupuesto ? Number(l.presupuesto) : null,
            cpvs: (l.cpvs ?? []) as string[],
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
