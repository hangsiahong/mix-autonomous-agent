FROM debian:12-slim

# Disable Python stdout buffering for immediate logs
ENV PYTHONUNBUFFERED=1
# Store Playwright browsers outside any volume mounts
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ama/.playwright

# System deps: bash, python3, curl, jq, nodejs (for pm2), git, ripgrep
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash curl jq git procps \
        python3 python3-pip python3-venv \
        nodejs npm \
        ripgrep ca-certificates \
        # Playwright Chromium system deps
        libnss3 libnspr4 libdbus-1-3 libatk1.0-0 libatk-bridge2.0-0 \
        libcups2 libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 \
        libxfixes3 libxrandr2 libgbm1 libasound2 && \
    rm -rf /var/lib/apt/lists/*

# Install pm2 globally
RUN npm install -g pm2 --quiet

WORKDIR /opt/ama

# Install Python deps first (layer cache)
COPY requirements.txt .
RUN pip3 install --no-cache-dir --break-system-packages -r requirements.txt && \
    playwright install chromium

# Copy the rest of the project
COPY . .

# Runtime env vars — override these at `docker run` time or via .env file
# Required:
#   TG_TOKEN       Telegram bot token
#   TG_ADMIN       Telegram admin user ID
# Optional:
#   GOOGLE_CLOUD_PROJECT  Vertex AI project ID
#   GOOGLE_CLOUD_REGION   (default: us-central1)
#   ANTHROPIC_API_KEY     For Anthropic provider
#   OPENAI_API_KEY        For OpenAI provider
#   PROVIDER              google | anthropic | openai (default: google)
#   MODEL                 Model name override

# Bot logs
RUN mkdir -p logs brain/state

EXPOSE 8080

CMD ["pm2-runtime", "pm2.config.js"]
