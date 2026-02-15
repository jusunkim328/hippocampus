FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .

# 환경변수: ES_URL, ES_API_KEY (필수), PORT (기본 8080),
# SCHEDULER_ENABLED (기본 false), REFLECT_INTERVAL_SECONDS, BLINDSPOT_INTERVAL_SECONDS
EXPOSE 8080
CMD ["python", "server.py"]
