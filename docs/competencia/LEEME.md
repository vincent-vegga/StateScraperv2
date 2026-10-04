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

### 2. Movimientos — la más débil tal como está

"Quién ganó qué el último mes" es interesante, pero no lleva a ninguna
acción, y se solapa con Empresas y Organismos.

- [ ] **Convertirla en "Lo que viene"**: adjudicaciones del sector cuya
      duración (más prórrogas) termina en los próximos 3–12 meses, y que
      por tanto volverán a licitarse. Ya se guardan la duración y las
      prórrogas (migraciones `20261001220000_duracion_del_contrato.sql` y
      siguientes). Es lo que más valoran los clientes de Tussell y
      Stotles, y es el mejor argumento para el plan Pro.
- [ ] Decidir si lo de "quién ganó el último mes" se queda como una
      sección dentro de "Lo que viene" o pasa a Empresas y Organismos.

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
      filtrado por organismo).
- [ ] **El correo de contacto** del órgano.
- [ ] **Sus contratos menores**, que revelan con quién trabaja antes de
      que salga el contrato grande (depende del conjunto 1143).

### 5. Viabilidad — la mejor pieza, mal colocada

Es una acción sobre un contrato concreto, no un sitio al que ir: su
pantalla "¿A cuál te presentas?" repite la lista de Contratos.

- [ ] **Llevar el veredicto a la lista de Contratos**, como etiqueta
      ("Tienes opciones / Difícil / Cerrado / Es tuyo") y como filtro u
      orden. Así la lista no solo dice qué encaja, también dónde se puede
      ganar. Ojo al coste: `viabilidad()` por fila sobre toda la lista
      probablemente pida precalcularlo en el cribado o de noche.
- [ ] **Quitar la pestaña** o dejarla solo como destino del botón
      "Analizar viabilidad" de la ficha.
- [x] **Dar un rango de precio y no solo la media**: percentiles de la baja
      ganadora en ese organismo y familia ("aquí se gana ofertando entre
      el 82 % y el 90 %"), más el umbral aproximado de baja anormal. Es lo
      que vende Sophia.
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

1. [ ] El veredicto de viabilidad dentro de la lista de Contratos.
2. [ ] "Lo que viene": contratos que van a vencer y volverán a licitarse.
3. [ ] Llevar la cuenta de cada contrato, de forma sencilla.
4. [ ] Solvencia y requisitos, sacados del feed y del pliego.
5. [ ] Contratos menores en vivo.

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
