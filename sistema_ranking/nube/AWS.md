# Pasar el Auditor de Rankings Digitales a un servidor en AWS

El sistema pasa de la PC a un servidor de AWS (EC2, Ubuntu). Funciona igual: mismo programa, mismos datos, mismos
usuarios y **el mismo enlace** de Tailscale. La diferencia es que el servidor está siempre encendido y no depende de
que nadie inicie sesión en Windows.

- **Quién lo hace:** la persona responsable (los pasos con ✋ los hace una persona: la consola
  de AWS, los inicios de sesión y las confirmaciones).
- **Tiempo:** cerca de una hora. El sistema queda sin uso solo entre los pasos 5 y 7 (unos 15 minutos): avisá antes.
- **Antes de empezar:** la cuenta de AWS aprobada, la cuenta de Tailscale con la que hoy se comparte el enlace y la
  cuenta de GitHub con acceso al repositorio.

Los comandos `ssh`/`scp` se corren en la terminal de Ubuntu de la PC; los demás, en el servidor (después de `ssh`).

## 1. Crear el servidor ✋

En la consola de AWS (https://console.aws.amazon.com/ec2/), región **us-east-2 (Ohio)**, la de la cuenta:

1. **Instancias > Lanzar instancias.**
2. **Nombre:** `auditor-rankings`.
3. **Imagen:** Ubuntu Server 24.04 LTS (64 bits, x86).
4. **Tipo de instancia:** `t3.small` (2 GB de memoria, unos USD 15 por mes). Si con el uso se nota lento, se cambia
   después a `t3.medium` sin perder nada (instancia detenida > Acciones > Configuración de instancia > Cambiar tipo).
5. **Par de claves:** Crear un nuevo par de claves, nombre `auditor-aws`, tipo ED25519, formato `.pem`. Se descarga
   el archivo `auditor-aws.pem`: guardalo, es la llave del servidor (no se puede volver a bajar).
6. **Configuración de red:** dejá marcado solo **Permitir el tráfico de SSH desde: Mi IP**. No habilites HTTP ni
   HTTPS: el acceso de las personas va por el enlace de Tailscale, que no necesita puertos abiertos.
7. **Almacenamiento:** 30 GiB, gp3.
8. **Lanzar instancia.** Cuando figure "En ejecución", copiá su **Dirección IPv4 pública** (en esta guía, `IP`).

## 2. Respaldo del disco y aviso de gastos ✋

- **Instantáneas diarias del disco:** EC2 > Elastic Block Store > **Administrador del ciclo de vida** > Crear
  política del ciclo de vida de EBS > Política de instantáneas de EBS. Destino: instancias con la etiqueta
  `Name = auditor-rankings`; cada 24 horas; conservar 7. (Además, el sistema hace su propio respaldo diario de la base
  y conserva 14, en el disco del servidor.)
- **Presupuesto:** Billing > Budgets > Crear presupuesto mensual (por ejemplo, USD 30) con aviso por email.

## 3. Conectarse al servidor (desde la PC)

```sh
mkdir -p ~/.ssh && cp "/mnt/c/Users/<usuario_windows>/Downloads/auditor-aws.pem" ~/.ssh/ && chmod 600 ~/.ssh/auditor-aws.pem
ssh -i ~/.ssh/auditor-aws.pem ubuntu@IP
```

Si se queda esperando y no conecta:
- la red de la empresa puede bloquear el puerto 22: probá desde otra red;
- o tu IP cambió: en la instancia > Seguridad > grupo de seguridad > editar la regla SSH > Mi IP.

## 4. Preparar el servidor e instalar el sistema (en el servidor)

```sh
sudo apt-get update && sudo apt-get install -y gh
gh auth login -h github.com -p https -w       # ✋ muestra un código: abrí github.com/login/device en la PC
gh auth setup-git                             # para que "actualizar" pueda bajar las versiones nuevas
mkdir -p ~/proyectos
gh repo clone roguevarac/ASW---Tempo-data ~/proyectos/ranking -- -b main
bash ~/proyectos/ranking/sistema_ranking/nube/preparar_servidor.sh
exit
```

`preparar_servidor.sh` instala Docker (el oficial, con Compose y Buildx), pone la hora de Buenos Aires y agrega
memoria de intercambio. Se sale (`exit`) para que tome el permiso de Docker; volvé a entrar e instalá:

```sh
ssh -i ~/.ssh/auditor-aws.pem ubuntu@IP
cd ~/proyectos/ranking/sistema_ranking && bash ranking.sh instalar
```

A "¿Crear ahora un usuario administrador nuevo?" respondé **N**: los usuarios vienen con los datos en el paso 7.

## 5. Retirar la PC como servidor (en la PC) ✋

```sh
cd ~/proyectos/ranking/sistema_ranking && bash ranking.sh actualizar
bash ranking.sh retirar
```

`retirar` deja de compartir el enlace, hace el **respaldo final**, apaga el sistema en la PC y cambia los accesos de
Windows para que abran el enlace del servidor. Desde ese momento la PC ya no arranca el sistema (si alguien lo
intenta, el comando indica el enlace). Al final muestra el nombre del respaldo, por ejemplo `ranking_20261118_101500`
(en esta guía, `NOMBRE`).

## 6. Copiar el respaldo al servidor (en la PC)

```sh
ssh -i ~/.ssh/auditor-aws.pem ubuntu@IP 'mkdir -p ~/proyectos/ranking-respaldos'
scp -i ~/.ssh/auditor-aws.pem ~/proyectos/ranking-respaldos/NOMBRE.dump ~/proyectos/ranking-respaldos/NOMBRE_archivos.tgz \
    ubuntu@IP:proyectos/ranking-respaldos/
```

## 7. Restaurar los datos y el enlace (en el servidor) ✋

```sh
cd ~/proyectos/ranking/sistema_ranking && bash ranking.sh restaurar NOMBRE
```

Antes de compartir, en https://login.tailscale.com/admin/machines: si todavía figura la máquina `auditor-rankings`
de la PC, eliminala (··· > Remove). Así el servidor toma el mismo nombre y **el enlace no cambia**.

```sh
bash ranking.sh compartir
```

Muestra un enlace de Tailscale: abrilo en el navegador de la PC e iniciá sesión con **la misma cuenta** que se usaba.
Al terminar, el enlace tiene que ser el mismo de siempre (`https://auditor-rankings.<red>.ts.net/`). Si sale con
`-1` al final, eliminá en esa página la máquina vieja, renombrá la nueva a `auditor-rankings` y corré
`bash ranking.sh compartir` de nuevo.

## 8. Comprobar

```sh
bash ranking.sh verificar
```

- Tiene que decir "Todo en orden", con la misma cantidad de usuarios, obras y archivos que tenía la PC.
- Abrí el enlace, ingresá y revisá la tabla principal, la tabla por territorio y el Panel de control.
- Enviá un reporte BO de prueba. El servidor de BO ahora ve la conexión desde AWS; si lo rechaza, pasame el
  "Registro de la conexión".
- Las personas siguen entrando con el mismo enlace y su misma contraseña. Tienen que ingresar una vez más (las
  sesiones abiertas en la PC no valen en el servidor); si alguien instaló la aplicación desde el enlace, sigue
  funcionando.

## 9. Dirección propia con HTTPS, sin Tailscale (hecho el 17/11/2026)

En lugar del enlace de Tailscale (o junto con él), el servidor tiene su propia dirección:
**`https://<IP-CON-GUIONES>.sslip.io`**. `sslip.io` es un servicio gratuito que traduce el nombre a la IP que contiene
(por ejemplo `1-2-3-4` → `1.2.3.4`), así que no hace falta comprar un dominio. Por delante del sistema corre **Caddy**,
que obtiene el certificado HTTPS de Let's Encrypt y lo renueva solo. El sistema no cambia: sigue escuchando solo en
`127.0.0.1:8000` del servidor.

1. **IP fija** (✋ CloudShell de la cuenta del servidor). Sin IP elástica, la IP cambia al detener e iniciar la
   instancia, y con ella la dirección:
   ```sh
   R=us-east-2; ID=$(aws ec2 describe-instances --region $R --filters Name=tag:Name,Values=auditor-rankings Name=instance-state-name,Values=running --query 'Reservations[0].Instances[0].InstanceId' --output text)
   EIP=$(aws ec2 allocate-address --region $R --domain vpc --query AllocationId --output text)
   aws ec2 associate-address --region $R --instance-id $ID --allocation-id $EIP
   ```
2. **Puertos** (✋ CloudShell), en el grupo de seguridad `auditor-rankings-ssh`:
   - 80 abierto a todos: solo sirve para el certificado; Caddy redirige todo lo demás a HTTPS.
   - 443 abierto a todos (`0.0.0.0/0`), para entrar desde cualquier red. Para limitarlo a la VPN de la empresa, en
     lugar de `0.0.0.0/0` se pone la IP de salida de la VPN (`<IP_DE_SALIDA_VPN>/32`).
   - 22 (SSH) sigue limitado a la IP de la PC.
3. **Caddy** (en el servidor). La dirección sale de la IP fija, con guiones:
   ```sh
   mkdir -p ~/caddy && printf '<IP-CON-GUIONES>.sslip.io {\n\treverse_proxy 127.0.0.1:8000\n}\n' > ~/caddy/Caddyfile
   docker run -d --name caddy --restart unless-stopped --network host \
     -v ~/caddy/Caddyfile:/etc/caddy/Caddyfile:ro -v caddy_data:/data -v caddy_config:/config caddy:2.10
   docker logs caddy 2>&1 | grep 'certificate obtained'
   ```
   Caddy arranca solo con el servidor (`--restart unless-stopped`). El certificado queda en el volumen `caddy_data`.
   Si algún día cambia la IP fija, se cambia el nombre en el `Caddyfile` y se corre `docker restart caddy`.

En la PC, los accesos de Windows abren la dirección nueva: `SERVIDOR_REMOTO=https://<IP-CON-GUIONES>.sslip.io/` en
`~/.config/ranking-digital/ranking.env` y `bash ranking.sh acceso-directo`. El Panel de control muestra esta dirección
en "Acceso desde otras computadoras", con el botón "Copiar enlace".

**Copias del disco y gastos** (paso 2), hechos desde CloudShell: política de Data Lifecycle Manager "Auditor copia
diaria" (instancias con `Name = auditor-rankings`, 07:00 UTC = 04:00 de Buenos Aires, conserva 7) y presupuesto
`auditor-mensual` (USD 30, aviso al 80 % del gasto real y al 100 % del previsto).

## Después

- **Actualizar** (cuando haya mejoras): desde la PC,
  `ssh -i ~/.ssh/auditor-aws.pem ubuntu@IP 'cd ~/proyectos/ranking/sistema_ranking && bash ranking.sh actualizar'`.
- **Usuarios, respaldos y demás comandos:** igual que antes, pero en el servidor (`ssh` y después `bash ranking.sh ...`).
- **Reinicios:** el servidor arranca el sistema y Caddy solos al encenderse. Detener la instancia apaga el sistema; al
  iniciarla vuelve solo. Con la IP fija del paso 9, la IP y la dirección no cambian (`IP` = `<IP_DEL_SERVIDOR>`).
- **SSH desde otra red:** el puerto 22 solo acepta la IP de la PC (la de la VPN, `<IP_DE_SALIDA_VPN>`). Sin la VPN, la PC
  sale con otra IP y `ssh` queda esperando: conectá la VPN o agregá esa IP a la regla SSH del grupo de seguridad.
- **Volver a la PC** (si hiciera falta): en el servidor `bash ranking.sh respaldo`, copiá los dos archivos a
  `~/proyectos/ranking-respaldos` de la PC y ahí corré `bash ranking.sh reactivar` y `bash ranking.sh restaurar NOMBRE`.
  Nunca usen los dos sistemas a la vez.
- **Sin OneDrive en el servidor:** no hay espejo de auditoría ni copia de respaldos a OneDrive. Los respaldos quedan
  en el servidor (`~/proyectos/ranking-respaldos`, 14 días) y en las instantáneas diarias del disco (paso 2). El
  servicio `espejo` queda encendido sin copiar nada (avisa "apagado" al Panel de control).
