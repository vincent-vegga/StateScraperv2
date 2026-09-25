# Afinar la selección de contratos por NIF — traspaso entre sesiones

Estado al 24/09/2026. Rama de trabajo: `claude/optimistic-dijkstra-myr851`.
Quien retome esto: lee este fichero entero antes de hacer nada.

## Estado (24/09/2026, 13:20 UTC): EN PRODUCCIÓN

Aprobado por el dueño y encendido (PR #5). Resumen:

- **Qué hay:** `puntuador.py` + `huellas.py` + `puntuacion_pesos.json` en la
  raíz. Huellas (256 dim) en Storage, bucket privado `huellas` (`v1/`);
  instantánea diaria en `estado/`; la sombra de la prueba en `sombra/`
  (ya no se usa).
- **Quién va por huellas:** perfiles con NIF y ≥5 contratos (antes ≥15;
  bajado tras medir 20 empresas de 5-14 contratos)
  (`perfiles.sistema = 'huellas'`). 11 perfiles al encenderlo. El resto
  (sin NIF o con poco historial) sigue con criterio + puerta CPV.
- **Cuándo corre:** cada mañana dentro del robot (`scraper.yml`, antes del
  correo, `--real`: ~8 min) y a demanda con `puntuador.yml` (alta y
  correcciones: `--real --instantanea --perfil X`, ~3 min). La función
  del alta lo lanza con el secret `GITHUB_DISPATCH_TOKEN`.
- **Volver atrás un perfil:** `update perfiles set sistema = 'criterio'
  where id = ...` (el cribado de siempre rellena lo que falte).
- **Gasto de OpenAI del banco y la puesta en marcha:** 5,77 $ (clave del
  banco). En producción: ~0,1 $ al día para todos los perfiles.
- **Regla para cualquier cambio del juez o de la puntuación** (el dueño
  avisa: ajustes hechos mirando una empresa concreta ya hundieron a otras):
  medirlo antes en el banco y pasar `banco/p10_por_empresa.py` con la
  versión vigente y la nueva. La media no basta: ninguna empresa debe
  perder más de un contrato sin explicación. El juez v2 lo pasó: 38 de 40
  igual, 2 pierden un contrato cada una (casos sueltos), ruido −19 %.
- **Juez en vigor:** `puntuacion-v3` (destinatario y reglas del cliente,
  con instrucciones sin nada de ningún sector). REGLA: las instrucciones
  del juez son comunes a todos; nunca un ejemplo ni una frase sacada del
  sector de un cliente (el v2 los tenía y se quitaron).
- **Presupuesto del banco:** 14,37 $ de 16 $ (límite del proyecto: 17 $).
- **Probado y descartado** (ver RESULTADOS.md): sin homologaciones en lo
  ganado, solo los últimos 5 años, ejemplos con quién convocó (juez v4).
- **Pendiente:**
  2. Historial sintético para el alta sin NIF (idea del otro agente):
     40 contratos parecidos a la descripción como «ganados» y medirlo con
     el banco.
  3. Repetir el informe del banco cuando acabe el reprocesado del 643
     (cambian fechas de adjudicación de 2025-2026). Gratis: todo en caché.
  4. Decisiones de producto abiertas (abajo).

## Reglas de la tarea (las puso el dueño del proyecto)

- **Presupuesto OpenAI: 11 $ en total** (proyecto aparte con límite). El
  script debe contar tokens y **pararse solo a 10 $**. Plan: *embeddings*
  de todos los títulos (~0,85 $) + banco de pruebas con **40 empresas**
  (~0,19 $ por empresa con los dos sistemas).
- **Producción: solo lectura** hasta que el dueño apruebe el cambio con los
  números del banco de pruebas delante. Nada de `pgvector`, tablas nuevas
  ni cambios en funciones sin su «sí». Todo el banco de pruebas se hace
  fuera de la base (en el contenedor).
- No escribir en el repo nombres, NIF ni correos de clientes (el repo es
  público). En los registros, perfiles por las 8 primeras cifras de su id.
- Variables de entorno disponibles: `OPENAI_API_KEY`, `SUPABASE_URL`,
  `SUPABASE_KEY` (clave secreta: usarla solo para leer). Red permitida:
  `api.openai.com` y `swgrbzqxagrqdyddmvfy.supabase.co`. Las conexiones
  TCP directas a Postgres NO funcionan en el contenedor: leer por
  PostgREST (paginado, corte de 8 s por petición) o por el conector MCP de
  Supabase (corte de 60 s).

## Cómo funciona hoy (resumen)

1. Alta por NIF (`supabase/functions/alta/index.ts`, `confirmar_empresa`):
   `ultimos_ganados(cif, 40)` + `prefijos_de_empresa(cif, 1)` (4 cifras de
   todos sus CPV). `leerHistorial` (`modelo.ts`, gpt-4o) escribe un
   criterio en prosa y valida prefijos (`prefijos_validos`). Se guarda en
   `lecturas_empresa` 30 días.
2. Puerta CPV: `pendientes_de_perfil` coge licitaciones PUB con plazo no
   vencido, no sustituidas, con `licitaciones.prefijos && cpv_prefijos`.
   `prefijos` lo rellena el disparador `trg_prefijos` →
   `calcular_prefijos(cpvs)` = prefijos de 2 y 4 cifras de TODOS los CPV.
3. Juez: gpt-4o-mini con `criterio + FORMATO` (cribador.py / `clasificar`
   en index.ts) ve título, órgano, presupuesto y CPV → si/quizas/no. Se
   enseñan si + quizas (`mis_oportunidades`).
4. Correcciones del cliente → `ajustar` → `regenerarCriterio` reescribe el
   criterio y se borra y rehace todo el cribado.

## Lo medido (24/09/2026, solo lectura)

- Universo vivo pequeño: **6.055 licitaciones abiertas**; entran
  **150-700 PUB nuevas al día**. La puerta CPV apenas ahorra.
- Veredictos existentes: 5.920 no / 1.726 sí / 495 quizás (73 % «no»).
- Contratos ganados sin CPV: muchos (p. ej. 90 de 114, 145 de 469), sobre
  todo menores. De las vivas, solo 67 sin CPV.
- **Recall temporal de la puerta** (80 empresas con ≥15 ganados antes de
  2026 y ≥5 después; prefijos con lo de antes, medido sobre lo de 2026,
  sin menores ni homologaciones):
  - todos los prefijos de 4 cifras (≥1 contrato): **92,9 %** (p10 = 79,8 %),
    deja pasar el 10 % del volumen, ~20 prefijos.
  - prefijos con ≥2 contratos: **86,0 %**, 6 % del volumen, ~10 prefijos.
  - prefijos con ≥5 % de su historial: 85,7 %, 5,6 % del volumen.
- Banco de pruebas posible: **4.240 empresas** con ≥15 ganados antes de
  2026 y ≥5 después (1.898 con ≥30/≥10; 3.192 con 3-10 antes y ≥3 después).
- Auditoría a mano del juez (perfil de uniformidad `d89446f2`): se
  contradice con su propio criterio (el criterio dice «quizás» para
  vestuario de otro personal municipal; marcó «no» a vestuario laboral de
  una empresa municipal de limpieza, de una empresa de aguas y del SEPE, y
  «quizás» a otros equivalentes). SDA con título genérico no se pueden
  juzgar por el título.
- Criterio degradado por correcciones (perfil `0b2d8e56`, versión 5):
  enumera casos («Catskills», «galerías de tiro», «Diputación de
  Valencia») en vez de patrones, y mete una preferencia de organismo en un
  texto que tiene prohibido el territorio.
- La prueba léxica (palabras distintivas de lo ganado contra títulos
  vivos fuera de la puerta) salió ruidosa: NO usarla como dato.

## Plan aprobado

0. **Banco de pruebas** (`docs/afinar-seleccion/banco/`, Python):
   - Muestra: 40 empresas de las 4.240 (estratificada por tamaño de
     historial), corte T = 2026-01-01.
   - Perfil construido solo con lo ganado antes de T. Positivos = lo que
     ganó en o después de T (sin menores ni homologaciones).
   - Universo por empresa = licitaciones con `fecha_actualizacion` ≥ T
     (una muestra fija, la misma para todos los sistemas) + sus positivos.
   - Métricas: recall de sus contratos futuros y volumen enseñado (por
     cada 1.000 licitaciones); curva recall/volumen para los sistemas con
     puntuación.
   - Guardar todas las llamadas al modelo en caché en disco (no pagar dos
     veces) y el contador de gasto.
1. **Sistema actual** reproducido con el mismo código de instrucciones
   (`INSTRUCCIONES_HISTORIAL`, `FORMATO`) → punto de partida.
2. **Puntuación**: *embeddings* (`text-embedding-3-small`) de títulos;
   similitud con lo ganado (kNN), afinidad CPV ponderada (como peso, no
   puerta) y «quién gana lo parecido» (ganadores de las licitaciones
   pasadas más parecidas: la propia empresa o sus pares).
3. **Juez con ejemplos**: para las mejor puntuadas, gpt-4o-mini ve los 5-8
   contratos ganados más parecidos (y, en producción, las correcciones más
   parecidas) y decide si encaja. Sin criterio en prosa.
4. Calibrar el corte y comparar todo con los dos números.
5. Proponer el cambio en producción (pgvector, tabla de embeddings,
   `pendientes_de_perfil`, alta, cribador) y esperar aprobación.

## Decisiones de producto pendientes (preguntar, no suponer)

- ¿Lista ordenada por encaje o se mantienen «Para mí / Puede ser para mí»?
- ¿Filtro visible de «organismos con los que no trabajo»?
- ¿Organismos con los que ha trabajado como señal de orden (no de criterio)?
