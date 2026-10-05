# Reporte CWR por territorio

Versión vigente: **v6** (`reporte_cwr_x_territorio_v6.sql`), misma lógica que la v5 pero optimizada. Es un **script**:
hay que correrlo completo en una sesión (DBeaver: Execute script / Alt+X; Query Editor v2: Run all). Para cambiar las
obras se edita solo el `INSERT INTO cwr_ids`. La v3, la v4 y la v5 se conservan como referencia.

## Rendimiento (v6)
La v5 no terminaba porque Redshift recalcula una CTE cada vez que se la nombra:
- `target_songs` salía de `song_v` (vista pesada que agrega writers, artistas, alertas y holds de todo el catálogo)
  y se nombraba ~7 veces.
- `song_share_detail_mv` y `contract_territories` se leían 3 veces cada una; el respaldo de texto agrupaba por los
  textos largos de todas las obras de cada contrato.
- `contract_info` recorría `contract_v` entera, sin filtro.

La v6 lee cada fuente una sola vez, filtrada a las obras y contratos pedidos, en tablas temporales chicas
(`cwr_ids`, `cwr_song`, `cwr_iswc`, `cwr_mv`, `cwr_ct`, `cwr_ct_fallback`, `cwr_contract`), y el reporte final corre
sobre ellas. Como cada paso es una sentencia aparte, si algo sigue lento se ve cuál paso es.
Requiere permiso para crear tablas temporales (en Redshift suele estar dado a todos).
Estado: v4 ejecutada (`resultados/resultado_v4.json`, 380 filas = 76 obras x 5 paises). Ver "Resultado de la v4".

## Qué agrega la v4 sobre la v3
- Obra ausente de `song_share_detail_mv` (caso 7525701) sale como `SIN DATOS`, no `NVFT`, con alerta.
- Alerta si algún total supera 100 (posible doble conteo en la cadena de publishers).
- Alerta de contrato sin texto de territorio, con la causa real (sin rate client o payment option activo).
- Consulta C en `control_previo_v3.sql` para investigar por qué falta esa obra.

## Contexto
El usuario no tiene permiso de lectura sobre el esquema `edw` (v2 descartada).
La v3 usa solo vistas `dp_*`: `song_v`, `identifiers_iswc_v`, `song_share_detail_mv`,
`contract_v`, `contract_territories`.

## Archivos
- `reporte_cwr_x_territorio_v3.sql`: query principal (una fila por obra y país: AR, CL, PE, UY, CO).
- `control_previo/control_previo_v3.sql`: consultas A y B.
- `control_previo/resultado_*.json`: resultados ya obtenidos.

## Resultados del control previo
**A. Cobertura de datos:** 75 de 76 obras tienen participaciones. La obra **7525701** no tiene
datos en `song_share_detail_mv`, así que saldrá NVFT en los 5 países por falta de datos, no por la query.

**B. Textos de territorio:** todos los contratos usan `World`, `ARGENTINA` o listas de países
europeos. No aparece ninguna región nueva, así que el diccionario `regiones`
(Latin America / South America) alcanza y no hay que agregar nada.
Contratos con efecto sobre los países pedidos:

| Contrato | Texto | Efecto |
|---|---|---|
| 173392 Jairo Varela | World, excl. COLOMBIA;MEXICO (otra fila sin exclusión) | no controla Colombia |
| 1546813 Cuatro Zonas | World, excl. URUGUAY | no controla Uruguay |
| 1693573 DP Publishing | World, excl. ARGENTINA | no controla Argentina |
| 1640587 Villarruel | solo ARGENTINA | controla únicamente Argentina |
| 210379 Piano Music / 1700764 Tuinfort | listas europeas | no cubren ningún país pedido |

## Cambio hecho al retomar
`ct_par` ordenaba por `inclusions` solamente. Con filas duplicadas (caso 173392) la elección era
arbitraria. Ahora desempata prefiriendo la fila con exclusiones (más conservadora).

## Siguientes pasos
1. Correr la v3 en Redshift.
2. Validar: Ella Dijo en Argentina = 25 (no 20.84); Te Encontre en Colombia = NVFT;
   Baba O'Riley con control en los países originales.
3. Revisar las filas con `alertas` (texto de otra obra, contrato sin texto, varios grupos empatados).
4. Si habilitan lectura sobre `edw`, volver a la v2, que lee el diccionario real de Tempo.

## Resultado de la v4
- 373 filas con porcentaje, 2 NVFT, 5 SIN DATOS. No hay totales > 100 ni alertas distintas de la obra ausente.
- **Validado:** Ella Dijo en Argentina = 25 (antes 20.84). Argentina vale la mitad que los otros 4 paises en 13 obras
  (contrato con territorio propio para Argentina).
- **NVFT coherentes con los contratos:** Sin Sentimientos / Colombia (contrato 173392 excluye Colombia) y
  Tan Lejos / Uruguay (contrato 1546813 excluye Uruguay).
- **7525701 "[DELETE] Sirena":** el titulo indica que esta marcada para borrar; su ausencia en la MV es esperable.
- **No verificables con esta lista:** Te Encontre (Colombia) y Baba O'Riley no estan entre las 76 obras.
- **Decision pendiente:** 6 obras (30 filas) tienen todos sus contratos vencidos pero igual muestran porcentaje:
  191014 Take On Me (1988), 1303178 Titanium (2016), 4273597 To My Love (2020), 4555478 That's What I Like (2021),
  6686578 Your Love Diplo Remix (2024), 7710563 Velocidade (2026-06-30). La columna `estado_contrato` las marca
  `TODOS VENCIDOS`; la query no las pasa a NVFT.

## Caso Baba O'Riley (2701309): resuelto en la v5
Archivos en `casos/baba_oriley/` (resultado v4, export del front, diagnóstico y sus tres resultados).

**Qué pasaba.** La v3/v4 exigían que el contrato de la columna "Associated Contract" de la participación cubriera el
país. Aquí ese contrato es el 1525818 (Westminster, texto Asia: China, Hong Kong… Tailandia; idéntico en las 191 obras
que lo usan), así que daba NVFT. El control real de la obra está en otras líneas de control que existen en
`contract_territories` pero no aparecen en las participaciones de `song_share_detail_mv`:

| Contrato | Texto | Cubre AR/CL/CO/PE/UY |
|---|---|---|
| 1551025 ABKCO Music International Limited | World menos una lista larga (ninguno de los 5 excluido) | Sí |
| 1146885 Westminster Admin Gen (2000) | Lista explícita con los 5 países | Sí |
| 1525818 Westminster (ex. Philippines) | Asia | No |
| 1551999 ABKCO (Mexico & Philippines Only) | Indonesia, Malasia, México, Filipinas | No |

**Regla nueva (v5).** El grupo "All (Other) Contractual Territories" significa "los demás territorios contratados".
Un país está controlado si el grupo IP que le corresponde es de SMP **y** alguna línea de control de la obra lo cubre.
Resultado esperado y obtenido con los datos del caso: Mecánico 100 / Performance 50 / Sync 100 en los 5 países, igual
que el front. Las filas donde el contrato asociado no cubre pero otra línea sí llevan la alerta
`CONTROL SOSTENIDO POR OTRA LINEA DE CONTROL`.

**Otros cambios de la v5**
- `estado_contrato` y los vencimientos se calculan sobre las líneas que cubren el país. Se corrigió un error: una línea
  sin vencimiento mezclada con una vencida daba `TODOS VENCIDOS`.
- Columnas nuevas: `lineas_de_control_obra`, `lineas_que_cubren_el_pais`; `texto_territorio_contratos` ahora lista
  todas las líneas con su texto.

## Pruebas
`python3 reporte_cwr/tests/test_reporte.py` ejecuta la v6 y la v5 en DuckDB (la query se transpila de Redshift con `sqlglot`) con 39
chequeos: el caso real 2701309, Ella Dijo, Sin Sentimientos, Te Encontre, obra ausente, vencimientos, regiones,
acentos y `(REG)`, empates de grupos, publishers múltiples y filas duplicadas. Además verifica que la v6 dé
exactamente el mismo resultado que la v5. Sirve para validar la lógica; no mide rendimiento ni reemplaza correr la query
en Redshift. Contra la v3 el mismo caso real da NVFT, como en producción.

## Pendiente
- Correr la v6 en Redshift y mirar las filas con la alerta `CONTROL SOSTENIDO POR OTRA LINEA DE CONTROL`: son las
  que cambian respecto de la v4 (se espera que pase de NVFT a un porcentaje).
- Decisión sobre contratos vencidos (ver arriba).
