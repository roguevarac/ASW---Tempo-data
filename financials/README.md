# Financials de obras

## Caso 6101269 (Bailando Bachata), fuente SMP Latin — query vs front "Song Financials"
- La query sobre `dp_statement_lines.statement_lines_v` (líneas Finalized) da un `converted_net_am` que coincide
  **exacto** con *Domestic NPS + Client Royalty* del front, por income type: 18,58 / 11.583,69 / 21.171,45.
- El *Gross Income* del front es mayor (18,29 / 12.203,02 / 22.415,47). SMP Latin es intercompany: una oficina
  afiliada de Latinoamérica cobró primero y retuvo su parte (*Affiliate NPS*). El gross es el monto en origen, que
  no está en `statement_lines_v`.
- `Gross − Affiliate NPS` no da exacto el converted net (1–6 % de diferencia según el tipo): probablemente es tipo
  de cambio, sin confirmar.
- `song_financials_ooel.sql` lista las columnas candidatas de `dp_earnings_lines.originating_office_earnings_lines_v`
  para identificar cuál usa el front. Pendiente: correrla y comparar. No tenemos el DDL de `dp_earnings_lines`.
