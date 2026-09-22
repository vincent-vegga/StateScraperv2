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

async function llamarModelo(mensajes: unknown[], maxTokens = 900,
                            modelo = MODELO) {
  const clave = Deno.env.get("OPENAI_API_KEY");
  if (!clave) throw new Error("Falta OPENAI_API_KEY en la función.");

  const cuerpo = JSON.stringify({
    model: modelo,
    messages: mensajes,
    response_format: { type: "json_object" },
    temperature: 0,
    // Con temperatura 0 el modelo no es determinista: dos altas de la
    // misma empresa dieron criterios distintos (38 y 17 contratos en la
    // lista). La semilla fija hace las respuestas mucho más repetibles.
    seed: 20260922,
    max_tokens: maxTokens,
  });

  // Seguro contra el límite de uso de OpenAI (429) y sus caídas (5xx).
  //
  // El 21/09/2026 dos altas simultáneas chocaron con el límite: 1.178
  // clasificaciones rechazadas en una hora, el cribado dio dos vueltas sin
  // avanzar y la web se rindió dejando el alta en "cribando". Esos
  // rechazos suelen pedir esperar menos de un segundo: se espera lo que
  // diga OpenAI (o 1 s, 2 s, 4 s) y se reintenta. Si pide más de 8 s, no
  // se espera: la petición de la web no puede quedarse colgada, y lo que
  // no se clasifique ahora lo recoge la vuelta siguiente o el cribador.
  let respuesta: Response | null = null;
  for (let intento = 0; intento <= 3; intento++) {
    respuesta = await fetch(OPENAI, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${clave}`,
        "Content-Type": "application/json",
        "User-Agent": "StateScraper/1.0",
      },
      body: cuerpo,
    });
    const reintentable = respuesta.status === 429 || respuesta.status >= 500;
    if (respuesta.ok || !reintentable || intento === 3) break;

    const pedidoMs = Number(respuesta.headers.get("retry-after-ms"))
      || Number(respuesta.headers.get("retry-after")) * 1000 || 0;
    const esperaMs = pedidoMs || 1000 * 2 ** intento;
    if (esperaMs > 8000) break;
    await respuesta.body?.cancel();
    // Con algo de azar: veinte clasificaciones rechazadas a la vez no
    // deben volver a llamar todas en el mismo milisegundo.
    await new Promise((r) => setTimeout(r, esperaMs + Math.random() * 500));
  }

  if (!respuesta!.ok) {
    throw new Error(`El modelo respondió ${respuesta!.status}: ${(await respuesta!.text()).slice(0, 300)}`);
  }
  const respuestaOk = respuesta!;
  const datos = await respuestaOk.json();
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
ganado comedores de colegios, el principio es la restauración colectiva \
para centros educativos, no "el comedor del CEIP de Valdemorillo".
   · Identifica primero QUÉ EJES distinguen sus contratos de los demás. \
Según el negocio pueden ser el producto, el destinatario o el tamaño del \
contrato. En comedores escolares el eje es el destinatario; en material \
de oficina, donde el destinatario da igual, serán otros. Escribe el \
criterio en función de los ejes que de verdad separan, no de los que \
suenan bien.
   · NUNCA uses el territorio como criterio. Ni provincia, ni comunidad, \
ni ciudad, ni "especialmente en X". Que sus contratos anteriores sean de \
una zona solo dice dónde ha trabajado hasta ahora, no dónde puede \
trabajar: una productora de Las Palmas puede presentarse a una cabalgata \
en Barcelona. El cliente filtra por territorio cuando quiere, con un \
selector propio; el criterio es SOLO sobre qué hace la empresa.
   · Tampoco uses el tamaño del organismo ni su nombre concreto. \
"Ayuntamientos grandes" o "el Ayuntamiento de X" son la misma trampa: \
describen su pasado, no su capacidad.
   · DEFINE EL "NO" CON EL VECINO MÁS PARECIDO, no con lo lejano. Decir \
"no cuando sea software o maquinaria" no sirve de nada: nadie confunde eso. \
Lo que hay que nombrar es el caso que SÍ se parece y aun así no encaja \
—"catering para un acto puntual, que es comida pero no un comedor \
diario"—, porque es el único que un clasificador puede equivocar.
   · Pero el "no" solo puede nombrar lo que CONTRADIGA sus contratos \
ganados. Un colectivo o un producto vecino del que no hay contratos ni a \
favor ni en contra —otro tipo de centro, otro cuerpo, otro servicio \
parecido— va a "quizás", NUNCA a "no": que no lo haya ganado todavía no \
dice que no pueda hacerlo. No inventes exclusiones que no salgan de los \
títulos que has leído.
   · Incluye la prueba decisiva: ¿podría esta empresa ser el proveedor \
principal de este contrato?
   · Ante duda razonable entre "quizás" y "no", elige "quizás". Perder una \
oportunidad es mucho más grave que mostrar una de más.
   · Máximo 350 palabras.

2. VALIDAR SUS CÓDIGOS CPV. Se te dan los prefijos que aparecen en sus \
contratos, con su frecuencia. Algunos están MAL PUESTOS por el organismo \
que publicó el anuncio: es habitual. Un contrato titulado "Servicio de \
comedor escolar" con el código de software lleva un error evidente.

   Devuelve solo los prefijos que encajan de verdad con lo que hace la \
empresa, según los títulos que has leído. Descarta los que solo pueden \
explicarse como un error de etiquetado.

   Si NO se te da ningún prefijo (hay organismos que publican sus \
contratos menores sin CPV), dedúcelos tú de los títulos: devuelve en \
"prefijos_validos" los prefijos de 4 cifras del vocabulario CPV que \
corresponden a lo que hace la empresa, del más al menos frecuente. Solo \
los que estés seguro de que existen.

3. RESUMIR EL FILTRO PARA EL CLIENTE. Dos o tres frases cortas, en \
lenguaje corriente, que expliquen QUÉ se busca y qué se descarta. No es el \
criterio: es lo que se le enseña a él para que entienda con qué se le \
filtra y pueda corregirlo si no encaja.

   Ejemplo: ["Buscamos servicios de comedor y cocina para colegios y \
escuelas infantiles", "También te enseñamos residencias y otros centros \
con comedor diario, por si te encajan", "Descartamos catering para actos \
puntuales y máquinas expendedoras"].

   Es un EJEMPLO DE FORMA, de otro sector: no copies nada de su contenido.

   Que sea concreto y en primera persona del plural. Nada de tecnicismos, \
códigos CPV ni referencias a cómo funciona el sistema.

Devuelve EXCLUSIVAMENTE JSON:
{"criterio":"...","prefijos_validos":["3581","1810"],\
"descartados":[{"prefijo":"4800","motivo":"..."}],\
"actividad":"una frase sobre a qué se dedica",\
"que_buscamos":["frase 1","frase 2"],\
"resumen":"una frase para el cliente"}`;

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
               (codigos
                 ? `PREFIJOS CPV QUE APARECEN:\n${codigos}`
                 : `PREFIJOS CPV QUE APARECEN: ninguno, los organismos no ` +
                   `los publicaron. Dedúcelos de los títulos.`),
    },
  ], 1600, MODELO_HISTORIAL);
}

// ------------------------------------------------------------
// Sectores: sus CPV agrupados con nombre de persona
// ------------------------------------------------------------
//
// El filtro por sector de la lista, y más adelante los avisos por sector.
// El cliente no ve códigos: ve 2-6 sectores con el nombre que usaría él.
// Se escriben agrupando SUS prefijos a partir de SUS contratos, porque el
// mismo código significa cosas distintas según la empresa: el 3499 de
// Alumbrados Viarios son iluminaciones navideñas, no "vehículos".

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
// Regeneración con las correcciones del cliente
// ------------------------------------------------------------

const INSTRUCCIONES_AJUSTE = `\
Eres un analista de contratación pública. Una empresa tiene un criterio \
automático que decide qué contratos públicos le interesan, y ha corregido \
algunos resultados. Tu tarea es reescribir su criterio incorporando esas \
correcciones.

REGLAS, POR ORDEN DE IMPORTANCIA:

1. CONSERVA LO QUE FUNCIONA. Las correcciones son ajustes, no un criterio \
nuevo. Los contratos que la empresa ha GANADO siguen siendo la base y \
deben seguir encajando en el "sí".

2. NO CIERRES DE MÁS. Perder una oportunidad cuesta un cliente; mostrar \
una de más cuesta un vistazo. Una corrección puede mover un caso de "sí" a \
"quizás" con facilidad; para moverlo a "no" hace falta que el motivo lo \
justifique explícitamente o que el patrón se repita en varias \
correcciones. Un rechazo suelto no cierra una categoría entera.

3. LOS MOTIVOS ESCRITOS MANDAN sobre los rechazos sin explicar. Si dice \
"no hacemos comedores de más de 500 menús", eso es una regla; diez \
rechazos sin motivo son solo una pista de que algo falla.

4. BUSCA EL PATRÓN, no los casos. Si ha rechazado tres comedores de \
residencias de mayores, el criterio debe decir que los comedores fuera de \
centros educativos no encajan, no enumerar esas tres residencias.

5. Mantén la estructura: qué es "sí", qué es "quizás", qué es "no". Define \
el "no" con el caso MÁS PARECIDO que aun así no encaja, no con lo lejano.

6. Máximo 350 palabras.

7. Devuelve además "que_buscamos": dos o tres frases cortas, en lenguaje \
corriente y en primera persona del plural, que expliquen al cliente qué se \
busca y qué se descarta. Es lo que él verá; el criterio no se le enseña.

8. Y "cambios": una LISTA de frases con lo que ha cambiado respecto al \
criterio anterior, escritas para que el cliente vea el efecto, no el \
mecanismo. En segunda persona y concretas:

   BIEN: "Ya no te mostraremos comedores de residencias de mayores"
   MAL: "Se ha restringido la cláusula de inclusión del criterio"

   Una o dos frases. Si no ha cambiado nada, lista vacía.

Devuelve EXCLUSIVAMENTE JSON:
{"criterio":"...","que_buscamos":["frase 1","frase 2"],\
"cambios":["frase sobre qué cambia para él"],\
"resumen":"una frase para el cliente"}`;

async function regenerarCriterio(
  criterio: string,
  ganados: { titulo: string }[],
  correcciones: { titulo: string; organo: string; interesa: boolean; motivo: string | null }[],
) {
  const lista = (xs: typeof correcciones) =>
    xs.map((c) => `- ${c.titulo}${c.organo ? ` (${c.organo})` : ""}` +
                  (c.motivo ? `\n  MOTIVO: ${c.motivo}` : "")).join("\n");
  const si = correcciones.filter((c) => c.interesa);
  const no = correcciones.filter((c) => !c.interesa);

  return await llamarModelo([
    { role: "system", content: INSTRUCCIONES_AJUSTE },
    {
      role: "user",
      content: `CRITERIO ACTUAL:\n${criterio}\n\n` +
        `CONTRATOS QUE HA GANADO (la base, no tocar):\n` +
        ganados.slice(0, 25).map((g) => `- ${g.titulo}`).join("\n") + "\n\n" +
        (si.length ? `HA MARCADO COMO "SÍ ME INTERESA" (${si.length}):\n${lista(si)}\n\n` : "") +
        (no.length ? `HA MARCADO COMO "NO ME INTERESA" (${no.length}):\n${lista(no)}` : ""),
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

Deno.serve(async (peticion) => {
  const origen = peticion.headers.get("origin");
  if (peticion.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origen) });

  try {
    const autorizacion = peticion.headers.get("Authorization");
    if (!autorizacion) return responder({ error: "sin_sesion" }, 401);

    const { accion, descripcion, prefijos, respuestas, cif, empresa, dias,
            perfil_id } = await peticion.json();

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
      if (!lectura) lectura = await leerHistorial(contratos, prefijos);

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
      // Sin códigos no hay nada que cribar: mejor que describa su negocio.
      if (!finales.length) return responder({ error: "sin_historial" }, 404);

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
        // Lo que se le enseña a él. El criterio completo no: es la
        // receta del filtro y además está escrito para un clasificador,
        // no para leerse.
        que_buscamos: Array.isArray(lectura.que_buscamos)
          ? lectura.que_buscamos.map((x: unknown) => String(x)).slice(0, 5) : [],
        criterio_version: (perfil.criterio_version ?? 0) + 1,
        criterio_fecha: new Date().toISOString(),
        // Directo a cribar: no hay tarjetas que deslizar.
        paso_alta: "cribando",
      }).eq("id", perfil.id);

      if (!reutilizada) {
        await admin.from("lecturas_empresa").upsert({
          cif: String(suya.cif), datos: lectura, creado: new Date().toISOString(),
        });
      }

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
      // El parámetro se llama `prefijos_buscados` en la base, no
      // `prefijos`. Enviarlo mal hacía que PostgREST no encontrara la
      // función y el alta sin historial fallara con «algo ha fallado».
      const argumentos = {
        prefijos_buscados: lista, producto, destinatario,
        solo_vivas: false, tope: 60,
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

      // Se vuelve a clasificar todo lo suyo con el criterio nuevo: si no,
      // la corrección se quedaría en el contrato que la provocó en lugar
      // de propagarse.
      await admin.from("veredictos").delete().eq("perfil_id", perfil.id);
      await comoUsuario.from("perfiles").update({ paso_alta: "cribando" })
        .eq("id", perfil.id);

      console.log(`Criterio ajustado con ${correcciones.length} correcciones`);

      return responder({
        ok: true,
        cambios: Array.isArray(nuevo.cambios)
          ? nuevo.cambios.map((c: unknown) => String(c)).slice(0, 3)
          : (nuevo.cambios ? [String(nuevo.cambios)] : []),
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
