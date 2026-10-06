# Alta sin NIF: todo lo que hay que saber

Estado al 06/10/2026. Si vas a trabajar en el alta sin NIF, lee este
fichero entero antes de hacer nada, y después [TRASPASO.md](TRASPASO.md),
con la sesión del 04/10 (la web y las correcciones) y lo que quedó a
medias. Recoge lo que está repartido por el
repositorio (con enlaces) y lo que no estaba escrito en ninguna parte:
feedback de betatesters, ideas descartadas y por qué, la última medición
y los límites de cómo medimos.

## Índice

1. [El problema](#1-el-problema)
2. [Cómo funciona hoy](#2-cómo-funciona-hoy)
3. [Historia: qué se ha probado y con qué resultado](#3-historia-qué-se-ha-probado-y-con-qué-resultado)
4. [Líneas y referentes: la medición del 01/10/2026](#4-líneas-y-referentes-la-medición-del-01102026)
5. [Ideas descartadas y por qué](#5-ideas-descartadas-y-por-qué)
6. [Cómo se mide, y por qué no hay que fiarse del todo](#6-cómo-se-mide-y-por-qué-no-hay-que-fiarse-del-todo)
7. [Diagnóstico](#7-diagnóstico)
8. [Vías abiertas](#8-vías-abiertas)
9. [Cómo lanzar una medición](#9-cómo-lanzar-una-medición)
10. [Reglas de trabajo](#10-reglas-de-trabajo)
11. [Glosario](#11-glosario)
12. [Dónde está cada cosa](#12-dónde-está-cada-cosa)

---

## 1. El problema

StateScraper avisa a empresas de licitaciones públicas que les encajan
([README-producto.md](../../README-producto.md)). Hay dos formas de darse
de alta:

- **Con NIF.** El sistema lee lo que la empresa ha ganado en contratación
  pública y construye su filtro a partir de esos contratos. Las que tienen
  5 o más contratos van por el **motor de huellas**, que funciona bien
  ([docs/afinar-seleccion/](../afinar-seleccion/TRASPASO.md)).
- **Sin NIF.** Es para quien no ha ganado contratos públicos, o casi
  ninguno: empresas que empiezan con la administración. El filtro se
  construye con lo que el cliente cuenta de sí mismo.

**Feedback de las dos primeras tandas de betatesters:** el alta sin NIF
es «aún muy imprecisa». En el banco de pruebas lo es: recupera alrededor
del 55–58 % de lo que vería con NIF, y de lo que enseña acierta alrededor
del 60 % (ver la sección 6 sobre qué significan esas cifras).

## 2. Cómo funciona hoy

El flujo en producción (decisiones 38, 40 y 41), con sus acciones en
[`supabase/functions/alta/index.ts`](../../supabase/functions/alta/index.ts):

1. **Describe su negocio** en texto libre (mínimo 15 caracteres) y, si
   quiere, marca los **tamaños de contrato** que le interesan
   (`perfiles.franjas`: <15k, 15–100k, 100k–1M, >1M).
2. **`proponer`.** El modelo propone familias CPV (divisiones de 2
   cifras) a partir de la descripción, con un catálogo que lleva el
   nombre de cada división (`DIVISIONES`, en `vecinos.ts`). Bajo cada
   familia se enseñan dos o tres contratos adjudicados parecidos a lo
   suyo, con quién los ganó. Solo para verlos.
3. **`confirmar_familias`.** Con las familias confirmadas:
   - lee lo adjudicado en esas familias (tabla `muestra_adjudicada`, que
     pg_cron rehace cada noche) y ordena por parecido a la descripción
     con embeddings (`buscarParecidos`, en
     [`vecinos.ts`](../../supabase/functions/alta/vecinos.ts));
   - **historial sintético** (`historialSintetico`): de los más
     parecidos, sin diversidad, el modelo descarta los que no encajan con
     lo que dice que hace (unas 80 llamadas), y se queda con los 40
     primeros. Si pasan menos de 10, se usan los 40 más parecidos sin
     filtrar. Se guardan en `perfiles.ganados_sinteticos`;
   - también se escribe un criterio en prosa y los códigos del
     vecindario, que quedan de reserva si el motor no llega.
4. **Motor de huellas** ([`puntuador.py`](../../puntuador.py)), igual que
   con NIF, con tres diferencias para el perfil sin NIF:
   - los contratos sintéticos hacen de «ganados»;
   - el rasgo `propio` (cuánto de lo parecido ganó ella) vale cero;
   - el juez recibe `AVISO_SIN_NIF` (sabe que esos contratos son de otras
     empresas) y ve la descripción («si un ejemplo y la descripción no
     casan, manda la descripción»).
5. **Después del alta**, el cliente puede marcar «no me interesa» (tabla
   `correcciones`, acción `ajustar`). Se pide al motor que rehaga su
   grupo. Al descartar, se le dice por qué salió: «se parece a «…», un
   contrato de otra empresa parecido a lo que nos contaste de la tuya»
   (`veredictos.parecido`, decisión 46). Encima de la lista, un aviso le
   dice que lo que más la afina son sus primeras correcciones, y cuántas
   lleva (decisión 47).

### Un límite estructural que no estaba escrito

Las correcciones **solo llegan al juez**. En `procesar_perfil`
(`puntuador.py`):

- el **grupo** (los 100 de cada 1.000 contratos vivos mejor puntuados,
  `grupo_por_mil` en `puntuacion_pesos.json`) sale **solo** de
  `rasgos_perfil` con los ganados, en este caso los sintéticos;
- las correcciones entran después, en el mensaje del juez: las 5 más
  parecidas a cada contrato y todas las que tienen motivo, como reglas.

Consecuencias:

- Un «no me interesa» puede **quitar** ruido de lo que ya está en el
  grupo.
- **Nada de lo que corrija puede traer un contrato que el historial
  sintético dejó fuera del grupo.** La recuperación queda fijada en el
  alta.
- Un contrato que le interesa no se añade a su historial: el historial
  sintético no cambia nunca después del alta.

Cualquier idea de «aprender después del alta» tiene que tocar esto.

## 3. Historia: qué se ha probado y con qué resultado

Detalle completo en [DECISIONES.md](../../DECISIONES.md), decisiones 37 a
41. En resumen:

| Fecha | Qué | Resultado | Decisión |
|---|---|---|---|
| 23/09 | Tarjetas: describir, confirmar familias y deslizar 30 tarjetas | F1 mediana 0,36, frente a 0,43 con la descripción sola. Cinco minutos de esfuerzo del cliente | 37: fuera las tarjetas |
| 23/09 | Catálogo de familias con nombre (antes solo número y volumen) | Con número, el modelo elegía las divisiones más grandes (obras para una empresa de uniformes). Con nombre, acertaba la familia en todos los perfiles | 38: catálogo con nombres |
| 23–24/09 | Referentes con el sistema antiguo: el cliente elige empresas que compiten con él | F1 0,52. Empata con la descripción sola en precisión | Quedó pendiente |
| 24/09 | 40 contratos parecidos a la descripción como ejemplos, y captura de los códigos donde caen muchos de los 200 más parecidos | F1 0,52. Mejor que la descripción sola en 13 de 16 | 38: en producción |
| 24/09 | Que el cliente revise los ejemplos | No mejora | Descartado |
| 24/09 | Esconder lo que pasa de su tamaño | Empeora siempre (−0,03 a −0,05 de F1) | Descartado |
| 24–25/09 | Usar el tamaño para ordenar la lista y marcar «por encima de tu tamaño» | Probado en producción y retirado | 39 |
| 25/09 | Buscar los ejemplos con títulos típicos que escribe el modelo | F1 0,50 frente a 0,54. Pierde en 10 de 16 | Descartado (39) |
| 25/09 | Historial sintético en el motor de huellas, frente al criterio en prosa | Recupera el 62 % frente al 32 %, pero enseña 256 contratos y solo el 44 % es bueno | 40: en producción |
| 25/09 | Historial sin diversidad, filtrado contra la descripción, y juez que ve la descripción | Enseña 176, recupera el 55 % y el 57 % es bueno. Algunas empresas pierden cobertura (una baja del 46 % al 19 %) | 41: en producción |
| 01/10 | Líneas de producto y referentes de su tamaño, con el motor de huellas | Ninguna mejora en media (sección 4) | Sin decisión. Ver sección 8 |
| 04/10 | La web de la empresa como entrada, junto a la descripción | F1 0,52 → 0,60 en las 8 con web legible: mejor en 4, peor en 2. Sola, peor (0,48) | Sí a pedirla. Falta diseñarla ([TRASPASO.md](TRASPASO.md), sección 5) |
| 04/10 | El cliente marca 10 o 20 contratos; motor de hoy y motor que corrige el historial | Mejor en 5 de 11, peor en 1–2. Con 20, el nuevo recupera lo que el alta dejó fuera | Tanda 2 en curso: falta el motor de hoy con 20 |
| 04/10 | Decir por qué salió cada contrato | Sin medición: es un hecho, no cuesta | 46: en producción |
| 06/10 | Avisar de que la lista aprende con las primeras correcciones | Sin medición | 47: en producción |

Relacionado, aunque no es del alta: **la decisión 43** (03/10, pestaña
Empresas) midió cómo encontrar «la competencia de tu tamaño». Filtrar por
**tamaño de contrato** (lo que son las franjas) **no separa a los
grandes**: también ganan muchos contratos pequeños, y en 6 de 7 perfiles
pequeños las tres primeras quedaron igual o peor. Lo que sí funciona es
un tope por **lo que la empresa gana al año en contratos públicos**
(`empresas_por_cif.anual`). Esto importa para la sección 4: los
referentes «de su tamaño» se eligieron por franjas.

## 4. Líneas y referentes: la medición del 01/10/2026

La medición del 04/10 (la web y las correcciones) está en la
[sección 3 de TRASPASO.md](TRASPASO.md#3-la-medición-del-0410-tanda-1).

Rama `simulacion-lineas-producto`, ejecución 36893150878 de GitHub
Actions. 15 empresas que van por huellas. 6,22 $ en total.

**Variantes** (todas con el motor de huellas):

- **`limpio_desc`.** Lo que hay en producción (decisión 41).
- **`lineas`.** Además de la descripción, «¿qué productos o servicios
  vendéis o hacéis más a menudo?», con 3 a 6 respuestas cortas. Una
  búsqueda de parecidos **por línea**, en vez de un único vector (que
  queda a medio camino entre las líneas y no se parece a ninguna). Los
  resultados se reparten por turnos entre las líneas, hasta 80. Las
  familias se proponen con la descripción y las líneas, y el filtro y el
  juez ven las líneas.
- **`referentes`.** Se enseñan hasta 8 empresas que ganan al menos 2 de
  los 200 contratos más parecidos a la descripción, con la mitad o más de
  esos contratos en sus franjas. El cliente marca las que hacen lo mismo
  que él (como mucho 3). De sus contratos solo se toma el «qué» (título y
  CPV), ordenados por parecido a la descripción e intercalados con los
  parecidos de producción.
- **`ambas`.** Líneas y referentes.

**Resultado:**

| Variante | Enseña (media) | Recupera | De lo que enseña, bueno | Mejor / peor que producción |
|---|---|---|---|---|
| `limpio_desc` | 173 | 0,58 | 0,61 | — |
| `lineas` | 169 | 0,58 | 0,63 | 4 / 4 |
| `referentes` | 167 | 0,56 | 0,62 | 2 / 5 |
| `ambas` | 161 | 0,57 | 0,63 | 5 / 4 |

«Mejor» quiere decir que recupera más (más de 0,02) sin acertar menos en
lo que enseña, o al revés. Las diferencias de menos de 0,02 cuentan como
empate.

**Por empresa** (recupera / de lo que enseña, bueno; «reales» es el
tamaño de su lista con NIF):

| Perfil | Reales | `limpio_desc` | `lineas` | `referentes` | `ambas` |
|---|---|---|---|---|---|
| P01 | 199 | 0,25 / 0,94 | 0,23 / 0,92 | 0,26 / 0,93 | 0,22 / 0,96 |
| P02 | 91 | 0,65 / 0,73 | 0,47 / 0,81 | 0,54 / 0,78 | 0,45 / 0,82 |
| P03 | 464 | 0,78 / 0,83 | 0,76 / 0,83 | 0,75 / 0,82 | 0,77 / 0,85 |
| P04 | 185 | 0,24 / 0,41 | 0,28 / 0,49 | 0,19 / 0,38 | 0,25 / 0,43 |
| P05 | 470 | 0,74 / 0,82 | 0,76 / 0,82 | 0,75 / 0,83 | 0,73 / 0,85 |
| P06 | 187 | 0,47 / 0,81 | 0,39 / 0,89 | 0,53 / 0,81 | 0,56 / 0,82 |
| P07 | 215 | 0,40 / 0,82 | 0,73 / 0,71 | 0,40 / 0,78 | 0,71 / 0,77 |
| P08 | 17 | 0,94 / 0,23 | 0,94 / 0,20 | 0,88 / 0,25 | 0,94 / 0,24 |
| P09 | 74 | 0,62 / 0,31 | 0,61 / 0,30 | 0,62 / 0,30 | 0,57 / 0,30 |
| P10 | 284 | 0,41 / 0,82 | 0,35 / 0,81 | 0,39 / 0,85 | 0,30 / 0,83 |
| P11 | 318 | 0,51 / 0,65 | 0,44 / 0,67 | 0,48 / 0,73 | 0,42 / 0,69 |
| P12 | 98 | 0,43 / 0,46 | 0,45 / 0,56 | 0,43 / 0,48 | 0,42 / 0,57 |
| P13 | 92 | 0,58 / 0,54 | 0,53 / 0,39 | 0,54 / 0,53 | 0,54 / 0,39 |
| P14 | 46 | 0,93 / 0,26 | 0,96 / 0,36 | 0,98 / 0,23 | 0,98 / 0,38 |
| P15 | 224 | 0,78 / 0,54 | 0,77 / 0,62 | 0,71 / 0,56 | 0,67 / 0,60 |

**Lectura:**

- **Líneas.** En media no cambia nada, pero por empresa los cambios son
  grandes. P07 (una empresa más amplia que su descripción, justo el caso
  que se buscaba) pasa de recuperar 0,40 a 0,73. P02 baja de 0,65 a 0,47.
  Las líneas se simularon partiendo una descripción que ya resume sus
  contratos (sección 6), así que aportan poca información nueva. **No se
  sabe qué darían respuestas reales.**
- **Referentes.** Las empresas las marcaba un oráculo con el filtro real
  de cada una, así que era el mejor caso posible, y aun así no mejora.
  Probables causas:
  - las candidatas salen de los mismos 200 contratos parecidos que ya usa
    producción, y lo que aportan lo vuelve a recortar el filtro contra la
    descripción;
  - «de su tamaño» se decidió por franjas, que según la decisión 43 no
    separan a los grandes.

  No se ha probado con un tope por volumen anual. Pero el cliente sin NIF
  no gana casi nada en contratos públicos, así que no hay con qué
  comparar salvo que lo elija él (como el deslizador de Empresas).

## 5. Ideas descartadas y por qué

No repetir sin un argumento nuevo.

- **Tarjetas para deslizar, o que el cliente revise los ejemplos.** No
  mejoraban y costaban minutos (decisiones 37 y 38).
- **Esconder lo que pasa de su tamaño, u ordenar la lista por tamaño.**
  Empeora o se retiró (decisiones 38 y 39). Las empresas también ganan
  contratos algo mayores de lo habitual.
- **Títulos típicos escritos por el modelo como consulta.** Peor en 10 de
  16 (decisión 39).
- **Triangular por comprador** («¿a quién vendéis?»). Sesga: premia a las
  empresas con clientes concentrados y castiga al resto. Regla: **el
  «qué» alimenta la similitud; el «dónde / a quién» solo puede ser un
  filtro explícito que controle el cliente.**
- **Preguntar qué no hacen** («¿qué os llega que no es vuestro?»). El
  cliente sin NIF no lo sabe: no ha usado herramientas así, solo ve un
  contrato que le encaja y se presenta.
- **Pedir el nombre de su competidor.** El cliente piensa la competencia
  por tamaño (un consultor TI pequeño no considera competencia a
  Capgemini) y no sabe si otra empresa es 3 o 12 veces más grande. No se
  sabe cuántos contestarían, y queda raro en un alta. Si nombra a un
  grande, su «qué» es tan amplio que trae ruido.
- **Preguntar la facturación.** En la base solo está lo que cada empresa
  gana en contratación pública, y la facturación no se traduce en tamaños
  de contrato: quien factura 2 M€ puede ganar contratos de 50.000 €.
- **Referentes de su tamaño por franjas** (sección 4). Incluso con
  oráculo, 2 mejor y 5 peor.

## 6. Cómo se mide, y por qué no hay que fiarse del todo

**El banco.** Se toman las empresas que ya van por huellas (unas 15) y
se hace como si entraran sin NIF:

1. [`scripts/simular_sin_nif.ts`](https://github.com/vincent-vegga/StateScraperv2/blob/simulacion-lineas-producto/scripts/simular_sin_nif.ts)
   con `MODO=exportar` (está en las ramas de simulación, no en `main`).
   El modelo escribe la descripción como la escribiría el dueño, se
   proponen y marcan familias, se buscan los parecidos y se guarda todo
   en `simulacion/sinteticos.json`.
2. [`scripts/medir_sintetico.py`](https://github.com/vincent-vegga/StateScraperv2/blob/simulacion-lineas-producto/scripts/medir_sintetico.py)
   pasa cada variante por las funciones de `puntuador.py`, sin tocarlas,
   y compara con lo que el motor les enseña hoy con su NIF (veredictos
   «sí» y «quizás» de lo vivo).

Dos cifras: **recupera** (qué parte de su lista real sale) y **de lo que
enseña, bueno** (qué parte de lo que sale está en su lista real).

Las mediciones anteriores a la decisión 40 usaban otra métrica (F1 contra
el filtro en prosa, con muestras evaluadas por el modelo) y no se pueden
comparar con las de ahora.

**Por qué no hay que fiarse del todo:**

1. **La referencia no es la verdad.** Es la salida del motor con NIF, que
   también falla. Algunas empresas tienen listas reales muy cortas (P08,
   17 contratos; P14, 46), y con ellas cualquier variante acierta un
   0,2–0,4 de lo que enseña. «Ronda el 50 %» mezcla un alta floja con una
   referencia imperfecta.
2. **Las respuestas simuladas tienen fuga.** La descripción simulada se
   reescribe a partir de `perfiles.descripcion`, que en los perfiles con
   NIF escribió el modelo **leyendo sus contratos ganados**
   (`leida.actividad`, en `index.ts`). Todo lo que se derive de ese texto
   hereda información que un cliente real no da. Un cliente real escribe
   otra cosa, a menudo más vaga.
3. **Las empresas del banco no son las del alta sin NIF.** Tienen 5 o más
   contratos ganados, y el cliente real sin NIF ninguno. Puede ser más
   pequeño y describirse peor.
4. **El ruido es pequeño (medido el 04/10).** Con temperatura 0 el
   modelo tampoco es determinista, pero repitiendo `limpio_desc` cada
   empresa cambia como mucho 0,02 en recupera y 0,05 en bueno, casi
   siempre 0,00. Una diferencia de 0,10 en una empresa es real. Una
   variante que «gana» por 0,02 en media sigue sin demostrar nada.
5. **Los oráculos son cotas.** Lo que en la simulación decide el
   «cliente» (familias, franjas, referentes) lo decide un oráculo con los
   datos reales de la empresa. Es lo mejor que daría ese camino si el
   cliente contesta bien, no lo que dará.

## 7. Diagnóstico

Opinión razonada, no medida:

- **El techo parece de información, no de método.** Sin NIF, todo lo que
  se sabe del cliente es lo que escribe en un minuto. Un historial de 50
  contratos lleva mucha más información que dos frases. Métodos muy
  distintos (tarjetas, catálogo, vecinos, historial sintético, filtro,
  líneas, referentes) acaban en la misma franja. Cuando pasa eso, lo
  normal es que el límite sea la entrada. Seguir afinando cómo se procesa
  la misma descripción probablemente dé otra variante que empata.
- **El banco no distingue mejoras pequeñas de ruido** (sección 6).
  Optimizar contra él a ciegas puede producir mejoras que no existen.
- **La recuperación se fija en el alta** (sección 2): las correcciones no
  pueden recuperar lo que el historial sintético dejó fuera.

## 8. Vías abiertas

Ordenadas por lo que creo que aportan. Ninguna está decidida.

Actualizado el 06/10. Lo hecho desde el 04/10, en
[TRASPASO.md](TRASPASO.md).

1. **La web de la empresa.** La única entrada nueva que se ha medido que
   mejora (+0,07 de F1 junto a la descripción). Aprobada; falta
   diseñarla en el alta después de saber por qué falló en tres de las
   pymes del banco (tanda 2).
2. **Información real de los betatesters.** Es lo único que trae
   información nueva, y no lo puede hacer un agente. Dos preguntas:
   - ¿Qué falla en su lista: le sobra ruido o le faltan cosas? Con
     ejemplos.
   - ¿Qué contestarían a «¿qué productos o servicios vendéis o hacéis más
     a menudo?»? Con 10–15 respuestas reales se mide `lineas` sin fuga
     (unos 3 $ con dos variantes).
3. **Aprender después del alta.** Medido el 04/10: con 10 o 20 marcas
   la lista mejora en 5 de 11 empresas. El cambio de motor (rama
   `correcciones-al-historial`) hace que los «me interesa» entren en el
   historial sintético, que los «no me interesa» saquen de él los
   contratos que se les parecen y que el grupo se rehaga con lo
   corregido. Se decide con la tanda 2 (el motor de hoy y el nuevo, los
   dos con 20 marcas). La parte de producto ya está: el aviso de la
   decisión 47.
4. **Mejorar la evaluación.** Una referencia mejor que la salida del
   motor con NIF, o señales reales (lo que marcan o descartan los
   betatesters). El ruido ya está medido (sección 6).

## 9. Cómo lanzar una medición

- **Workflow:** `.github/workflows/medir-sintetico.yml` (en las ramas de
  simulación). Pasos:
  1. `simular_sin_nif.ts` con `MODO=exportar`;
  2. `medir_sintetico.py`;
  3. el detalle (con nombres) se cifra con
     `scripts/simulacion_certificado.pem` y se sube como artefacto. En el
     registro solo salen cifras y perfiles anónimos.
- **Se lanza solo** al subir cambios de los scripts a
  `simulacion-sin-nif`, `simulacion-lineas-producto` o `simulacion-web`
  (la última, con la web y las correcciones; parámetros por entorno:
  `N_MARCAS`, `MARCAS_HOY`, `SIN_BIS`, `WEB_SOLO`). Ya se lanzó una
  vez sin querer. Trabaja en otra rama, o quita el disparador por push
  antes de subir, y lánzalo a mano (`workflow_dispatch`).
- **Gasto.** La versión de `simulacion-lineas-producto` cuenta todo lo
  que gasta, sin depender de que cada función lo apunte:
  - en Deno, envolviendo `fetch`;
  - en Python, envolviendo `requests.Session.request`, que incluye las
    huellas nuevas;
  - con precios de gpt-4o-mini y text-embedding-3-small; si se cambia de
    modelo, se para.

  `MAX_GASTO` es el tope de las dos fases juntas, y `MAX_GASTO_EXPORTAR`
  el de la exportación. Antes de cada empresa, si lo gastado más la
  empresa más cara hasta ahora (con un 25 % de margen) pasaría el tope,
  se para ahí. Una empresa que se queda a medias no cuenta en las medias.
  **Reutilízalo.**
- **Referencias de coste:** la exportación de 15 empresas, unos 0,10 $.
  Cada variante medida, unos 1,5 $ por 15 empresas. 4 variantes, 6,22 $ y
  1 h 40 min.
- **El dueño no puede ver ni dar acceso al saldo de OpenAI** desde aquí:
  la API de costes pide una clave de administrador. El tope lo pone el
  propio código.

## 10. Reglas de trabajo

- **El repositorio es público.** Nada de nombres, NIF, correos ni
  códigos de acceso de clientes en código, commits, PR ni registros de
  Actions. Los perfiles van como P01, P02…
- **Producción en solo lectura** hasta que el dueño apruebe un cambio con
  los números delante. Ni migraciones, ni cambios en funciones, ni
  despliegues sin su «sí».
- **Presupuesto de OpenAI:** se propone antes de cada medición. El dueño
  ha puesto 12 $ como tope en la última.
- **Cambios del juez o de la puntuación:** se miden empresa por empresa,
  no solo en media. Ajustes hechos mirando una empresa ya hundieron a
  otras ([TRASPASO.md](../afinar-seleccion/TRASPASO.md)). Nada de
  ajustes específicos de un sector.
- **Lo que se decida va a [DECISIONES.md](../../DECISIONES.md)** con el
  formato de las demás (contexto, decisión con fecha, motivo con números)
  y se actualiza este fichero.
- Todo en español, como el resto del proyecto.

## 11. Glosario

- **Huellas:** embeddings de títulos (text-embedding-3-small, 256
  dimensiones) guardados en Storage (`huellas.py`).
- **Motor de huellas:** `puntuador.py`. Puntúa cada contrato vivo con
  siete rasgos frente a lo ganado, se queda con los 100 de cada 1.000
  mejores (el **grupo**) y el **juez** (gpt-4o-mini, con ejemplos) dice
  sí, quizás o no.
- **Historial sintético:** los 40 contratos adjudicados a otras empresas
  que hacen de «ganados» para un perfil sin NIF
  (`perfiles.ganados_sinteticos`).
- **Vecindario:** los 200 contratos adjudicados más parecidos a la
  descripción.
- **Franjas:** tamaños de contrato que marca el cliente
  (`perfiles.franjas`). No son tamaño de empresa (decisión 43).
- **Oráculo:** en la simulación, quien contesta por el cliente usando sus
  datos reales. Da cotas, no estimaciones.
- **`limpio_desc`:** nombre en la medición de lo que hay en producción
  (decisión 41).

## 12. Dónde está cada cosa

| Qué | Dónde |
|---|---|
| Flujo del alta | `supabase/functions/alta/index.ts`: acciones `proponer`, `confirmar_familias`, `ejemplos`, `ajustar` |
| Búsqueda de parecidos e historial sintético | `supabase/functions/alta/vecinos.ts` |
| Instrucciones al modelo del alta | `supabase/functions/alta/modelo.ts` e `index.ts` (`INSTRUCCIONES_*`) |
| Motor de huellas | `puntuador.py` (`procesar_perfil`, `AVISO_SIN_NIF`, `ganados_del_perfil`), `huellas.py`, `puntuacion_pesos.json` |
| Contratos adjudicados para el alta | Tabla `muestra_adjudicada` (pg_cron, cada noche) |
| Correcciones del cliente | Tabla `correcciones` (`interesa`, `motivo`) |
| Historia y números | `DECISIONES.md`, 37–41 (y 43 para el tamaño) |
| Motor de huellas: traspaso, resultados y propuesta | `docs/afinar-seleccion/` |
| Simulador y medición | Ramas `simulacion-sin-nif` y `simulacion-lineas-producto`: `scripts/simular_sin_nif.ts`, `scripts/medir_sintetico.py`, `.github/workflows/medir-sintetico.yml` |
| Última medición | Ejecución 36893150878 de Actions (registro y artefacto cifrado; GitHub los borra con el tiempo, las cifras están en la sección 4) |
