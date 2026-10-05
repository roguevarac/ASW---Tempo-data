# Esquema Tempo

| Archivo | Contenido |
|---|---|
| `sa001_dp_song_metadata_create_statements.sql` | Vistas, MVs y procedimiento de canciones, IP, territorios, CWR |
| `sa002_dp_deal_metadata_create_statements.sql` | Clientes, contratos, subcontratos, acuerdos |
| `sa003_dp_deal_financials_create_statements.sql` | Balances de clientes y trial balance |
| `sa004_dp_statement_lines_create_statements.sql` | Statement headers/lines, CRJ, fuentes |
| `Enterprise_Metadata_Workbook_Consolidated.xlsx` | Workbook original (7 subject areas) |
| `workbook_csv/` | El workbook, una hoja por CSV (se puede buscar con grep) |
| `CATALOG.md` | Índice generado: objetos, grano, columnas, relaciones |

Para regenerar `CATALOG.md` hay que volver a convertir el xlsx a CSV y correr el script de generación
(está en el historial de la sesión; es un recorrido simple de `02_Objects`, `03_Columns` y `05_Relationships`).
