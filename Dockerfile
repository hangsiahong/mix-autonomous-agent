FROM debian:12-slim

# Disable Python stdout buffering for immediate logs
ENV PYTHONUNBUFFERED=1
# Store Playwright browsers inside the image (not on a volume mount)
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ama/.playwright

# UID/GID build args — match your host user to avoid volume permission issues.
# Override at build time: docker compose build --build-arg UID=$(id -u)
# Or set in .env: UID=1000 GID=1000
ARG UID=1000
ARG GID=1000

# System deps: bash, python3, curl, jq, nodejs (for pm2), git, ripgrep, fd
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash curl jq git procps \
        python3 python3-pip python3-venv \
        nodejs npm \
        ripgrep fd-find ca-certificates \
        # Playwright Chromium system deps
        libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
        libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libgbm1 libasound2 && \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd && \
    rm -rf /var/lib/apt/lists/*

# Install pm2 globally (as root — needs global npm write access)
RUN npm install -g pm2 --quiet

# Create non-root user with matching UID/GID before any file operations
RUN groupadd -g ${GID} ama 2>/dev/null || true && \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash ama 2>/dev/null || true

WORKDIR /opt/ama

# Install Python deps first (layer cache) — still as root for system packages
COPY requirements.txt .
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt && \
    playwright install chromium && \
    chown -R ${UID}:${GID} /opt/ama/.playwright

# Copy project files, owned by the ama user from the start
COPY --chown=${UID}:${GID} . .

# Create runtime dirs with correct ownership
RUN mkdir -p logs brain/state tools/custom skills && \
    chown -R ${UID}:${GID} /opt/ama

# Switch to non-root for runtime
USER ama
ENV HOME=/home/ama
# pm2 state lives in home dir — writable by ama user
ENV PM2_HOME=/home/ama/.pm2

# Runtime env vars — override at `docker run` time or via .env file
# Required:
#   TG_TOKEN       Telegram bot token
#   TG_ADMIN       Telegram admin user ID
# Optional:
#   PROVIDER              google | anthropic | openai (default: google)
#   MODEL                 Model name override
#
# Volumes (use docker-compose.yml — it has all of these):
#   -v ./brain:/opt/ama/brain
#   -v ./logs:/opt/ama/logs
#   -v ./tools/custom:/opt/ama/tools/custom
#   -v ./skills:/opt/ama/skills
#   -v ama_memory:/home/ama/ama_memory

EXPOSE 8080

CMD ["pm2-runtime", "pm2.config.js"]
