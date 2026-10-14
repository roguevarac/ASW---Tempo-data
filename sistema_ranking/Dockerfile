# API + front del sistema Ranking Digital.
FROM python:3.12-slim
WORKDIR /app
COPY api/requirements.txt api/requirements.txt
RUN pip install --no-cache-dir -r api/requirements.txt
COPY api/ api/
COPY admin/ admin/
COPY migracion/ migracion/
COPY front/index.html front/tempo-client.js front/papaparse.min.js front/
RUN useradd --system --uid 10001 ranking && mkdir -p /data/storage && chown ranking /data/storage
USER ranking
ENV STORAGE_DIR=/data/storage FRONT_DIR=/app/front
WORKDIR /app/api
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
