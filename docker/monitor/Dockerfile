# syntax=docker/dockerfile:1.6
# agent-fleet-skeleton — Monitor container.
#
# Lightweight Python stdlib HTTP server. No npm, no external packages.
# Reads workspace files directly via the read-only bind mount and serves
# a live dashboard at http://localhost:${MONITOR_PORT:-8080}.

FROM python:3.12-alpine

ENV WORKDIR=/workspace \
    MONITOR_PORT=8080

WORKDIR /app

COPY docker/monitor/server.py docker/monitor/dashboard.html ./

CMD ["python3", "server.py"]
