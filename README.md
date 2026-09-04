# Detector de licitaciones

Detecta contratos públicos relevantes para un profesional concreto, y le
avisa solo de los que puede aprovechar.

El problema no es encontrar licitaciones: hay agregadores de sobra que las
listan. El problema es que **están mal filtradas**. Un profesional que recibe
veinte contratos al día y descarta dieciséis no tiene una herramienta, tiene
una tarea más.

La causa está en cómo se clasifican los contratos públicos. El código CPV
—el vocabulario europeo de clasificación— es demasiado grueso en unos
sectores y demasiado concreto en otros, y en ningún caso captura la
intención de quien busca. `92312250` significa "servicios prestados por
artistas individuales" y lo usan por igual un cantautor y un apoderado
taurino.

**La propuesta de valor no es el filtro: es el proceso que construye el
filtro.** El cliente describe su negocio en lenguaje natural, marca sobre
licitaciones reales cuáles le interesan, y de ahí sale un criterio a su
medida. Ningún competidor lo hace: todos asumen que el cliente ya sabe qué
códigos quiere.

---

## Estado

Este repositorio parte de un MVP funcionando en producción, validado en un
sector concreto —espectáculo en vivo— durante tres semanas.

**Lo que ya funciona y se hereda:**

| | |
|---|---|
| Lectura de feeds ATOM oficiales, con ventana adaptativa | ✅ |
| Filtro por CPV y control de estado en base de datos | ✅ |
| Filtro por estado del expediente (solo lo que sigue abierto) | ✅ |
| Cribado semántico con LLM, tres salidas y trazabilidad | ✅ |
| Interfaz web generada a diario | ✅ |
| Alerta diaria por correo | ✅ |
| Importación de histórico desde los ZIP de datos abiertos | ✅ |

**Lo que hay que construir:**

| | Horas estimadas |
|---|---|
| Alta guiada: describir negocio → CPV → marcar ejemplos → criterio | 15-25 |
| Usuarios, suscripciones y preferencias | 15-25 |
| Web personalizada por cliente y alojamiento propio | 8-15 |
| Extracción de requisitos del pliego (solvencia) | 8-12 |
| Datos de adjudicatarios: quién ganó, por cuánto | 6-10 |

---

## El resultado medido en el sector de partida

| Etapa | Filas | Filtro |
|---|---|---|
| Capturado de los feeds | ~2.000 | prefijo CPV |
| Vivo | 124 | estado del expediente |
| Relevante | 53 | cribado semántico |
| Mostrado | 34 | regla de vigencia |

**Cero falsos negativos** en la evaluación del cribado, auditando 30
rechazos al azar contra criterio humano. Es el único error que hace daño:
una oportunidad descartada en silencio no vuelve a mirarse nunca.

Como referencia del mercado: un servicio de pago existente entrega veinte
contratos diarios de los que el cliente aprovecha cuatro.

---

## Arquitectura

```
  Feeds ATOM oficiales            ZIP de datos abiertos
  (sindicación PLACSP)            (histórico, por sector)
            │                                │
            ▼                                ▼
  lector_atom.py                  importar_historico.py
   ├─ descarga con reintentos              │
   ├─ parseo CODICE                        │
   ├─ extractor por fuente                 │
   ├─ filtro por prefijo CPV               │
   └─ control de estado                    │
            │                                │
            └────────────┬───────────────────┘
                         ▼
                 Supabase (PostgreSQL)
                 tabla `licitaciones`
                         │
            ├──▶ cribador.py ──▶ veredicto de relevancia
            │
            ├──▶ generar_interfaz.py ──▶ web
            │
            └──▶ alertador.py ──▶ correo
```

Todo se ejecuta en GitHub Actions. No requiere ninguna instalación local ni
servidor propio.

**Tres principios de diseño**, cada uno pagado con un error real
documentado en `DECISIONES.md`:

**La base de datos es la única fuente de verdad.** El repositorio contiene
código y nada más. Se guarda todo, incluido lo ya adjudicado: el ruido de
hoy es inteligencia de mercado mañana. El filtrado se hace al mirar, no al
guardar.

**Los fallos deben ser ruidosos.** Un sistema desatendido que devuelve cero
resultados en silencio es indistinguible de uno que funciona en un mercado
tranquilo. Tres incidentes reales lo confirmaron: una ventana temporal que
cubría dos días creyendo cubrir siete, un indicador que medía lo que no
tocaba, y un guardado que terminaba en verde sin escribir una fila.

**Solo se enseña lo que se puede respaldar.** No saber si una licitación
sigue abierta no es lo mismo que suponer que sí. Sin evidencia —plazo
vigente o haberla visto hace poco— no se muestra.

---

## Ficheros

| Fichero | Función |
|---|---|
| `lector_atom.py` | Lectura de feeds, filtro CPV y control de estado |
| `importar_historico.py` | Carga histórico de un sector desde los ZIP oficiales |
| `cribador.py` | Cribado semántico con LLM |
| `generar_interfaz.py` | Construye la web desde la base de datos |
| `alertador.py` | Alerta diaria por correo |
| `esquema.sql` | Esquema completo y reproducible de la base de datos |
| `requirements.txt` | Dependencias |
| `.github/workflows/scraper.yml` | Programación y configuración |
| `DECISIONES.md` | **Por qué el sistema es como es.** Leer antes de tocar nada |

---

## Puesta en marcha

**1. Base de datos.** Proyecto nuevo en Supabase → SQL Editor → pegar
`esquema.sql` entero → Run. Reconstruye la estructura desde cero.

**2. Credenciales.** En Settings → Secrets and variables → Actions:

| Secret | De dónde sale |
|---|---|
| `SUPABASE_URL` | Project Settings → Data API |
| `SUPABASE_KEY` | Project Settings → API Keys → clave **secreta** |
| `OPENAI_API_KEY` | Clave de un proyecto propio, para medir el gasto aparte |
| `RESEND_API_KEY` | Solo si el envío de correo está activo |
| `DESTINATARIOS_ALERTA` | Solo si el envío de correo está activo |

La clave de Supabase debe ser la secreta, no la pública: con las políticas
de acceso cerradas, la pública no puede escribir.

**3. Configuración.** Todo en `.github/workflows/scraper.yml`, sin tocar
Python. `CPV_PREFIJOS` define el sector vigilado.

**4. Primera carga.** Para trabajar con un sector nuevo hace falta material.
El scraper diario tardaría días en acumularlo, así que se importa histórico:

```
python importar_historico.py --cpv 3581,1883 --anio 2026 --mes 8 --simulacro
```

El simulacro descarga, procesa e informa **sin guardar nada**. Dice cuántas
licitaciones de ese sector existen y enseña una muestra. Quitando
`--simulacro`, las guarda.

---

## Operación

**Ejecución automática:** cada mañana, sin intervención. El planificador de
GitHub no garantiza puntualidad; la ventana adaptativa absorbe las
ejecuciones perdidas.

**Ejecución manual:** Actions → Run workflow, con estos modos:

| Modo | Qué hace |
|---|---|
| `normal` | Ejecución completa |
| `diagnostico` | Lee y mide **sin tocar la base de datos** |
| `solo_cribado` | Clasifica sin releer los feeds |
| `cribado_prueba` | Clasifica 20 y las imprime **sin guardar** |
| `alerta_prueba` | Compone el correo y lo imprime **sin enviarlo** |

Los parámetros `dias_solape` y `max_paginas` permiten una *pasada profunda*
puntual, que relee semanas atrás y refresca estados y plazos. Vacíos, se
usan los valores de siempre: así no hay que acordarse de revertir nada.

**Qué mirar en el registro:**

| Buscar | Significa |
|---|---|
| `Ventana cubierta hasta` | Profundidad real de vigilancia por feed |
| `FRENO DE EMERGENCIA` | ⚠️ Posible hueco sin vigilar |
| `Refrescado el estado de` | Expedientes conocidos actualizados |
| `Guardados N de M veredictos` | ⚠️ Si N ≠ M, se perdió trabajo |

---

## Límites conocidos

- **El criterio de relevancia está escrito a mano** para un sector. Hacerlo
  generable por el propio cliente es el objeto de este repositorio.
- **Los canales principales excluyen los contratos menores** (por debajo de
  15.000 €). Existe un canal específico, ya soportado por el importador
  pero no integrado en el flujo diario.
- **El estado solo se refresca en lo que reaparece** en el feed. Un
  expediente adjudicado que no vuelva conservaría su plazo futuro. Con
  ciclos cortos el refresco lo alcanza; es una probabilidad baja, no una
  imposibilidad.
- **La solvencia remite al pliego en el 23 % de los casos.** Ese contenido
  solo existe en PDF, y es el que responde a "¿puedo presentarme?".
- **No hay datos de adjudicatario.** Están en el feed y no se extraen
  todavía. Es lo que permitiría enseñar quién ganó y por cuánto.
- **La web lleva los datos incrustados** y es igual para todos. Con clientes
  distintos habrá que consultar la base desde el navegador, lo que obliga a
  escribir políticas de acceso reales. Es la parte donde un error es una
  fuga de datos.

---

## Antes de dar de alta a un tercero

Requisitos, no mejoras: baja en un clic, política de privacidad accesible y
dominio verificado en el proveedor de correo. En cuanto se trate el correo
de una persona ajena, aplica el RGPD.

---

## Historia

Este sistema nació como MVP en un programa de fellowship, construido en tres
semanas por alguien sin experiencia previa en programación, trabajando con
un asistente. `DECISIONES.md` recoge las 32 decisiones de arquitectura con
su motivo, los datos que las respaldan y —lo más útil— las que hubo que
rectificar.
