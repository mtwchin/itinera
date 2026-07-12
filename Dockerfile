FROM python:3.12-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --requirement requirements.txt


FROM python:3.12-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgomp1 \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 itinera \
    && useradd --uid 10001 --gid itinera --no-create-home --shell /usr/sbin/nologin itinera

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=itinera:itinera backend ./backend
COPY --chown=itinera:itinera alembic ./alembic
COPY --chown=itinera:itinera alembic.ini ./alembic.ini

USER itinera

EXPOSE 8000

# Compose and Render override this for workers and the outbox dispatcher.
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
