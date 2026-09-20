# Base de datos: qué hay aquí y cómo se ejecuta

Todo lo de este directorio se ejecuta desde el **SQL Editor** del panel de
Supabase: https://supabase.com/dashboard/project/swgrbzqxagrqdyddmvfy/sql

Abres el fichero, copias el contenido, lo pegas y pulsas **Run**.

---

## Estado a 20/09/2026

### Ya aplicado (no hay que hacer nada)

| Fichero | Qué hizo |
|---|---|
| `migrations/20260920120000_revocar_execute_publico.sql` | Cerró 53 funciones que cualquiera podía llamar sin cuenta |
| `migrations/20260920120100_perfil_ajeno.sql` | Impide pedir el perfil de otro pasando su UUID |
| `migrations/20260920130000_viabilidad_dependencias.sql` | Arregló `permission denied for function incumbencia` |
| `migrations/20260920140000_autovacuum_licitaciones.sql` | Evita que la tabla vuelva a quedarse sin estadísticas |
| `migrations/20260920140100_indice_licitaciones_vivas.sql` | Índice para las 4.517 licitaciones vivas |
| `migrations/20260920140200_pendientes_de_perfil_rapida.sql` | Pantalla principal: 23,6 s -> 1,4 s |

Además se ejecutó a mano, una vez: `ANALYZE` y `VACUUM` sobre
`public.licitaciones`. Eso solo ya bajó `count(*)` de 50,8 s a 1,37 s.

### Pendiente, por orden de urgencia

**1. `migrations/20260920150000_indice_vivas_con_prefijos.sql` — LO MÁS IMPORTANTE**

`arrancar()` en web/index.html llama a `pendientes_de_perfil` dentro de
una carrera contra un timeout de 4 segundos, en CADA entrada a la
aplicación. Medido el 20/09/2026: **4.807 ms con la caché fría**, o sea
que la pierde. Cuando la pierde, el usuario entra sin que se haya
cribado lo pendiente y puede ver la lista vacía.

Necesita subir el límite de tiempo antes (ver más abajo), porque el
índice tarda varios minutos en construirse.

**2. Decidir qué hacer con `idx_licitaciones_titulo_trgm` — 407 MB**

ACTUALIZACIÓN 20/09/2026: la lentitud que motivaba este índice ya está
resuelta sin trigramas (ver `20260920170000_palabras_titulo.sql`), así
que la balanza se inclina a borrarlo. Verificado a conciencia antes de
decirlo: ninguna de las 42 funciones ni de las 9 vistas usa operadores
de trigramas, ningún código cliente menciona `titulo_normal`, y el
contador de usos lleva a cero desde que existe la base.

Y conviene recordar que borrar un índice NO toca datos: la columna
`titulo_normal` se queda como está. Si alguna vez hiciera falta, se
reconstruye en minutos.


Es el índice más grande de la tabla y tiene **0 usos en toda la vida de
la base** (`stats_reset` es null, el contador es fiable). Es GIN de
trigramas sobre `titulo_normal`, pero `incumbencia` compara títulos con
`parecido_util()`, que es solapamiento de palabras: ese índice no puede
entrar.

NO es una decisión obvia, y conviene no despacharla como "índice
muerto". Medido el 20/09/2026 sobre un grupo de 5.365 contratos:

  · filtrar por trigramas EN LUGAR de parecido_util ....... 537 ms
  · parecido_util (el criterio actual) ................. 10.758 ms
  · trigramas COMO PREFILTRO + parecido_util ........... 10.384 ms

O sea: como prefiltro no sirve de nada, porque en grupos grandes el 90%
de los contratos pasa el filtro y no hay nada que descartar. Solo
serviría si los trigramas SUSTITUYERAN a parecido_util como criterio,
y eso cambia qué entiende el producto por "convocatoria parecida".

Así que la pregunta no es técnica sino de producto:

  · Si el criterio se queda como está -> son 407 MB de peso muerto que
    encarecen cada escritura del scraper. Borrarlo.
  · Si algún día el parecido pasa a ser por trigramas -> el índice ya
    está construido y es 20 veces más rápido. Conservarlo.

Mientras tanto, la lentitud que motivaba esto ya está resuelta por otra
vía (ver `20260920160000_incumbencia_rapida.sql`).

```sql
-- solo si se decide lo primero:
drop index concurrently if exists public.idx_licitaciones_titulo_trgm;
```

**3. `migrations/20260920140400_indices_sobrantes.sql`**

Borra dos índices duplicados exactos. Sin prisa, pero acelera al scraper.

Los duplicados exactos ya se borraron el 20/09/2026. Lo que queda en
ese fichero son los candidatos nunca usados, que conviene revisar tras
unos días con betatesters dentro.

### Marcha atrás

`migrations/REVERTIR_20260920.sql` deshace los permisos si algo se rompe.
**Reabre los agujeros de seguridad**: es freno de emergencia, no solución.

### Auditoría

`auditoria/auditoria_rls.sql` — consultas de solo lectura para comprobar
el estado de permisos y políticas cuando quieras.

---

## Cómo subir el límite de tiempo

No hace falta para nada de lo que queda pendiente, pero se deja anotado:
cualquier operación larga sobre `licitaciones` (crear un índice, un
`VACUUM` a mano) se corta por el límite de tiempo de la sesión. Para
esos casos, **en la misma pestaña y antes** de lanzar la operación:

```sql
set statement_timeout = '30min';
```

Ejecuta esa línea sola. Luego, **en esa misma pestaña**, pega y ejecuta
el `create index concurrently ...` del fichero.

El ajuste dura solo lo que dure esa conexión. No cambia nada global y no
hace falta deshacerlo.

Un par de avisos sobre ese índice concreto:

- `CREATE INDEX CONCURRENTLY` **no puede ir dentro de una transacción**.
  Ejecútalo como única sentencia, sin `begin`/`commit` alrededor.
- Si se corta a medias deja un índice **inválido**, que ocupa espacio y
  se mantiene en cada escritura pero no sirve para consultar. Comprueba
  siempre después:

```sql
select c.relname, i.indisvalid
from pg_index i join pg_class c on c.oid = i.indexrelid
join pg_class t on t.oid = i.indrelid
where t.relname = 'licitaciones' and not i.indisvalid;
```

Si devuelve algo, bórralo antes de reintentar:

```sql
drop index concurrently if exists public.idx_licitaciones_adjudicatario_trgm;
```

---

## Decisión tomada el 20/09/2026: no se busca por nombre

Hubo un índice de trigramas propuesto para acelerar la búsqueda de
empresa por nombre, que tardaba 12 s contra un límite de 8 y fallaba
siempre con nombres poco comunes. **Se descartó y se quitó la función
de la interfaz**, junto con `pantallaPorNombre` en `web/index.html`.

El razonamiento: la búsqueda por NIF es exacta, va por
`idx_licitaciones_cif` y tarda 73 ms. Si no encuentra contratos, es que
no los hay — no que la búsqueda se haya quedado corta. Ofrecer un
rescate por nombre era añadir un camino lento para disimular un
resultado que en realidad era correcto.

Quien no tenga historial va ahora directo a `pantallaDescribir`.

Queda un resto: la Edge Function `alta` todavía acepta `empresa` en el
cuerpo de la petición y ejecutaría esa consulta lenta si alguien la
llamara a mano. La interfaz ya no lo hace nunca. Cerrarlo del todo es
quitar el parámetro `nombre_buscado` de la llamada en
`supabase/functions/alta/index.ts:590`, lo que obliga a redesplegar la
función.

---

## Vigilancia después de la sesión de betatesters

```sql
-- ¿Autovacuum ha entrado ya? Debería dejar de dar cero.
select relname, n_live_tup, n_dead_tup,
       autovacuum_count, autoanalyze_count, last_autoanalyze
from pg_stat_user_tables where relname = 'licitaciones';

-- ¿Qué índices no usa nadie? (mirar tras unos días de uso real)
select indexrelname, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) as tamano
from pg_stat_user_indexes where relname = 'licitaciones'
order by idx_scan, pg_relation_size(indexrelid) desc;
```

Y en el panel, los timeouts se ven en **Logs → Postgres**, buscando
`canceling statement due to statement timeout`. El 19/09 había 153.

---

## Viabilidad, guardada en el cajón (20/09/2026)

La pestaña está **escondida, no borrada**. El interruptor es
`VIABILIDAD_VISIBLE` en `web/index.html`, junto a `ZONA`. Poniéndolo en
`true` vuelve exactamente como estaba.

Se cerraron las TRES entradas que tenía, no solo la pestaña:

1. El botón de la barra de navegación.
2. El botón "Analizar viabilidad" dentro de cada oportunidad.
3. La restauración de estado guardado, que devolvía a esa pantalla a
   quien la tuviera abierta al recargar.

No se ha tocado nada más: `pantallaViabilidad` sigue en el fichero, y
en la base siguen `viabilidad`, `incumbencia` y `ediciones_anteriores`
con sus permisos.

### Por qué se esconde

No es por rendimiento, que está resuelto (`incumbencia` 370 ms en el
peor caso, `ediciones_anteriores` 1,9 s). Es porque **el criterio de
emparejamiento no discrimina**: en grupos grandes de un mismo órgano y
familia CPV, el 90% de los contratos pasa el filtro de parecido (4.845
de 5.365 medidos). Decir "X ha ganado 8 de las últimas 10 convocatorias
de este contrato" cuando son diez contratos distintos es peor que
callar.

Y falta histórico: hay desde septiembre de 2021.

### Cabo suelto: la sección nueva nunca se vio en pantalla

La lista de convocatorias anteriores se conectó (commit b02246f), se
desplegó y **no llegó a verificarse visualmente**. El SQL sí está
comprobado: 60 licitaciones contrastadas contra la versión anterior,
46 filas por versión, cero diferencias.

Al buscarla no aparecía, y lo más probable es simple estadística: solo
el **39%** de las licitaciones vivas tiene convocatorias anteriores
(78 de 200 muestreadas al azar), así que pinchando dos o tres es fácil
no ver ninguna.

Pero NO está descartado que haya un fallo de pintado. Al retomarlo,
poner `VIABILIDAD_VISIBLE = true` y probar con una licitación que se
sepa que tiene anteriores:

    select l.id_licitacion, l.titulo,
           (select count(*) from public.ediciones_anteriores(l.id_licitacion, 0.4)) as anteriores
    from public.licitaciones l
    where coalesce(l.estado_licitacion,'')='PUB'
      and coalesce(l.fecha_limite,'infinity'::timestamptz) >= now()
    order by anteriores desc nulls last
    limit 5;

### Al retomarlo, empezar por aquí

La pista es `expediente`, con cobertura del 100%. Quitándole los
dígitos al expediente para quedarse con el tronco, **441.897 contratos
(41,7%) caen en series repetidas** del mismo órgano. Sin comparar un
solo título y con un índice btree corriente.

Encaja con cómo lo hacen los productos del sector (Tussell,
TenderLedger, Hermix): emparejan por señales estructurales —órgano,
CPV, vencimiento y duración del contrato anterior— y no por parecido
del texto. Trabajan hacia atrás desde la fecha de expiración, porque
las re-licitaciones salen de tres a seis meses antes.

Falta validar que esos troncos no sean demasiado genéricos. No está
comprobado, es una línea de trabajo.

### Cuánto histórico aguanta la base

Estado a 20/09/2026: la base entera ocupa **2.699 MB** con 1.061.075
filas, a razón de **213.396 filas al año** (datos desde 2021-09).

  licitaciones ........ 2.267 MB  (1.658 datos + 570 índices)
  palabras_titulo ......  414 MB  (268 datos + 146 índices)

Proyección añadiendo histórico hacia atrás:

  +3 años  ->  ~640.000 filas más  ->  ~4,3 GB
  +4 años  ->  ~850.000 filas más  ->  ~4,8 GB

Cabe sin problema en el disco de un plan Pro (8 GB de partida), aunque
conviene mirar el disco contratado antes de lanzarlo.

**Lo importante no es el tamaño, es que no frena las consultas.**
`incumbencia` y `ediciones_anteriores` filtran por
`fecha_actualizacion >= now() - N years`, así que meter datos de 2017
no añade ni una fila a la ventana que miran. Su coste no se mueve.

El coste sube si se AMPLÍA la ventana, que es justo el motivo para
querer más histórico. Con `anios` de 4 a 8, los grupos aproximadamente
doblan y el coste también: `incumbencia` pasaría de ~370 ms a ~700-800
ms. Sigue sobrado bajo el límite de 8 segundos.

**El riesgo real está en la importación, no en el resultado.** Meter
640.000 filas dispara los seis triggers BEFORE de `licitaciones` por
cada una y deja una tupla muerta por fila actualizada. Hay que hacerlo
por lotes y con `VACUUM` por el camino, no de una tacada. Es la misma
lección del backfill de `palabras_titulo` de hoy.
