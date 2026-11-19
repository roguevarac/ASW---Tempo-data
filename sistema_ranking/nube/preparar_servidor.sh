#!/usr/bin/env bash
# Prepara un servidor Ubuntu (24.04 LTS o posterior; por ejemplo, una instancia EC2 de AWS) para el Auditor de Rankings
# Digitales: Docker Engine oficial con Compose y Buildx, git, GitHub CLI, zona horaria de Buenos Aires y memoria de
# intercambio. No toca datos. Se puede correr varias veces.
#   bash preparar_servidor.sh
set -euo pipefail
[ "$(id -u)" = 0 ] && SUDO="" || SUDO="sudo"
paso() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

. /etc/os-release
[ "${ID:-}" = ubuntu ] || { echo "Este script es para Ubuntu (encontré: ${PRETTY_NAME:-desconocido})."; exit 1; }

paso "1/5 Paquetes base"
$SUDO apt-get update -q
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q ca-certificates curl git gh tzdata

paso "2/5 Docker Engine (repositorio oficial de Docker)"
if ! docker compose version > /dev/null 2>&1 || ! docker buildx version > /dev/null 2>&1; then
    $SUDO install -m 0755 -d /etc/apt/keyrings
    $SUDO curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    $SUDO chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
        | $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update -q
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
if [ -d /run/systemd/system ]; then
    $SUDO systemctl enable --now docker > /dev/null   # arranca solo al encender el servidor (y con él, el sistema)
fi
if [ -n "$SUDO" ] && ! id -nG "$USER" | grep -qw docker; then
    $SUDO usermod -aG docker "$USER"
    NUEVO_GRUPO=1
fi

paso "3/5 Zona horaria (nombres de los respaldos y horarios del Panel)"
if [ -d /run/systemd/system ]; then $SUDO timedatectl set-timezone America/Argentina/Buenos_Aires
else $SUDO ln -sf /usr/share/zoneinfo/America/Argentina/Buenos_Aires /etc/localtime; fi

paso "4/5 Memoria de intercambio (2 GB, para servidores chicos)"
if [ -d /run/systemd/system ] && ! swapon --show=NAME --noheadings | grep -q .; then
    $SUDO fallocate -l 2G /swapfile && $SUDO chmod 600 /swapfile && $SUDO mkswap /swapfile > /dev/null && $SUDO swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | $SUDO tee -a /etc/fstab > /dev/null
    echo "Creada /swapfile (2 GB)."
else
    echo "Ya hay memoria de intercambio (o no corresponde en este entorno)."
fi

paso "5/5 Listo"
docker --version 2> /dev/null || $SUDO docker --version
$SUDO docker compose version
echo
if [ "${NUEVO_GRUPO:-0}" = 1 ]; then
    echo "Tu usuario quedó en el grupo docker: cerrá esta sesión (exit) y volvé a entrar antes de seguir con la guía."
else
    echo "Seguí con la guía (sistema_ranking/nube/AWS.md, paso 4)."
fi
