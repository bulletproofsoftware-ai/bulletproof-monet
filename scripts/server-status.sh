#!/bin/bash
# Server health status reporter — outputs Telegram-friendly plain text
# Deployed on: c2, hi, h2, hg
# v2 — resilient against docker ps hangs (uses docker info + inspect fallback)

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
UPTIME_RAW=$(awk '{print int($1)}' /proc/uptime)
DAYS=$((UPTIME_RAW / 86400))
HOURS=$(( (UPTIME_RAW % 86400) / 3600 ))
LOAD=$(awk '{printf "%.2f %.2f %.2f", $1, $2, $3}' /proc/loadavg)

# Disk (root partition)
DISK_PCT=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
DISK_ALERT=""
[ "$DISK_PCT" -ge 85 ] && DISK_ALERT=" (!)"

# Memory
MEM_INFO=$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END {
    used=(t-a)/1048576; total=t/1048576;
    printf "%.1fG/%.1fG", used, total
}' /proc/meminfo)

# Swap
SWAP_INFO=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {
    if (t == 0) { print "none (!)" }
    else { printf "%dM/%dM", (t-f)/1024, t/1024 }
}' /proc/meminfo)

# Docker
if command -v docker &>/dev/null; then
    # Use docker info for counts — reliable even when docker ps hangs
    DOCKER_INFO=$(timeout 10 docker info --format '{{.Containers}} {{.ContainersRunning}} {{.ContainersPaused}} {{.ContainersStopped}}' 2>/dev/null)
    if [ -n "$DOCKER_INFO" ]; then
        DOCKER_TOTAL=$(echo "$DOCKER_INFO" | awk '{print $1}')
        DOCKER_RUNNING=$(echo "$DOCKER_INFO" | awk '{print $2}')
        DOCKER_STOPPED=$(echo "$DOCKER_INFO" | awk '{print $4}')
    else
        DOCKER_TOTAL="?"
        DOCKER_RUNNING="?"
        DOCKER_STOPPED=0
    fi

    # Parallel docker ps probes with tight timeout (all run simultaneously)
    PS_TMPDIR=$(mktemp -d)
    ( timeout 5 docker ps -a --filter health=unhealthy --format '{{.Names}}' > "$PS_TMPDIR/unhealthy" 2>/dev/null || true ) &
    ( timeout 5 docker ps -a --filter status=exited --format '{{.Names}}' > "$PS_TMPDIR/exited" 2>/dev/null || true ) &
    ( timeout 5 docker ps -q > "$PS_TMPDIR/ids" 2>/dev/null || true ) &
    wait
    DOCKER_UNHEALTHY=$(cat "$PS_TMPDIR/unhealthy" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    DOCKER_EXITED=$(cat "$PS_TMPDIR/exited" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    CONTAINER_IDS=$(cat "$PS_TMPDIR/ids" 2>/dev/null)
    rm -rf "$PS_TMPDIR"

    DOCKER_ALERT=""
    # If docker ps timed out but docker info reports stopped containers
    if [ -z "$DOCKER_EXITED" ] && [ "$DOCKER_STOPPED" -gt 0 ] 2>/dev/null; then
        DOCKER_EXITED="(${DOCKER_STOPPED} stopped)"
    fi

    # If docker ps -q timed out, get running IDs via filesystem + inspect
    if [ -z "$CONTAINER_IDS" ] && [ "$DOCKER_RUNNING" -gt 0 ] 2>/dev/null; then
        for DIR in /var/lib/docker/containers/*/; do
            [ -d "$DIR" ] || continue
            CID=$(basename "$DIR")
            STATUS=$(timeout 3 docker inspect --format='{{.State.Status}}' "$CID" 2>/dev/null)
            [ "$STATUS" = "running" ] && CONTAINER_IDS="${CONTAINER_IDS} ${CID}"
        done
        # Also try to get unhealthy via inspect if docker ps failed
        if [ -z "$DOCKER_UNHEALTHY" ]; then
            UH_LIST=""
            for CID in $CONTAINER_IDS; do
                HEALTH=$(timeout 3 docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CID" 2>/dev/null)
                if [ "$HEALTH" = "unhealthy" ]; then
                    NAME=$(timeout 3 docker inspect --format='{{.Name}}' "$CID" 2>/dev/null | sed 's|^/||')
                    UH_LIST="${UH_LIST:+$UH_LIST,}${NAME}"
                fi
            done
            DOCKER_UNHEALTHY="$UH_LIST"
        fi
    fi
    [ -n "$DOCKER_UNHEALTHY" ] && DOCKER_ALERT=" (!)"

    # Error count (last hour) — parallelized across containers
    ERR_TMPDIR=$(mktemp -d)
    for CID in $CONTAINER_IDS; do
        [ -z "$CID" ] && continue
        ( timeout 10 docker logs --since 1h "$CID" 2>&1 | grep -ciE 'error|exception|fatal|panic' > "$ERR_TMPDIR/$CID" 2>/dev/null || echo 0 > "$ERR_TMPDIR/$CID" ) &
    done
    wait
    ERR_COUNT=0
    for f in "$ERR_TMPDIR"/*; do
        [ -f "$f" ] || continue
        C_ERRS=$(cat "$f" | tr -d '[:space:]')
        [ -z "$C_ERRS" ] && C_ERRS=0
        ERR_COUNT=$((ERR_COUNT + C_ERRS))
    done
    rm -rf "$ERR_TMPDIR"

    # Reclaimable space — use cached value (refreshed in background, max 1h stale)
    CACHE_FILE="/tmp/.docker-system-df.cache"
    CACHE_MAX_AGE=3600
    if [ -f "$CACHE_FILE" ]; then
        CACHE_AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
    else
        CACHE_AGE=$((CACHE_MAX_AGE + 1))
    fi
    if [ "$CACHE_AGE" -gt "$CACHE_MAX_AGE" ]; then
        ( timeout 30 docker system df 2>/dev/null | awk '
            /^Images/ || /^Build Cache/ {
                for (i=1; i<=NF; i++) {
                    if ($i ~ /^\(/) { print $(i-1); break }
                }
            }' | grep -v '^0B$' | tr '\n' '+' | sed 's/+$//' > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE" ) &
        disown
    fi
    RECLAIMABLE=""
    [ -f "$CACHE_FILE" ] && RECLAIMABLE=$(cat "$CACHE_FILE")
    [ -z "$RECLAIMABLE" ] && RECLAIMABLE="pending"

    DOCKER_LINE="Docker: ${DOCKER_RUNNING}/${DOCKER_TOTAL} running${DOCKER_ALERT}"
    [ -n "$DOCKER_UNHEALTHY" ] && DOCKER_LINE="${DOCKER_LINE}
  unhealthy: ${DOCKER_UNHEALTHY}"
    [ -n "$DOCKER_EXITED" ] && DOCKER_LINE="${DOCKER_LINE}
  exited: ${DOCKER_EXITED}"
else
    DOCKER_LINE="Docker: not installed"
    ERR_COUNT="n/a"
    RECLAIMABLE="n/a"
fi

# Web server (nginx or Apache)
if pgrep -x nginx &>/dev/null; then
    WEB_STATUS="nginx: running"
elif pgrep -x httpd &>/dev/null || pgrep -x apache2 &>/dev/null; then
    WEB_STATUS="apache: running"
else
    WEB_STATUS="web: DOWN (!)"
fi

# SSL certs (soonest expiry)
SSL_LINE="SSL: n/a"
SOONEST_DAYS=999999
SOONEST_DOMAIN=""
for CERT in /etc/letsencrypt/live/*/fullchain.pem; do
    [ -f "$CERT" ] || continue
    DOMAIN=$(basename "$(dirname "$CERT")")
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT" 2>/dev/null | cut -d= -f2)
    [ -z "$EXPIRY" ] && continue
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
    if [ "$DAYS_LEFT" -lt "$SOONEST_DAYS" ]; then
        SOONEST_DAYS=$DAYS_LEFT
        SOONEST_DOMAIN=$DOMAIN
    fi
done
if [ "$SOONEST_DAYS" -lt 999999 ]; then
    SSL_ALERT=""
    [ "$SOONEST_DAYS" -lt 14 ] && SSL_ALERT=" (!)"
    SSL_LINE="SSL: ${SOONEST_DOMAIN} ${SOONEST_DAYS}d${SSL_ALERT}"
fi

# Output
echo "=== ${HOSTNAME} ==="
echo "Up: ${DAYS}d ${HOURS}h | Load: ${LOAD}"
echo "Disk: ${DISK_PCT}%${DISK_ALERT} | Mem: ${MEM_INFO} | Swap: ${SWAP_INFO}"
echo "$DOCKER_LINE"
echo "$WEB_STATUS"
echo "$SSL_LINE"
echo "Errors(1h): ${ERR_COUNT} | Reclaim: ${RECLAIMABLE}"
