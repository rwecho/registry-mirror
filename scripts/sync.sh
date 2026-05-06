#!/usr/bin/env bash
# ============================================================================
# Registry Mirror Sync Script
# ============================================================================
# Reads images.yaml and syncs each image from source to target registry
# using skopeo. Performs digest comparison for incremental sync.
# ============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
CONFIG_FILE="${1:-images.yaml}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
# Allow overriding target registry via environment (useful for local runner)
TARGET_REGISTRY="${TARGET_REGISTRY:-}"
NO_TLS_VERIFY="${NO_TLS_VERIFY:-false}"

# --- Colors ------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Stats -------------------------------------------------------------------
TOTAL=0
SYNCED=0
SKIPPED=0
FAILED=0
FAILED_IMAGES=""

# --- Functions ---------------------------------------------------------------

log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
log_skip()  { echo -e "${YELLOW}[SKIP]${NC} $*"; }
log_err()   { echo -e "${RED}[FAIL]${NC} $*"; }

# Parse YAML using Python3 (available on ubuntu-latest GitHub Actions runners)
parse_config() {
    python3 -c "
import sys, yaml
try:
    with open('$1') as f:
        data = yaml.safe_load(f)
    if not data:
        sys.exit(1)
    print(data.get('registry', ''))
    for img in data.get('images', []):
        src = img.get('source', '')
        tgt = img.get('target', '')
        if src and tgt:
            print(f'{src}|{tgt}')
except Exception as e:
    sys.exit(1)
"
}

# Get the digest of an image (returns SHA256 or empty string on failure)
get_digest() {
    local image="$1"
    local auth_option="${2:-}"

    local output
    if [ -n "$auth_option" ]; then
        output=$(skopeo inspect --authfile /tmp/.skopeo_auth --raw "docker://${image}" 2>/dev/null || true)
    else
        output=$(skopeo inspect --raw "docker://${image}" 2>/dev/null || true)
    fi

    if [ -z "$output" ]; then
        echo ""
        return
    fi

    # Try to extract digest from the manifest
    echo "$output" | sha256sum | cut -d' ' -f1
}

# --- Main --------------------------------------------------------------------

# Check prerequisites
if ! command -v skopeo &>/dev/null; then
    log_err "skopeo is not installed. Please install it first."
    exit 1
fi

# Parse config
log_info "Reading configuration from ${CONFIG_FILE}..."
if [ ! -f "$CONFIG_FILE" ]; then
    log_err "Config file '${CONFIG_FILE}' not found!"
    exit 1
fi

CONFIG_OUTPUT=$(parse_config "$CONFIG_FILE")
CONFIG_REGISTRY=$(echo "$CONFIG_OUTPUT" | head -1)

# Use env override if set, otherwise use config file value
if [ -n "$TARGET_REGISTRY" ]; then
    log_info "Using TARGET_REGISTRY from environment: ${TARGET_REGISTRY}"
    TARGET_REGISTRY="${TARGET_REGISTRY}"
else
    TARGET_REGISTRY="${CONFIG_REGISTRY}"
fi

if [ -z "$TARGET_REGISTRY" ]; then
    log_err "Failed to parse config or no registry specified."
    exit 1
fi

# Extract image entries (skip first line which is registry)
mapfile -t IMAGE_ENTRIES < <(echo "$CONFIG_OUTPUT" | tail -n +2)

log_info "Target registry: ${TARGET_REGISTRY}"
log_info "Images to process: ${#IMAGE_ENTRIES[@]}"
echo ""

# Login to target registry
if [ -n "$REGISTRY_USERNAME" ] && [ -n "$REGISTRY_PASSWORD" ]; then
    log_info "Logging in to ${TARGET_REGISTRY}..."
    echo "$REGISTRY_PASSWORD" | skopeo login --authfile /tmp/.skopeo_auth \
        --username "$REGISTRY_USERNAME" \
        --password-stdin \
        "$TARGET_REGISTRY" 2>/dev/null
    log_ok "Login successful"
    AUTH_OPTION="--authfile /tmp/.skopeo_auth"
else
    log_info "No credentials provided — proceeding without authentication"
    AUTH_OPTION=""
fi
echo ""

# Process each image
for entry in "${IMAGE_ENTRIES[@]}"; do
    TOTAL=$((TOTAL + 1))

    IFS='|' read -r source_image target_path <<< "$entry"
    target_image="${TARGET_REGISTRY}/${target_path}"

    echo "----------------------------------------"
    log_info "Source: ${source_image}"
    log_info "Target: ${target_image}"

    # Get source digest
    source_digest=$(get_digest "$source_image" "")
    if [ -z "$source_digest" ]; then
        log_err "Cannot access source image — skipping"
        FAILED=$((FAILED + 1))
        FAILED_IMAGES="${FAILED_IMAGES}  - ${source_image}\n"
        continue
    fi
    log_info "Source digest: ${source_digest:0:12}..."

    # Get target digest (for incremental check)
    target_digest=$(get_digest "$target_image" "$AUTH_OPTION")
    if [ -n "$target_digest" ]; then
        log_info "Target digest: ${target_digest:0:12}..."
    else
        log_info "Target does not exist yet"
    fi

    # Compare digests
    if [ -n "$target_digest" ] && [ "$source_digest" = "$target_digest" ]; then
        log_skip "Digest match — image is up to date"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Sync the image
    log_info "Syncing..."
    SKOPEO_OPTS="--all --retry-times 3"
    # For HTTP (non-HTTPS) registries, skip TLS verification
    if [ "$NO_TLS_VERIFY" = "true" ] || [[ "$target_image" == http://* ]]; then
        SKOPEO_OPTS="$SKOPEO_OPTS --dest-tls-verify=false"
    fi
    sync_success=false
    set +e
    for retry_round in 0 1 2 3; do
        if [ $retry_round -gt 0 ]; then
            log_info "Connection lost — retry ${retry_round}/3 in 30s..."
            sleep 30
        fi
        skopeo copy \
            $SKOPEO_OPTS \
            ${AUTH_OPTION:+--authfile /tmp/.skopeo_auth} \
            "docker://${source_image}" \
            "docker://${target_image}" 2>/tmp/skopeo_err.$$
        exit_code=$?
        if [ $exit_code -eq 0 ]; then
            sync_success=true
            break
        fi
        err_output=$(cat /tmp/skopeo_err.$$)
        if ! echo "$err_output" | grep -qiE "(connection refused|connection timed out|i/o timeout|dial tcp|write tcp)"; then
            log_err "Non-connection error — not retrying"
            break
        fi
    done
    set -e
    if [ "$sync_success" = true ]; then
        log_ok "Sync completed"
        SYNCED=$((SYNCED + 1))
    else
        log_err "Sync failed"
        FAILED=$((FAILED + 1))
        FAILED_IMAGES="${FAILED_IMAGES}  - ${source_image}\n"
    fi
done

# --- Summary -----------------------------------------------------------------
echo ""
echo "========================================"
echo "           SYNC SUMMARY"
echo "========================================"
echo "  Total:   ${TOTAL}"
echo -e "  Synced:  ${GREEN}${SYNCED}${NC}"
echo -e "  Skipped: ${YELLOW}${SKIPPED}${NC}"
echo -e "  Failed:  ${RED}${FAILED}${NC}"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed images:${NC}"
    echo -e "$FAILED_IMAGES"
    exit 1
fi

exit 0
