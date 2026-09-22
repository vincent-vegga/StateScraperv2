// ============================================================
// STATE SCRAPER · Lo que habla con el modelo (compartido)
// ============================================================
//
// Lo usan la función de alta (index.ts) y el script de regeneración de
// perfiles (regenerar.ts), que corre en GitHub Actions con la clave de
// servicio. Una sola copia de las instrucciones: si cada uno tuviera la
// suya, acabarían diciendo cosas distintas y la misma empresa saldría
// distinta según por dónde entrara.
// ============================================================

export const MODELO = Deno.env.get("MODELO_ALTA") ?? "gpt-4o-mini";
// La lectura del historial define el producto de cada cliente y ocurre
// una sola vez en su vida. Compensa un modelo mejor que el del cribado
// diario: unos céntimos por cliente frente a un criterio mediocre para
// siempre.
export const MODELO_HISTORIAL = Deno.env.get("MODELO_HISTORIAL") ?? "gpt-4o";
export const OPENAI = "https://api.openai.com/v1/chat/completions";

export async function llamarModelo(mensajes: unknown[], maxTokens = 900,
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

export async function leerHistorial(
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

export async function regenerarCriterio(
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
// De la lectura a los prefijos del perfil
// ------------------------------------------------------------
//
// Los que el modelo da por buenos; si no devuelve ninguno, los que
// aparecen en al menos dos de sus contratos. Vacío = no hay con qué
// cribar, y el alta manda a describir el negocio.
export function prefijosDeLectura(
  lectura: Record<string, unknown>,
  prefijos: { prefijo: string; contratos: number }[],
): string[] {
  const validos = (Array.isArray(lectura.prefijos_validos)
    ? lectura.prefijos_validos : [])
    .map((p: unknown) => String(p).replace(/\D/g, ""))
    .filter((p: string) => p.length >= 2 && p.length <= 6);
  return validos.length
    ? validos
    : prefijos.filter((p) => p.contratos >= 2).map((p) => p.prefijo);
}
