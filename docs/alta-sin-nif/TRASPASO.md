# Alta sin NIF: traspaso de la sesión del 04/10/2026

Lo esencial para seguir en otra sesión. Complementa a [LEEME.md](LEEME.md)
(léelo primero: el problema, la historia y las reglas siguen valiendo).
Sin nombres ni NIF: el repositorio es público. Los perfiles del banco van
como P01, P02… (orden por contratos ganados, el de `simular_sin_nif.ts`).

## 1. De dónde sale esto

Sin betatesters suficientes para dar feedback del alta sin NIF, se miró
cómo lo hacen los competidores (Tendios, Stotles, Tussell, HigherGov,
GovSpend, Jorpex, Awardly, Tendly, Licita-ia, LicitaPilot, El Vínculo y
otros). Lo que salió:

- **Casi nadie da de alta por NIF.** Lo habitual es que el cliente monte
  su filtro (palabras clave, CPV, exclusiones) y lo afine durante 2–4
  semanas. Los nuevos con IA piden **la URL de la web** y sacan de ella
  el perfil, que el cliente revisa. Los caros lo montan con una persona.
  El más parecido a nosotros (El Vínculo) usa lo ganado más lo que cuenta
  el cliente, con su equipo técnico.
- Todos venden que «la lista aprende de lo que marcas» y explican por
  qué encaja cada contrato.

Propuestas que salieron, y lo que decidió el dueño:

| # | Propuesta | Decisión |
|---|---|---|
| 1 | Pedir la web como entrada del alta | **Sí.** Medida (sección 3). Falta diseñarla en el alta |
| 2 | Alta acompañada por una persona durante la beta | **No** |
| 3 | Que las correcciones cambien el historial sintético (y el grupo), no solo al juez | Sí si los números lo respaldan. Preparada, sin fusionar |
| 4 | Decir por qué salió cada contrato | **Sí, desplegada** (sección 2) |
| — | Aviso de que la lista aprende con las correcciones | **Sí, sin cifra** («20 es muchísimo»). Preparado, sin desplegar |

Otras ideas vistas en competidores, apuntadas y no hechas: varias alertas
por empresa (una por línea de negocio; resolvería el caso P07 del 01/10),
subir un documento si no hay web, probar antes de registrarse.

## 2. Lo que ya está en producción

**Propuesta 4** ([vincent-vegga/StateScraperv2#28](https://github.com/vincent-vegga/StateScraperv2/pull/28), fusionado):

- Migración `parecido_en_veredictos` (aplicada): `veredictos.parecido` y
  la vista `mis_oportunidades` con esa columna al final.
- `puntuador.py` guarda en `parecido` el contrato del historial que más
  se parece a cada uno del grupo (mismos vectores que los ejemplos del
  juez, sin llamar al modelo), para todo el grupo en cada pasada.
- `web/index.html`: al pulsar «no me interesa», «Te lo enseñamos porque
  se parece a «…», un contrato que ganaste / un contrato de otra empresa
  parecido a lo que nos contaste de la tuya». Nada nuevo en la lista.
- **No se usa `veredicto_motivo`**: sin NIF, el juez escribe «similar a
  los contratos ganados» de una empresa que no ha ganado ninguno.
- Pasada manual del puntuador tras desplegar: 21 perfiles, 0,055 $. El
  94 % de lo vivo en las listas tiene `parecido` (el resto son veredictos
  de pasadas anteriores fuera del grupo de hoy).

Apuntado como decisión 46. El aviso (abajo) se desplegó el 06/10/2026
(#31) y es la decisión 47.

## 3. La medición del 04/10 (tanda 1)

Rama `simulacion-web`, ejecución 37218562719 de Actions. 8,31 $.
11 empresas medidas: **P02, P08 y P14 fallaron en la exportación**
(«Error» genérico, sección 5). P03, P06 y P09 no tienen web legible
(web hecha con JavaScript, 379 caracteres, y una que no se pudo leer).

**Ruido** (`limpio_desc` dos veces): como mucho 0,02 en recupera y 0,05
en bueno por empresa, casi siempre 0,00. El banco distingue mejor de lo
que temía la sección 6.4 del LEEME: 0,10 en una empresa es real.

**Web** (F1 de las 8 con web legible):

| Perfil | Producción (`limpio_desc`) | Solo web | Web + descripción |
|---|---|---|---|
| P01 | 0,74 | 0,59 | 0,67 |
| P04 | 0,77 | 0,77 | 0,79 |
| P05 | 0,55 | 0,65 | 0,71 |
| P07 | 0,33 | 0,30 | 0,32 |
| P10 | 0,57 | 0,59 | 0,58 |
| P11 | 0,24 | 0,23 | 0,56 |
| P12 | 0,54 | 0,08 | 0,50 |
| P13 | 0,44 | 0,62 | 0,64 |
| **Media** | **0,52** | **0,48** | **0,60** |

- Sola, la web es peor (una web que es un catálogo enorme lo trae
  todo). **Como complemento de la descripción, +0,07**: mejor en 4,
  peor en 2, empate en 2.
- Probablemente se subestima: la descripción simulada tiene la fuga de
  siempre (sale de `perfiles.descripcion`, escrita leyendo sus
  contratos). Razonado, no medido.

**Correcciones** (frente a producción sin los mismos contratos marcados;
las medias de la tabla del registro NO son comparables, solo «mejor /
peor en»):

| Variante | Mejor en | Peor en |
|---|---|---|
| `corr10_hoy` (motor de hoy) | 5 | 1 |
| `corr5_nuevo` | 5 | 2 |
| `corr10_nuevo` | 5 | 1 |
| `corr20_nuevo` | 5 | 2 (ΔF1 medio +0,06) |

Con 10 marcas, el motor de hoy y el nuevo empatan. Con 20, el nuevo trae
lo que el alta dejó fuera (P05 recupera 0,35 → 0,60; P06 0,37 → 0,51),
pero falta **el motor de hoy con 20** para saber si es el motor o solo
marcar más. Eso es la tanda 2.

Dos fallos del informe de la tanda 1, ya arreglados en el código: la
variante `web` pisaba el campo `web` de cada fila (la tabla «solo con web
legible» contaba las 11), y las medias de correcciones no quitan los
marcados a la base.

## 4. Lo pendiente, rama por rama

**Estado al 06/10/2026.** El commit de la tanda 2 no llegó a subirse
desde Windows; se rehízo en Mac a partir de esta sección (cf5ab4e) y la
tanda 2 está en marcha (ejecución 37436528853, aprobada: ~4,5 $, tope
6 $). `aviso-entrenar-lista` ya está desplegada (#31). La tabla de
abajo es la del 04/10.

Cada rama tenía su worktree al lado del repositorio (en Windows).

| Rama | Worktree | Estado | Qué falta |
|---|---|---|---|
| `simulacion-web` | `../StateScraperv2-simweb` | Tanda 2 preparada, **commit local sin subir** | El sí del dueño a **~4,5 $ (tope 6 $)**. Subir la rama la lanza sola |
| `correcciones-al-historial` | `../StateScraperv2-corr` | Propuesta 3 en `puntuador.py`, commit local, probada en seco | Decidir con la tanda 2. Si va: PR, LEEME sección 2 («Un límite estructural») y DECISIONES |
| `aviso-entrenar-lista` | `../StateScraperv2-aviso` | Aviso sin cifra y bienvenida corregida, 2 commits locales | El sí del dueño para desplegar (no depende de la tanda 2) |
| `explicar-no-me-interesa` | `../StateScraperv2-explicar` | Fusionada (#28) | Se puede borrar el worktree |

**Tanda 2** (`.github/workflows/medir-sintetico.yml` en `simulacion-web`):
`N_MARCAS=20`, `MARCAS_HOY=20`, `SIN_BIS=1`, `WEB_SOLO=P02,P08,P14`,
`MAX_GASTO=6`. Mide `limpio_desc`, `corr20_hoy` y `corr20_nuevo` en las
14, y la web solo en las tres que fallaron. Solo se dispara con push a
`simulacion-web`.

**Propuesta 3** (`historial_corregido` en `puntuador.py`, solo sin NIF):
un «me interesa» entra en el historial sintético; sale el ejemplo que se
parece a un «no me interesa» (≥ `SIM_CORRECCION`, 0,55) más que a
cualquier «me interesa»; si quedaran menos de `minimo_ganados`, se queda
el del alta. Es lo mismo que mide `corrN_nuevo`. Sin migración.

**Aviso** (solo sin NIF): encima de la lista, «Tu lista sale de lo que
nos contaste… Lo que más la afina son tus primeras correcciones… Llevas
3.» (cuenta en la base, sube al corregir). La bienvenida ya no le dice
que su filtro sale de «los contratos que has ganado». Usa la misma clave
`sin-explicacion` del navegador: quien cerró la explicación antigua no
verá la nueva.

## 5. Cómo diseñar la propuesta 1 en el alta (lo medido es `web_desc`)

- La web **acompaña** a la descripción, no la sustituye.
- Lectura (como `leerWeb` en `scripts/simular_sin_nif.ts`): portada y
  hasta 6 páginas propias que parezcan contar qué hace; **User-Agent de
  navegador** (con uno propio, algunas webs dan 403); hasta 15.000
  caracteres, **reparados con `toWellFormed()`**; menos de 300
  caracteres = sin web.
- Lo que pasará en producción: webs con certificado roto (solo `http`),
  webs hechas con JavaScript (sin texto), bloqueos de bots.
- Extracción (`webComoCliente`): a qué se dedica y de 3 a 8 líneas, sin
  clientes, organismos, zonas ni cifras (regla del «qué» frente al
  «dónde / a quién»).
- Familias propuestas con descripción + web; búsqueda **por línea**
  (`[descripción, ...líneas de la web]`); el filtro y el juez ven la
  descripción + lo de la web.
- Todos los competidores enseñan al cliente lo que sacaron de su web
  para que lo corrija. Encaja aquí.
- Antes: averiguar por qué fallaron P02, P08 y P14 (la tanda 2 registra
  el código de estado y la línea, sin datos). Son tres de las pymes, las
  más parecidas al cliente sin NIF real. El banco tiene varias empresas
  grandes, con webs que no se parecen a lo que ganan.

## 6. Cosas prácticas

- **Webs del banco:** en el secreto `SIM_WEBS` del repositorio (JSON
  `{"<NIF>": "https://..."}`). GitHub no deja leer un secreto: hay una
  copia en `../StateScraperv2-privado/SIM_WEBS.json`, **fuera del
  repositorio**.
- **Crear el secreto desde bash, no desde PowerShell**: PowerShell le
  añadió un BOM y la primera ejecución falló citando el principio del
  valor en el registro público. Esa ejecución se borró. El script ya
  quita el BOM y no cita el secreto si falla.
- **`gh`** está instalado en `C:\Program Files\GitHub CLI\gh.exe`, con
  sesión iniciada.
- En local no hay Deno ni claves: todo se ejecuta en Actions. Para
  pruebas en seco de Python hay que usar un entorno con numpy.
- Gasto de OpenAI de la sesión: 8,31 $ (tanda 1) + 0,055 $ (pasada del
  puntuador).
- LEEME (secciones 6.4 y 8) y DECISIONES (46 y 47) actualizados el
  06/10.
