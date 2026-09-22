# Pendientes tras la auditoría del 21/09/2026

Ocho asuntos detectados durante la auditoría previa a la beta que **no se
arreglaron a propósito**: por falta de tiempo, porque dependen de una
decisión de producto, o porque arreglarlos tenía más riesgo que dejarlos.
Cada uno explica qué pasa, cómo se detectó, dónde vive en el código y qué
haría falta para cerrarlo.

Contexto útil para cualquier sesión nueva:

- Base de datos en Supabase (proyecto `swgrbzqxagrqdyddmvfy`, plan Pro,
  instancia **Micro, 1 GB de RAM** desde el 21/09/2026 por la noche; hasta
  entonces estaba en **Nano, 0,5 GB**, sin que se supiera). La tabla
  `licitaciones` tiene ~1,2 millones de filas y ~2,5 GB.
- Las llamadas por la API (PostgREST) cortan a los **8 segundos**. Lo que
  tarde más tiene que ir por `pg_cron`, dentro de la base.
- El scraper corre en GitHub Actions (`.github/workflows/scraper.yml`). GitHub
  retrasa el cron: las pasadas "de las 06:00 UTC" arrancan hacia las
  10:30-11:15. Los agregados de `pg_cron` van a las 14:00-14:30 UTC por eso.
- El correo diario está apagado a propósito durante la beta
  (`if: env.MODO == 'nunca'` en el workflow). No es una avería.

---

## 1. `resumen_cpv` no se recalcula: agota el tiempo de la API

**Qué pasa.** Al terminar cada mes del catálogo histórico,
`procesar_historico.py` llama a `refrescar_resumen()` (línea ~650), que pide
por RPC `refrescar_resumen_cpv`. Con la tabla del tamaño actual tarda más de
8 s y la API la corta. En el registro aparece:

```
ERROR | No se pudo recalcular el resumen: The read operation timed out
```

El paso sigue en verde porque el error se captura y solo se anota.

**A qué afecta.** La tabla `resumen_cpv` (y la vista `resumen_cpv_total`) la
usa la función de alta (`supabase/functions/alta/index.ts`, líneas ~723 y
~743) para enseñar cuántos contratos al año trae cada familia CPV cuando un
cliente se da de alta **sin NIF** y describe su negocio. Si no se recalcula,
esas cifras se quedan con los valores de la última vez que funcionó: salen
desfasadas, no rotas.

**Cómo cerrarlo.** Igual que se hizo con los demás agregados
(`supabase/migrations/20260920235000_agregados_por_cron.sql` y
`20260921150000_agregados_despues_del_scraper.sql`): programar
`select public.refrescar_resumen_cpv()` en `pg_cron`, por ejemplo a las
14:40 UTC, detrás de los otros refrescos, y quitar la llamada RPC de
`procesar_historico.py` (o dejarla, sabiendo que fallará siempre). Antes,
medir cuánto tarda la función dentro de la base para elegir la hora.

---

## 2. Avisos de Node.js 20 en los workflows

**Qué pasa.** Cada ejecución avisa:

```
Node.js 20 is deprecated. The following actions target Node.js 20 but are
being forced to run on Node.js 24: actions/checkout@v4, actions/setup-python@v5
```

No es un fallo: GitHub ya las ejecuta con Node 24 y funcionan. Pero cuando
retire Node 20 del todo podrían dejar de funcionar.

**Dónde.** `.github/workflows/scraper.yml` (`actions/checkout@v4`,
`actions/setup-python@v5`, `actions/cache/restore@v4`,
`actions/cache/save@v4`) y `.github/workflows/desplegar-funciones.yml`
(`actions/checkout@v4`, `supabase/setup-cli@v1`).

**Cómo cerrarlo.** Subir cada acción a la versión mayor que ya use Node 24
(comprobar en el repositorio de cada acción cuál es) y lanzar una pasada en
modo `diagnostico` para verificar que todo sigue igual.

---

## 3. Adjudicaciones republicadas pueden contarse dos veces en los agregados

**Qué pasa.** Las plataformas republican el mismo expediente con otro
identificador de sindicación. Desde el 21/09/2026 la columna
`licitaciones.sustituida` marca las copias viejas (por órgano y
expediente, gana la de `fecha_actualizacion` más reciente; lo mantiene el
disparador `trg_sustituidas`, ver
`supabase/migrations/20260921190000_licitaciones_sustituidas.sql`). Esa
marca se respeta en la lista de la web, "Mi cuenta", el cribado y el
correo. **No** se respeta en las ~25 funciones que agregan adjudicaciones:
fichas de empresa y organismo, rankings, Movimientos y los refrescos
nocturnos (`refrescar_organismos`, `refrescar_empresas`,
`refrescar_catalogo_empresas`, `movimientos_mercado`, `pulso_mercado`,
`competencia`, `ficha_empresa`, `ficha_organismo`, `buscar_empresa`, etc.).

**Cuánto pesa.** Medido el 21/09/2026: 292 adjudicaciones duplicadas de
965.986 (0,03 %); en los últimos 30 días, que es lo que enseña
Movimientos, 35 de 7.638 (0,46 %). Unos 100 M€ de importe duplicado en
total.

**Por qué no se hizo.** Añadir `and not sustituida` a 25 funciones, varias
con cachés y refrescos encadenados, tenía más riesgo de romper algo que
beneficio por medio punto porcentual.

**Cómo cerrarlo.** Revisar función por función (sacar la lista con
`pg_get_functiondef` buscando `adjudicatario_cif` o `adjudicaciones`),
añadir el filtro y rehacer los agregados. Hacerlo junto con cualquier otro
trabajo sobre las pasadas o los agregados, no suelto.

---

## 4. La verificación de "1.000 expedientes en seguimiento" no puede cumplirse

**Qué pasa.** Cada pasada del scraper pide a la base
(`pendientes_de_verificar`, llamada en `lector_atom.py` línea ~94) hasta
1.000 contratos que se están enseñando a algún cliente y que llevan días
sin "verse" en el feed. `recorrer_feed` (línea ~1687) sigue bajando páginas
hasta encontrarlos todos, aunque se salga de la ventana, hasta el tope de
páginas. Los que no aparecen se marcan como no verificados, y en la web, a
los 90 días, salen con "Sin movimiento desde hace N días · comprueba en el
expediente".

**El fallo de la idea.** El feed solo vuelve a publicar un contrato
**cuando cambia**. Uno que sigue abierto sin cambios no reaparece nunca. En
las pasadas del 21/09/2026: "Verificados 347 de 1000" en el 643 y "114 de
1000" en el 1044. El recorrido llega siempre al tope de 25 páginas.

**Lo que sí funciona.** El objetivo real (no enseñar como abierto algo ya
adjudicado) lo cubre el refresco normal: si se adjudica, cambia, aparece en
las páginas recientes y se refresca.

**Por qué no urge.** Desde la caché de páginas revalidada (commit
`460d84e`) releer esas páginas cuesta segundos, no minutos. El efecto que
queda es marcar como sospechosos contratos que no han cambiado.

**Cómo cerrarlo (propuesta, no decidida).** Dejar de forzar el recorrido
por ellos y no marcarlos como "no verificados" solo por no reaparecer. Si
se quiere una verificación real, hacerla por expediente contra la
Plataforma (está en la deuda técnica de `DECISIONES.md`: "Verificación de un
expediente concreto sin esperar al feed").

---

## 5. El feed estatal (643) está parado en origen desde el 17/09/2026

**Qué pasa.** Hacienda no actualiza
`sindicacion_643/licitacionesPerfilesContratanteCompleto3.atom` desde el
**17/09/2026 a las 18:22 GMT** (comprobado en los dos dominios,
`contrataciondelsectorpublico.gob.es` y `contrataciondelestado.es`, con el
mismo `Last-Modified`). La dirección oficial en la página de datos abiertos
de Hacienda no ha cambiado. Desde ese día **no entran contratos nuevos del
Estado**; el feed autonómico (1044) sí está al día.

**Qué se hizo.** Una alarma: si la primera página de un feed lleva más de
72 h sin cambiar, `comprobar_feed_vivo` (`lector_atom.py` línea ~1629) lo
anota y el paso final "Avisar de feeds parados" del workflow pone la
ejecución en rojo. Por eso las pasadas salen en rojo mientras dure: es a
propósito. El resto de pasos se ejecuta igual.

**Cómo cerrarlo.** Depende de Hacienda. Cuando las pasadas vuelvan a verde,
el feed se ha reactivado. Si tarda mucho: buscar si han publicado otra
dirección, o recuperar el hueco con los ZIP mensuales del catálogo
(`catalogar_historico`, conjunto 643, mes en curso) en cuanto aparezcan.

---

## 6. Histórico hasta 2021 y contratos menores (1143)

**Lo que hay cargado** (21/09/2026):

| Conjunto | Años | Filas aprox. |
|---|---|---|
| 643 (Estado) | 2024 completo, 2025, 2026 ene-sep | ~495.000 |
| 1044 (autonómicas) | 2024, 2025, 2026 ene-sep | ~175.000 |
| 1143 (contratos menores) | solo 2025 | ~542.000 |

2024 del 643 está completo (152.504 filas, los 12 meses). Se cargó a
trozos: marzo-septiembre por la tarde (con fallos por sobrecarga en Nano),
y enero, febrero, octubre, noviembre y diciembre la noche del 21/09/2026,
de uno en uno, ya en Micro: 11-18 minutos por mes, sin errores, y la API
respondiendo en 0,2-0,6 s durante la importación. Reprocesar un mes es
seguro: las inserciones ignoran lo existente y el completado solo rellena
huecos.

**Lo que faltaría hasta 2021:** 643 de 2021 a 2023 (~660.000 filas), 1044 de
2021 a 2023 (~165.000), 1143 de 2021 a 2024 y 2026 (~2,5 millones). Los ZIP
mensuales existen para todos esos años (comprobado: son ZIP de verdad), y
el workflow `catalogar_historico` los procesa sin cambios.

**Lo que se aprendió al cargar 2024:**

- En **Nano (0,5 GB)**, dos meses del 643 a la vez saturaron la base:
  bloqueos, tiempos agotados, la web con errores 500 y consultas de 1-2 s
  que pasaban de 3 minutos. Octubre falló.
- En **Micro (1 GB)**, de noche y de mes en mes, cada mes tardó ~11 minutos
  y la API siguió respondiendo en 0,2-0,6 s.

**Recomendación.** Cargar 643 y 1044 hasta 2021 (la base se quedaría en
~5,5 GB, dentro de los 8 GB del plan) **de noche y de mes en mes**, y medir
la web tras las primeras noches. Con todo el histórico, los índices (~1,4
GB) no caben en 1 GB de RAM: lo prudente es la instancia **Small (2 GB)**.
Los menores (1143) son el 70 % del crecimiento y su integración es una
decisión de producto pendiente (ver deuda técnica en `DECISIONES.md`):
no cargarlos sin decidirlo.

**Para importar sin tocar el código:** lanzar un mes por ejecución
(`gh workflow run scraper.yml -f modo=catalogar_historico -f conjunto_xml=643
-f catalogo_anio=2023 -f catalogo_meses=1`) y esperar a que acabe antes del
siguiente. El workflow no deja encolar más de una ejecución pendiente. Si se
quiere automatizar, poner `max-parallel: 1` en el trabajo `catalogar` y
tandas más pequeñas en `completar_explicacion` (`procesar_historico.py`).

---

## 7. El cribado de la web al darse de alta usa 20 llamadas simultáneas

**Qué pasa.** La cuenta de OpenAI admite unas 500 clasificaciones por minuto
(500 peticiones y 200.000 tokens por minuto, a ~400 tokens cada una). En el
scraper se bajó de 20 a 8 hilos (commit `7d3f643`): con 20 se pedían ~800
por minuto y hubo 5.812 errores 429 en una pasada. La función de alta
(`supabase/functions/alta/index.ts`, `const SIMULTANEAS = 20`, línea ~51)
sigue con 20, y usa la misma cuenta de OpenAI. Si un cliente se da de alta
mientras corre el cribado del scraper, compiten y los dos van peor.

**Además.** El 21/09/2026 se agotó el límite **diario** (10.000 peticiones,
nivel 1 de OpenAI) a las 13:33 UTC. Se subió de nivel ese mismo día; con el
nivel 2 ese límite diario desaparece para `gpt-4o-mini`. Comprobar el nivel
en platform.openai.com/settings/organization/limits.

**Cómo cerrarlo.** Bajar `SIMULTANEAS` de la función de alta a 8 (o menos)
y desplegar (el workflow `desplegar-funciones.yml` lo hace solo al cambiar
`supabase/functions/`). El alta de un cliente nuevo tardará algo más, pero
fallará menos.

---

## 8. Sistemas dinámicos de adquisición (SDA) de 2024 aparecen como abiertos

**Qué pasa.** Del histórico 643 de 2024 salen contratos en estado `PUB` con
plazo en 2026-2027. Comprobados en la Plataforma el 21/09/2026 dos de ellos:

- Diputación de Badajoz, expediente 692/23 (pienso y bloques minerales):
  en la Plataforma está en **"Evaluación Previa"**; "Fecha fin de
  presentación de solicitud: 09/02/2024"; "Vigencia del sistema dinámico de
  adquisición: 09/02/2027".
- Ayuntamiento de Alcobendas (SDA de productos de limpieza): **"Evaluación
  Previa"**; fin de presentación 08/05/2024; vigencia 09/04/2027.

En la base los dos tienen `estado_licitacion = 'PUB'` y `fecha_limite` =
la vigencia (2027).

**Dos causas distintas:**

1. **Estado desfasado.** El histórico guarda el estado que tenía el
   expediente en el fichero de ese mes (enero de 2024: publicado). El
   scraper solo refresca lo que reaparece en el feed, y estos no han
   vuelto a cambiar. Afecta a todo el histórico, no solo a los SDA.
2. **La fecha límite es la vigencia del sistema.** Hipótesis por verificar
   con el XML: `extraer_fecha_limite` (`lector_atom.py` línea ~1022) busca
   primero `TenderSubmissionDeadlinePeriod` y después
   `ParticipationRequestReceptionPeriod`; en los SDA la Plataforma parece
   publicar la vigencia en el primero y el plazo de solicitudes en el
   segundo, así que gana la vigencia.

**El matiz de producto.** En un SDA, la ley permite que cualquier empresa
pida la admisión durante toda su vigencia, así que en cierto sentido sí
siguen "abiertos" hasta 2027. Pero la web los enseña con "Plazo: 2027" y
estado publicado, como un contrato normal, y eso induce a error.

**Cómo cerrarlo.** Primero decidir: ¿un SDA vigente es una oportunidad? Si
sí, enseñarlo aparte ("Sistema dinámico: admisión abierta hasta …") con la
vigencia como tal y no como plazo. Si no, excluirlos cuando haya pasado el
plazo de solicitudes. En los dos casos, verificar antes la hipótesis de la
fecha con el XML de uno de ellos y medir cuántos hay: el 21/09/2026 salían
133 contratos "vivos" del histórico de 2024 (100 sin fecha límite y 33 con
plazo futuro), además de 520 de 2025.

---

## 9. Varias empresas por cuenta: lo que quedó fuera (22/09/2026)

La función (hasta 3 NIF por cuenta, `20260922100000_varias_empresas.sql`)
se hizo con lo mínimo para la prueba con betatesters. Queda:

- **Un correo por empresa.** `alertador.py` recorre perfiles, así que quien
  lleve 3 empresas recibiría 3 correos al mismo buzón. Hoy no importa: el
  correo está apagado en la beta. Antes de encenderlo, agrupar por
  `usuario_id` en un solo correo con una sección por empresa.
- **Sin vuelta atrás a mitad del alta.** Al añadir una empresa, la pantalla
  del NIF tiene "Cancelar", pero las siguientes (confirmar, describir,
  entrenar, cribando) no enseñan el selector. Quien se arrepienta ahí tiene
  que terminar o recargar la página (entonces vuelve a esa empresa a medias).
- **Sin contador de novedades por empresa en el selector.** El boceto lo
  tenía ("4 nuevos"); pide una consulta por empresa en cada carga y se dejó
  para después de medir la carga.
- **Coste del cribado.** Cada empresa se criba aparte con el modelo: una
  cuenta con 3 cuesta como 3 clientes.
- **Respaldo.** Las definiciones anteriores de las 21 funciones reescritas
  están en `public.respaldo_funciones_20260922`. Para volver atrás, ejecutar
  cada `definicion` de esa tabla.
