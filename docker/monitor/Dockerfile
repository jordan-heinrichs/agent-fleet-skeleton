FROM python:3.12-alpine
ENV WORKDIR=/workspace MONITOR_PORT=8080
WORKDIR /app
COPY docker/monitor/server.py docker/monitor/dashboard.html ./
CMD ["python3", "server.py"]
