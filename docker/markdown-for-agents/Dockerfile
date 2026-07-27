FROM python:3.14-slim

# System deps for SSL and Chromium
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    libnss3 \
    libnspr4 \
    libdbus-1-3 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libxkbcommon0 \
    libatspi2.0-0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    libx11-xcb1 \
    fonts-liberation \
    fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

WORKDIR /app

# Create a non-root user and a shared Playwright browser path
RUN useradd --create-home --uid 10001 appuser \
    && mkdir -p /ms-playwright \
    && chown -R appuser:appuser /app /ms-playwright
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Install Chromium binary only (system deps handled above) into the shared path
RUN playwright install chromium

COPY app/main.py .

EXPOSE 8090

# Drop privileges: run the service as the non-root appuser
USER appuser

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8090", "--workers", "1", "--log-level", "info"]
