#!/bin/bash
# deploy-and-test.sh — Deploy openclaw to App Platform and run E2E verification.
#
# Deploys a pre-built Docker image (from GHCR) as an App Platform worker,
# waits for it to become active, runs health checks via doctl console,
# and cleans up the test app afterward.
#
# Required env vars:
#   DOCTL_TOKEN         — DigitalOcean API token with write access
#   IMAGE_TAG           — GHCR image tag to deploy (e.g. "e2e-12345")
#   GHCR_REPOSITORY     — GHCR repository path (set automatically by CI via github.repository)
#
# Optional env vars:
#   TELEGRAM_BOT_TOKEN  — Telegram bot token for channel probe
#   RUN_ID              — Unique run identifier (defaults to timestamp)
#   DEPLOY_TIMEOUT      — Max seconds to wait for deployment (default: 600)
#   SKIP_CLEANUP        — If "true", don't delete the app (for debugging)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_ID="${RUN_ID:-$(date +%s)}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-600}"
APP_ID=""
GATEWAY_TOKEN="e2e-token-${RUN_ID}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "[e2e] $*"; }
fail() { echo "[e2e] FAIL: $*" >&2; }

cleanup() {
    if [ "${SKIP_CLEANUP:-false}" = "true" ]; then
        log "SKIP_CLEANUP=true — leaving app $APP_ID alive for debugging"
        return 0
    fi
    if [ -n "$APP_ID" ]; then
        log "Cleaning up: deleting app $APP_ID..."
        doctl apps delete "$APP_ID" --force 2>/dev/null || true
        log "Cleanup complete."
    fi
}
trap cleanup EXIT

# ─── Preflight ────────────────────────────────────────────────────────────────

if [ -z "${DOCTL_TOKEN:-}" ]; then
    echo "SKIP: DOCTL_TOKEN not set — skipping App Platform E2E"
    exit 0
fi

if [ -z "${IMAGE_TAG:-}" ]; then
    fail "IMAGE_TAG is required"
    exit 1
fi

if [ -z "${GHCR_REPOSITORY:-}" ]; then
    fail "GHCR_REPOSITORY is required (e.g. 'digitalocean-labs/openclaw-appplatform')"
    exit 1
fi

# Configure doctl auth
export DIGITALOCEAN_ACCESS_TOKEN="$DOCTL_TOKEN"

log "Starting App Platform E2E (run=$RUN_ID, image=ghcr.io/${GHCR_REPOSITORY}:${IMAGE_TAG})"

# ─── Render app spec ─────────────────────────────────────────────────────────

SPEC_FILE="/tmp/openclaw-e2e-spec-${RUN_ID}.yaml"
sed \
    -e "s|PLACEHOLDER_RUN_ID|${RUN_ID}|g" \
    -e "s|PLACEHOLDER_IMAGE_TAG|${IMAGE_TAG}|g" \
    -e "s|PLACEHOLDER_GATEWAY_TOKEN|${GATEWAY_TOKEN}|g" \
    -e "s|PLACEHOLDER_REPOSITORY|${GHCR_REPOSITORY}|g" \
    "$SCRIPT_DIR/app-spec-template.yaml" > "$SPEC_FILE"

log "Rendered app spec → $SPEC_FILE"

# ─── Deploy ───────────────────────────────────────────────────────────────────

log "Creating App Platform app..."
log "App spec contents:"
cat "$SPEC_FILE"
echo ""

set +e
CREATE_OUTPUT=$(doctl apps create --spec "$SPEC_FILE" --output json 2>&1)
CREATE_EXIT=$?
set -e

log "doctl apps create exit code: $CREATE_EXIT"
log "doctl apps create output (last 20 lines):"
echo "$CREATE_OUTPUT" | tail -20

# doctl apps create may return non-zero exit code even on success (e.g. warnings).
# We check for a valid APP_ID instead of relying on exit code.
# doctl apps create --output json returns either [{...}] or {...}
APP_ID=$(echo "$CREATE_OUTPUT" | jq -r 'if type == "array" then .[0].id else .id end // empty' 2>/dev/null)

if [ -z "$APP_ID" ]; then
    log "DEBUG: Trying alternative JSON paths..."
    APP_ID=$(echo "$CREATE_OUTPUT" | jq -r '.. | .id? // empty' 2>/dev/null | head -1)
fi

log "Extracted APP_ID: $APP_ID"

if [ -z "$APP_ID" ]; then
    fail "Could not extract app ID from doctl output"
    echo "$CREATE_OUTPUT"
    exit 1
fi

log "App created: $APP_ID"
log "Waiting for deployment to become active (timeout: ${DEPLOY_TIMEOUT}s)..."

ELAPSED=0
POLL_INTERVAL=15
PHASE=""

while [ "$ELAPSED" -lt "$DEPLOY_TIMEOUT" ]; do
    PHASE=$(doctl apps get "$APP_ID" --output json 2>/dev/null \
        | jq -r '.[0].active_deployment.phase // .active_deployment.phase // "UNKNOWN"' 2>/dev/null \
        || echo "UNKNOWN")

    case "$PHASE" in
        ACTIVE)
            log "Deployment active after ${ELAPSED}s"
            break
            ;;
        ERROR|CANCELED|SUPERSEDED)
            fail "Deployment entered terminal phase: $PHASE"
            # Dump deployment logs for debugging
            log "--- Deployment logs ---"
            doctl apps logs "$APP_ID" --type=deploy 2>/dev/null | tail -50 || true
            exit 1
            ;;
        *)
            echo "  Phase: $PHASE (${ELAPSED}s / ${DEPLOY_TIMEOUT}s)"
            sleep "$POLL_INTERVAL"
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
            ;;
    esac
done

if [ "$PHASE" != "ACTIVE" ]; then
    fail "Deployment did not become active within ${DEPLOY_TIMEOUT}s (last phase: $PHASE)"
    log "--- Deployment logs ---"
    doctl apps logs "$APP_ID" --type=deploy 2>/dev/null | tail -50 || true
    exit 1
fi

# ─── Wait for container init ─────────────────────────────────────────────────

log "Deployment active. Waiting 30s for s6-overlay init to complete..."
sleep 30

# ─── Run health checks via console ──────────────────────────────────────────

PASS=0
FAIL_COUNT=0

check_pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
check_fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

log "Running E2E health checks..."

# Check 1: Config is valid JSON
CONFIG_VALID=$(doctl apps console "$APP_ID" openclaw --command "jq empty /data/.openclaw/openclaw.json && echo VALID" 2>/dev/null || echo "")
if echo "$CONFIG_VALID" | grep -q "VALID"; then
    check_pass "Config is valid JSON"
else
    check_fail "Config is invalid JSON"
fi

# Check 2: tools.profile is coding
PROFILE=$(doctl apps console "$APP_ID" openclaw --command "jq -r '.tools.profile' /data/.openclaw/openclaw.json" 2>/dev/null || echo "")
if echo "$PROFILE" | grep -q "coding"; then
    check_pass "tools.profile: coding"
else
    check_fail "tools.profile: '$PROFILE'"
fi

# Check 3: Config owned by openclaw
OWNER=$(doctl apps console "$APP_ID" openclaw --command "stat -c '%U' /data/.openclaw/openclaw.json" 2>/dev/null || echo "")
if echo "$OWNER" | grep -q "openclaw"; then
    check_pass "Config owned by openclaw"
else
    check_fail "Config owned by: '$OWNER'"
fi

# Check 4: Gateway process running
GW_PROC=$(doctl apps console "$APP_ID" openclaw --command "pgrep -f openclaw-gateway >/dev/null 2>&1 && echo RUNNING" 2>/dev/null || echo "")
if echo "$GW_PROC" | grep -q "RUNNING"; then
    check_pass "Gateway process running"
else
    check_fail "Gateway process not running"
fi

# Check 5: Gateway HTTP responds
GW_HTTP=$(doctl apps console "$APP_ID" openclaw --command "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18789/ 2>/dev/null" 2>/dev/null || echo "000")
if echo "$GW_HTTP" | grep -q "200"; then
    check_pass "Gateway HTTP: 200"
else
    check_fail "Gateway HTTP: $GW_HTTP"
fi

# Check 6: Auth mode is token
AUTH_MODE=$(doctl apps console "$APP_ID" openclaw --command "jq -r '.gateway.auth.mode' /data/.openclaw/openclaw.json" 2>/dev/null || echo "")
if echo "$AUTH_MODE" | grep -q "token"; then
    check_pass "Auth mode: token"
else
    check_fail "Auth mode: '$AUTH_MODE'"
fi

# Check 7: Channel plugins loaded
PLUGINS=$(doctl apps console "$APP_ID" openclaw --command "jq -r '.plugins.entries | keys | sort | join(\",\")' /data/.openclaw/openclaw.json" 2>/dev/null || echo "")
if echo "$PLUGINS" | grep -q "telegram"; then
    check_pass "Channel plugins loaded"
else
    check_fail "Channel plugins: '$PLUGINS'"
fi

# Check 8: Backup config valid
BACKUP_CFG=$(doctl apps console "$APP_ID" openclaw --command "yq eval '.repository' /etc/digitalocean/backup.yaml 2>/dev/null && echo CFG_OK" 2>/dev/null || echo "")
if echo "$BACKUP_CFG" | grep -q "CFG_OK"; then
    check_pass "Backup config valid"
else
    check_fail "Backup config not parseable"
fi

# Check 9: Telegram channel probe (optional)
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    log "Probing Telegram channel..."
    doctl apps console "$APP_ID" openclaw --command "
        jq '.plugins.entries.telegram.token = \"${TELEGRAM_BOT_TOKEN}\"' /data/.openclaw/openclaw.json > /tmp/oc_tg.json \
        && cp /tmp/oc_tg.json /data/.openclaw/openclaw.json \
        && chown openclaw:openclaw /data/.openclaw/openclaw.json \
        && /command/s6-svc -r /run/service/openclaw
    " 2>/dev/null || true
    sleep 15
    TG_STATUS=$(doctl apps console "$APP_ID" openclaw --command "su - openclaw -c 'openclaw channels status 2>/dev/null'" 2>/dev/null || echo "")
    if echo "$TG_STATUS" | grep -qi "connected\|available\|ok"; then
        check_pass "Telegram channel connected"
    else
        echo "  WARN: Telegram channel status unclear: $TG_STATUS"
    fi
else
    echo "  SKIP: Telegram probe (TELEGRAM_BOT_TOKEN not set)"
fi

# ─── Results ──────────────────────────────────────────────────────────────────

echo ""
log "E2E Results: $PASS passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    log "--- Runtime logs ---"
    doctl apps logs "$APP_ID" --type=run 2>/dev/null | tail -30 || true
    fail "$FAIL_COUNT E2E checks failed"
    exit 1
fi

log "All E2E checks passed ✅"
exit 0
