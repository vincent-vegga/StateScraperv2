# El producto frente a la competencia

Análisis del 04/10/2026: qué hace cada pantalla, qué ofrecen los
competidores y qué falta. Sirve de hoja de ruta: cada punto se marca al
cerrarlo, con la fecha y el commit o la migración que lo resuelve.

Aviso: los competidores se han estudiado **por su web pública**, no
probándolos por dentro. Las cifras que dan (históricos, frecuencias,
precios) son las suyas.

---

## Qué es State Scraper, en una frase

"Te decimos qué contratos son para ti y si merece la pena presentarse."
El alta por NIF deduce el perfil a partir de lo ganado, un LLM criba cada
día, el filtro aprende de los "sí / no me interesa", y encima hay cuatro
pantallas de inteligencia de mercado.

---

## La competencia

| Producto | Precio/mes | Lo relevante |
|---|---|---|
| [Licitandum](https://licitandum.app/) | 0 / 19 / 49 / 99 € | Histórico desde 2012, contratos menores, alertas en menos de 1 h (correo, Telegram, webhook), tablero de expedientes en 12 etapas, chat con los pliegos con citas, distribución de bajas por empresa, roles de equipo, API, exportación a CSV, ICS y Google Calendar |
| [El Vínculo](https://el-vinculo.com/en) | 39 € (330 €/año) | **Búsqueda semántica describiendo tu actividad, sin CPV**, competidores parecidos para cada licitación, predicción de quién gana, fichas de organismos, chat con los pliegos, 36 países y TED. Actualiza 3 veces al día |
| [Sophia](https://www.sophia-anphis.es/) | 59 / 99 / 133 / 199+ € | Resumen de pliegos con IA, alertas diarias, cálculo de la baja con datos de adjudicaciones |
| [LicitaPilot](https://licitapilot.com/) | — | Analiza los pliegos, detecta requisitos y riesgos, redacta un borrador de la oferta técnica |
| [LICAI](https://licai.es/) | — | Análisis documental con OCR, memorias técnicas con IA, fichas de competidores, predicción de contratos menores que van a vencer |
| [Tendios](https://theofficer.es/tendios-impulsa-licitaciones-publicas-inteligencia-artificial/) | caro | Equipos comerciales: paneles, alertas, riesgos, previsión de plazos. Ronda de 2 M€ en 2025 |
| [Gobierto Contratación](https://contratos.gobierto.es/) | barato | Datos abiertos visualizados, alertas por palabra clave, CPV y adjudicador |
| Licitaciones.es, Infonalia, Infoconcurso | baratos | Alertas por CPV y palabras clave, sin inteligencia |
| [Tussell](https://psip.co.uk/compare) / [Stotles](https://www.stotles.com/platform) (Reino Unido) | contratos anuales | La referencia en inteligencia de mercado: cuotas, compradores, **contratos que vencen y volverán a licitarse**, decidir si presentarse o no |

### Lo que ya no es exclusivo nuestro

- "No necesitas saber qué es un CPV": El Vínculo lo hace por 39 €.
- Chat o resumen de pliegos con IA: ya lo da casi todo el mundo. Desde el
  10/10/2026 también aquí: «Pregúntale al pliego» (Decisión 57).
- Fichas de organismos y de adjudicatarios: estándar.

### Lo que sigue siendo nuestro

- **El perfil se deduce del NIF.** El cliente no tiene que describirse.
- **El filtro aprende de las correcciones** (a las tres, se regenera el criterio).
- **Viabilidad con un veredicto honesto**, que dice sobre cuántos contratos se apoya.
- **La competencia de tu tamaño** en Empresas (Decisión 43).

---

## Pantalla por pantalla

### 1. Contratos — tiene sentido, es el núcleo

Le falta:

- [x] **Llevar la cuenta de cada contrato**: guardado → me presento →
      presentado → ganado/perdido, con notas. Sin eso el usuario se lleva
      el trabajo a un Excel y deja de entrar. Licitandum lo da desde 19 €.
      Sencillo, no un tablero de 12 etapas. **Hecho y publicado el
      07/10/2026**: pestaña "Mi cartera" (`20261006230000_cartera.sql` +
      `web/index.html` + `alertador.py`, Decisión 53). Seis estados, nota
      e importe de la oferta, el resultado cruzado con el NIF, su oferta
      frente a la ganadora y aviso de plazo a 7, 3 y 1 día. Ver el
      traspaso del final.
- [x] **Enseñar lo que el feed ya trae** (Decisiones 18 y 19): requisitos
      de solvencia, correo del órgano, garantía definitiva, enlaces a cada
      pliego. **Hecho y publicado el 07/10/2026** (Decisión 54): bloque
      "Qué piden para presentarte" en la ficha. Medido de nuevo: la
      solvencia con contenido propio en el anuncio es el 26 %, no el 77 %
      (se contaban las declaraciones de trámite); el resto se lee del
      pliego.
- [ ] **Contratos menores en vivo** (conjunto 1143). Hoy solo está el
      histórico de 2025. Para una pyme son la puerta de entrada, y la
      competencia los incluye. Ver también `PENDIENTES.md` §6.
- [x] **Distinguir los sistemas dinámicos de adquisición** en la lista
      (ya en la deuda técnica del `README.md`). Hecho el 04/10/2026:
      etiqueta en la fila y explicación en el detalle, también para
      acuerdos marco y contratos basados en ellos
      (`20261004190000_sistema_en_mis_oportunidades.sql`).
- [ ] **Avisar antes.** El cron de "las 06:00 UTC" arranca hacia las
      10:30–11:15 (`PENDIENTES.md`), frente a menos de 1 h en Licitandum.
      Valorar un cron externo o varias pasadas al día.
- ~~**Exportar el plazo al calendario** (ICS) desde la ficha.~~
      Descartado el 04/10/2026: demasiado intrusivo. Además, con Google
      o Outlook en el navegador un .ics solo se descarga, y hacerlo bien
      pedía enlaces a Google y a Microsoft.

### 2. Movimientos, ahora "Lo que viene" — hecho

Antes decía "quién ganó qué el último mes": interesante, pero sin una
acción detrás, y solapada con Empresas y Organismos. Desde el 06/10/2026
es "Lo que viene" y esa vista queda como "Lo adjudicado".

- [x] **Convertirla en "Lo que viene"**: adjudicaciones del sector cuya
      duración (más prórrogas) termina en los próximos 3–12 meses, y que
      por tanto volverán a licitarse. Ya se guardan la duración y las
      prórrogas (migraciones `20261001220000_duracion_del_contrato.sql` y
      siguientes). Es lo que más valoran los clientes de Tussell y
      Stotles, y es el mejor argumento para el plan Pro.
      **Hecho y publicado el 06/10/2026**: `20261005100000_lo_que_viene.sql`
      + `web/index.html`, Decisión 48. Desde ese día, las filas dicen
      además si ya hay una nueva licitación abierta
      (`20261006100000_ya_publicada.sql`, Decisión 52). Ver el traspaso
      del final.
- [x] Decidir si lo de "quién ganó el último mes" se queda como una
      sección dentro de "Lo que viene" o pasa a Empresas y Organismos.
      **Decidido y publicado:** se queda dentro, como segunda vista
      ("Lo adjudicado"), igual que estaba.

### 3. Empresas — tiene sentido

La comparación con empresas de tu tamaño es una buena idea. Le falta:

- [x] **Avisar cuando una empresa que sigues gana algo**, por correo o al
      entrar. Hoy seguir no avisa de nada. **Hecho el 10/10/2026** por
      correo (Decisión 56, `20261010100000_seguir_avisa.sql`): va con lo
      demás o, solo, como mucho una vez por semana. Al entrar, no.
- [ ] **Cómo baja precios cada competidor**: la distribución de sus bajas
      (Licitandum lo enseña como histograma), no solo cuánto gana al año.
- [ ] **Comparar tu empresa con otra**: los organismos donde coincidís,
      quién gana más allí y con qué bajas.

### 4. Organismos — tiene sentido, todos los competidores la tienen

Le falta:

- [x] **Seguir un organismo** y recibir avisos de sus licitaciones nuevas.
      **Hecho el 10/10/2026** (Decisión 56): botón en la ficha; avisa de
      lo que publica en las familias CPV del perfil.
- [ ] **Sus contratos que van a vencer** (lo mismo que "Lo que viene",
      filtrado por organismo). Con la tabla `vencimientos` es
      una consulta por `organo`; falta la función y el bloque en la ficha.
- [ ] **El correo de contacto** del órgano.
- [ ] **Sus contratos menores**, que revelan con quién trabaja antes de
      que salga el contrato grande (depende del conjunto 1143).

### 5. Viabilidad — la mejor pieza, mal colocada

Es una acción sobre un contrato concreto, no un sitio al que ir: su
pantalla "¿A cuál te presentas?" repite la lista de Contratos.

- [x] **Llevar el veredicto a la lista de Contratos**, como etiqueta
      ("Tienes opciones / Difícil / Cerrado / Es tuyo") y como filtro u
      orden. Así la lista no solo dice qué encaja, también dónde se puede
      ganar. Ojo al coste: `viabilidad()` por fila sobre toda la lista
      probablemente pida precalcularlo en el cribado o de noche. Hecho el
      04/10/2026 (`20261004210000_viabilidad_en_la_lista.sql`): tabla
      `viabilidad_guardada` que rellena `pg_cron` cada 10 minutos (los
      2.865 contratos abiertos en listas se calcularon en ~2 minutos). En
      la fila solo se marca Difícil, Parece cerrado y Es tuyo: "Tienes
      opciones" sale en 3 de cada 4 y no avisaría de nada; está en el
      filtro, junto con "Sin los cerrados".
- [ ] **Quitar la pestaña** o dejarla solo como destino del botón
      "Analizar viabilidad" de la ficha.
- [x] **Dar un rango de precio y no solo la media**: percentiles de la baja
      ganadora en ese organismo y familia ("aquí se gana ofertando entre
      el 82 % y el 90 %"), más el umbral aproximado de baja anormal. Es lo
      que vende Sophia. Hecho el 04/10/2026 el rango (cuartiles, con 5
      contratos o más; `20261004200000_viabilidad_rango_y_contratos.sql`).
      Queda el umbral de baja anormal: depende de las ofertas de cada
      licitación, que no tenemos.
- [x] **Los contratos exactos, con enlace a la plataforma** (petición del
      04/10/2026): en "Quién ha ganado aquí", sin serie, cada empresa se
      abre con sus cinco contratos más recientes; en "Las convocatorias
      anteriores", el título enlaza al expediente.
- [x] **Comprobar la solvencia**: si el pliego pide una facturación de X o
      una clasificación concreta, contrastarlo con el historial de la
      empresa, que ya se conoce. Ningún competidor que hayamos visto lo
      hace de forma automática. **Hecho y publicado el
      07/10/2026** (Decisión 54): se lee del anuncio o del pliego, y con NIF
      se compara con lo que la empresa gana en contratos públicos
      ("Llegas" / "Compruébalo con tu facturación total"). También en la
      pantalla de Viabilidad.

---

## Prioridades

No competir en amplitud: generar memorias técnicas es el terreno de
LicitaPilot y LICAI, y el tablero de equipo el de Licitandum. Centrarse en
**decidir dónde presentarse**. Por este orden:

| # | Prioridad | Estado | Detalle |
|---|---|---|---|
| 1 | El veredicto de viabilidad dentro de la lista de Contratos | ✅ Hecho | Marca en la fila y filtro, desde el 04/10/2026 |
| 2 | "Lo que viene": contratos que van a vencer y volverán a licitarse | ✅ Hecho | Publicado el 06/10/2026 (Decisión 48). Las filas dicen si ya hay una nueva licitación abierta (Decisión 52) |
| 3 | Llevar la cuenta de cada contrato, de forma sencilla | ✅ Hecho | "Mi cartera", publicada el 07/10/2026 (Decisión 53) |
| 4 | Solvencia y requisitos, sacados del feed y del pliego | ✅ Hecho | Publicado el 07/10/2026 (Decisión 54): qué piden en la ficha, en Viabilidad y en la fila, y si lo que ya ganas llega |
| 5 | Contratos menores en vivo | ⬜ Pendiente | |

Lo demás de cada pantalla, cuando toque trabajar en ella.

---

## Planes y precio

Con lo anterior, la diferencia entre los dos planes del
`README-producto.md` se entiende sola:

- **Básico**: encuentra los contratos que encajan (Contratos y el aviso por correo).
- **Pro**: te dice cuáles puedes ganar y qué viene después (Viabilidad,
  "Lo que viene", Empresas, Organismos).

El mercado está entre 19 y 199 € al mes. La referencia directa es El
Vínculo a 39 €, que ya ofrece búsqueda semántica, competencia y chat con
los pliegos. Licitandum tiene un plan gratuito permanente.

---

## Traspaso: estado al cierre del 04/10/2026

Para retomar en otra sesión sin repasar la conversación.

### Lo hecho, todo en producción

| Qué | Dónde | Commit |
|---|---|---|
| Esta hoja de ruta | `docs/competencia/LEEME.md`, enlazada desde el `README.md` | `aa066fe` |
| Exportar el plazo al calendario | Descartado, no llegó a `main` | — |
| Etiqueta de sistema dinámico, acuerdo marco y "solo homologados" en Contratos | `20261004190000_sistema_en_mis_oportunidades.sql` + `web/index.html` | `fc54874` |
| Viabilidad: rango de precio (cuartiles) y contratos con enlace al expediente | `20261004200000_viabilidad_rango_y_contratos.sql` + `web/index.html` | `5831795` |
| El veredicto de Viabilidad en la lista de Contratos: marca en la fila y filtro | `20261004210000_viabilidad_en_la_lista.sql` + `web/index.html` | `e84f747` |

Las tres migraciones están **aplicadas** en Supabase. Lo último se probó
con sesión iniciada (cuenta de prueba de uniformidad, 63
contratos): el filtro, la marca de la fila y la ficha de Viabilidad con
sus contratos enlazados funcionan con datos reales.

### Cómo funciona lo nuevo

- **`mis_oportunidades`** (la vista de la lista) tiene dos columnas más al
  final: `sistema` y `viabilidad` (`abierto`, `dificil`, `cerrado`,
  `mio` o null). Esta vista la han redefinido **varias sesiones el mismo
  día** (la PR #28 le añadió `parecido`): antes de tocarla, leer la
  definición de producción con `pg_get_viewdef`, no la del repositorio,
  y añadir columnas solo al final.
- **`viabilidad_guardada`**: el veredicto de cada contrato abierto que
  está en alguna lista. No depende de quién mira; "Es tuyo" lo resuelve
  la vista comparando `ultimo_cif` con el NIF del perfil. Guarda también
  `sin_datos` y `error`, que la vista convierte en null.
- **`refrescar_viabilidad_guardada(segundos)`**, por `pg_cron` (trabajo
  `refrescar-viabilidad-guardada`, cada 10 minutos, 100 s como mucho):
  primero lo que no tiene veredicto, recalcula a los 7 días y borra a los
  30 lo que ya no se recalcula. Va a unos 25 contratos por segundo; los
  2.865 del arranque tardaron unos 2 minutos.
- **`incumbencia()`**: cada empresa del `reparto` lleva `contratos` (los
  cinco más recientes, con `enlace`). **`ediciones_anteriores()`**
  devuelve `enlace`. **`viabilidad()`** devuelve `baja_p25` y `baja_p75`
  en `organismo`; la web solo enseña el rango con 5 contratos o más.

### Abierto, para decidir

1. **"Difícil" con muy poca base.** Basta con que una empresa gane la
   mitad de 3 adjudicaciones del organismo (caso real: Málaga, Sagres
   S.L., 2 de 3). Ahora que la lista se filtra por el veredicto, quizá
   convenga exigir más contratos. Y "Parece cerrado" es rarísimo: 14 de
   2.865. Si "Sin los cerrados" apenas cambia la lista, revisar los
   umbrales de `viabilidad()`.
2. **La casilla del correo diario viene marcada** en la bienvenida del
   alta, aunque el `README.md` dice que los avisos nacen apagados.
3. **Permisos de `mis_oportunidades`**: `anon` y `authenticated` tienen
   todos los privilegios, no solo `select`. Ya era así; en la práctica no
   se puede escribir (la vista une varias tablas), pero lo correcto es
   dejar solo `select`.
4. **Viabilidad tarda 3–5 s en frío** en organismos muy grandes (uno de
   4.228 adjudicaciones). Ya pasaba antes de estos cambios; está cerca
   del corte de 8 s de la API.
5. **El umbral de baja anormal** no se puede dar: depende de las ofertas
   de cada licitación, que no tenemos.

### Lo siguiente: "Lo que viene"

Prioridad 2. Datos medidos el 04/10/2026: de 942.000 adjudicaciones desde
2023, el 83 % tiene duración y fecha (783.000), y unas 76.000 vencen en
los próximos 12 meses. Esa cifra incluye los contratos menores, que duran
poco: filtrado por el sector de cada cliente, y sin menores, saldrán
muchas menos. Fecha de fin = `coalesce(fecha_formalizacion,
fecha_formalizacion_estimada, fecha_adjudicacion) + duracion_meses`; las
prórrogas solo están en texto (`prorrogas_texto`). Hará falta un agregado
nocturno por prefijo, como `organismos_por_prefijo`, por el corte de 8 s.

Después: llevar la cuenta de cada contrato (decidir antes los estados y
si lleva notas). Solvencia y contratos menores tocan el scraper y la
tabla grande: mejor cuando no haya otra sesión cargando histórico.

### Cómo se ha trabajado, por si sirve

- **Subir a `main` publica la web en producción** (Cloudflare Pages).
  Cada rama subida tiene su vista previa en
  `https://<rama>.statescraperv2.pages.dev`: sirve para comprobar que la
  página carga sin errores antes de unirla.
- **Web en local**: `py -m http.server 8765 --bind 127.0.0.1 --directory web`
  y abrir `http://localhost:8765`. En este equipo hay un
  `.claude/launch.json` con eso mismo (la carpeta `.claude` no se sube:
  está en el `.gitignore`). **Habla con la base de producción.**
- **No hay Node en este equipo.** Para comprobar el JavaScript, la vista
  previa de la rama o la web en local.
- **Otras sesiones trabajan en paralelo** (alta sin NIF, capacidad de la
  base e histórico). Cada cambio se hizo en su propio worktree y su
  rama, y se miró `pg_stat_activity` antes de aplicar migraciones.
- **Probar SQL sin dejar rastro**: un bloque `do $$ ... $$` que crea las
  funciones, las llama y termina con `raise exception` con el resultado.
  La excepción deshace todo y el mensaje trae los datos.

---

## Traspaso: "Lo que viene", noche del 04 al 05/10/2026

**Estado (06/10/2026): aplicado, rellenado y publicado** (PR 30). Lo que
sigue cuenta cómo estaba la noche del 04 al 05/10/2026, antes de aplicarlo.

Trabajo nocturno, sin supervisión. Todo está en la rama `lo-que-viene`
(PR hacia `main`), **nada aplicado ni publicado**. En la base solo se
han hecho lecturas y bloques `do` que terminan en excepción.

### Lo construido

| Qué | Dónde |
|---|---|
| Tabla `vencimientos`, vista `vencimientos_calculados`, refresco `refrescar_vencimientos(prefijos)`, lectura `lo_que_viene(meses, provincia_elegida, tope)`, lectura de prórrogas (`meses_de_prorroga`, `prorrogable_hasta`, `prorroga_de`) y trabajo de `pg_cron` `refrescar-vencimientos` (14:45 UTC) | `supabase/migrations/20261005100000_lo_que_viene.sql` |
| La pestaña Movimientos pasa a ser "Lo que viene", con dos vistas: "Lo que vence" (por defecto) y "Lo adjudicado" (lo de antes, sin cambios) | `web/index.html` |
| Decisión 48 y dos filas nuevas en la deuda técnica | `DECISIONES.md` |

Cada fila dice quién lo tiene (enlace a su ficha en Empresas), qué es
(enlace al expediente), de qué organismo (enlace a Organismos), el
importe y lo que sale al año, cuándo vence ("en 41 días"), la duración y
las prórrogas si el organismo las publicó. Filtros: plazo (3, 6 y 12
meses, con cuántos hay en cada uno) y provincia. Lo tuyo y lo de las
empresas que sigues va marcado, y el resumen dice cuántos son tuyos.

### Lo medido (04/10/2026)

- **Cobertura.** Muestra del 2 % de la tabla (23.028 adjudicaciones): el
  99 % tiene fecha de inicio y el 85 % duración. Sin menores, la duración
  la tiene el 99,5 %.
- **Menores.** El 47 % de las adjudicaciones, duración mediana de un
  mes, solo histórico de 2025: de 7.384 con duración, 7.373 ya vencidos
  y 6 entre 3 y 12 meses. Fuera.
- **Acuerdos marco.** Los basados (10 % de los no menores, 4 meses de
  mediana) fuera: el siguiente solo lo piden los homologados. Los marcos
  con importe, dentro (rotulados "Acuerdo marco"); las homologaciones sin
  importe, fuera.
- **Duraciones absurdas.** No hay ceros ni negativas. Más de 25 años:
  concesiones demaniales, enajenaciones (996 meses) y errores de unidades
  (electrocardiógrafos a 720 meses), fuera. Menos de 6 meses: compras y
  actos sueltos, entre el 14 y el 29 % de lo que vence según el sector,
  fuera. También las obras (CPV 45).
- **Prórrogas.** Texto en el 22 % de los no menores. Las reglas leen el
  63 % (48 % meses, 14 % "no hay", 2 % una fecha); 55 de 55 casos
  etiquetados a mano bien. De lo que vence, el 25 % tiene prórrogas
  leídas y el 63 % no trae texto.
- **Por perfil** (12 meses / 3 meses): ascensores 586 / 170,
  uniformidad 735 / 178, espectáculos 459 / 122,
  consultoría 2.024 / 533.
- **Tiempos.** Refresco de 8 prefijos: 7,2 s (2.800 filas, por índice).
  `lo_que_viene()`: 40-660 ms con 300 filas (230-250 KB de respuesta).
  El cálculo sobre la muestra del 2 % copiada aparte: 1,2 s.

### Lo que no se ha podido probar

1. **El relleno completo** (`refrescar_vencimientos()` sin argumentos):
   recorre `licitaciones` entera, y esta noche no se podía. Estimado:
   **1,5-2,5 minutos** y unas **80.000 filas** (60 s de cálculo por la
   muestra, más leer 2,5 GB; `refrescar_organismos` tardó 68 s).
2. **El trabajo de `pg_cron`**: el bloque de prueba no lo crea (no se
   toca `cron.job`).
3. **La pantalla con sesión y datos reales.** Se ha comprobado con una
   copia local de la página y la base simulada (datos sacados de las
   pruebas): escritorio, móvil de 375 px, modo oscuro, filtros, cambio
   de vista, tabla vacía y función inexistente. La página real carga sin
   errores, pero sin sesión.
4. **Los perfiles con prefijos de dos cifras** ("72,48,79"): la lectura
   los cruza por familia, pero la prueba solo rellenó prefijos de cuatro.
5. **Los permisos a través de la API.** La función se probó como el
   usuario (`request.jwt.claims` y `x-perfil` en el bloque), no por
   PostgREST.

### Para ponerlo en producción

1. Mirar que no haya cargas pesadas en marcha:
   `select pid, state, now() - query_start, left(query, 80) from pg_stat_activity where state <> 'idle';`
2. **Aplicar la migración** `supabase/migrations/20261005100000_lo_que_viene.sql`
   (con `apply_migration` o en el editor SQL). Solo crea objetos y el
   trabajo de `pg_cron`: es instantánea. No toca `mis_oportunidades` ni
   Viabilidad.
3. **Rellenar la tabla la primera vez**, en el editor SQL (no por la
   API: no cabe en 8 s):
   `select public.refrescar_vencimientos();`
   Tardará unos 1,5-2,5 minutos. Si algo la corta, rellenar primero solo
   los sectores de los clientes, que va por índice (la tabla se rehace
   entera esa misma tarde a las 14:45 UTC):
   `select public.refrescar_vencimientos(array(select distinct trim(x) from public.perfiles p, unnest(string_to_array(coalesce(p.cpv_prefijos, ''), ',')) x where trim(x) ~ '^\d{4}$'));`
4. **Comprobar**:
   `select count(*), min(vence), max(vence), max(actualizado), count(*) filter (where prorroga = 'si') from public.vencimientos;`
   (unas 80.000 filas, `vence` entre hoy y dentro de 13 meses) y
   `select jobname, schedule from cron.job where jobname = 'refrescar-vencimientos';`
5. **Unir la PR** a `main`, lo que publica la web. Si se une antes del
   paso 2 no se rompe nada: la vista dice "se está preparando".
6. Entrar con la cuenta de prueba de uniformidad y mirar "Lo
   que viene": unos 735 contratos en 12 meses, los filtros, un enlace a
   Empresas, uno a Organismos y uno al expediente.

### Abierto, para decidir

1. **¿Ya se ha vuelto a licitar?** Hecho el 06/10/2026 para lo que se
   empareja con seguridad (Decisión 52, `20261006100000_ya_publicada.sql`):
   278 contratos de 84.000. Queda abierto cómo ampliar la cobertura sin
   perder precisión.
2. **Avisar por correo** de lo tuyo que vence (4-5 contratos en los
   clientes con NIF probados): es retener un contrato, no ganar uno
   nuevo.
3. **El umbral de 6 meses** se eligió mirando títulos; algunos
   suministros de un año siguen siendo compras sueltas.
4. **"Sus contratos que van a vencer" en Organismos** sale casi gratis
   con la tabla (ver arriba, Organismos).

---

## Traspaso: "Mi cartera", noche del 06 al 07/10/2026

**Estado (07/10/2026): aplicado y publicado** (PR 44). La migración se
aplicó sin cargas en marcha; pasaron a la cartera 5 "sí me interesa" de
contratos abiertos (4 perfiles), `mi_cartera()` responde en 3 ms y, con
datos reales, marca como suyo el contrato que la cuenta de prueba ganó.
Queda el paso 5 (probar con sesión) y el 6 (el correo en simulacro). Lo
que sigue cuenta cómo estaba la noche anterior.

Trabajo nocturno, sin supervisión. Todo en la rama `mis-contratos` (PR
hacia `main`). **Nada aplicado ni publicado**: en la base de producción
solo se han hecho lecturas. Crear objetos, aunque fuera en un bloque que
se deshace, no estaba permitido esta noche; la migración se probó en un
PostgreSQL local (ver Decisión 53, "Probado").

### Qué hace la competencia (mirado el 06/10/2026, por su web)

- **Licitandum**: tablero de 12 etapas (de "interesado" a "finalizada"),
  sobres A/B/C con requisitos y responsable, documentos, tareas, avisos a
  7, 3 y 1 día, go/no-go con motivo, probabilidad, importe ofertado y
  resultado. 3 expedientes en el plan gratuito, 25 en Starter.
- **El Vínculo**: tablero "en revisión, candidata, en curso, presentada,
  ganada" más descartada, en lista o calendario, notas, recordatorios de
  cierre, aviso si cambia el plazo de lo guardado, exportar a Excel.
- **Stotles**: tablero por estado e informes de bid/no-bid en equipo.

Lo que se ha tomado: los avisos a 7, 3 y 1 día, el aviso de plazo
cambiado, el go/no-go como "No me presento" con nota y el importe
ofertado. Lo que no: sobres, tareas, documentos y equipos. Lo que no da
ninguno: el resultado cruzado con el NIF, sin que el cliente lo busque, y
su oferta frente a la ganadora.

### Lo construido

| Qué | Dónde |
|---|---|
| Tabla `cartera`; `poner_en_cartera`, `anotar_en_cartera`, `quitar_de_cartera`, `dar_plazo_por_visto`, `mi_cartera`, `plazos_de_cartera`, `licitacion_vigente`, `resultado_licitacion`; los "sí me interesa" abiertos pasan a la cartera | `supabase/migrations/20261006230000_cartera.sql` |
| Pestaña "Mi cartera" en Contratos; la etiqueta del estado en la fila; el bloque "Tu cartera" en cada ficha; "Sí me interesa" guarda en la cartera; `statescraper.com/#cartera` abre la pestaña | `web/index.html` |
| "Plazos de tu cartera" en el correo diario, a 7, 3 y 1 día del cierre | `alertador.py` |
| Decisión 53, README | `DECISIONES.md`, `README.md` |

### Para ponerlo en producción

1. Mirar que no haya cargas pesadas: `select pid, state, now() - query_start, left(query, 80) from pg_stat_activity where state <> 'idle';`
2. **Aplicar la migración** `20261006230000_cartera.sql`. Solo crea objetos
   y copia unas pocas filas (6 "sí me interesa" abiertos el 06/10/2026):
   instantánea. No toca `mis_oportunidades` ni `licitaciones`.
3. Comprobar: `select count(*) from public.cartera;` (los "sí me interesa"
   de contratos abiertos) y, con la cuenta de prueba de uniformidad,
   que `select public.mi_cartera();` responde.
4. **Unir la PR** a `main`. El orden no importa: la web sin la migración
   no enseña la pestaña y todo funciona como antes.
5. Entrar con la cuenta de prueba: "Sí me interesa" en un contrato →
   aparece en Mi cartera; abrir la ficha, "Preparo la oferta", escribir
   una nota y un importe, guardar, recargar y ver que siguen; quitarla y
   deshacer.
6. El correo: `python alertador.py --simulacro --solo <NIF de prueba>` con
   algo de la cartera que cierre dentro de 7, 3 o 1 día.

### Abierto, para decidir

1. **La primera vez que se guarda un contrato cuenta como corrección**, y
   a las tres se ajusta el filtro (con su ventana y la recarga). Es lo que
   ya hacía "Sí me interesa", pero ahora también pasa al elegir "Preparo
   la oferta" en la ficha de un contrato sin corregir.
2. **¿Vigilar contratos de "Lo que viene"?** Un estado "vigilar" para los
   que vencen y se volverán a licitar, con aviso cuando salga la nueva
   licitación (Decisión 52). Encajaría en la cartera. **Hecho el
   10/10/2026, fuera de la cartera** (Decisión 56): tabla `vigilados`,
   botón «Vigilar» en cada fila de Lo que viene. La cartera es de
   licitaciones abiertas con plazo; lo vigilado es un contrato
   adjudicado.
3. **¿Aplicar el resultado solo cuando el NIF coincide?** Hoy se propone y
   el cliente confirma. Con NIF y un solo adjudicatario el acierto sería
   casi seguro; se dejó manual por las UTE y los NIF mal publicados.
4. **La cartera en Viabilidad.** La ficha de Viabilidad no dice si el
   contrato está en la cartera ni deja guardarlo.

---

## Traspaso: solvencia y requisitos, noche del 06 al 07/10/2026

**Estado (07/10/2026): aplicado y publicado** (PR 45). Lo que sigue
cuenta cómo estaba la noche del 06 al 07/10/2026, antes de unirlo.

Prioridad 4. Trabajo nocturno sin supervisión, en la rama `solvencia`
(worktree `../StateScraperv2-solvencia`). Detalle y cifras en la
Decisión 54 de `DECISIONES.md`.

### Estado

- **Base: aplicado en producción** (con permiso): migraciones
  `20261007100000_condiciones.sql` y `20261007110000_requisitos_en_la_lista.sql`.
  Tablas `condiciones`, `requisitos_guardados` y `gasto_lecturas_dia`;
  `mis_oportunidades` tiene una columna más al final, `requisitos`; trabajo
  de `pg_cron` `refrescar-requisitos-guardados` (cada 10 minutos, minuto
  5). Nada de esto cambia lo que ve la web publicada: la columna nueva se
  ignora y las funciones nuevas no las llama nadie hasta unir la rama.
- **Datos: cargados.** Condiciones de lo abierto (relleno desde los ZIP)
  y lectura de la solvencia de todo lo abierto, primero lo que está en
  listas (ver "Lo medido").
- **Web y scraper: en la rama, sin publicar.** Hasta unir, el scraper no
  guarda condiciones nuevas cada día y `condiciones.yml` no corre (su
  disparador `workflow_run` solo vale desde `main`).

### Lo medido (06/10/2026)

- **Lectura.** De las 4.875 licitaciones abiertas con condiciones: 4.465
  leídas (92 %), 315 sin pliego publicado (6,5 %) y 95 con el pliego
  escaneado o protegido (2 %). El 8 % está exento de solvencia. De las
  que piden solvencia económica, el 87 % queda con cifra.
- **Lista.** De 5.141 pares perfil-contrato: 349 con "Piden facturar…"
  (solo con NIF) y 134 con "Exigen clasificación".
- **Coste.** 3,77 $ la carga entera, con la relectura de lo de las
  listas con el prompt final (tope que pusiste: 5 $). Unos 0,0007 $ por
  lectura; ~1 s por contrato con 6 hilos.
- **Precisión.** Dos muestras al azar revisadas contra el pliego (15 y
  12). Los fallos que salieron (una cifra inventada, la cifra de la
  técnica en la económica, una técnica mal entendida) tienen ya su
  defensa: ver la Decisión 54.

### Lo construido

| Qué | Dónde |
|---|---|
| Guardar solvencia (con código y umbral), clasificación, garantías por tipo, contacto y documentos de lo PUB en cada pasada | `lector_atom.py` (`extraer_condiciones`, `guardar_condiciones`) |
| Relleno desde los ZIP del mes y los dos anteriores | `rellenar_condiciones.py` |
| Lectura de la solvencia del anuncio o del pliego, con topes de gasto | `leer_pliegos.py` |
| Lectura diaria tras el scraper (0,50 $/día, 10 $/mes) y relleno a mano | `.github/workflows/condiciones.yml` |
| Bloque "Qué piden para presentarte" en la ficha de Contratos y en Viabilidad; marcas "Exigen clasificación" y "Piden facturar X al año" en la fila | `web/index.html` |
| Decisión 54, README | `DECISIONES.md`, `README.md` |

### Para ponerlo en producción

1. Revisar la PR. Ojo a dos conflictos de contexto con la de la cartera
   (Propuesta 3, rama `mis-contratos`): `DECISIONES.md` (las dos añaden
   una decisión antes de "Deuda técnica": la 53 es la suya y la 54 la
   mía) y la ficha de `web/index.html` (mi hueco `.requisitos` va justo
   tras el `</dl>`, su `bloqueCartera` antes del botón de Viabilidad).
2. Unir la PR a `main`: publica la web y deja activos el scraper nuevo y
   `condiciones.yml`. No hace falta aplicar nada en la base.
3. Entrar con la cuenta de prueba de uniformidad y abrir un par de fichas:
   el bloque se carga al abrir, con "Llegas" o "Compruébalo".
4. Al día siguiente, mirar en Actions que "Solvencia y requisitos" corrió
   tras el scraper, y su gasto: `select * from gasto_lecturas_dia order by dia desc;`

### Abierto, para decidir

1. **Los topes de gasto diarios** (0,50 $/día, 10 $/mes) son míos. Lo
   nuevo de cada día cuesta unos 0,15-0,30 $.
2. **La solvencia técnica en la comparación** usa las tres primeras cifras
   del CPV (art. 90.1.a). Sale "Compruébalo" en 3 de cada 5: es estricto, y
   por eso no se marca en la fila.
3. **El correo del órgano en Organismos** (punto de la pantalla 4) sale
   casi gratis de `condiciones`, pero solo para órganos con algo abierto.
   No hecho.
4. **Avisar en el correo diario** de los contratos que exigen
   clasificación o más facturación: el correo es de la sesión de la
   cartera esta noche; no lo he tocado.
5. **La rama `ejecutar-condiciones`** fue la de usar y tirar para lanzar
   la carga desde Actions antes de que el workflow estuviera en `main`.
   Borrada al acabar.
