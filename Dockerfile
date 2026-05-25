# ==========================================
# Stage 1: Build the Frontend Assets (Node.js)
# ==========================================
FROM node:20-slim AS frontend-builder
WORKDIR /opt/hermes

# Install minimal git utilities needed for specific package setups
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

# Copy only what is necessary for the frontend build engine
COPY package.json package-lock.json ./
COPY web/package.json web/package-lock.json web/
COPY ui-tui/package.json ui-tui/package-lock.json ui-tui/
COPY ui-tui/packages/hermes-ink/ ui-tui/packages/hermes-ink/

ENV npm_config_install_links=false

# Install node modules and immediately compile the static build bundles
RUN npm install --prefer-offline --no-audit && \
    (cd web && npm install --prefer-offline --no-audit) && \
    (cd ui-tui && npm install --prefer-offline --no-audit)

# Copy source trees needed for compiling dashboard and terminal UI assets
COPY web ./web
COPY ui-tui ./ui-tui

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

# Install compiling utilities strictly inside this temporary build layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential gcc python3-dev libffi-dev git && \
    rm -rf /var/lib/apt/lists/*

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

# Sync core dependencies using lockfile manifest tracking
COPY pyproject.toml uv.lock ./
RUN touch ./README.md
RUN uv sync --frozen --no-install-project --extra all --extra messaging

# ==========================================
# Stage 3: Ultra-Lean Production Runtime
# ==========================================
FROM tianon/gosu:1.19-trixie@sha256:3b176695959c71e123eb390d427efc665eeb561b1540e82679c15e992006b8b9 AS gosu_source
FROM python:3.11-slim AS runtime
WORKDIR /opt/hermes

# Strict low-memory allocation adjustments
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MALLOC_ARENA_MAX=2 \
    PORT=8080 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    HERMES_CONTAINER=1 \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_HOME=/opt/data \
    PATH="/opt/data/.local/bin:/opt/hermes/.venv/bin:${PATH}"

# Install only light runtime binaries needed for task execution
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ripgrep ffmpeg procps git openssh-client docker-cli tini && \
    rm -rf /var/lib/apt/lists/*

# Set up non-root execution parameters safely
RUN useradd -u 10000 -m -d /opt/data hermes
COPY --chmod=0755 --from=gosu_source /gosu /usr/local/bin/
COPY --chmod=0755 --from=uv_source /usr/local/bin/uv /usr/local/bin/uvx /usr/local/bin/

# Pull compiled virtual environment layer from Stage 2
COPY --from=python-builder /opt/hermes/.venv /opt/hermes/.venv

# Pull static web / TUI distribution bundles from Stage 1
COPY --from=frontend-builder /opt/hermes/web /opt/hermes/web
COPY --from=frontend-builder /opt/hermes/ui-tui /opt/hermes/ui-tui
COPY --from=frontend-builder /opt/hermes/node_modules /opt/hermes/node_modules

# Bring in remainder of runtime tracking scripts/configurations
COPY . .

# Link hermes-agent instantly without processing dependency layers down
RUN uv pip install --no-cache-dir --no-deps -e "."

# Install minimal playwright runtime elements 
RUN npx playwright install --with-deps chromium --only-shell && \
    npm cache clean --force

# Establish directory adjustments safely for the runtime uid
USER root
RUN mkdir -p /opt/data && \
    chmod -R a+rX /opt/hermes && \
    chown -R hermes:hermes /opt/hermes/.venv /opt/hermes/ui-tui /opt/hermes/node_modules /opt/data

VOLUME [ "/opt/data" ]
ENTRYPOINT [ "/usr/bin/tini", "-g", "--", "/opt/hermes/docker/entrypoint.sh" ]
