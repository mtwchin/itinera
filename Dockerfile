FROM python:3.12-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt ./
RUN pip install -r requirements.txt

COPY backend ./backend
COPY alembic ./alembic
COPY alembic.ini ./alembic.ini

EXPOSE 8000

# Default to API; docker-compose overrides `command:` for the worker.
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
