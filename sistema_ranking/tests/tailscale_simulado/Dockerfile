# Tailscale simulado para tests/test_docker_linux.py (la red de las pruebas no llega a Tailscale). Se arma sobre la
# imagen de la API de la prueba: no baja nada. El estado vive en /var/lib/tailscale (el volumen "tunel"), como el real.
ARG BASE
FROM ${BASE}
USER root
COPY tailscale /usr/local/bin/tailscale
RUN chmod 755 /usr/local/bin/tailscale
ENTRYPOINT ["sh", "-c", "mkdir -p /var/lib/tailscale && env > /var/lib/tailscale/entorno && exec sleep infinity"]
