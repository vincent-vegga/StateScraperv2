# State Scraper V2

Detecta contratos públicos relevantes para una empresa concreta y los presenta con contexto de mercado: quién gana habitualmente, a qué precio adjudica cada organismo, y si merece la pena presentarse.

El problema no es encontrar licitaciones: hay agregadores que las listan. El problema es que **están mal filtradas**. Un proveedor que recibe veinte contratos al día y descarta dieciséis no tiene una herramienta, tiene una tarea más.

**La propuesta de valor es el proceso que construye el filtro.** El sistema busca qué ha ganado la empresa antes, deduce un criterio en prosa y lo aplica cada mañana. El cliente no necesita saber qué es un CPV.

---

## Estado (septiembre 2026)

En producción con primeros usuarios reales. El core funciona; hay deuda técnica conocida.

| | |
|---|---|
| Lectura de feeds ATOM oficiales, con ventana adaptativa | ✅ |
| Cribado semántico personalizado por empresa | ✅ |
| Web multiusuario con sesión y autenticación | ✅ |
| Alta guiada: CIF → historial → criterio → cribado | ✅ |
| Pantalla de Contratos abiertos | ✅ |
| Mi cartera: llevar la cuenta de cada contrato, con su resultado y avisos de plazo | ✅ Desde el 07/10/2026 (Decisión 53) |
| Inteligencia de mercado: Empresas, Lo que viene, Organismos | ✅ |
| Lo que viene: contratos del sector que van a vencer (sustituye a Movimientos) | ✅ Desde el 06/10/2026, con la etiqueta de nueva licitación abierta |
| Viabilidad: puntuación por contrato, rango de precio y contratos enlazados | ✅ |
| Viabilidad en la lista de Contratos: marca y filtro | ✅ Desde el 04/10/2026 |
| Alerta diaria por correo | ✅ Activa, solo para quien enciende la campana |
| Seguir avisa: lo que ganan las empresas, lo que publican los organismos y la nueva licitación de lo que vence | ✅ Desde el 10/10/2026 (Decisión 56) |
| Pregúntale al pliego: preguntas en lenguaje normal sobre los documentos de cada contrato abierto | ✅ Desde el 10/10/2026 (Decisión 57) |
| Histórico completo | ⚙️ Parcial (~25% del disponible) |
| Sistemas dinámicos y acuerdos marco marcados como tales | ✅ Desde el 04/10/2026 |
| Alta sin historial: camino estable | ⬜ Frágil |

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
   ├─ filtro por prefijo CPV               │
   └─ control de estado                    │
            │                                │
            └────────────┬───────────────────┘
                         ▼
                 Supabase (PostgreSQL)
                 tabla `licitaciones`
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
    cribador.py    alertador.py     Edge Function
    (semántico)    (correo)         /alta (onboarding)
                                        │
                                        ▼
                                   web/index.html
                                   (Cloudflare Pages)
```

Todo corre en GitHub Actions. No requiere instalación local ni servidor propio.

**URL de producción:** https://statescraper.com
**Supabase:** swgrbzqxagrqdyddmvfy.supabase.co

---

## Ficheros

| Fichero | Función |
|---|---|
| `lector_atom.py` | Lectura de feeds, filtro CPV y control de estado |
| `importar_historico.py` | Carga histórico desde los ZIP oficiales |
| `cribador.py` | Cribado semántico con LLM, por perfil de empresa |
| `alertador.py` | Alerta diaria por correo (Resend) |
| `leer_pliegos.py` | Lee la solvencia del anuncio o del pliego con el modelo, con topes de gasto (Decisión 54) |
| `rellenar_condiciones.py` | Relee los ZIP del mes y guarda las condiciones de lo abierto (Decisión 54) |
| `web/index.html` | Interfaz web completa: todo en un solo fichero |
| `supabase/functions/alta/index.ts` | Edge Function: onboarding guiado |
| `supabase/functions/pliego/index.ts` | Edge Function: Pregúntale al pliego (Decisión 57) |
| `relevo_pliego.py` | Descarga desde GitHub los pliegos que la función no alcanza (portal vasco) y los deja un momento en el almacén `relevo` (Decisión 57) |
| `.github/workflows/scraper.yml` | Cron y modos de ejecución |
| `.github/workflows/condiciones.yml` | Lectura de la solvencia al acabar el scraper; relleno a mano |
| `DECISIONES.md` | Por qué el sistema es como es. Leer antes de tocar nada |

Las migraciones SQL están en `migracion-*.sql`. Cada una explica en cabecera qué problema resuelve y por qué.

---

## Base de datos

### Tablas principales

| Tabla | Función |
|---|---|
| `licitaciones` | Todo lo descargado. Una fila = un expediente o lote |
| `perfiles` | Una fila por empresa registrada. CPV, criterio, historial |
| `veredictos` | Sí/quizás/no por contrato y perfil. El resultado del cribado |
| `veredictos_mercado` | Cribado semántico del mercado (adjudicaciones históricas) |
| `correcciones` | Cuando el cliente pulsa "no me interesa" o "sí me interesa" |
| `seguimiento` | Empresas que el cliente ha marcado para seguir |
| `cartera` | Contratos que el cliente lleva: estado, nota e importe de su oferta (Decisión 53) |
| `codigos_acceso` | Códigos de acceso para el periodo de pruebas |
| `condiciones` | Lo que piden para presentarse a cada licitación abierta: solvencia, clasificación, garantías, contacto, pliegos y la lectura del modelo (Decisión 54) |

### Tablas de caché

| Tabla | Qué guarda | Caduca |
|---|---|---|
| `competencia_guardada` | Las 25 empresas que más compiten en el sector | 1 día |
| `organismos_guardados` | La lista de organismos del sector, ya paginada | 1 día |
| `fichas_organismo` | Datos de cada organismo que alguien haya consultado | 1 día |
| `organismos_por_prefijo` | Agregado de organismos **por prefijo CPV**, no por perfil | Lo rehace el robot cada noche |
| `viabilidad_guardada` | El veredicto de Viabilidad de cada contrato abierto que está en alguna lista | 7 días; la rellena `pg_cron` cada 10 minutos |
| `vencimientos` | Los contratos que vencen en los próximos 13 meses, **por prefijo**, con sus prórrogas leídas del texto | La rehace `pg_cron` cada día (14:45 UTC) |
| `requisitos_guardados` | La marca de la fila de Contratos ("Exigen clasificación", "Piden facturar…") por perfil y contrato | Al cambiar la lectura, o a los 7 días; la rellena `pg_cron` cada 10 minutos |

La caché existe porque calcular competencia o fichas sobre 25.000 contratos cada vez que alguien abre la pestaña agota el tiempo de espera. El resultado es el mismo; el trabajo se hace una vez.

`organismos_por_prefijo` es distinta de las demás: va **por prefijo y no por perfil**. Dos clientes del mismo sector hacían dos veces el mismo trabajo, y uno nuevo lo hacía desde cero. Ahora se calcula una vez por la noche y sirve a todos, incluido el que se dio de alta hace un minuto. Para un sector grande eso es la diferencia entre 11.900 ms —que no caben en el límite de 8 s, así que la pestaña salía vacía— y 344 ms.

### Funciones principales

| Función | Qué hace |
|---|---|
| `pendientes_de_perfil(perfil, tope)` | Cola de contratos abiertos sin cribar |
| `mis_oportunidades` (vista) | Lo que ve el cliente en Contratos |
| `analizables()` | Lo que ve en Viabilidad — mismo filtro que mis_oportunidades |
| `competencia()` | Las 25 empresas que más compiten, con caché |
| `buscar_organismo(texto)` | Organismos del sector, con caché |
| `ficha_organismo(organo)` | Datos de un organismo concreto, con caché |
| `pulso_mercado()` | Cifras del mes: contratos, importe, empresas |
| `viabilidad(id)` | Puntuación de viabilidad de un contrato concreto |
| `refrescar_viabilidad_guardada(segundos)` | Rellena `viabilidad_guardada` por tandas (`pg_cron`) |
| `mi_cartera()` | Lo que ve en "Mi cartera", con el resultado de la adjudicación cruzado con su NIF |
| `poner_en_cartera(licitacion, estado)` | Guarda o cambia el estado; apunta el "sí me interesa" si no lo había |
| `plazos_de_cartera(perfil)` | Para el correo: lo que lleva y cierra en los próximos 8 días (solo clave de servicio) |
| `lo_que_viene(meses, provincia, tope)` | Lo que ve en "Lo que viene": los contratos de su sector que vencen |
| `refrescar_vencimientos(prefijos)` | Rehace `vencimientos`, entera o solo unos prefijos (`pg_cron`) |
| `requisitos(id)` | Qué piden para presentarse y si lo que ya gana la empresa llega (ficha de Contratos y Viabilidad) |
| `guardar_condiciones(filas)` / `condiciones_por_leer(tope)` / `guardar_lectura(...)` | Escritura del scraper y cola del lector de pliegos |
| `refrescar_requisitos_guardados(segundos)` | Rellena `requisitos_guardados` por tandas (`pg_cron`) |
| `comprobar_codigo(codigo)` | Dice si un código de acceso vale, sin consumirlo ni pedir sesión (primera pantalla) |
| `canjear_codigo(codigo)` | Valida y consume un código de acceso (insensible a mayúsculas) |

---

## Operación

### Cron diario

Cada mañana a las 06:00 UTC (08:00 peninsular en verano). Ejecuta el scraper, el cribado y la alerta por correo. Solo recibe correo quien haya encendido la campana: `perfiles.avisos` nace apagado. El correo sale si hay contratos nuevos, si algo de su cartera cierra dentro de 7, 3 o 1 día, o si hay algo de lo que sigue: una licitación de un organismo seguido o la nueva de un contrato vigilado. Lo que gana la competencia va con lo demás o, solo, como mucho una vez por semana (Decisión 56).

Al acabar el scraper, `condiciones.yml` lee la solvencia de lo nuevo (anuncio o pliego), con un tope de 0,50 $ al día y 10 $ al mes.

### Modos manuales

Actions → Run workflow → parámetro `modo`:

| Modo | Qué hace |
|---|---|
| `normal` | Scraper + cribado + correo (cuando se reactive) |
| `solo_cribado` | Solo clasifica, sin leer feeds ni mandar correos |
| `diagnostico` | Lee los feeds **sin tocar la base** |
| `cribado_prueba` | Clasifica 20 y los imprime **sin guardar** |
| `alerta_prueba` | Compone el correo y lo imprime **sin enviarlo** |

`solo_cribado` es el modo habitual durante pruebas: pone al día a los clientes nuevos sin riesgo de mandar correos no esperados.

### Credenciales (secrets del repo)

| Secret | De dónde sale |
|---|---|
| `SUPABASE_URL` | Project Settings → Data API |
| `SUPABASE_KEY` | Project Settings → API Keys → clave **secreta** |
| `OPENAI_API_KEY` | Clave de proyecto propio |
| `RESEND_API_KEY` | Resend → API Keys |

Variables de entorno opcionales:
- `REMITENTE_ALERTA`: por defecto `State Scraper <hola@statescraper.com>`

---

## Alta de un usuario

El flujo completo:

1. El cliente entra en https://statescraper.com con un código de acceso.
2. Introduce su NIF → la Edge Function `/alta` busca qué ha ganado.
3. El LLM deduce los CPV y redacta el criterio en prosa.
4. El cliente elige si quiere ampliar o afinar.
5. Al entrar por primera vez, el arranque detecta pendientes y criba.
6. Si hay muchos pendientes (>5s de espera), se muestra la lista vacía y el workflow los criba en la siguiente pasada.

El alta sin NIF (quien no ha ganado contratos públicos) tiene su propio
documento, con su historia, lo medido y lo descartado:
[docs/alta-sin-nif/LEEME.md](docs/alta-sin-nif/LEEME.md).


Para crear uno nuevo:
```sql
insert into public.codigos_acceso (codigo, nota, usos_maximos, caduca)
values ('nuevo', 'Descripción', 100, now() + interval '3 months');
```

---

## Vigilar el estado en producción

```sql
-- Quién ha entrado y qué ve
select p.empresa, p.email, to_char(p.fecha_alta, 'DD/MM HH24:MI') as alta,
       (select count(*)
        from public.veredictos v
        join public.licitaciones l on l.id_licitacion = v.id_licitacion
        left join public.correcciones c
          on c.id_licitacion = l.id_licitacion and c.perfil_id = p.id
        where v.perfil_id = p.id and v.veredicto in ('si','quizas')
          and coalesce(l.estado_licitacion,'') = 'PUB'
          and ((l.fecha_limite is not null and l.fecha_limite >= now())
               or (l.fecha_limite is null
                   and l.fecha_actualizacion >= now() - interval '14 days'))
          and (c.interesa is null or c.interesa)) as le_salen
from public.perfiles p order by p.fecha_alta desc;

-- Códigos de acceso
select codigo, usos, usos_maximos, caduca from public.codigos_acceso;
```

---

## Límites conocidos

- **El alta sin historial es frágil.** Con pocos contratos el criterio puede ser demasiado estrecho o demasiado territorial. El prompt está corregido para no usar geografía, pero con cuatro o cinco contratos el margen es pequeño.
- **Los sistemas dinámicos de adquisición inundan algunos sectores.** Son contratos que técnicamente encajan pero son inscripciones a catálogos, no licitaciones. Siguen en la lista, pero desde el 04/10/2026 llevan su etiqueta (también los acuerdos marco y los contratos basados en ellos, "solo homologados").
- **`pendientes_de_perfil` tarda con sectores grandes.** Con 25.000 contratos en el sector, la primera visita de un usuario nuevo puede superar el tiempo de espera del navegador. El workflow lo resuelve, pero el usuario puede ver la pantalla vacía antes.
- **El histórico es parcial.** La inteligencia de mercado funciona mejor cuanto más histórico hay. Ahora hay unos dos años en algunos sectores y menos en otros.
- **Los criterios geográficos.** Si la empresa tiene todo su historial en una provincia, el modelo podía deducir un criterio territorial. El prompt está corregido, pero hay perfiles antiguos que pueden tener ese sesgo.

---

## Hoja de ruta de producto

Qué ofrece la competencia y qué le falta a cada pantalla, con las
prioridades: [docs/competencia/LEEME.md](docs/competencia/LEEME.md). Al
final tiene el traspaso: lo hecho, lo abierto y cómo seguir.

---

## Deuda técnica conocida

- Caché de `pendientes_de_perfil` — prioritario: resuelve el problema de entrada vacía
- Alta sin historial: mejorar usando historial de empresas similares
- `alertador.py` necesita actualizar el remitente (está en el workflow pero no en el código)
- Índice en `perfiles.cif` — hay búsquedas lentas porque hace seq scan
