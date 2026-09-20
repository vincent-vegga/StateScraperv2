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
