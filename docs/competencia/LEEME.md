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
- Chat o resumen de pliegos con IA: ya lo da casi todo el mundo.
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

- [ ] **Llevar la cuenta de cada contrato**: guardado → me presento →
      presentado → ganado/perdido, con notas. Sin eso el usuario se lleva
      el trabajo a un Excel y deja de entrar. Licitandum lo da desde 19 €.
      Sencillo, no un tablero de 12 etapas.
- [ ] **Enseñar lo que el feed ya trae** (Decisiones 18 y 19): requisitos
      de solvencia (contenido real en el 77 %), correo del órgano (93 %),
      garantía definitiva (40 %), enlaces a cada pliego. Hoy la ficha solo
      tiene "Ver el expediente".
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

- [ ] **Avisar cuando una empresa que sigues gana algo**, por correo o al
      entrar. Hoy seguir no avisa de nada.
- [ ] **Cómo baja precios cada competidor**: la distribución de sus bajas
      (Licitandum lo enseña como histograma), no solo cuánto gana al año.
- [ ] **Comparar tu empresa con otra**: los organismos donde coincidís,
      quién gana más allí y con qué bajas.

### 4. Organismos — tiene sentido, todos los competidores la tienen

Le falta:

- [ ] **Seguir un organismo** y recibir avisos de sus licitaciones nuevas.
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
- [ ] **Comprobar la solvencia**: si el pliego pide una facturación de X o
      una clasificación concreta, contrastarlo con el historial de la
      empresa, que ya se conoce. Ningún competidor que hayamos visto lo
      hace de forma automática. Necesita la solvencia del feed y, en el
      23 % que remite al pliego, leer el pliego (Decisión 19).

---

## Prioridades

No competir en amplitud: generar memorias técnicas es el terreno de
LicitaPilot y LICAI, y el tablero de equipo el de Licitandum. Centrarse en
**decidir dónde presentarse**. Por este orden:

| # | Prioridad | Estado | Detalle |
|---|---|---|---|
| 1 | El veredicto de viabilidad dentro de la lista de Contratos | ✅ Hecho | Marca en la fila y filtro, desde el 04/10/2026 |
| 2 | "Lo que viene": contratos que van a vencer y volverán a licitarse | ✅ Hecho | Publicado el 06/10/2026 (Decisión 48). Las filas dicen si ya hay una nueva licitación abierta (Decisión 52) |
| 3 | Llevar la cuenta de cada contrato, de forma sencilla | ⬜ Pendiente | |
| 4 | Solvencia y requisitos, sacados del feed y del pliego | ⬜ Pendiente | |
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
