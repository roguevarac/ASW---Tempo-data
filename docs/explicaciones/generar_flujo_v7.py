"""
Genera "Flujo de trabajo de Query Tempo Control (v7).docx" usando el documento original
como plantilla (mismos estilos, viñetas y formato de tablas).
Uso: python3 docs/explicaciones/generar_flujo_v7.py
"""
import re, shutil, zipfile, pathlib, html

AQUI = pathlib.Path(__file__).resolve().parent
ORIGINAL = AQUI / "Flujo_de_trabajo_de_Query_Tempo_Control_original.docx"
SALIDA = AQUI / "Flujo_de_trabajo_de_Query_Tempo_Control_v7.docx"

F = '<w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:cs="Arial"/>'
PPR_R = f'<w:rPr>{F}</w:rPr>'
def esc(t): return html.escape(t, quote=False)

def runs(texto, extra=""):
    """Texto con **negrita** opcional."""
    out = []
    for i, parte in enumerate(re.split(r"\*\*", texto)):
        if not parte:
            continue
        b = "<w:b/><w:bCs/>" if i % 2 else ""
        out.append(f'<w:r><w:rPr>{F}{b}{extra}</w:rPr><w:t xml:space="preserve">{esc(parte)}</w:t></w:r>')
    return "".join(out)

def titulo(t):
    return f'<w:p><w:pPr><w:pStyle w:val="Ttulo"/><w:spacing w:after="80"/>{PPR_R}</w:pPr>{runs(t)}</w:p>'
GRIS24 = '<w:color w:val="5B6470"/><w:sz w:val="24"/><w:szCs w:val="24"/>'
def subtitulo(t):
    return f'<w:p><w:pPr><w:spacing w:after="340"/>{PPR_R}</w:pPr>{runs(t, GRIS24)}</w:p>'
def h1(t):
    return f'<w:p><w:pPr><w:pStyle w:val="Ttulo1"/><w:spacing w:before="360" w:after="140"/>{PPR_R}</w:pPr>{runs(t)}</w:p>'
def h2(t, lineas=None):
    gris = '<w:color w:val="5B6470"/><w:sz w:val="18"/><w:szCs w:val="18"/>'
    extra = runs(f" (líneas {lineas})", gris) if lineas else ""
    return f'<w:p><w:pPr><w:pStyle w:val="Ttulo2"/><w:spacing w:before="280" w:after="110"/>{PPR_R}</w:pPr>{runs(t)}{extra}</w:p>'
def p(t):
    return f'<w:p><w:pPr>{PPR_R}</w:pPr>{runs(t)}</w:p>'
def vineta(t):
    return f'<w:p><w:pPr><w:pStyle w:val="Prrafodelista"/><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr><w:spacing w:after="80"/>{PPR_R}</w:pPr>{runs(t)}</w:p>'
def tabla(encabezados, filas, anchos):
    bordes = "".join(f'<w:{b} w:val="single" w:sz="4" w:space="0" w:color="auto"/>' for b in ("top", "left", "bottom", "right", "insideH", "insideV"))
    mar = '<w:tcMar><w:top w:w="70" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="70" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tcMar>'
    def celda(txt, w, head):
        shd = '<w:shd w:val="clear" w:color="auto" w:fill="0F4BAB"/>' if head else ""
        estilo = '<w:b/><w:bCs/><w:color w:val="FFFFFF"/>' if head else '<w:color w:val="1A1A1A"/>'
        estilo += '<w:sz w:val="19"/><w:szCs w:val="19"/>'
        return f'<w:tc><w:tcPr><w:tcW w:w="{w}" w:type="dxa"/>{shd}{mar}</w:tcPr><w:p><w:pPr>{PPR_R}</w:pPr>{runs(txt, estilo)}</w:p></w:tc>'
    def fila(vals, head=False):
        trpr = "<w:trPr><w:tblHeader/></w:trPr>" if head else ""
        return f"<w:tr>{trpr}" + "".join(celda(v, w, head) for v, w in zip(vals, anchos)) + "</w:tr>"
    grid = "".join(f'<w:gridCol w:w="{w}"/>' for w in anchos)
    return (f'<w:tbl><w:tblPr><w:tblW w:w="{sum(anchos)}" w:type="dxa"/><w:tblBorders>{bordes}</w:tblBorders>'
            f'<w:tblCellMar><w:left w:w="10" w:type="dxa"/><w:right w:w="10" w:type="dxa"/></w:tblCellMar>'
            f'<w:tblLook w:val="04A0" w:firstRow="1" w:lastRow="0" w:firstColumn="1" w:lastColumn="0" w:noHBand="0" w:noVBand="1"/></w:tblPr>'
            f'<w:tblGrid>{grid}</w:tblGrid>' + fila(encabezados, True) + "".join(fila(f) for f in filas) + "</w:tbl>"
            + f'<w:p><w:pPr>{PPR_R}</w:pPr></w:p>')

# ---------------------------------------------------------------------------
C = []
C += [titulo("Query Tempo Control (v7)"),
      subtitulo("Explicación de la lógica detrás de la query que usamos para ver, de manera masiva, el % de control que tenemos sobre cada obra en los diferentes territorios. Esta es la versión 7, que reemplaza a la anterior.")]

C += [h1("Punto importante:"),
      p("La query sigue siendo una cadena de bloques (CTE), donde cada bloque toma el resultado del anterior y le agrega una capa. La diferencia con la versión anterior es cómo está armada esa cadena."),
      p("Redshift no guarda el resultado de un bloque: cada vez que otro bloque lo nombra, lo vuelve a calcular. Con muchos bloques que se nombraban entre sí, las mismas tablas se terminaban leyendo decenas de veces y la query no terminaba nunca. Por eso esta versión lee cada tabla una sola vez (o muy pocas), junta todo en una única lista y hace las comparaciones dentro de esa lista. Así sale en una sola consulta, con un solo resultado, y en poco tiempo.")]

C += [h1("Qué cambió respecto de la versión anterior:"),
      vineta("**El territorio lo dan las líneas de control de la obra**, no el contrato que figura en la participación. Si alguna línea de control de la obra cubre el país, el país está controlado. Esto salió del caso Baba O'Riley (ver paso 7)."),
      vineta("**Un solo grupo IP por obra y país.** Antes se podían sumar dos grupos para el mismo país (Ella Dijo en Argentina daba 12,5 + 8,34 = 20,84 en vez de 25)."),
      vineta("**Los textos de territorio se comparan elemento por elemento**, no buscando una palabra adentro de un texto largo."),
      vineta("**Si falta un dato, ya no se asume control mundial.** Queda NVFT y marcado para revisar."),
      vineta("**Columnas nuevas de auditoría y alertas**, para entender por qué salió cada número sin tener que abrir la query.")]

C += [h1("Pasos que sigue:")]

C += [h2("1. Definir el alcance", "37 a 83"),
      p("Acá se cargan las tres listas fijas que definen todo lo demás:"),
      vineta("lista: las obras a analizar, pegadas como números separados por coma. Es el único lugar que hay que tocar para cambiar las obras (admite espacios y saltos de línea, y hasta 1000 obras)."),
      vineta("paises: los cinco territorios del reporte (Argentina, Chile, Colombia, Perú y Uruguay)."),
      vineta("regiones: un diccionario de regiones que pueden aparecer en los contratos en lugar de los países, por ejemplo LATIN AMERICA o SOUTH AMERICA. Si aparece una región nueva que contenga alguno de los cinco países, se agrega acá."),
      p("Los bloques digitos y numeros solo sirven para partir la lista de obras en filas; no hay que tocarlos.")]

C += [h2("2. Leer los datos, una sola vez", "88 a 181"),
      p("Cada tabla se lee una vez, ya filtrada a las obras de la lista:"),
      vineta("mv_raw: las participaciones de cada obra (autor, editor, grupo IP, contrato asociado, si es controlada por Sony y los tres porcentajes)."),
      vineta("lineas_raw: las líneas de control de la obra, que salen de contract_territories. Es una fila por obra y contrato, con el texto de qué incluye y qué excluye. Ese texto ya viene con los ajustes propios de la obra aplicados."),
      vineta("fb_faltan, fb_conteo y fb: el respaldo. Si una participación controlada tiene un contrato que no tiene línea propia para esa obra, se toma el texto de territorio más repetido de ese mismo contrato en otras obras. Solo se busca para esos contratos, por eso no pesa."),
      vineta("vinfo: nombre, oficina de origen y vencimiento de los contratos involucrados."),
      vineta("song_info: título, fecha de alta en Tempo y song_not_ours_dt (la fecha en que la obra dejó de ser nuestra, que dispara el NOP)."),
      vineta("iswc: un ISWC por obra (el preferido; si no hay, cualquiera). En la versión anterior este bloque estaba pero no se usaba; ahora sale en el reporte.")]

C += [h2("3. Juntar todo en una sola lista", "186 a 201"),
      p("El bloque u0 pone en un mismo listado dos tipos de filas:"),
      vineta("Filas M: cada participación de la obra. Si su contrato no tiene línea propia, la fila lleva el texto de respaldo."),
      vineta("Filas L: cada línea de control de la obra, con su texto de territorio."),
      p("Tener todo en la misma lista es lo que permite que la query sea rápida: de acá en adelante nadie vuelve a leer las tablas, todo se resuelve mirando filas de esta lista.")]

C += [h2("4. Ordenar los textos", "203 a 239"),
      p("Antes de comparar, se limpian los textos para que no haya falsos positivos ni negativos:"),
      vineta("El grupo IP se pasa a palabras sueltas y se separa la parte excluida. Por ejemplo, WORLD EX PHILIPPINES queda como: incluye WORLD, excluye PHILIPPINES."),
      vineta("El texto del contrato se pasa a mayúsculas, sin tildes, sin el sufijo (REG) y sin los prefijos Include: o Exclude:, y queda como una lista separada por punto y coma. Por ejemplo, Include: Argentina (REG);PERÚ queda como ;ARGENTINA;PERU;"),
      vineta("En el mismo paso se le pega a cada fila el nombre, la oficina y el vencimiento de su contrato."),
      p("Como se compara elemento por elemento, PERU solo coincide con PERU y nunca con otro país que lo contenga en el nombre.")]

C += [h2("5. Cruzar cada fila con cada país", "241 a 267"),
      p("El bloque u4 repite cada fila de la lista una vez por cada país y anota, para ese país:"),
      vineta("si el grupo IP nombra al país, nombra una región que lo incluye, o lo excluye;"),
      vineta("si el texto del contrato dice World, nombra al país o a una región que lo incluye, o lo excluye."),
      p("Todavía no decide nada: solo deja las marcas para los pasos siguientes.")]

C += [h2("6. Elegir el grupo IP de cada país", "269 a 320"),
      p("Una obra puede tener varios grupos IP (por ejemplo ARGENTINA y All Other Contractual Territories). Para cada país se queda con uno solo, el más específico:"),
      tabla(["Prioridad", "Cuándo", "Ejemplo"],
            [["1", "El grupo nombra al país", "ARGENTINA"],
             ["2", "El grupo nombra una región que incluye al país", "LATIN AMERICA"],
             ["3", "Grupo mundial (All…, World, o vacío)", "All Other Contractual Territories"]],
            [1500, 3900, 3960]),
      p("Si el grupo excluye al país (WORLD EX ARGENTINA), ese grupo no cuenta para ese país."),
      p("Si el grupo elegido no es de Sony, el país queda NVFT: no se cae al grupo genérico. Y si hay dos grupos con la misma prioridad, se usa uno y se avisa en alertas."),
      p("Esto es lo que corrige Ella Dijo: en Argentina se usa solo el grupo ARGENTINA y da 25, en lugar de sumar los dos grupos.")]

C += [h2("7. Decidir si el país está cubierto", "269 a 358"),
      p("Es el núcleo de la lógica y lo que más cambió. La pregunta es: ¿Sony tiene contrato en ese país para esta obra?"),
      p("Primero se evalúa cada texto de territorio contra el país, en este orden: si el país o su región están excluidos, no cubre; si dice World, nombra al país o a su región, cubre; si no, no cubre."),
      p("Después se decide para cada participación del grupo elegido:"),
      tabla(["Situación", "Resultado"],
            [["Alguna línea de control de la obra cubre el país", "Cuenta"],
             ["El contrato asociado a la participación cubre el país", "Cuenta"],
             ["La participación no tiene contrato asociado", "Cuenta (y se avisa en alertas)"],
             ["Ninguna de las anteriores", "No cuenta"]],
            [6000, 3360]),
      p("Por qué cambió: en Baba O'Riley la participación de Westminster figura con el contrato 1525818, cuyo territorio es Asia, así que la versión anterior daba NVFT en los cinco países. Pero la obra tiene otras líneas de control, la 1551025 (ABKCO, World con exclusiones que no tocan a nuestros países) y la 1146885 (Westminster Admin, con los cinco países explícitos). El grupo All Other Contractual Territories quiere decir justamente eso: los demás territorios contratados. Con la regla nueva da 50 / 100 / 100, igual que el front."),
      p("Cuando una fila cuenta gracias a otra línea de control y no a su contrato asociado, queda marcada en alertas para poder revisarla."),
      p("Si el contrato asociado no tiene texto en ningún lado, no se asume control: la participación no cuenta, salvo que otra línea de control cubra el país.")]

C += [h2("8. Evitar contar dos veces", "360 a 380"),
      p("Solo se suman las participaciones controladas por Sony del grupo elegido que quedaron cubiertas. Para las listas de texto (editores, contratos, reglas), cada valor se marca la primera vez que aparece y se ignora el resto, así ningún nombre sale repetido.")]

C += [h2("9. Armar una fila por obra y país", "382 a 474"),
      p("El bloque res junta todo lo calculado en una fila por obra y país: los tres porcentajes, las listas de editores y contratos, las líneas que cubren el país con su vencimiento, el texto de auditoría y las marcas para las alertas."),
      p("Un detalle técnico: Redshift exige que todas las listas de una misma consulta se ordenen por la misma columna. Para cumplirlo, cada fila se copia una vez por cada lista (bloques listas y u11) y todas se ordenan por una columna común llamada orden. No cambia ningún resultado; es solo para que Redshift lo acepte en una sola consulta.")]

C += [h2("10. Clasificar el resultado", "478 a 550"),
      p("El SELECT final decide qué mostrar en cada uno de los tres porcentajes (perf, mech y sync):"),
      tabla(["Orden", "Condición", "Resultado"],
            [["1", "La obra tiene fecha de baja (song_not_ours_dt)", "NOP"],
             ["2", "La obra no tiene participaciones cargadas en Tempo", "SIN DATOS"],
             ["3", "No hay participaciones que cuenten, o la suma da cero", "NVFT"],
             ["4", "Cualquier otro caso", "El porcentaje"]],
            [1100, 5000, 3260]),
      p("Los tres porcentajes se evalúan por separado, así que una obra puede tener valor en perf y NVFT en mech."),
      p("SIN DATOS es nuevo: antes esas obras salían como NVFT y no se podía distinguir una obra sin control de una obra sin datos."),
      p("También clasifica el estado de los contratos, mirando solo las líneas que cubren el país:"),
      tabla(["Estado", "Cuándo"],
            [["SIN CONTROL", "No hay participaciones que cuenten"],
             ["SIN LINEA DE CONTROL", "Cuenta solo por participaciones sin contrato"],
             ["TODOS VENCIDOS", "Todas las líneas que cubren el país están vencidas"],
             ["MIXTO (alguno vencido)", "Hay líneas vencidas y otras vigentes o sin vencimiento"],
             ["SIN VENCIMIENTO", "Ninguna línea tiene fecha de vencimiento"],
             ["VIGENTE", "Hay líneas con vencimiento futuro y ninguna vencida"]],
            [3000, 6360])]

C += [h2("11. Unir todo contra la grilla", "551 a 556"),
      p("El FROM parte de la lista de obras cruzada con los cinco países (76 obras dan 380 filas) y le engancha todo lo calculado con LEFT JOIN. Eso asegura que, si para una obra en un país no se encontró nada, la fila igual aparece, con NVFT o SIN DATOS, y no desaparece del reporte.")]

C += [h1("Columnas de auditoría y alertas"),
      p("Al final de cada fila hay columnas para entender el resultado sin abrir la query:"),
      vineta("grupo_ip_usado y como_se_eligio_grupo: qué grupo se usó y por qué (paso 6)."),
      vineta("lineas_de_control_obra: todas las líneas de control de la obra."),
      vineta("lineas_que_cubren_el_pais: las que cubren ese país, con su vencimiento."),
      vineta("texto_territorio_contratos: el texto de territorio de cada contrato tal como está en Tempo, y si cubre o no el país."),
      vineta("regla_territorial: la regla que se aplicó a cada participación."),
      p("La columna alertas avisa los casos que conviene mirar:"),
      tabla(["Alerta", "Qué significa"],
            [["CONTROL SOSTENIDO POR OTRA LINEA DE CONTROL", "El contrato asociado no cubre el país, pero otra línea de la obra sí (caso Baba O'Riley)."],
             ["VARIOS GRUPOS CON LA MISMA PRIORIDAD", "Dos grupos IP nombran al país; se usó uno solo."],
             ["PARTICIPACION SIN CONTRATO", "Se sumó una participación que no tiene contrato asociado."],
             ["CONTRATO SIN TEXTO DE TERRITORIO", "El contrato no tiene territorio cargado en ningún lado. Verificar."],
             ["TERRITORIO TOMADO DE OTRA OBRA DEL CONTRATO", "Se usó el texto de respaldo (paso 2)."],
             ["OBRA AUSENTE EN song_share_detail_mv", "Tempo no devuelve participaciones para la obra (por ejemplo, un autor sin sociedad cargada u obra marcada para borrar)."],
             ["TOTAL SUPERA 100", "Posible doble conteo en la cadena de editores. Revisar."]],
            [4200, 5160])]

C += [h1("Cómo se usa el resultado"),
      p("El archivo se carga en el panel de Ranking Digital Regional, que lo cruza por Tempo ID contra el reporte del Back Office y compara los porcentajes mecánicos de ambas fuentes. Según el resultado, marca cada obra automáticamente:"),
      tabla(["Situación", "Marca"],
            [["Los dos porcentajes coinciden", "OK BO-Tempo"],
             ["BO 0% y la obra se originó en Argentina", "OK - Obra AR"],
             ["BO 0% y la obra se originó en México", "OK - Obra MX"],
             ["Diferencia por cualquier otro motivo", "REVISAR"]],
            [6000, 3360]),
      p("La oficina de origen (originating_office) sigue estando solo para esta diferenciación; no se usa en el cálculo del porcentaje.")]

C += [h1("Puntos abiertos:"),
      vineta("Contratos vencidos: hoy una obra con todas sus líneas vencidas igual muestra el porcentaje, marcada como TODOS VENCIDOS. Falta definir si debería pasar a NVFT."),
      vineta("Regiones: si en un contrato aparece una región nueva que contenga a alguno de los cinco países (por ejemplo, Andean Pact), hay que sumarla al diccionario del paso 1."),
      vineta("Obras sin datos: una obra que sale SIN DATOS no tiene participaciones en Tempo para este reporte. Conviene revisarla en el front antes de cargarla."),
      vineta("Validación: la versión 7 se probó con los casos conocidos (Ella Dijo, Sin Sentimientos, Te Encontre, Baba O'Riley) y da lo mismo que el front. Si aparece una diferencia nueva, se suma como caso de prueba antes de corregir.")]

# ---------------------------------------------------------------------------
tmp = AQUI / "_tmp_docx"
if tmp.exists(): shutil.rmtree(tmp)
with zipfile.ZipFile(ORIGINAL) as z:
    z.extractall(tmp)
doc = (tmp / "word/document.xml").read_text(encoding="utf-8")
ini = doc.index("<w:body>") + len("<w:body>")
fin = doc.index("<w:sectPr")
doc = doc[:ini] + "".join(C) + doc[fin:]
(tmp / "word/document.xml").write_text(doc, encoding="utf-8")
if SALIDA.exists(): SALIDA.unlink()
with zipfile.ZipFile(ORIGINAL) as zin, zipfile.ZipFile(SALIDA, "w", zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        zout.writestr(item, (tmp / item.filename).read_bytes() if not item.is_dir() else b"")
shutil.rmtree(tmp)
print("OK", SALIDA)
