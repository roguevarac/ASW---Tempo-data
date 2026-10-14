#!/bin/sh
# Recrea la base de prueba local desde cero (Postgres 16 del entorno, puerto 54340).
set -eu
psql -h localhost -p 54340 -U postgres -q -c "DROP DATABASE IF EXISTS ranking WITH (FORCE)" -c "CREATE DATABASE ranking"
PGURL="postgresql://postgres@localhost:54340/ranking" AUTHENTICATOR_PASSWORD="prueba_local_123" "$(dirname "$0")/../db/instalar.sh"
