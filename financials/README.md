# Financials de obras

## Query vigente: `song_financials_el.sql`
Reproduce el "Song Sub Source Summary" del front para todas las obras de `public.rankingdigital_song_id`, por
oficina, fuente, sub fuente e income type. Lee `dp_earnings_lines.earnings_lines_v` una sola vez.

| Front | Columna en `earnings_lines_v` |
|---|---|
| Gross Income | `gross_client_share_of_income_amt` |
| Affiliate NPS | `foreign_nps_am` |
| Domestic NPS | `gross_nps` |
| Client Royalty | `gross_royalty_payable` |
| (converted net de `statement_lines_v`) | `converted_net_am`, una vez por línea de statement |
| Withholding Tax | no hay columna: `gross − affiliate − domestic − royalty` (exacto en fuentes locales; aproximado en intercompany) |

- Montos en la moneda de la oficina que procesó. El front en USD = `processing_office_name = 'United States'`.
- Verificado con la obra 6101269, fuente SMP Latin: 34.636,78 / 2.183,33 / 3.705,94 / 29.067,78, igual al front.

## Caso 6101269 (Bailando Bachata) — por qué statement_lines_v no daba el front
- `statement_lines_v.converted_net_am` = Domestic NPS + Client Royalty del front, exacto (32.773,72 en SMP Latin).
- SMP Latin es intercompany: la oficina afiliada cobró y retuvo Affiliate NPS antes de girar a Estados Unidos. El
  Gross Income es el monto antes de esa retención y solo está en las líneas de ganancia.
- `originating_office_earnings_lines_v` no sirve para esto: no tiene filas con fuente SMP Latin para la obra.
- Archivos del caso en `casos/6101269/`. `song_financials_ooel.sql` y `diagnostico_ooel.sql` quedan como historia.

## Fuentes locales vs intercompany en `statement_lines_v`
- **Local** (ej. YouTube - USA): `converted_net_am` = Gross Income del front, exacto (118.078,88 en 6101269).
- **Intercompany** ("SMP Latin", "SMP Argentina"...): `converted_net_am` = Gross − Affiliate NPS − WHT (lo que llegó).
- `diagnostico_gross_intercompany.sql` busca qué columna de `statement_lines_v` da el gross en intercompany.
  Mientras tanto, `song_financials_el.sql` ya da el gross exacto para las dos.

## México / EMMAC: `mexico_emmac.sql`
Cuánto generó cada obra en México con la fuente EMMAC, en moneda local y en USD. Lee `statement_lines_v` filtrando
oficina `Mexico%`, fuente `%EMMAC%` y líneas Finalized; obras desde `public.rankingdigital_song_id`.
- Gross = `lc_gross_stmt_am` (lo informado por EMMAC); neto = `converted_net_am` (después de comisión y retención).
- USD con `exchange_to_us_currency` de cada statement: si el valor es > 1 se divide, si es < 1 se multiplica.
- `neto_sobre_gross` es un control de que gross y neto estén en la misma moneda (esperado 0,7 a 1).
- `mexico_emmac_validacion_usa.sql`: lo que llegó a Estados Unidos (fuente SMP Mexico / sub fuente EMMAC) en USD,
  desde líneas de ganancia. Es solo la parte de clientes de Estados Unidos: debe ser ≤ al neto USD de México.
- Pendiente de confirmar con la primera corrida: que la oficina se llame `Mexico...` y la fuente contenga `EMMAC`.

## Recaudación EMMAC + SMP Latin de las obras controladas: `recaudacion_emmac_smp_latin_v1.sql`
Una fila por obra de `public.obras_controladas_pais_resultado` (todos los países ya corridos; lista en
`paises_controlados`) con importe en EMMAC o SMP Latin.
- EMMAC: `statement_lines_v`, oficina México, Finalized, fuente o sub fuente con EMMAC **comparado en mayúsculas**
  (nombres reales del 12/11/2026: "EMMAC A EN P", "Emmac", "EMMAC/SACM", "Emmac / Maquilas", "Emmac / Musica Impresa",
  "Emmac / Cosmic Juego Elect", "Emmac / Ediciones Pentagrama"). MXN y USD. `mexico_emmac.sql` tenía `LIKE '%EMMAC%'`
  y perdía las variantes "Emmac"; corregido.
- SMP Latin Estados Unidos: `earnings_lines_v` (columnas del front, USD). SMP Latin llega además a UK, México, Holanda,
  Corea, Argentina, Colombia, España, Japón, Brasil... (102 M líneas en US, 29 M en UK): esas salen de
  `statement_lines_v` convertidas a USD con `exchange_to_us_currency` (sentido **sin confirmar** para monedas más
  fuertes que el dólar).
- `total_recaudado_usd` = EMMAC gross USD + SMP Latin US Gross Income; `total_con_otras_oficinas_usd` suma además las
  otras oficinas.
- No se cuenta "SMP Mexico" (lo que México gira a otras oficinas): duplicaría EMMAC.

Tipo de cambio por oficina (para confirmar el sentido antes de usar otras oficinas):
```sql
SELECT processing_office_name, MIN(exchange_to_us_currency) AS tc_min, MAX(exchange_to_us_currency) AS tc_max,
       AVG(exchange_to_us_currency) AS tc_prom, COUNT(*) AS lineas
FROM dp_statement_lines.statement_lines_v
WHERE source_name = 'SMP Latin' AND statement_line_status = 'Finalized'
  AND semiannual_statement_period >= DATE '2025-01-01'
GROUP BY 1 ORDER BY lineas DESC;
```
Prueba: `python3 financials/tests/test_recaudacion_emmac_smp_latin.py`.
