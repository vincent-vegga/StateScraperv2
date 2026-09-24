# Banco de pruebas · resultados

Generado por `banco/p7_informe.py`. Solo agregados y etiquetas anónimas.

- Corte T = 2026-01-01. Perfil construido solo con lo ganado antes de T.
- 40 empresas (10 por cuartil de historial) de las que ganaron ≥15 licitaciones antes de T y ≥5 desde T (sin menores ni homologaciones).
- Universo común: 4000 licitaciones al azar de las 189105 con fecha_actualizacion ≥ T (sin menores ni homologaciones), más los positivos de cada empresa (935 en total).
- **Recall**: parte de lo que la empresa ganó desde T que el sistema le enseña.
- **Volumen**: licitaciones del universo que le enseña por cada 1.000 (sin contar sus positivos).
- Media sobre las 40 empresas y percentil 10 (la empresa peor servida de cada diez).

## Sistemas

| Sistema | Volumen/1.000 (media · mediana) | Recall (media · p10) |
|---|---|---|
| A1 · Actual: solo puerta CPV | 39.0 · 31.0 | 77.1 % · 48.3 % |
| A2 · Actual: puerta + juez (sí+quizás) | 28.2 · 18.9 | 75.6 % · 47.5 % |
| A3 · Actual: puerta + juez (solo sí) | 21.4 · 10.2 | 66.5 % · 24.5 % |
| A4 · Puerta CPV jerárquica (sin juez) | 49.6 · 41.5 | 83.3 % · 59.8 % |
| B · Puntuación sola, corte a 20/1.000 | 20.0 · 20.0 | 87.6 % · 63.5 % |
| B · Puntuación sola, corte a 30/1.000 | 30.0 · 30.0 | 90.1 % · 72.2 % |
| B · Puntuación sola, corte a 50/1.000 | 50.0 · 50.0 | 92.2 % · 77.1 % |
| C · Puntuación (mejores 30/1.000) + juez con ejemplos (sí+quizás) | 23.7 · 25.3 | 90.1 % · 72.2 % |
| C · Puntuación (mejores 30/1.000) + juez con ejemplos (solo sí) | 15.8 · 16.1 | 86.2 % · 63.8 % |
| C · Puntuación (mejores 50/1.000) + juez con ejemplos (sí+quizás) | 35.3 · 38.0 | 91.6 % · 77.1 % |
| C · Puntuación (mejores 50/1.000) + juez con ejemplos (solo sí) | 21.1 · 20.1 | 87.3 % · 63.8 % |
| C · Puntuación (mejores 100/1.000) + juez con ejemplos (sí+quizás) | 54.8 · 54.8 | 94.9 % · 83.0 % |
| C · Puntuación (mejores 100/1.000) + juez con ejemplos (solo sí) | 28.8 · 26.0 | 89.4 % · 71.1 % |

## Curvas de cada puntuación (sin modelo de lenguaje)

Recall medio (p10 entre paréntesis) enseñando N por cada 1.000:

| Puntuación | 10 | 20 | 30 | 50 | 75 | 100 | 150 | 200 |
|---|---|---|---|---|---|---|---|---|
| knn1 | 71 % (49) | 79 % (62) | 84 % (64) | 88 % (67) | 90 % (72) | 93 % (80) | 95 % (83) | 96 % (87) |
| knn5 | 69 % (41) | 79 % (50) | 85 % (56) | 89 % (72) | 91 % (72) | 92 % (75) | 95 % (83) | 96 % (83) |
| cpv4 | 46 % (12) | 61 % (20) | 71 % (33) | 81 % (50) | 87 % (71) | 89 % (71) | 91 % (78) | 93 % (80) |
| cpv2 | 17 % (0) | 37 % (10) | 45 % (12) | 64 % (28) | 77 % (38) | 83 % (50) | 92 % (81) | 95 % (81) |
| propio | 64 % (33) | 66 % (33) | 66 % (33) | 66 % (33) | 66 % (33) | 66 % (33) | 71 % (43) | 75 % (50) |
| pares | 63 % (25) | 75 % (43) | 82 % (52) | 86 % (57) | 89 % (62) | 91 % (71) | 94 % (77) | 96 % (85) |
| combinada | 80 % (52) | 88 % (64) | 90 % (72) | 92 % (77) | 95 % (83) | 96 % (85) | 98 % (88) | 99 % (98) |

- `knn1`/`knn5`: similitud con sus contratos ganados antes de T (máxima / media de 5).
- `cpv4`/`cpv2`: fracción de sus contratos anteriores con ese prefijo (peso, no puerta).
- `propio`: de las 50 licitaciones pasadas más parecidas, cuánto ganó ella.
- `pares`: cuánto ganaron sus pares (quienes ganan lo parecido a lo suyo).
- `combinada`: regresión logística; cada empresa se puntúa con pesos aprendidos de las otras 39.

Pesos (variables estandarizadas, ajuste con las 40):

```
{"knn1": 0.653, "knn5": 0.693, "cpv4": 0.141, "cpv2": 0.417, "sin_cpv": -0.055, "propio": 0.3, "pares": 0.495, "constante": -3.299}
```

Comprobación de fuga: 93 de 935 positivos tienen un título idéntico a uno que la empresa ganó antes de T (contratos recurrentes). Quitándolos, la puntuación a 30/1.000 sigue en el 90,0 % y el sistema actual en el 75,4 %: la mejora no viene de ahí.

## Por estrato de tamaño de historial

| Estrato (ganados antes de T) | Sistema | Volumen/1.000 | Recall |
|---|---|---|---|
| 0 (15-25) | A2 · Actual: puerta + juez (sí+quizás) | 47.0 | 74.2 % |
| 0 (15-25) | B · Puntuación sola, corte a 30/1.000 | 30.0 | 88.6 % |
| 0 (15-25) | C · Puntuación (mejores 100/1.000) + juez con ejemplos (solo sí) | 37.9 | 86.9 % |
| 1 (26-39) | A2 · Actual: puerta + juez (sí+quizás) | 16.4 | 75.3 % |
| 1 (26-39) | B · Puntuación sola, corte a 30/1.000 | 30.0 | 86.4 % |
| 1 (26-39) | C · Puntuación (mejores 100/1.000) + juez con ejemplos (solo sí) | 22.5 | 86.0 % |
| 2 (42-68) | A2 · Actual: puerta + juez (sí+quizás) | 28.2 | 75.9 % |
| 2 (42-68) | B · Puntuación sola, corte a 30/1.000 | 30.0 | 92.1 % |
| 2 (42-68) | C · Puntuación (mejores 100/1.000) + juez con ejemplos (solo sí) | 26.6 | 91.5 % |
| 3 (80-598) | A2 · Actual: puerta + juez (sí+quizás) | 21.3 | 76.8 % |
| 3 (80-598) | B · Puntuación sola, corte a 30/1.000 | 30.0 | 93.4 % |
| 3 (80-598) | C · Puntuación (mejores 100/1.000) + juez con ejemplos (solo sí) | 28.2 | 93.1 % |

## Gasto de OpenAI

Total: **4.53 $** en 25198 llamadas (tope del banco: 10 $).

- lectura_actual: 0.48 $
- embeddings: 0.97 $
- juez_actual: 0.54 $
- juez_ejemplos: 2.54 $

## Juez v2: destinatario y reglas del cliente (24/09/2026, tarde)

Tras probar el alta de una empresa de uniformidad policial, el juez v1
aceptaba el mismo producto para cualquier destinatario (Guardia Civil,
Policía Nacional, ropa de trabajo genérica). El v2 mira también para quién
es, cuando eso cambia lo que se suministra, y aplica a toda la lista lo
que el cliente explica al descartar. Medido en el banco rejuzgando lo que
v1 aceptó (lo que v1 rechazó se da por rechazado; `banco/p9_juez_v2.py`):

| Grupo 100/1.000 | Volumen/1.000 (media · mediana) | Recall (media · p10) |
|---|---|---|
| v1 · sí+quizás | 54,8 · 54,8 | 94,9 % · 83,0 % |
| **v2 · sí+quizás** | **45,5 · 39,9** | **94,7 % · 80,0 %** |
| v1 · solo sí | 28,8 · 26,0 | 89,4 % · 71,1 % |
| **v2 · solo sí** | **33,9 · 28,9** | **92,1 % · 79,5 %** |

Un 17 % menos de volumen sin perder recall, y «Para mí» más fiable. Coste
de la medida: 1,68 $. Gasto total del banco y la puesta en marcha: 7,53 $.

## Juez v3: las mismas reglas, sin nada de ningún sector (24/09/2026, tarde)

El v2 llevaba ejemplos y una frase sobre cuerpos policiales. Las
instrucciones son comunes a todos los clientes: un ejemplo sacado de uno
empuja a los demás (a quien vende justo a esos cuerpos lo pondría del
revés). El v3 dice lo mismo en abstracto, con ejemplos de forma de otros
sectores. Medido igual que v2:

| Grupo 100/1.000 | Volumen/1.000 | Recall (media · p10) |
|---|---|---|
| v1 · sí+quizás | 54,8 | 94,9 % · 83,0 % |
| v2 · sí+quizás | 45,5 | 94,7 % · 80,0 % |
| **v3 · sí+quizás** | **40,8** | **94,0 % · 80,0 %** |
| **v3 · solo sí** | 32,8 | 91,4 % · 79,6 % |

Empresa por empresa (`p10_por_empresa.py`): frente a v1, 7 empresas
pierden 9 contratos (ninguna más de 2; casos sueltos, sin un patrón de
destinatario); frente a v2, 7 pierden uno cada una. Ruido −30 % frente a
v1. Coste de la medida: 1,86 $. Gasto total del banco: 9,28 $ (tope 10 $).

## Mejoras de la auditoría (24/09/2026, noche)

Todo medido antes de decidir; se adopta solo lo que mejora sin que
ninguna empresa pierda más de la cuenta.

**Puntuación (sin juez, gratis).** Recall de la puntuación sola, 256 dim:

| Variante | a 30/1.000 | a 50/1.000 | a 100/1.000 |
|---|---|---|---|
| En vigor | 89,8 % | 91,9 % | 96,7 % |
| Sin homologaciones en lo ganado | 90,0 % | 91,9 % | 96,7 % |
| Solo los últimos 5 años | 89,8 % | 91,9 % | 96,4 % |

Ninguna mejora de verdad: **no se adopta ninguna**.

**Juez v4: ejemplos con quién convocó cada contrato ganado.** Peor:
recall 92,9 % (v3: 94,0 %), «solo sí» 89,3 % (v3: 91,4 %); frente a v3,
6 empresas pierden 7 contratos. El organismo le hace más estricto aunque
se le diga que no decida por él. **No se adopta: sigue v3.**

**Empresas con poco historial (5-14 contratos, 20 empresas, `p11`-`p13`),
con el juez v3 y los pesos de producción:**

| | Recall (media · p10) | Volumen/1.000 |
|---|---|---|
| Sistema anterior (criterio + puerta) | 79,2 % · 63,3 % | 20,2 |
| **Puntuación por huellas** | **95,4 % · 74,2 %** | 29,1 |

Ninguna empresa pierde; 9 ganan. **Se baja `minimo_ganados` de 15 a 5.**

**Duplicados en la lista:** en lo vivo solo hay 2 casos de mismo título y
órgano, y son expedientes distintos: no se toca.

Gasto de estas medidas: 5,09 $. Gasto total del banco: 14,37 $ (tope 16 $).
