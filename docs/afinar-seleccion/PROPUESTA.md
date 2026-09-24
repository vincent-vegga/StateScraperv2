# Propuesta de cambio en producción — PENDIENTE DE APROBACIÓN

Estado al 24/09/2026. **No se ha tocado producción.** Nada de lo de abajo se
aplica sin el «sí» del dueño. Los números salen de `RESULTADOS.md` (banco de
pruebas de 40 empresas, corte T = 2026-01-01, perfil con lo ganado antes de T,
recall medido sobre lo que ganaron después).

## Los números

| | Volumen/1.000 | Recall medio | Recall p10 |
|---|---|---|---|
| **Hoy**: puerta CPV + juez con criterio (sí+quizás) | 28,2 | 75,6 % | 47,5 % |
| Hoy, solo «sí» | 21,4 | 66,5 % | 24,5 % |
| Arreglo mínimo: puerta CPV jerárquica, sin juez | 49,6 | 83,3 % | 59,8 % |
| **Puntuación** sola, corte a 30/1.000 | 30,0 | 90,1 % | 72,2 % |
| Puntuación (mejores 100/1.000) + juez con ejemplos, solo «sí» | 28,8 | 89,4 % | 71,1 % |
| Puntuación (mejores 100/1.000) + juez con ejemplos, sí+quizás | 54,8 | 94,9 % | 83,0 % |

Enseñando lo mismo que hoy, la puntuación recupera **+14,5 puntos** de lo que
la empresa acaba ganando, y la empresa peor servida de cada diez pasa del
47 % al 72 %. La mejora se mantiene en los cuatro tamaños de historial y no
viene de contratos repetidos (comprobado quitándolos).

## Por qué falla el sistema actual

De 935 contratos futuros, el sistema actual pierde 173 **en la puerta CPV**
y solo 21 en el juez. Dos causas:

1. **La validación de prefijos de gpt-4o descarta prefijos buenos.** Con
   todos los prefijos del historial, la puerta recupera el 91 % (volumen
   93/1.000); con los que valida el modelo, el 77 % (39/1.000).
2. **La puerta no entiende la jerarquía CPV.** Una licitación con el código
   genérico `03000000` no pasa para una empresa con `0331`, porque se
   comparan prefijos de 4 cifras exactos (`0300` ≠ `0331`). Igual con
   `48000000` frente a `4821`.

El juez con criterio en prosa pierde poco (21 «no»), pero manda 83 más a
«quizás» y marca «sí» al 58 % de lo que pasa la puerta: no ordena.

## Qué aporta cada pieza nueva

- La **similitud con lo ganado** (embeddings de títulos) es la señal más
  fuerte: por sí sola, 84 % a 30/1.000.
- **Pares** (quién gana lo parecido a lo suyo) y **CPV como peso** (no como
  puerta) suman hasta el 90 %.
- El **juez con ejemplos** apenas mejora el recall a igual volumen: la
  puntuación ya ordena bien. Su valor es de producto: da un motivo legible y
  separa «Para mí» (sí) de «Puede ser» (quizás) con criterio, y a volúmenes
  mayores mejora la cola (p10 83 % frente a 77 % sin juez a ~50/1.000).
- Con 256 dimensiones en lugar de 512 se pierde casi nada (89,8 % frente a
  90,1 % a 30/1.000): basta la mitad de espacio.

## El cambio propuesto

Todo en una migración reversible, más cambios en el alta y el cribador.

1. **pgvector** (disponible en el proyecto, no instalado) y una tabla
   `titulos_emb (id_licitacion text primary key, emb halfvec(256))`.
   - Qué se guarda: licitaciones adjudicadas desde 2022 + las vivas:
     1.136.027 vectores (casi todo el histórico cargado es de 2022 en
     adelante). Estimación: ~0,7 GB de tabla y ~0,8-1 GB de índice HNSW;
     la base ocupa hoy 5,4 GB. Hay que confirmar que cabe en el plan de
     Supabase. Si no, se puede guardar solo lo adjudicado en los últimos
     dos años (se pierde algo de «pares» y «propio», sin medir).
   - Coste: la carga inicial ya está calculada en el banco (se sube desde el
     contenedor, sin volver a pagar); las nuevas, 150-700 al día ≈ céntimos
     al mes.
2. **Embeddings de las nuevas**: el scraper (o un disparador que encole)
   pide el embedding de cada licitación nueva al insertarla.
3. **Perfil** (alta y regeneración): además de lo actual, guardar por
   perfil los vectores de sus contratos ganados y los pesos de sus pares
   (top 200, calculados una vez en el alta). Deja de hacer falta que el
   modelo valide prefijos.
4. **`pendientes_de_perfil` → `puntuar_perfil`**: sobre las vivas, calcula
   knn1/knn5, CPV ponderado, propio y pares, y los combina con los pesos
   del banco (fijos, en una tabla de configuración). Devuelve las mejores
   por encima del corte, en orden. Sin puerta CPV.
5. **Cribador**: el juez deja de leer el criterio en prosa y ve los 8
   contratos ganados más parecidos (y, cuando las haya, las correcciones
   del cliente más parecidas). Solo juzga lo que la puntuación deja pasar
   (mejores ~100/1.000 del día).
6. **Correcciones**: en lugar de reescribir el criterio (`regenerarCriterio`,
   que lo degrada, como con el perfil `0b2d8e56`), cada corrección se guarda
   como ejemplo: un «no me interesa» baja la puntuación de lo parecido y se
   enseña al juez como contraejemplo. Esto no se ha medido en el banco
   (no hay correcciones históricas con fecha) y habría que vigilarlo.

Coste de OpenAI por perfil: parecido al actual (juzga ~100/1.000 de las
vivas, más o menos lo que hoy pasa la puerta), sin la lectura con gpt-4o.

## Riesgos y lo que el banco NO mide

- El recall mide «lo que acabó ganando», no «lo que le habría interesado».
  El volumen de más no es necesariamente ruido: puede ser lo que no ganó.
- Los pesos se aprendieron con 40 empresas de ≥15 contratos. Para
  empresas con poco historial o que describen su negocio a mano (sin NIF),
  la puntuación no tiene con qué trabajar: ahí hay que conservar el camino
  actual (criterio en prosa + puerta, ya con jerarquía CPV).
- Contratos menores sin CPV: la puntuación no depende del CPV, así que
  mejora, pero no se ha medido aparte.

## Arreglo mínimo, por si no se aprueba lo grande

Sin embeddings ni tablas nuevas: puerta con jerarquía CPV y todos los
prefijos del historial con ≥2 contratos (sin la validación del modelo). Sube
el recall a ~83 % a costa de más volumen para el juez.

## Decisiones de producto pendientes (preguntar, no suponer)

- ¿Lista ordenada por encaje, o se mantienen «Para mí» / «Puede ser para mí»?
  La puntuación permite las dos: orden continuo, o «sí» del juez = «Para
  mí» y «quizás» = «Puede ser».
- ¿Qué corte? 30/1.000 (≈ lo de hoy) o más generoso (50-100/1.000 con el
  juez separando las dos listas).
- ¿Filtro visible de «organismos con los que no trabajo»?
- ¿Organismos con los que ha trabajado como señal de orden (no de criterio)?
