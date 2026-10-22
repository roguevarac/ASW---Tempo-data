# Instrucciones para Antigravity: dejar funcionando Ranking Digital en la PC del usuario

Estas instrucciones son para vos, el agente que trabaja en la PC del usuario. El objetivo es dejar Ranking Digital
funcionando en contenedores Docker, de forma limpia y prolija, con el ícono en el escritorio. Después, mantenerlo
actualizado con las mejoras que se suban a GitHub.

El código lo escribe y lo prueba Claude, y lo sube a GitHub. Vos lo instalás y lo actualizás en esta PC.
**No modifiques el código ni hagas push**: si algo hay que cambiar, pasale al usuario el mensaje de error para
Claude.

## Reglas (no negociables)

1. **Secretos.** Nunca pidas, leas, copies ni guardes la service_role key de Supabase, contraseñas de usuarios, el
   archivo `~/.config/ranking-digital/ranking.env` ni tokens. Cuando haga falta un secreto, el usuario lo escribe en
   su terminal; el script lo pide sin mostrarlo.
2. **Datos.** Nunca corras `docker compose down -v`, `docker volume rm`, `docker system prune` con volúmenes, ni
   borres `~/.config/ranking-digital`. Ahí están la base, los archivos del historial y las claves.
3. **`restaurar`, `migrar`, `vaciar-historial` y `empezar-de-cero` (de `bash ranking.sh`) reemplazan o borran
   datos.** Solo con el usuario presente y si él lo pide. `vaciar-historial` y `empezar-de-cero` los confirma él en su
   terminal.
4. **Todo desde la terminal de Ubuntu (bash, WSL2)**, dentro de `~/proyectos`. Nada desde `/mnt/c` ni desde
   PowerShell. No uses Docker Desktop: no existe en esta PC.
5. **Si un paso falla,** no improvises arreglos en el código. Mostrale al usuario la salida completa del comando y
   la de `bash ranking.sh logs`, para que se la pase a Claude.

## El entorno (ya está así; solo comprobalo)

- Windows corporativo, sin permisos de administrador. El usuario de Windows es `7000042560`.
- WSL2 con Ubuntu 26.04. El usuario tiene `sudo` en Ubuntu; la contraseña la escribe él.
- Docker Engine instalado dentro de Ubuntu (`docker`, `docker compose` v5) y el usuario en el grupo `docker`.
- Red corporativa: puede haber un proxy o un certificado de la empresa.

```bash
docker info > /dev/null && echo "Docker OK" || sudo service docker start
docker compose version
```

## Paso 1. Herramientas y acceso a GitHub (una sola vez)

```bash
sudo apt update && sudo apt install -y git curl openssl gh
gh auth status || gh auth login --hostname github.com --git-protocol https --web
gh auth setup-git
```

`gh auth login --web` muestra un código. El usuario lo ingresa en el navegador de Windows
(https://github.com/login/device) y autoriza. Vos no ves ni guardás ningún token.

## Paso 2. Bajar el proyecto con git

El proyecto se usa **como clon de git**: así `actualizar` trae las mejoras. No uses la copia de OneDrive
(`...\Backoffice\RANKING DIGITAL REGIONAL`), porque está desactualizada y no es un clon.

```bash
mkdir -p ~/proyectos
[ -d ~/proyectos/ranking ] && [ ! -d ~/proyectos/ranking/.git ] && mv ~/proyectos/ranking ~/proyectos/ranking-copia-vieja-$(date +%Y%m%d)
[ -d ~/proyectos/ranking/.git ] || git clone -b claude/funny-bell-bbdz84 https://github.com/roguevarac/ASW---Tempo-data.git ~/proyectos/ranking
cd ~/proyectos/ranking/sistema_ranking
git log -1 --oneline
```

## Paso 3. Instalar (sin preguntas)

```bash
cd ~/proyectos/ranking/sistema_ranking
bash ranking.sh instalar --automatico
```

Qué hace, en orden:
1. Crea las claves internas al azar en `~/.config/ranking-digital/ranking.env`. Si ya existían, las conserva y la
   base sigue igual.
2. Baja PostgreSQL 17 y Python. Si Docker Hub falla, usa solo los espejos `mirror.gcr.io` y `public.ecr.aws`.
3. Arma la imagen, levanta los contenedores (`ranking-digital-db-1` y `ranking-digital-api-1`) y crea la base.
4. Crea la aplicación **Ranking Digital** en Windows: escritorio, menú Inicio (abrir y "Apagar Ranking Digital") y
   arranque oculto del servidor al iniciar Windows.

| Si la salida dice | Hacé esto |
|---|---|
| `x509`, `certificate`, `SSL` | `bash ranking.sh certificados` (el usuario escribe su contraseña de Ubuntu) y repetí el paso 3 |
| `timeout`, `no such host`, `proxy` | Preguntale al usuario la dirección del proxy de la empresa y seguí la sección "Red de la empresa" de `sistema_ranking/README.md`; después repetí el paso 3 |
| `toomanyrequests` en las 3 fuentes | Esperá una hora y repetí, o `docker login` con la cuenta del usuario |
| Otra cosa | Regla 5 |

## Paso 4. Verificar

```bash
bash ranking.sh verificar
```

Tiene que terminar con **"Todo en orden."** y código de salida 0. Antes de migrar es normal ver "0 usuarios".

## Paso 5. Traer los datos de Supabase (lo hace el usuario, una sola vez)

Hacelo solo si `verificar` muestra **0 usuarios**. Si ya hay usuarios, la migración ya se hizo: no la repitas.

Pedile al usuario que, en **su** terminal de Ubuntu, corra:

```bash
cd ~/proyectos/ranking/sistema_ranking && bash ranking.sh migrar
```

Explicale qué contestar:
- **URL del proyecto:** Enter.
- **service_role key:** la copia él de Supabase > Project Settings > API Keys > service_role > Reveal. No se ve al
  pegarla.
- **Carpetas con CSV:** encuentra solas las de OneDrive. Enter para seguir.
- **Si faltan archivos del historial:** `1`.
- **Contraseña para cada usuario:** `S` y una contraseña nueva (mínimo 10 caracteres).

Cuando termine, corré `bash ranking.sh verificar` y confirmá:
- que están los usuarios, las obras y los archivos.

## Paso 6. Respaldo

```bash
bash ranking.sh respaldo
```

Deja la copia en `~/proyectos/ranking-respaldos`. También la copia sola al espejo de OneDrive:
`...\Latam\RANKING DIGITAL REGIONAL\respaldo_documentacion_sistema\respaldos`. No copies a mano: las rutas tienen
espacios.

**Espejo de OneDrive** (`...\Latam\RANKING DIGITAL REGIONAL`):
- el sistema copia ahí cada carga de charts y reportes, y la documentación;
- es solo de respaldo y auditoría: nunca borres ni edites nada ahí pensando que cambia el sistema, porque no lo
  cambia;
- si faltan archivos, `bash ranking.sh espejo` los vuelve a copiar.

## Paso 7. Entregar

Confirmale al usuario:
- que tiene la aplicación **Ranking Digital** en el escritorio y en el menú Inicio (la encuentra buscándola en
  Windows). Se abre en su propia ventana; si el servidor estaba apagado, lo enciende solo y muestra "Iniciando…";
- que el servidor arranca solo y oculto al iniciar Windows, sin ventanas negras, y que "Apagar Ranking Digital"
  (menú Inicio) lo apaga;
- que, si la quiere en la barra de tareas, la instala desde Edge:
  1. abre `http://localhost:8000` en una pestaña común de Edge (no InPrivate);
  2. usa el ícono Instalar de la barra de direcciones, o ··· > Aplicaciones > Instalar este sitio como aplicación;
  3. después, la ancla;
- que entra con su email y la contraseña nueva.

Si los accesos no aparecieron: `bash ranking.sh acceso-directo --automatico`.

## Actualizaciones (cada vez que el usuario diga que hay mejoras nuevas en GitHub)

```bash
cd ~/proyectos/ranking/sistema_ranking
bash ranking.sh actualizar
```

`actualizar`:
1. hace un respaldo (también en OneDrive);
2. baja la versión nueva (`git pull --ff-only`);
3. la arma y la arranca;
4. actualiza los accesos de Windows (la aplicación);
5. verifica.

Los datos no se tocan. Si la versión nueva no arranca, **vuelve sola a la anterior** y te dice "Quedó funcionando la
versión anterior": en ese caso pasale la salida al usuario para Claude (regla 5).

Si dice "Hay cambios hechos a mano en esta copia", alguien editó archivos del proyecto. No los borres sin
preguntarle al usuario.

## Si la API se reinicia sola

`abrir` ya no reinicia un sistema que está funcionando, y el proxy queda guardado en la configuración. Si igual ves en
`bash ranking.sh logs` "Shutting down" seguido de "Started server process" sin que nadie haya corrido `actualizar`,
`instalar` o `migrar`:
- No corras `abrir` en un bucle para probar.
- Mirá cuántas veces se reinició: `docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' ranking-digital-api-1`.
- Contá los mantenedores (tiene que haber uno solo), desde bash:
  `ps -ef | grep -c "[r]anking.sh abrir --mantener"`.
- Pasale todo eso al usuario para Claude.

## Comandos útiles (no cambian datos)

| Comando | Para qué |
|---|---|
| `bash ranking.sh verificar` | Estado completo; código 0 si está todo bien |
| `bash ranking.sh estado` | Contenedores y dirección |
| `bash ranking.sh logs` | Últimos mensajes de la API y la base, para diagnosticar |
| `bash ranking.sh espejo` | Copia al espejo de OneDrive los archivos cargados que falten (no borra ni pisa nada) |
| `bash ranking.sh abrir` / `detener` | Prender / apagar (los datos quedan) |

## Cómo está organizado (para orientarte)

- `sistema_ranking/docker-compose.yml`, proyecto `ranking-digital`:
  - `db`: PostgreSQL 17, con un volumen para los datos;
  - `instalador`: crea la base la primera vez;
  - `api`: el servidor y el front, solo en `127.0.0.1`;
  - `herramientas`: un perfil que usan migrar, usuarios y respaldo.
- Volúmenes:
  - `ranking-digital_datos_db`: la base;
  - `ranking-digital_archivos`: el historial de CSV;
  - `ranking-digital_exportacion`: lo bajado de Supabase.
- Configuración: `~/.config/ranking-digital/ranking.env`. Es secreta (regla 1).
- Documentación completa: `sistema_ranking/README.md`, sección "En tu PC: Ubuntu (WSL2) + Docker Engine".
