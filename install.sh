#!/bin/bash
# bulletproof-monet installer.
#
#   git clone <repo> monet && cd monet
#   cp .env.example .env && $EDITOR .env
#   ./install.sh
#
# See --help for the full contract.

set -euo pipefail

# --------------------------------------------------------------------------
# Contract
# --------------------------------------------------------------------------
usage() {
cat <<'EOF'
install.sh [--check | --dry-run] [--skip-docker] [--skip-systemd] [--yes] [--help]

Modes:
  (default)      Full install: preflight -> env -> docker -> venv -> db -> models
                 -> systemd -> webhook -> commands -> smoke test
  --check        Run every step that needs NO credential and NO network write.
                 Never mutates system state outside MONET_HOME. Exit 0 = the
                 checkout is installable. THIS IS THE CI / CLEAN-CLONE MODE.
  --dry-run      Alias for --check.

Flags:
  --skip-docker  Assume the stack is already running elsewhere.
  --skip-systemd Do not install/enable units (for non-systemd hosts, containers, macOS).
  --yes          Non-interactive; never prompt. Any prompt-requiring step is skipped
                 with a printed instruction instead.
  --help         Print this contract and exit 0.

Environment:
  MONET_HOME     Install root. Default: the directory containing install.sh.
  MONET_USER     Service account for systemd units. Default: the invoking user.
  All variables from .env are loaded via lib/monet-env.sh.

Exit codes:
   0  success (or --check passed)
   1  usage error (bad flag)
   2  preflight failed: a required tool is missing
   3  configuration error: .env missing, or a required variable unset/placeholder
   4  docker step failed
   5  service/venv/db step failed
   6  webhook registration failed (Telegram rejected the request)
   7  smoke test failed

Requirements:
  Docker Compose >= 2.20.0  (the stack uses the Compose Spec 'include:' key)
  python3 >= 3.11, node >= 18, curl, openssl, git
EOF
}

# --------------------------------------------------------------------------
# Flags
# --------------------------------------------------------------------------
CHECK_ONLY=0
SKIP_DOCKER=0
SKIP_SYSTEMD=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --check|--dry-run) CHECK_ONLY=1 ;;
        --skip-docker)     SKIP_DOCKER=1 ;;
        --skip-systemd)    SKIP_SYSTEMD=1 ;;
        --yes|-y)          ASSUME_YES=1 ;;
        --help|-h)         usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; echo >&2; usage >&2; exit 1 ;;
    esac
    shift
done

TOTAL_STEPS=17
STEP_NO=0

step()  { STEP_NO=$((STEP_NO + 1)); printf '==> [%d/%d] %s\n' "$STEP_NO" "$TOTAL_STEPS" "$1"; }
ok()    { printf '    ok%s\n' "${1:+ ($1)}"; }
skip()  { printf '    SKIP (%s)\n' "$1"; }
fail()  { printf '    FAIL (%s)\n' "$1" >&2; }
note()  { printf '      %s\n' "$1"; }

# die <exit-code> <reason>
die() { fail "$2"; exit "$1"; }

# --------------------------------------------------------------------------
# Step 1 — preflight
# --------------------------------------------------------------------------
step "Preflight: required tooling"

need_tool() {
    local bin="$1" label="${2:-$1}"
    if ! command -v "$bin" >/dev/null 2>&1; then
        die 2 "$label not found in PATH"
    fi
}

# Docker is only strictly required when we intend to touch Docker.
DOCKER_AVAILABLE=1
if ! command -v docker >/dev/null 2>&1; then
    DOCKER_AVAILABLE=0
fi

if [ "$DOCKER_AVAILABLE" -eq 1 ]; then
    compose_raw=$(docker compose version --short 2>/dev/null || true)
    if [ -z "$compose_raw" ]; then
        die 2 "the 'docker compose' plugin is not installed; the legacy 'docker-compose' v1 binary is NOT supported — this stack requires Compose Spec 'include:', added in Docker Compose 2.20.0"
    fi
    # Normalize: --short may emit "2.29.7" or "v2.29.7".
    compose_ver=${compose_raw#v}
    compose_major=${compose_ver%%.*}
    compose_rest=${compose_ver#*.}
    compose_minor=${compose_rest%%.*}
    # Guard against non-numeric output from an exotic build.
    case "$compose_major$compose_minor" in
        ''|*[!0-9]*) die 2 "could not parse the Docker Compose version from '$compose_raw'; 2.20.0 or newer is required" ;;
    esac
    if [ "$compose_major" -lt 2 ] || { [ "$compose_major" -eq 2 ] && [ "$compose_minor" -lt 20 ]; }; then
        die 2 "Docker Compose $compose_ver found; 2.20.0 or newer is required. This project's docker-compose.yml uses the Compose Spec 'include:' key, which older versions ignore or reject — the stack will not assemble. Upgrade the Docker Compose plugin and re-run."
    fi
    note "docker compose $compose_ver (>= 2.20)"
elif [ "$SKIP_DOCKER" -eq 1 ]; then
    note "docker not found, but --skip-docker was given"
else
    die 2 "docker not found in PATH (pass --skip-docker if the stack runs elsewhere)"
fi

need_tool python3
need_tool curl
need_tool openssl
need_tool git

# python3 >= 3.11
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)'; then
    die 2 "python3 >= 3.11 required, found $(python3 -V 2>&1)"
fi
note "$(python3 -V 2>&1)"

# node >= 18 (needed for the memory MCP build in step 13)
NODE_OK=1
if command -v node >/dev/null 2>&1; then
    node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
    case "$node_major" in ''|*[!0-9]*) node_major=0 ;; esac
    if [ "$node_major" -lt 18 ]; then
        die 2 "node >= 18 required, found $(node -v 2>&1)"
    fi
    note "node $(node -v 2>&1)"
else
    NODE_OK=0
fi
[ "$NODE_OK" -eq 1 ] || note "node not found — step 13 (MCP build) will be skipped"

note "curl, openssl, git present"
ok

# --------------------------------------------------------------------------
# Step 2 — resolve MONET_HOME and the path libraries
# --------------------------------------------------------------------------
step "Resolve MONET_HOME and path libraries"

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
: "${MONET_HOME:=$SELF_DIR}"
export MONET_HOME

[ -f "$MONET_HOME/lib/monet-env.sh" ]  || die 2 "lib/monet-env.sh not found under $MONET_HOME"
[ -f "$MONET_HOME/lib/monet_paths.py" ] || die 2 "lib/monet_paths.py not found under $MONET_HOME"

# shellcheck source=lib/monet-env.sh
. "$MONET_HOME/lib/monet-env.sh"

# Verify the Python side resolves to the same root (the spec-002 V4 check).
py_home=$(python3 -c "import sys; sys.path.insert(0, '$MONET_HOME/lib'); import monet_paths; print(monet_paths.MONET_HOME)")
[ "$py_home" = "$MONET_HOME" ] || die 2 "monet_paths.py resolved MONET_HOME to '$py_home' but the shell resolved '$MONET_HOME'"

MONET_USER="${MONET_USER:-$(id -un)}"
export MONET_USER

note "MONET_HOME=$MONET_HOME"
note "MONET_LOG_DIR=$MONET_LOG_DIR"
note "MONET_USER=$MONET_USER"
note "monet_paths.py agrees"
ok

# --------------------------------------------------------------------------
# Step 3 — .env creation with generated secrets
# --------------------------------------------------------------------------
step "Configure .env"

# Variables we can safely generate. Everything else needs a human.
GENERATED_VARS="QDRANT_API_KEY N8N_ENCRYPTION_KEY N8N_USER_MANAGEMENT_JWT_SECRET WEBHOOK_API_KEY WEBHOOK_SECRET MONET_API_KEY POSTGRES_PASSWORD"

# Fill placeholder secrets in $1 (in place) with `openssl rand -hex 32`.
generate_secrets() {
    local target="$1" var val
    for var in $GENERATED_VARS; do
        val=$(openssl rand -hex 32)
        # Replace only the assignment line for this var. Use a literal-safe
        # delimiter; the generated value is hex so it cannot contain '|'.
        if grep -q "^${var}=" "$target"; then
            python3 - "$target" "$var" "$val" <<'PY'
import sys
path, var, val = sys.argv[1], sys.argv[2], sys.argv[3]
out = []
for line in open(path):
    if line.startswith(var + "="):
        out.append("%s=%s\n" % (var, val))
    else:
        out.append(line)
open(path, "w").writelines(out)
PY
        fi
    done
}

ENV_FILE="$MONET_HOME/.env"
if [ "$CHECK_ONLY" -eq 1 ]; then
    # --check must NOT create the real .env. Exercise the same logic in a temp file.
    if [ -f "$ENV_FILE" ]; then
        skip "an .env already exists; --check leaves it untouched"
    else
        CHECK_ENV=$(mktemp "${TMPDIR:-/tmp}/monet-env-check.XXXXXX")
        trap 'rm -f "${CHECK_ENV:-}"' EXIT
        cp "$MONET_HOME/.env.example" "$CHECK_ENV"
        generate_secrets "$CHECK_ENV"
        if grep -q '^QDRANT_API_KEY=your-' "$CHECK_ENV"; then
            die 3 "secret generation did not replace placeholders"
        fi
        ok "generation rehearsed into a temp file; real .env NOT created"
    fi
else
    if [ -f "$ENV_FILE" ]; then
        ok "existing .env kept (secrets never regenerated)"
    else
        cp "$MONET_HOME/.env.example" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        generate_secrets "$ENV_FILE"
        ok "created from .env.example with generated secrets"
        note "EDIT $ENV_FILE and set BOT_TOKEN, TG_AUTHORIZED_USER_ID, MONET_PUBLIC_URL"
        # A brand-new .env cannot contain a bot token, so the credentialed steps
        # below will all skip. Offer to stop here so the user can fill it in --
        # unless --yes says never prompt.
        if [ "$ASSUME_YES" -eq 1 ]; then
            note "--yes: continuing; credentialed steps will SKIP until you fill in .env and re-run"
        elif [ -t 0 ]; then
            printf '    Edit .env now and re-run install.sh? [Y/n] '
            read -r reply
            case "$reply" in
                [Nn]*) note "continuing without credentials" ;;
                *) echo "Stopped. Edit $ENV_FILE, then re-run ./install.sh"; exit 0 ;;
            esac
        else
            note "no TTY: continuing; credentialed steps will SKIP until .env is filled in"
        fi
    fi
    # Reload so later steps see the new values.
    # shellcheck source=lib/monet-env.sh
    . "$MONET_HOME/lib/monet-env.sh"
fi

# --------------------------------------------------------------------------
# Step 4 — validate .env
# --------------------------------------------------------------------------
step "Validate .env"

REQUIRED_VARS="BOT_TOKEN TG_AUTHORIZED_USER_ID QDRANT_API_KEY POSTGRES_PASSWORD N8N_ENCRYPTION_KEY"

# A value is a placeholder if it matches the one in .env.example, or looks like one.
is_placeholder() {
    local var="$1" val="$2" example
    [ -z "$val" ] && return 0
    example=$(grep "^${var}=" "$MONET_HOME/.env.example" 2>/dev/null | head -1 | cut -d= -f2-)
    [ -n "$example" ] && [ "$val" = "$example" ] && return 0
    case "$val" in
        your-*|YOUR_*|changeme|CHANGEME) return 0 ;;
    esac
    return 1
}

MISSING_VARS=""
if [ -f "$ENV_FILE" ]; then
    # Every var declared in .env.example should be present in .env.
    absent=""
    while IFS= read -r line; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        v="${line%%=*}"
        grep -q "^${v}=" "$ENV_FILE" || absent="$absent $v"
    done < "$MONET_HOME/.env.example"
    [ -n "$absent" ] && note "not present in .env (will fall back to defaults):$absent"

    for v in $REQUIRED_VARS; do
        val=$(grep "^${v}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
        if is_placeholder "$v" "$val"; then
            MISSING_VARS="$MISSING_VARS $v"
        fi
    done
else
    MISSING_VARS=" (no .env file)"
fi

if [ -n "$MISSING_VARS" ]; then
    if [ "$CHECK_ONLY" -eq 1 ]; then
        skip "report-only under --check; unset/placeholder:$MISSING_VARS"
    else
        note "unset or still-placeholder:$MISSING_VARS"
        die 3 "required variables are unset or still placeholders:$MISSING_VARS"
    fi
else
    ok "all required variables set"
fi

# Steps that need a credential are skipped when one is missing.
HAVE_CREDENTIALS=0
[ -z "$MISSING_VARS" ] && HAVE_CREDENTIALS=1

# --------------------------------------------------------------------------
# Step 5 — render templates
# --------------------------------------------------------------------------
step "Render templates into build/"

BUILD_DIR="$MONET_HOME/build"
mkdir -p "$BUILD_DIR/nginx"

render() {
    # render <template> <output>
    local src="$1" dst="$2"
    [ -f "$src" ] || { fail "template not found: $src"; return 1; }
    sed -e "s|@MONET_HOME@|$MONET_HOME|g" \
        -e "s|@MONET_LOG_DIR@|$MONET_LOG_DIR|g" \
        -e "s|@MONET_USER@|$MONET_USER|g" \
        "$src" > "$dst"
}

render "$MONET_HOME/api/monet-api.service.template"     "$BUILD_DIR/monet-api.service"     || die 5 "rendering monet-api.service"
render "$MONET_HOME/src/monet-webhook.service.template" "$BUILD_DIR/monet-webhook.service" || die 5 "rendering monet-webhook.service"
render "$MONET_HOME/src/monet-worker@.service.template" "$BUILD_DIR/monet-worker@.service" || die 5 "rendering monet-worker@.service"
render "$MONET_HOME/claude/settings.json.template"      "$BUILD_DIR/claude-settings.json"  || die 5 "rendering claude settings.json"

# nginx: MONET_PUBLIC_URL supplies the server name when it is set.
NGINX_SERVER_NAME=$(printf '%s' "${MONET_PUBLIC_URL:-}" | sed -e 's|^https\{0,1\}://||' -e 's|/.*$||')
[ -n "$NGINX_SERVER_NAME" ] || NGINX_SERVER_NAME="@MONET_SERVER_NAME@"
sed -e "s|@MONET_SERVER_NAME@|$NGINX_SERVER_NAME|g" \
    -e "s|@MONET_TLS_CERT@|${MONET_TLS_CERT:-/etc/letsencrypt/live/$NGINX_SERVER_NAME/fullchain.pem}|g" \
    -e "s|@MONET_TLS_KEY@|${MONET_TLS_KEY:-/etc/letsencrypt/live/$NGINX_SERVER_NAME/privkey.pem}|g" \
    -e "s|@MONET_WEBHOOK_PORT@|${MONET_WEBHOOK_PORT:-8093}|g" \
    "$MONET_HOME/deploy/nginx/monet.conf.template" > "$BUILD_DIR/nginx/monet.conf" \
    || die 5 "rendering nginx config"

# Crontab, generated from MONET_HOME (unit 002 removed the checked-in crontab.txt).
# The daily-briefing entry is rendered from BRIEFING_TIME (HH:MM, 24h) and
# BRIEFING_TIMEZONE. Both have defaults, so an unconfigured checkout still
# produces a valid crontab -- and the briefing itself stays inert until
# BRIEFING_ENABLED=true, which monet-pulse.sh checks at run time.
if [ -f "$MONET_HOME/cron/monet-crontab.example" ]; then
    BRIEFING_TIME_VALUE="${BRIEFING_TIME:-07:30}"
    if ! printf '%s' "$BRIEFING_TIME_VALUE" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$'; then
        die 5 "BRIEFING_TIME must be HH:MM in 24-hour form, got '$BRIEFING_TIME_VALUE'"
    fi
    # Strip the leading zero so cron sees 7, not 07 (which some crons reject).
    BRIEFING_HOUR=$((10#${BRIEFING_TIME_VALUE%%:*}))
    BRIEFING_MIN=$((10#${BRIEFING_TIME_VALUE##*:}))
    sed -e "s|@MONET_HOME@|$MONET_HOME|g" \
        -e "s|@BRIEFING_HOUR@|$BRIEFING_HOUR|g" \
        -e "s|@BRIEFING_MIN@|$BRIEFING_MIN|g" \
        -e "s|@BRIEFING_TZ@|${BRIEFING_TIMEZONE:-UTC}|g" \
        "$MONET_HOME/cron/monet-crontab.example" > "$BUILD_DIR/monet.crontab" \
        || die 5 "rendering crontab"
fi

# Fail loudly if any token survived rendering.
if leftover=$(grep -rlE '@[A-Z_]+@' "$BUILD_DIR" 2>/dev/null); then
    if [ -n "$leftover" ]; then
        # An unrendered @MONET_SERVER_NAME@ is expected when MONET_PUBLIC_URL is unset.
        real_leftover=$(grep -rlE '@(MONET_HOME|MONET_LOG_DIR|MONET_USER|BRIEFING_HOUR|BRIEFING_MIN|BRIEFING_TZ)@' "$BUILD_DIR" 2>/dev/null || true)
        if [ -n "$real_leftover" ]; then
            note "files with unsubstituted tokens: $real_leftover"
            die 5 "template rendering left @TOKEN@ placeholders behind"
        fi
        note "nginx server_name left as a token (MONET_PUBLIC_URL unset) — fill it before installing"
    fi
fi
ok "build/ populated"

# --------------------------------------------------------------------------
# Step 6 — runtime directories
# --------------------------------------------------------------------------
step "Create runtime directories"
for d in logs data queue pending bg-jobs research; do
    mkdir -p "$MONET_HOME/$d"
done
ok "logs data queue pending bg-jobs research"

# --------------------------------------------------------------------------
# Step 7 — webhook venv
# --------------------------------------------------------------------------
step "Create webhook-venv and install dependencies"

VENV="$MONET_HOME/webhook-venv"
REQ="$MONET_HOME/requirements-webhook.txt"
if [ ! -f "$REQ" ]; then
    die 5 "requirements-webhook.txt not found"
fi
if [ ! -d "$VENV" ]; then
    python3 -m venv "$VENV" || die 5 "could not create $VENV"
fi
if ! "$VENV/bin/pip" install -q --disable-pip-version-check -r "$REQ"; then
    die 5 "pip install from requirements-webhook.txt failed"
fi
if ! "$VENV/bin/python" -c 'import fastapi, uvicorn, httpx' 2>/dev/null; then
    die 5 "webhook-venv is missing fastapi/uvicorn/httpx after install"
fi
ok "fastapi, uvicorn, httpx installed"

# --------------------------------------------------------------------------
# Step 8 — validate the merged compose graph
# --------------------------------------------------------------------------
step "Validate docker compose configuration"
if [ "$DOCKER_AVAILABLE" -eq 0 ]; then
    skip "docker not available"
elif ! docker compose -f "$MONET_HOME/docker-compose.yml" config -q 2>/dev/null; then
    docker compose -f "$MONET_HOME/docker-compose.yml" config -q || true
    die 4 "docker compose config failed to validate the merged stack"
else
    svc_count=$(docker compose -f "$MONET_HOME/docker-compose.yml" --profile ollama config --services 2>/dev/null | wc -l | tr -d ' ')
    if [ "$svc_count" -lt 5 ]; then
        die 4 "merged stack resolved to $svc_count service(s); expected 5 — the include: key was probably ignored (Compose < 2.20)"
    fi
    ok "$svc_count services resolved (include: merged correctly)"
fi

# --------------------------------------------------------------------------
# Step 9 — start the stack
# --------------------------------------------------------------------------
step "Start the Docker stack"
OLLAMA_PROFILE=""
if [ "$CHECK_ONLY" -eq 1 ]; then
    skip "--check does not start containers"
elif [ "$SKIP_DOCKER" -eq 1 ]; then
    skip "--skip-docker"
elif [ "$DOCKER_AVAILABLE" -eq 0 ]; then
    skip "docker not available"
else
    # A host Ollama already listening means we must NOT start the container,
    # or the two fight over 127.0.0.1:11434.
    if curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
        note "host Ollama detected on 11434 — not starting the ollama profile"
    else
        OLLAMA_PROFILE="--profile ollama"
        note "no host Ollama — starting the containerized one"
    fi
    # shellcheck disable=SC2086
    if ! docker compose -f "$MONET_HOME/docker-compose.yml" $OLLAMA_PROFILE up -d; then
        die 4 "docker compose up failed"
    fi
    ok "stack started"
fi

# --------------------------------------------------------------------------
# Step 10 — wait for health
# --------------------------------------------------------------------------
step "Wait for services to become healthy"
wait_for() {
    local name="$1" cmd="$2" deadline=$((SECONDS + 120))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if eval "$cmd" >/dev/null 2>&1; then
            note "$name ready"
            return 0
        fi
        sleep 3
    done
    fail "$name did not become healthy within 120s"
    return 1
}
if [ "$CHECK_ONLY" -eq 1 ]; then
    skip "--check does not start containers"
elif [ "$SKIP_DOCKER" -eq 1 ] || [ "$DOCKER_AVAILABLE" -eq 0 ]; then
    skip "docker step skipped"
else
    health_rc=0
    wait_for "qdrant"   "curl -sf --max-time 5 http://127.0.0.1:6334/healthz" || health_rc=1
    wait_for "n8n"      "curl -sf --max-time 5 http://127.0.0.1:5679/healthz" || health_rc=1
    wait_for "postgres" "docker compose -f '$MONET_HOME/docker-compose.yml' exec -T postgres pg_isready -U '${POSTGRES_USER:-n8n}'" || health_rc=1
    [ "$health_rc" -eq 0 ] || die 4 "one or more services did not become healthy"
    ok "qdrant, n8n, postgres healthy"
fi

# --------------------------------------------------------------------------
# Step 11 — pull embedding/chat models
# --------------------------------------------------------------------------
step "Pull Ollama models"
if [ "$CHECK_ONLY" -eq 1 ]; then
    skip "--check does not pull models"
elif [ "$SKIP_DOCKER" -eq 1 ]; then
    skip "--skip-docker"
elif ! curl -sf --max-time 5 http://localhost:11434/api/tags >/dev/null 2>&1; then
    skip "no Ollama reachable on 11434"
else
    pull_rc=0
    for model in "${EMBED_MODEL:-nomic-embed-text}" llama3.2:3b; do
        note "pulling $model"
        if command -v ollama >/dev/null 2>&1; then
            ollama pull "$model" >/dev/null 2>&1 || pull_rc=1
        else
            curl -sf --max-time 900 -X POST http://localhost:11434/api/pull \
                -d "{\"name\":\"$model\"}" >/dev/null 2>&1 || pull_rc=1
        fi
    done
    [ "$pull_rc" -eq 0 ] || die 4 "one or more model pulls failed"
    ok "models pulled"
fi

# --------------------------------------------------------------------------
# Step 12 — audit database
# --------------------------------------------------------------------------
step "Initialize the audit database"
if [ "$CHECK_ONLY" -eq 1 ]; then
    skip "--check does not write the audit database"
elif [ ! -x "$MONET_HOME/scripts/init-db.sh" ]; then
    skip "scripts/init-db.sh not executable"
else
    "$MONET_HOME/scripts/init-db.sh" >/dev/null || die 5 "scripts/init-db.sh failed"
    ok "audit database ready"
fi

# --------------------------------------------------------------------------
# Step 13 — build the memory MCP server
# --------------------------------------------------------------------------
step "Build the claude-memory MCP server"
MCP_DIR="$MONET_HOME/mcp/claude-memory-mcp"
if [ ! -d "$MCP_DIR" ]; then
    skip "mcp/claude-memory-mcp not present"
elif [ "$NODE_OK" -eq 0 ] || ! command -v npm >/dev/null 2>&1; then
    skip "node/npm not available"
else
    if ! (cd "$MCP_DIR" && npm ci >/dev/null 2>&1); then
        die 5 "npm ci failed in $MCP_DIR"
    fi
    if ! (cd "$MCP_DIR" && npm run build >/dev/null 2>&1); then
        die 5 "npm run build failed in $MCP_DIR"
    fi
    ok "MCP server built"
fi

# --------------------------------------------------------------------------
# Step 14 — systemd units
# --------------------------------------------------------------------------
step "Install systemd units"
if [ "$CHECK_ONLY" -eq 1 ]; then
    skip "--check does not touch systemd"
elif [ "$SKIP_SYSTEMD" -eq 1 ]; then
    skip "--skip-systemd"
elif ! command -v systemctl >/dev/null 2>&1; then
    skip "systemd not present on this host"
elif [ "$(id -u)" -ne 0 ]; then
    # No sudo inside the installer. Print the exact commands instead.
    skip "not running as root — run these yourself:"
    note "sudo cp $BUILD_DIR/monet-api.service $BUILD_DIR/monet-webhook.service $BUILD_DIR/monet-worker@.service /etc/systemd/system/"
    note "sudo systemctl daemon-reload"
    note "sudo systemctl enable --now monet-api.service monet-webhook.service"
else
    cp "$BUILD_DIR/monet-api.service" "$BUILD_DIR/monet-webhook.service" \
       "$BUILD_DIR/monet-worker@.service" /etc/systemd/system/ || die 5 "copying systemd units"
    systemctl daemon-reload || die 5 "systemctl daemon-reload failed"
    systemctl enable --now monet-api.service monet-webhook.service || die 5 "enabling units failed"
    ok "units installed and enabled"
fi

# --------------------------------------------------------------------------
# Step 15 — register the Telegram webhook
# --------------------------------------------------------------------------
step "Register the Telegram webhook"
if [ "$CHECK_ONLY" -eq 1 ]; then
    # Config-only validation: zero network calls.
    if "$MONET_HOME/deploy/register-webhook.sh" --check >/dev/null 2>&1; then
        ok "configuration valid (no network call made)"
    else
        skip "no BOT_TOKEN / MONET_PUBLIC_URL — cannot register a webhook without credentials"
    fi
elif [ "$HAVE_CREDENTIALS" -eq 0 ] || [ -z "${MONET_PUBLIC_URL:-}" ]; then
    skip "BOT_TOKEN and MONET_PUBLIC_URL must be set in .env"
else
    "$MONET_HOME/deploy/register-webhook.sh" || die 6 "webhook registration failed"
    ok "webhook registered"
fi

# --------------------------------------------------------------------------
# Step 16 — register the Telegram command menu
# --------------------------------------------------------------------------
step "Register Telegram bot commands"
if [ "$CHECK_ONLY" -eq 1 ]; then
    skip "--check makes no Telegram API calls"
elif [ "$HAVE_CREDENTIALS" -eq 0 ]; then
    skip "BOT_TOKEN not set"
elif [ ! -x "$MONET_HOME/scripts/tg-register-commands.sh" ]; then
    skip "scripts/tg-register-commands.sh not executable"
else
    "$MONET_HOME/scripts/tg-register-commands.sh" >/dev/null || die 6 "command registration failed"
    ok "command menu registered"
fi

# --------------------------------------------------------------------------
# Step 17 — smoke test
# --------------------------------------------------------------------------
step "Smoke test"
if [ "$CHECK_ONLY" -eq 1 ]; then
    skip "--check does not run the smoke test (it needs running services)"
elif [ "$HAVE_CREDENTIALS" -eq 0 ] || [ -z "${MONET_CHAT_ID:-}" ]; then
    skip "BOT_TOKEN and MONET_CHAT_ID required for the end-to-end test"
    note "run './deploy/smoke-test.sh --local-only' to test without Telegram"
else
    "$MONET_HOME/deploy/smoke-test.sh" || die 7 "smoke test failed"
    ok "smoke test passed"
fi

# --------------------------------------------------------------------------
echo
if [ "$CHECK_ONLY" -eq 1 ]; then
    echo "CHECK PASSED — this checkout is installable."
    echo "Next: cp .env.example .env, fill in BOT_TOKEN / TG_AUTHORIZED_USER_ID / MONET_PUBLIC_URL, then ./install.sh"
else
    echo "INSTALL COMPLETE."
    echo "  Rendered units and config: $BUILD_DIR"
    echo "  nginx:    sudo cp $BUILD_DIR/nginx/monet.conf /etc/nginx/conf.d/monet.conf && sudo nginx -t && sudo systemctl reload nginx"
    [ -f "$BUILD_DIR/monet.crontab" ] && echo "  crontab:  crontab $BUILD_DIR/monet.crontab"
    echo "  verify:   ./deploy/smoke-test.sh --local-only"
fi
exit 0
