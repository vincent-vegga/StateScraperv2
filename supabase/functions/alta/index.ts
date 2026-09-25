// ============================================================
// STATE SCRAPER · Función de alta
// ============================================================
//
// Atiende el flujo de alta de un cliente. Sin historial, en dos acciones:
//
//   proponer            -> lee su descripción, propone prefijos CPV y
//                          cuenta cuántas licitaciones trae cada uno
//   ejemplos            -> los contratos adjudicados más parecidos a su
//                          descripción, por familia, para enseñárselos
//   confirmar_familias  -> guarda las familias que deja marcadas, genera
//                          su criterio con la descripción y los contratos
//                          más parecidos como ejemplos, y lo activa
//
// Con NIF, `buscar_empresa` y `confirmar_empresa` (ver más abajo).
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
import {
  MODELO, MODELO_HISTORIAL, llamarModelo, leerHistorial, regenerarCriterio,
  prefijosDeLectura,
} from "./modelo.ts";
import {
  DIVISIONES, FRANJAS, buscarParecidos, codigosDelVecindario, ejemplosPorFamilia, titulosTipicos,
  type Adjudicada, type Parecidos,
} from "./vecinos.ts";



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



const ORIGENES = new Set([
  "https://statescraperv2.pages.dev",
  "https://statescraper.com",
  "https://www.statescraper.com",
]);
const corsHeaders = (o: string | null) => ({
  "Access-Control-Allow-Origin": o && ORIGENES.has(o) ? o : "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
});

const responder = (cuerpo: unknown, estado = 200, origen: string | null = null) =>
  new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { ...corsHeaders(origen), "Content-Type": "application/json" },
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
en singular y plural: "comed" cubre comedor y comedores; "menu" cubre menú \
y menús. Entre 5 y 12 palabras. Sin tildes.

- "destinatario": a quién se lo vende. Es lo que separa "comedor para \
colegios" de "comedor para residencias de mayores", que es la distinción \
que de verdad importa. Entre 3 y 8 palabras, también en raíz y \
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
—"escolar", "alumn", "residen", "hospital"—, no el organismo que firma \
el contrato.
  · Prefiere palabras específicas del oficio aunque cubran menos casos: \
más vale reconocer la mitad con precisión que todo sin criterio.

Devuelve EXCLUSIVAMENTE JSON:
{"prefijos":[{"prefijo":"18","que_trae":"...","aviso":"..."}],\
"producto":["comed","menu"],"destinatario":["escolar","alumn"],\
"resumen":"..."}`;

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
// Sectores: sus CPV agrupados con nombre de persona
// ------------------------------------------------------------
//
// El filtro por sector de la lista, y más adelante los avisos por sector.
// El cliente no ve códigos: ve 2-6 sectores con el nombre que usaría él.
// Se escriben agrupando SUS prefijos a partir de SUS contratos, porque el
// mismo código significa cosas distintas según la empresa: el 3499 de
// una empresa de alumbrado público son iluminaciones navideñas, no "vehículos".

const INSTRUCCIONES_SECTORES = `\
Te dan los prefijos CPV con los que se buscan contratos públicos para una \
empresa y, para cada uno, cuántos de sus contratos caen ahí y algunos \
títulos de ejemplo.

Agrúpalos en SECTORES para un filtro que verá el cliente.

REGLAS:
1. Entre 2 y 6 sectores. Menos si la empresa hace pocas cosas distintas: \
dos prefijos que en sus contratos significan lo mismo van juntos.
2. Cada prefijo en UN solo sector, y TODOS los prefijos repartidos. No \
inventes prefijos.
3. El filtro sirve para SEPARAR. Si un sector se queda con casi todos \
los contratos, divídelo según lo que dicen los títulos (desarrollo a \
medida, mantenimiento de sistemas, licencias...). Una empresa con muchos \
prefijos parecidos casi siempre hace varias cosas distintas.
4. El nombre, como lo diría el propio cliente: corto (2-5 palabras), en \
español, sin códigos ni jerga de contratación, y con mayúscula solo en la \
primera palabra. "Alumbrado público", no "Trabajos de instalación de \
equipos de alumbrado" ni "Alumbrado Público".
5. Nombra por lo que dicen SUS títulos, no por la definición oficial del \
código: si bajo un prefijo de vehículos aparecen iluminaciones navideñas, \
el sector es de iluminación.
6. Nombra QUÉ se contrata (el producto o el servicio), nunca CÓMO: nada \
de "sistemas de adquisición", "acuerdos marco", "homologación" ni \
"lotes". Si los títulos solo hablan del procedimiento, nombra lo que se \
compra según el código.
7. Nada de "Otros" ni "Varios": cada sector con un nombre que diga algo.
8. Ordena de más a menos contratos.

Devuelve EXCLUSIVAMENTE JSON:
{"sectores":[{"nombre":"...","prefijos":["4531","5023"]}]}`;

async function agruparSectores(
  empresa: string,
  muestras: { prefijo: string; contratos: number; titulos: string[] | null }[],
) {
  const lista = muestras.map((m) =>
    `${m.prefijo} (${m.contratos} contratos)` +
    ((m.titulos ?? []).length
      ? `:\n${(m.titulos ?? []).map((t) => `  - ${t}`).join("\n")}` : "")
  ).join("\n");
  return await llamarModelo([
    { role: "system", content: INSTRUCCIONES_SECTORES },
    { role: "user", content: `EMPRESA: ${empresa}\n\nPREFIJOS:\n${lista}` },
  ], 700, MODELO_HISTORIAL);
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
marcó "no" a comedores de residencias y "sí" a comedores escolares, el \
principio es el destinatario, no la comida.
4. NUNCA uses el territorio como criterio —ni provincia, ni comunidad, \
ni ciudad, ni "especialmente en X"—. Dónde ha trabajado no dice dónde \
puede trabajar, y el cliente ya filtra por zona con un selector propio.

5. Incluye la prueba decisiva: ¿podría esta empresa ser el proveedor \
principal de este contrato?
6. Ante duda razonable entre "quizás" y "no", elige "quizás". Perder una \
oportunidad es mucho más grave que mostrar una de más.
7. Máximo 400 palabras. Un criterio largo se aplica peor.

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

Es el fallo habitual: ante un criterio como "comedor para centros \
educativos", un contrato de "comedor para el personal del Ayuntamiento" \
cumple lo de comedor pero NO lo de centros educativos. Eso es "quizás".

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
    // Sin tildes ni espacios: el modelo a veces contesta "sí" o "quizás",
    // y eso se daba por respuesta no válida. La licitación se quedaba sin
    // veredicto y el cribado no avanzaba.
    const veredicto = String(salida.veredicto ?? "")
      .normalize("NFD").replace(/[\u0300-\u036f]/g, "").trim().toLowerCase();
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

// Los contratos adjudicados de sus familias más parecidos a su
// descripción. Null si la muestra no tiene con qué (vacía hasta la
// primera pasada de refrescar_muestra_adjudicada, o familias sin
// contratos).
async function parecidosDe(
  // deno-lint-ignore no-explicit-any
  admin: { rpc: (f: string, a: Record<string, unknown>) => PromiseLike<{ data: any; error: any }> },
  perfil: Record<string, unknown>, familias: string[],
): Promise<Parecidos | null> {
  // En jsonb, una sola fila: como conjunto de filas, la API cortaba en
  // 1.000 y solo llegaban las primeras familias.
  const { data, error } = await admin.rpc("muestra_de_familias_json", { familias });
  if (error) throw error;
  const filas = ((data ?? []) as Adjudicada[]).filter((l) => l.titulo);
  if (filas.length < 50) return null;
  const franjas = Array.isArray(perfil.franjas) ? perfil.franjas as string[] : [];
  const descripcion = String(perfil.descripcion);
  // Si el modelo no los da, se busca con la descripción tal cual.
  const titulos = await titulosTipicos(descripcion).catch(() => [] as string[]);
  return await buscarParecidos(descripcion, filas, franjas, titulos);
}

// ------------------------------------------------------------
// Puntuación por huellas (puntuador.py en GitHub Actions)
// ------------------------------------------------------------
//
// Las empresas con NIF y al menos MIN_HUELLAS contratos ganados no se
// criban con el criterio en prosa: su lista la calcula puntuador.py
// (parecido con lo que han ganado, sus pares y el CPV como peso, y un juez
// con ejemplos). Recupera el 95 % de lo que la empresa acaba ganando
// frente al 76 % del criterio (docs/afinar-seleccion/RESULTADOS.md).
//
// Corre en GitHub Actions porque necesita ~600 MB de huellas en memoria.
// Desde aquí solo se pide la pasada (workflow_dispatch) y se espera a que
// `puntuado_en` alcance a `puntuacion_pedida`. Sin GITHUB_DISPATCH_TOKEN
// no se puede pedir: el perfil sigue con el criterio de siempre y pasa al
// sistema nuevo en la pasada diaria del día siguiente.
// El mismo mínimo que puntuacion_pesos.json (minimo_ganados): medido en el
// banco con empresas de 5-14 contratos, les va mejor que el criterio.
const MIN_HUELLAS = 5;
const REPO = "vincent-vegga/StateScraperv2";

async function pedirPuntuacion(perfilId: string, rehacer: boolean): Promise<boolean> {
  const token = Deno.env.get("GITHUB_DISPATCH_TOKEN");
  if (!token) return false;
  try {
    const r = await fetch(
      `https://api.github.com/repos/${REPO}/actions/workflows/puntuador.yml/dispatches`, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${token}`,
          "Accept": "application/vnd.github+json",
          "User-Agent": "StateScraper/1.0",
        },
        body: JSON.stringify({
          ref: "main",
          inputs: { perfil: perfilId, rehacer: rehacer ? "true" : "false" },
        }),
      });
    if (r.status !== 204) {
      console.error(`No se pudo pedir la puntuación: ${r.status} ${(await r.text()).slice(0, 200)}`);
      return false;
    }
    return true;
  } catch (error) {
    console.error("No se pudo pedir la puntuación:", error);
    return false;
  }
}

Deno.serve(async (peticion) => {
  const origen = peticion.headers.get("origin");
  if (peticion.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origen) });

  try {
    const autorizacion = peticion.headers.get("Authorization");
    if (!autorizacion) return responder({ error: "sin_sesion" }, 401);

    const { accion, descripcion, prefijos, cif, empresa, dias,
            perfil_id, franjas } = await peticion.json();

    // Con varias empresas por cuenta, la web dice cuál está mirando. Se
    // reenvía a la base como `x-perfil` para que las funciones que buscan
    // "mi perfil" (mi_perfil_id) resuelvan la misma. No da acceso a nada:
    // solo elige entre los perfiles del propio usuario.
    const perfilPedido = typeof perfil_id === "string" &&
        /^[0-9a-f-]{36}$/i.test(perfil_id) ? perfil_id : null;

    // Cliente en nombre del usuario: las políticas de acceso se aplican,
    // así que no puede tocar el perfil de otro aunque lo intente.
    const comoUsuario = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: {
        Authorization: autorizacion,
        ...(perfilPedido ? { "x-perfil": perfilPedido } : {}),
      } } },
    );

    const { data: { user } } = await comoUsuario.auth.getUser();
    if (!user) return responder({ error: "sin_sesion" }, 401);

    // Cliente de servidor: solo para leer el catálogo de Storage, que no
    // pertenece a ningún usuario.
    const admin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // La pedida si es suya; si no (borrada, o de una versión vieja de la
    // web que no la manda), la más antigua, igual que mi_perfil_id().
    const { data: perfiles } = await comoUsuario.from("perfiles")
      .select("*").eq("usuario_id", user.id)
      .order("fecha_alta").order("id").limit(3);
    const perfil = perfiles?.find((p) => p.id === perfilPedido) ?? perfiles?.[0];
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
      // Por CIF o por nombre.
      //
      // El nombre estuvo retirado unas horas el 20/09/2026, cuando la
      // búsqueda recorría `licitaciones` entera: 12 s contra un límite
      // de 8. Volvió al verse que hace falta de verdad: las matrices de
      // los grupos NO licitan. Acciona S.A. (A08001851) y ACS
      // (A28004885) tienen cero contratos a su nombre; los tienen sus
      // filiales, cada una con el suyo. Quien escribe el CIF que conoce
      // se queda fuera aunque su grupo tenga cientos de adjudicaciones.
      //
      // Ya no es lenta: busca contra `empresas`, una fila por CIF
      // (193.312 en vez de 965.337) con índice de trigramas. 'DELOITTE'
      // pasó de 12.294 ms a 7 ms.
      if (!cif && !empresa) return responder({ error: "sin_cif" }, 400);

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

      // Sin CPV no es sin historial. Hay organismos (universidades,
      // ayuntamientos) que publican sus contratos menores sin código, y a
      // una empresa que solo trabaja con ellos se la echaba del alta con
      // "algo ha fallado" teniendo decenas de contratos. Medido el
      // 22/09/2026: el 2,75 % de las sociedades limitadas con entre 15 y
      // 150 contratos, y el 7 % de los autónomos. Los títulos bastan: el
      // modelo deduce los códigos de ellos (ver INSTRUCCIONES_HISTORIAL).
      if (!contratos.length) {
        return responder({ error: "sin_historial" }, 404);
      }
      if (!prefijos.length) {
        console.log(`Empresa ${cif}: ${contratos.length} contratos sin CPV, ` +
                    `se deducen de los títulos`);
      }

      // Misma empresa, misma lectura. El modelo no es determinista y dos
      // altas del mismo NIF daban listas de 17 y de 38 contratos. Un
      // perfil nuevo reutiliza la lectura guardada de ese NIF (30 días);
      // quien rehace su filtro (criterio_version > 0) pide una nueva.
      const CADUCA_LECTURA = 30 * 24 * 3600 * 1000;
      let lectura: Record<string, unknown> | null = null;
      if (!((perfil.criterio_version ?? 0) > 0)) {
        const { data: guardada } = await admin.from("lecturas_empresa")
          .select("datos, creado").eq("cif", String(suya.cif)).maybeSingle();
        if (guardada && Date.now() - Date.parse(guardada.creado) < CADUCA_LECTURA) {
          lectura = guardada.datos;
          console.log(`Empresa ${suya.cif}: lectura reutilizada del ${guardada.creado}`);
        }
      }
      const reutilizada = lectura !== null;
      const leida: Record<string, unknown> =
        lectura ?? await leerHistorial(contratos, prefijos);

      // Los prefijos que valida el modelo. Si no valida ninguno —cosa que
      // no debería pasar— se usan los que tengan al menos dos contratos,
      // que es el criterio anterior.
      const finales = prefijosDeLectura(leida, prefijos);
      // Sin códigos no hay nada que cribar: mejor que describa su negocio.
      if (!finales.length) return responder({ error: "sin_historial" }, 404);

      const descartados = Array.isArray(leida.descartados) ? leida.descartados : [];
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
        descripcion: String(leida.actividad ?? ""),
        criterio: String(leida.criterio ?? ""),
        // Lo que se le enseña a él. El criterio completo no: es la
        // receta del filtro y además está escrito para un clasificador,
        // no para leerse.
        que_buscamos: Array.isArray(leida.que_buscamos)
          ? leida.que_buscamos.map((x: unknown) => String(x)).slice(0, 5) : [],
        criterio_version: (perfil.criterio_version ?? 0) + 1,
        criterio_fecha: new Date().toISOString(),
        // Directo a cribar: no hay tarjetas que deslizar.
        paso_alta: "cribando",
      }).eq("id", perfil.id);

      // Con historial suficiente, su lista la calcula el puntuador.
      // Si no se puede pedir la pasada, sigue con el criterio de siempre.
      const conHuellas = Number(suya.contratos ?? 0) >= MIN_HUELLAS &&
        await pedirPuntuacion(perfil.id, true);
      await admin.from("perfiles").update(conHuellas
        ? { sistema: "huellas", puntuado_en: null,
            puntuacion_pedida: new Date().toISOString() }
        : { sistema: "criterio" }).eq("id", perfil.id);

      if (!reutilizada) {
        await admin.from("lecturas_empresa").upsert({
          cif: String(suya.cif), datos: leida, creado: new Date().toISOString(),
        });
      }

      console.log(`Empresa ${suya.cif}: ${suya.contratos} contratos, ` +
                  `prefijos ${finales.join(",")}`);

      return responder({
        ok: true,
        prefijos: finales,
        descartados,
        actividad: String(leida.actividad ?? ""),
        resumen: String(leida.resumen ?? ""),
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
        // Con su nombre: con el número solo, el modelo escogía las más
        // grandes (ver DIVISIONES en vecinos.ts).
        .map((d) => DIVISIONES[d.prefijo]
          ? `${d.prefijo} (${DIVISIONES[d.prefijo]}): ${d.licitaciones}`
          : `${d.prefijo}: ${d.licitaciones}`)
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
        .in("prefijo", propuesta.prefijos.map((p: { prefijo: string }) => p.prefijo));

      const porPrefijo = Object.fromEntries(
        (resumen ?? []).map((r) => [r.prefijo, r]));
      for (const p of propuesta.prefijos) {
        p.volumen = porPrefijo[p.prefijo]?.licitaciones ?? 0;
        p.vivas = porPrefijo[p.prefijo]?.vivas ?? 0;
      }

      console.log("Palabras:", propuesta.producto.join(","), "|",
                  propuesta.destinatario.join(","));
      console.log("Propuesta:", propuesta.prefijos
        .map((p: { prefijo: string; volumen?: number }) => `${p.prefijo}=${p.volumen}`).join(" "));

      // Los que no traen nada no se enseñan. Un cero sin explicación
      // desconcierta y no aporta: ofrecer una categoría que no va a dar
      // resultados es peor que no ofrecerla.
      const conVolumen = propuesta.prefijos.filter((p: { volumen?: number }) => (p.volumen ?? 0) > 0);
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
        // Los tamaños que ha marcado; ninguno es "no lo sé".
        franjas: (Array.isArray(franjas) ? franjas : [])
          .map((f: unknown) => String(f)).filter((f: string) => FRANJAS.includes(f)),
        paso_alta: "describiendo",
      }).eq("id", perfil.id);

      return responder({ ok: true, ...propuesta });
    }

    // --- Confirmar las familias y generar el criterio (sin historial) ---
    //
    // Aquí iban treinta tarjetas que deslizar. Se quitaron el 23/09/2026:
    // en la simulación con los perfiles que tienen NIF, el criterio que
    // salía de las tarjetas no mejoraba al de la descripción sola, y
    // costaba cinco minutos al cliente. El vecindario que debía elegirlas
    // buscaba por `prefijo_principal` (4 dígitos) con divisiones de 2 y
    // nunca encontraba nada: salían contratos al azar de la división y el
    // cliente les decía que no a casi todos.
    //
    // El criterio sale de su descripción y de los contratos adjudicados
    // más parecidos a ella, como ejemplos de lo que le interesa: lo que
    // hace la entrada por NIF con lo que la empresa ha ganado (decisión
    // 38). Lo que no encaje lo corrige él desde la lista ("no me
    // interesa"), que regenera el criterio con `ajustar`.
    //
    // Si no hay con qué (la muestra aún vacía, o sus familias sin apenas
    // contratos), como antes: la descripción sola y las familias enteras.
    if (accion === "confirmar_familias") {
      const lista = (prefijos ?? []).map((p: string) => String(p).replace(/\D/g, ""))
        .filter((p: string) => p.length >= 2 && p.length <= 6);
      if (!lista.length) return responder({ error: "sin_prefijos" }, 400);
      if (!perfil.descripcion) return responder({ error: "descripcion_corta" }, 400);

      let parecidos: Parecidos | null = null;
      try {
        parecidos = await parecidosDe(admin, perfil, lista);
      } catch (fallo) {
        console.error("Sin contratos parecidos, se sigue con la descripción:", fallo);
      }
      const conEjemplos = parecidos && parecidos.vecinos.length >= 10;

      const criterio = await generarCriterio(perfil.descripcion, conEjemplos
        ? parecidos!.vecinos.map((l) => ({
            titulo: l.titulo, organo: l.organo ?? "",
            cpvs: (l.cpvs ?? []).join(","), interesa: true,
          }))
        : []);
      const codigos = conEjemplos ? codigosDelVecindario(parecidos!) : [];

      await comoUsuario.from("perfiles").update({
        cpv_prefijos: (codigos.length ? codigos : lista).join(","),
        criterio: criterio.criterio,
        criterio_version: (perfil.criterio_version ?? 0) + 1,
        criterio_fecha: new Date().toISOString(),
        paso_alta: "cribando",
      }).eq("id", perfil.id);

      console.log(`Alta sin NIF: ${conEjemplos ? parecidos!.vecinos.length : 0} ejemplos, ` +
                  `${codigos.length || lista.length} códigos`);
      return responder({ ok: true, resumen: criterio.resumen });
    }

    // --- Contratos parecidos a su descripción, para enseñárselos ---
    //
    // En la pantalla de familias, bajo cada una. Solo para verlos: en la
    // simulación, pedirle que los revisara no mejoraba el filtro.
    if (accion === "ejemplos") {
      const lista = (prefijos ?? []).map((p: string) => String(p).replace(/\D/g, ""))
        .filter((p: string) => p.length >= 2 && p.length <= 6);
      if (!lista.length || !perfil.descripcion) return responder({ ok: true, ejemplos: {} });
      const parecidos = await parecidosDe(admin, perfil, lista);
      return responder({ ok: true, ejemplos: parecidos ? ejemplosPorFamilia(parecidos, lista) : {} });
    }

    // --- Regenerar el criterio con las correcciones ---
    //
    // No se regenera con cada corrección: con un solo ejemplo el modelo
    // no puede deducir nada, y llamar al modelo por cada clic sería caro
    // y lento. Con cinco juntas ya hay patrón.
    if (accion === "ajustar") {
      const { data: correcciones } = await comoUsuario.from("correcciones")
        .select("id, id_licitacion, titulo, organo, interesa, motivo")
        .eq("perfil_id", perfil.id).eq("aplicada", false);

      if (!correcciones?.length) {
        return responder({ ok: true, sin_cambios: true });
      }

      const { data: ganados } = await admin.rpc("ultimos_ganados",
        { cif_buscado: perfil.cif ?? "", tope: 25 });

      const nuevo = await regenerarCriterio(
        perfil.criterio ?? "",
        ((ganados ?? []) as Record<string, unknown>[])
          .map((g) => ({ titulo: String(g.titulo ?? "") })),
        correcciones.map((c) => ({
          titulo: String(c.titulo), organo: String(c.organo ?? ""),
          interesa: Boolean(c.interesa),
          motivo: c.motivo ? String(c.motivo) : null,
        })),
      );

      await comoUsuario.from("perfiles").update({
        criterio: String(nuevo.criterio ?? perfil.criterio),
        que_buscamos: Array.isArray(nuevo.que_buscamos)
          ? nuevo.que_buscamos.map((x: unknown) => String(x)).slice(0, 5)
          : perfil.que_buscamos,
        criterio_version: (perfil.criterio_version ?? 0) + 1,
        criterio_fecha: new Date().toISOString(),
      }).eq("id", perfil.id);

      await comoUsuario.from("correcciones")
        .update({ aplicada: true })
        .in("id", correcciones.map((c) => c.id));

      // Con huellas, el juez ve las correcciones directamente (las más
      // parecidas a cada contrato): se le pide rehacer su grupo entero.
      // Los veredictos no se borran: la lista sigue ahí mientras tanto.
      // Si no se puede pedir, se vuelve al criterio (ya regenerado arriba).
      const rehecho = perfil.sistema === "huellas" &&
        await pedirPuntuacion(perfil.id, true);
      if (rehecho) {
        await admin.from("perfiles").update({
          paso_alta: "cribando", puntuacion_pedida: new Date().toISOString(),
        }).eq("id", perfil.id);
      } else {
        // Se vuelve a clasificar todo lo suyo con el criterio nuevo: si no,
        // la corrección se quedaría en el contrato que la provocó en lugar
        // de propagarse.
        await admin.from("veredictos").delete().eq("perfil_id", perfil.id);
        await admin.from("perfiles").update({ paso_alta: "cribando", sistema: "criterio" })
          .eq("id", perfil.id);
      }

      console.log(`Criterio ajustado con ${correcciones.length} correcciones`);

      // Con huellas, lo que cambia es lo que el cliente ha dicho: el juez
      // aplica sus correcciones tal cual, no el criterio en prosa. Se le
      // cuenta eso, y no lo que el modelo haya reescrito en un texto que
      // este sistema no usa.
      const corto = (t: unknown) => {
        const x = String(t ?? "");
        return x.length > 70 ? x.slice(0, 67).trimEnd() + "..." : x;
      };
      const cambiosHuellas = rehecho ? correcciones.slice(0, 3).map((c: Record<string, unknown>) =>
        c.interesa
          ? `Te enseñaremos más contratos como «${corto(c.titulo)}»`
          : c.motivo
            ? `Tendremos en cuenta en toda tu lista que ${String(c.motivo).trim().replace(/[.\s]+$/, "")}`
            : `Hemos quitado «${corto(c.titulo)}» de tu lista`) : null;

      return responder({
        ok: true,
        cambios: cambiosHuellas ?? (Array.isArray(nuevo.cambios)
          ? nuevo.cambios.map((c: unknown) => String(c)).slice(0, 3)
          : (nuevo.cambios ? [String(nuevo.cambios)] : [])),
        que_buscamos: Array.isArray(nuevo.que_buscamos)
          ? nuevo.que_buscamos.map((c: unknown) => String(c)).slice(0, 5) : [],
        resumen: String(nuevo.resumen ?? ""),
        aplicadas: correcciones.length,
      });
    }

    // --- Cribar un lote de lo pendiente ---
    // ---------- Cribar lo ADJUDICADO ----------
    //
    // Responde a otra pregunta que el cribado normal: no «¿me presento
    // a esto?» sino «¿esta empresa es de mi mercado?».
    //
    // Hace falta porque el sector se define cruzando códigos CPV, y eso
    // trae competidores que no lo son: a un proveedor de equipamiento
    // médico le salían empresas de mantenimiento de escuelas infantiles
    // y de semáforos, porque comparten el código de «reparación y
    // mantenimiento».
    if (accion === "cribar_mercado") {
      if (!perfil.criterio) return responder({ error: "sin_criterio" }, 400);

      // Los parámetros se desestructuran arriba; no hay ningún objeto
      // `cuerpo`. Usarlo lanzaba un ReferenceError que la web veía solo
      // como un tiempo de espera agotado.
      const ventana = Number(dias ?? 30);
      const { data: cola } = await admin.rpc("mercado_sin_cribar_de",
        { perfil: perfil.id, dias: ventana });
      const pendientes = (cola ?? []) as Record<string, unknown>[];

      if (!pendientes.length) {
        return responder({ ok: true, terminado: true, quedan: 0 });
      }

      const tanda = pendientes.slice(0, LOTE);
      const veredictos: Record<string, unknown>[] = [];

      for (let i = 0; i < tanda.length; i += SIMULTANEAS) {
        const grupo = tanda.slice(i, i + SIMULTANEAS);
        const juicios = await Promise.all(grupo.map((l) =>
          clasificar(perfil.criterio, {
            titulo: String(l.titulo ?? ""),
            organo: String(l.organo ?? ""),
            presupuesto: null,
            cpvs: [],
          })
        ));
        grupo.forEach((l, j) => {
          // Un "quizás" cuenta como del sector: en el mercado interesa
          // no perder de vista a un competidor por un caso dudoso, que
          // es lo contrario de lo que conviene con los contratos
          // abiertos.
          const v = juicios[j]?.veredicto ?? "quizas";
          veredictos.push({
            id: String(l.id_licitacion),
            del_sector: v === "si" || v === "quizas",
          });
        });
      }

      // Con el perfil explícito: esta llamada va con la clave de
      // servicio y `auth.uid()` no resuelve a nadie desde aquí.
      const { data: metidas, error: fallo } = await admin.rpc(
        "guardar_criba_mercado", { datos: veredictos, perfil: perfil.id });

      if (fallo) {
        return responder({ error: "no_guardado", detalle: fallo.message }, 500);
      }

      return responder({
        ok: true,
        terminado: pendientes.length <= LOTE,
        quedan: Math.max(0, pendientes.length - tanda.length),
        cribados: veredictos.length,
        guardados: metidas ?? 0,
      });
    }

    if (accion === "cribar" && perfil.sistema === "huellas") {
      // Espera a que el puntuador termine la pasada pedida. Cada llamada
      // espera hasta ~20 s aquí dentro para que la web no martillee; la
      // web vuelve a llamar mientras reciba `esperando`.
      const hecha = (p: Record<string, unknown>) =>
        !!p.puntuado_en && (!p.puntuacion_pedida ||
          Date.parse(String(p.puntuado_en)) >= Date.parse(String(p.puntuacion_pedida)));
      let actual: Record<string, unknown> = perfil;
      for (let i = 0; i < 4 && !hecha(actual); i++) {
        if (i) await new Promise((r) => setTimeout(r, 5000));
        const { data } = await admin.from("perfiles")
          .select("sistema, puntuado_en, puntuacion_pedida").eq("id", perfil.id).single();
        actual = data ?? actual;
        if (actual.sistema !== "huellas") break;
      }
      if (actual.sistema === "huellas" && !hecha(actual)) {
        // Si la pasada pedida no ha llegado en 20 minutos (Actions caído o
        // la pasada ha fallado), no se vuelve a pedir: se pasa al criterio
        // de siempre para que el cliente tenga su lista ya. Pedirla otra vez
        // podía repetirse sin fin si la pasada fallaba siempre. La pasada
        // diaria lo devuelve a este sistema cuando funcione.
        const pedida = actual.puntuacion_pedida
          ? Date.parse(String(actual.puntuacion_pedida)) : 0;
        if (Date.now() - pedida > 20 * 60 * 1000) {
          console.error(`Perfil ${perfil.id}: la puntuación pedida no llegó; vuelve al criterio`);
          await admin.from("perfiles").update({ sistema: "criterio" }).eq("id", perfil.id);
        }
        return responder({ ok: true, terminado: false, hechas: 0, quedan: 0, esperando: true });
      }
      if (actual.sistema === "huellas") {
        if (perfil.paso_alta === "cribando") {
          await comoUsuario.from("perfiles").update({ paso_alta: "listo" }).eq("id", perfil.id);
        }
        return responder({ ok: true, terminado: true, quedan: 0 });
      }
      // Ha vuelto al criterio: sigue abajo, con el cribado de siempre.
    }

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

    // --- Empezar de cero ---
    //
    // Para un cambio de línea de negocio. Ampliar un criterio existente
    // funciona mal cuando el cambio es radical: se queda arrastrando lo
    // viejo. Rehacerlo cuesta un minuto y sale limpio.
    // --- Sectores del filtro de la lista ---
    //
    // La web los pide cuando abre la lista y no los encuentra (empresa
    // nueva, filtro rehecho, o empresas de antes de que existieran). Así
    // no hace falta un relleno aparte ni tocar cada camino del alta.
    if (accion === "sectores") {
      const base = String(perfil.cpv_prefijos ?? "");
      const suyos = base.split(",").map((x) => x.trim()).filter(Boolean);
      // Con un solo prefijo no hay nada que elegir.
      if (suyos.length < 2) return responder({ ok: true, sectores: [] });

      const { data: muestras, error: fallo } = await comoUsuario.rpc(
        "muestras_por_prefijo", { perfil: perfil.id });
      if (fallo) {
        console.error("Fallo al leer muestras:", fallo);
        return responder({ error: "error_interno" }, 500);
      }

      const lectura = await agruparSectores(
        String(perfil.empresa ?? perfil.descripcion ?? ""), muestras ?? []);

      // El modelo propone; aquí se garantiza lo que el filtro necesita:
      // prefijos reales, cada uno una vez, ninguno sin sector.
      const vistos = new Set<string>();
      const sectores = (Array.isArray(lectura.sectores) ? lectura.sectores : [])
        .map((x: Record<string, unknown>) => ({
          // La mayúscula inicial no se le deja al modelo: unas veces
          // Capitaliza Cada Palabra y otras lo escribe todo en minúscula.
          nombre: String(x.nombre ?? "").trim().slice(0, 60)
            .replace(/^./, (c) => c.toLocaleUpperCase("es")),
          prefijos: (Array.isArray(x.prefijos) ? x.prefijos : [])
            .map((p: unknown) => String(p).trim())
            .filter((p: string) => suyos.includes(p) && !vistos.has(p) && vistos.add(p)),
        }))
        .filter((x: { nombre: string; prefijos: string[] }) =>
          x.nombre.length >= 2 && x.prefijos.length)
        .slice(0, 6);
      const sueltos = suyos.filter((p) => !sectores.some(
        (x: { prefijos: string[] }) => x.prefijos.includes(p)));
      // Un solo "Otros", al final: los prefijos sueltos más cualquier
      // "Otros servicios" o "Varios" que el modelo escriba pese a las
      // instrucciones.
      const esOtros = (x: { nombre: string }) => /^(otros|varios)\b/i.test(x.nombre);
      const restos = [...sueltos, ...sectores.filter(esOtros)
        .flatMap((x: { prefijos: string[] }) => x.prefijos)];
      const conNombre = sectores.filter((x: { nombre: string }) => !esOtros(x));
      if (restos.length) conNombre.push({ nombre: "Otros", prefijos: restos });

      const { data: guardado } = await comoUsuario.rpc("guardar_sectores",
        { perfil: perfil.id, base, datos: conNombre });
      if (!guardado) console.log(`Sectores de ${perfil.id} no guardados: cambió el filtro`);

      return responder({ ok: true, sectores: conNombre });
    }

    if (accion === "reiniciar") {
      await admin.from("veredictos").delete().eq("perfil_id", perfil.id);
      await admin.from("correcciones").delete().eq("perfil_id", perfil.id);
      await comoUsuario.from("perfiles").update({
        criterio: null,
        que_buscamos: [],
        cpv_prefijos: null,
        descripcion: null,
        cif: null,
        empresa: null,
        paso_alta: "describiendo",
      }).eq("id", perfil.id);
      await admin.from("perfiles").update({
        sistema: "criterio", puntuado_en: null, puntuacion_pedida: null,
      }).eq("id", perfil.id);

      console.log(`Perfil ${perfil.id} reiniciado`);
      return responder({ ok: true });
    }

    return responder({ error: "accion_desconocida" }, 400);

  } catch (error) {
    // El detalle va al registro de la función, no al cliente: un mensaje
    // de error puede revelar cómo está montado el sistema.
    console.error("Error en la función de alta:", error);
    return responder({ error: "error_interno" }, 500);
  }
});
