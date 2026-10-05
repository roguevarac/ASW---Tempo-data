# Reporte CWR por territorio (v3)

Estado: query v3 y control previo ejecutado. **Falta correr la v3 y validar los tres casos conocidos.**

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
