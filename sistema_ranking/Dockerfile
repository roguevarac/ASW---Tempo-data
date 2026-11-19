# API + front del sistema Ranking Digital.
# IMAGEN_PYTHON permite usar un espejo interno de la empresa (por ejemplo Artifactory) si Docker Hub está bloqueado.
ARG IMAGEN_PYTHON=python:3.12-slim
FROM ${IMAGEN_PYTHON}
# Certificados de la empresa (certificados/*.crt): necesarios detrás de un proxy que inspecciona HTTPS.
COPY certificados/ /usr/local/share/ca-certificates/empresa/
RUN find /usr/local/share/ca-certificates/empresa -type f ! -name '*.crt' -delete \
    && update-ca-certificates > /dev/null
ENV PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
WORKDIR /app
COPY api/requirements.txt api/requirements.txt
RUN pip install --no-cache-dir --disable-pip-version-check -r api/requirements.txt
COPY api/ api/
COPY admin/ admin/
COPY migracion/ migracion/
COPY db/ db/
COPY front/ front/
RUN useradd --system --uid 10001 ranking \
    && mkdir -p /data/storage /exportacion && chown ranking /data/storage /exportacion
USER ranking
ENV STORAGE_DIR=/data/storage FRONT_DIR=/app/front PYTHONDONTWRITEBYTECODE=1
WORKDIR /app/api
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
