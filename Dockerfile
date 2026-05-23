FROM debian:12-slim

# Disable Python stdout buffering for immediate logs
ENV PYTHONUNBUFFERED=1
# Playwright browsers live in /home/ama (named volume → persistent)
ENV PLAYWRIGHT_BROWSERS_PATH=/home/ama/.playwright

# UID/GID build args — match your host user to avoid bind-mount permission issues.
# Override at build time: docker compose build --build-arg UID=$(id -u)
# Or set in .env: UID=1000 GID=1000
ARG UID=1000
ARG GID=1000

# System deps: bash, python3, curl, jq, nodejs (for pm2), git, ripgrep, fd, plus
# the system libs Playwright Chromium needs. Code is NOT baked into the image —
# it arrives at runtime via bind mount (compose) or first-run git clone (entrypoint).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash curl jq git procps \
        python3 python3-pip python3-venv \
        nodejs npm \
        ripgrep fd-find ca-certificates \
        libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
        libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libgbm1 libasound2 && \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd && \
    rm -rf /var/lib/apt/lists/*

# pm2 globally (as root — needs global npm write access)
RUN npm install -g pm2 --quiet

# Non-root user with matching host UID/GID
RUN groupadd -g ${GID} ama 2>/dev/null || true && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash ama 2>/dev/null || true

# Project root — code mounted in by compose or cloned by entrypoint on first run.
# Pre-created with right ownership so bind-mounted dirs are writable from the
# host user we mapped above.
RUN mkdir -p /opt/ama && chown -R ${UID}:${GID} /opt/ama
WORKDIR /opt/ama

# Entrypoint handles: first-run clone, conditional pip install --user (so deps
# live in /home/ama/.local and survive container recreate), Playwright install,
# and exec into pm2-runtime. Code-update path is `/update` from the bot itself
# — never requires an image rebuild.
COPY docker/entrypoint.sh /usr/local/bin/ama-entrypoint
RUN chmod +x /usr/local/bin/ama-entrypoint

USER ama
ENV HOME=/home/ama
ENV PM2_HOME=/home/ama/.pm2
# pip --user installs land in /home/ama/.local; add to PATH so console_scripts work
ENV PATH=/home/ama/.local/bin:/usr/local/bin:/usr/bin:/bin

# Runtime env vars expected (set via compose env_file or `docker run -e`):
#   Required:  TG_TOKEN  TG_ADMIN
#   Optional:  PROVIDER (default: google), MODEL, AMA_REPO, AMA_BRANCH
#
# Volumes (see docker-compose.yml — set up automatically there):
#   ./:/opt/ama          host repo bind-mounted (so `git pull` from host or
#                        `/update` from bot both update the same code)
#   ama_home:/home/ama   named volume: pip --user, npm cache, pm2 dump,
#                        Playwright browsers — everything install-once persists

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/ama-entrypoint"]
