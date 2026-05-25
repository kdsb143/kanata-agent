# ==========================================
# Stage 1: Build Frontend & Download Playwright
# ==========================================
FROM node:20-slim AS frontend-builder
WORKDIR /opt/hermes

RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/
COPY ui-tui/package.json ui-tui/package-lock.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/

ENV npm_config_install_links=false

RUN npm install --prefer-offline --no-audit && \
    (cd web && npm install --prefer-offline --no-audit) && \
    (cd ui-tui && npm install --prefer-offline --no-audit)

COPY web ./web
COPY ui-tui ./ui-tui

# Tell Playwright where to download the browsers inside Stage 1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright
RUN npx playwright install --with-deps chromium --only-shell

RUN cd web && npm run build && \
    cd ../ui-tui && npm run build && \
    npm cache clean --force

# ==========================================
# Stage 2: Resolve and Compile Python Venv
# ==========================================
FROM ghcr.io/astral-sh/uv:0.11.6-python3.13-trixie@sha256:b3c543b6c4f23a5f2df22866bd7857e5d304b67a564f4feab6ac22044dde719b AS uv_source
FROM python:3.11-slim AS python-builder
WORKDIR /opt/hermes

COPY --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc python3-dev libffi-dev git && \
    rm -rf /var/lib/apt/lists/*

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

COPY pyproject.toml uv.lock ./
RUN touch ./README.md
RUN uv sync --frozen --no-install-project --extra all --extra messaging

# ==========================================
# Stage 3: Ultra-Lean Production Runtime
# ==========================================
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source
FROM python:3.11-slim AS runtime
WORKDIR /opt/hermes

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MALLOC_ARENA_MAX=2 \
    PORT=8080 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    HERMES_CONTAINER=1 \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_HOME=/opt/data \
    PATH="/opt/data/.local/bin:/opt/hermes/.venv/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ripgrep ffmpeg procps git openssh-client docker-cli tini && \
    rm -rf /var/lib/apt/lists/*

RUN useradd -u 10000 -m -d /opt/data hermes
COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

# Pull compiled virtual environment
COPY --from=python-builder /opt/hermes/.venv /opt/hermes/.venv

# Pull static web, modules, AND the downloaded Playwright browsers from Stage 1
COPY --from=frontend-builder /opt/hermes/web /opt/hermes/web
COPY --from=frontend-builder /opt/hermes/ui-tui /opt/hermes/ui-tui
COPY --from=frontend-builder /opt/hermes/node_modules /opt/hermes/node_modules
COPY --from=frontend-builder /opt/hermes/.playwright /opt/hermes/.playwright

COPY . .

# Fast editable link setup
RUN uv pip install --no-cache-dir --no-deps -e "."

USER root
RUN mkdir -p /opt/data && \
    chmod -R a+rX /opt/hermes && \
    chown -R hermes:hermes /opt/hermes/.venv /opt/hermes/ui-tui /opt/hermes/node_modules /opt/hermes/.playwright /opt/data

VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh" ]
