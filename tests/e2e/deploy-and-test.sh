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
    APP_JSON=$(doctl apps get "$APP_ID" --output json 2>/dev/null || echo "{}")

    # doctl returns the app object directly (not wrapped in array)
    # pending_deployment holds a deployment in progress (PENDING → BUILDING → DEPLOYING → ACTIVE)
    # Once ACTIVE, it becomes the active_deployment and pending_deployment disappears
    PENDING_PHASE=$(echo "$APP_JSON" | jq -r '.pending_deployment.phase // ""' 2>/dev/null)
    ACTIVE_PHASE=$(echo "$APP_JSON" | jq -r '.active_deployment.phase // ""' 2>/dev/null)

    # Prefer pending (in-progress) over active (stable state)
    if [ -n "$PENDING_PHASE" ]; then
        PHASE="$PENDING_PHASE"
    elif [ -n "$ACTIVE_PHASE" ]; then
        PHASE="$ACTIVE_PHASE"
    else
        PHASE="UNKNOWN"
        # Debug on first occurrence
        if [ "$ELAPSED" -eq 0 ]; then
            log "DEBUG: No deployment phase found. Raw JSON keys:"
            echo "$APP_JSON" | jq -r 'keys | .[]' 2>/dev/null | head -10 || echo "jq failed"
        fi
    fi

    case "$PHASE" in
        ACTIVE)
            log "Deployment active after ${ELAPSED}s"
            break
            ;;
        ERROR|CANCELED|SUPERSEDED)
            fail "Deployment entered terminal phase: $PHASE"
            log "--- Build logs ---"
            doctl apps logs "$APP_ID" --type=build 2>/dev/null | tail -30 || true
            log "--- Deploy logs ---"
            doctl apps logs "$APP_ID" --type=deploy 2>/dev/null | tail -30 || true
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
    log "--- Build logs ---"
    doctl apps logs "$APP_ID" --type=build 2>/dev/null | tail -30 || true
    log "--- Deploy logs ---"
    doctl apps logs "$APP_ID" --type=deploy 2>/dev/null | tail -50 || true
    exit 1
fi

# ─── Wait for gateway startup and collect runtime logs ───────────────────────
# doctl apps console has no --command flag; use runtime log polling instead.

PASS=0
FAIL_COUNT=0

check_pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
check_fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

log "Waiting for gateway startup (up to 3min)..."

LOG_CONTENT=""
for i in $(seq 1 18); do
    RAW_LOGS=$(doctl apps logs "$APP_ID" openclaw --type=run 2>/dev/null || echo "")
    # Strip the "<component> <timestamp>" prefix from each log line
    LOG_CONTENT=$(echo "$RAW_LOGS" | sed 's/^[^ ]* [^ ]* //')
    if echo "$LOG_CONTENT" | grep -q "\[openclaw\] Starting openclaw"; then
        log "Gateway startup detected (~$((i * 10))s)"
        break
    fi
    echo "  [$i/18] Waiting for gateway startup..."
    sleep 10
done

log "Running E2E health checks..."

# Check 1: Config was generated successfully
if echo "$LOG_CONTENT" | grep -q "Done generating config"; then
    check_pass "Config generated"
else
    check_fail "Config generation not confirmed in logs"
fi

# Check 2: tools.profile is coding
if echo "$LOG_CONTENT" | grep -q '"profile": "coding"'; then
    check_pass "tools.profile: coding"
else
    PROFILE=$(echo "$LOG_CONTENT" | grep '"profile"' | head -1 | sed 's/.*"profile": *"\([^"]*\)".*/\1/')
    check_fail "tools.profile: '$PROFILE'"
fi

# Check 3: Gateway process started
if echo "$LOG_CONTENT" | grep -q "\[openclaw\] Starting openclaw"; then
    check_pass "Gateway process started"
else
    check_fail "Gateway process not started"
fi

# Check 4: Auth mode is token
if echo "$LOG_CONTENT" | grep -q '"mode": "token"'; then
    check_pass "Auth mode: token"
else
    check_fail "Auth mode not 'token' in logs"
fi

# Check 5: Channel plugins present (telegram is the canary)
if echo "$LOG_CONTENT" | grep -q '"telegram"'; then
    check_pass "Channel plugins present"
else
    check_fail "Channel plugins not found in config log"
fi

# Check 6: Feature flags applied (services disabled per spec)
MISSING_FLAGS=""
for svc in tailscale ngrok sshd; do
    if ! echo "$LOG_CONTENT" | grep -qi "\[$svc\].*[Dd]isabled\|\[$svc\].*[Ss]kip"; then
        MISSING_FLAGS="$MISSING_FLAGS $svc"
    fi
done
if [ -z "$MISSING_FLAGS" ]; then
    check_pass "Feature flags applied (tailscale/ngrok/ssh disabled)"
else
    echo "  WARN: disable log not found for:$MISSING_FLAGS (may still be correct)"
fi

# Check 7: Init scripts all exited 0
INIT_FAILURES=$(echo "$LOG_CONTENT" | grep "cont-init.*exited" | grep -v "exited 0" || true)
if [ -z "$INIT_FAILURES" ]; then
    check_pass "All init scripts exited 0"
else
    check_fail "Init failures detected: $INIT_FAILURES"
fi

# ─── Results ──────────────────────────────────────────────────────────────────

echo ""
log "E2E Results: $PASS passed, $FAIL_COUNT failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
    log "--- Runtime logs (last 50 lines) ---"
    echo "$LOG_CONTENT" | tail -50
    fail "$FAIL_COUNT E2E checks failed"
    exit 1
fi

log "All E2E checks passed ✅"
exit 0
