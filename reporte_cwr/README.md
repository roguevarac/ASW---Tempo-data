# Reporte CWR por territorio

Versión vigente: **v4** (`reporte_cwr_x_territorio_v4.sql`). La v3 se conserva como referencia.
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
