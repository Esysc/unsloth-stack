#!/bin/bash
set -euo pipefail

USER_DB_PATH="/var/lib/caddy/users.json"

# Create user from environment variables if users.json doesn't exist
if [[ ! -f "$USER_DB_PATH" ]]; then
    echo "Creating admin user from environment variables..."

    # Check if required environment variables are set
    if [[ -z "${ADMIN_USERNAME:-}" || -z "${ADMIN_PASSWORD:-}" || -z "${ADMIN_EMAIL:-}" ]]; then
        echo "ERROR: Required environment variables not set:"
        echo "  ADMIN_USERNAME: ${ADMIN_USERNAME:-not set}"
        echo "  ADMIN_PASSWORD: ${ADMIN_PASSWORD:-not set}"
        echo "  ADMIN_EMAIL: ${ADMIN_EMAIL:-not set}"
        exit 1
    fi

    # Hash the password using caddy's bcrypt implementation
    PASSWORD_HASH="$(caddy hash-password --plaintext "$ADMIN_PASSWORD" --algorithm bcrypt)"
    HASH_COST="$(printf '%s' "$PASSWORD_HASH" | cut -d'$' -f3)"
    HASH_COST="${HASH_COST:-10}"

    NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    USER_ID="$(cat /proc/sys/kernel/random/uuid)"
    EMAIL_DOMAIN="${ADMIN_EMAIL##*@}"

    # Create users.json directly (no caddy validate needed — it creates a default webadmin user)
    cat > "$USER_DB_PATH" <<ENDJSON
{
  "revision": 1,
  "last_modified": "$NOW",
  "users": [
    {
      "id": "$USER_ID",
      "username": "$ADMIN_USERNAME",
      "email_address": {"address": "$ADMIN_EMAIL", "domain": "$EMAIL_DOMAIN"},
      "email_addresses": [{"address": "$ADMIN_EMAIL", "domain": "$EMAIL_DOMAIN"}],
      "passwords": [
        {
          "purpose": "generic",
          "algorithm": "bcrypt",
          "hash": "$PASSWORD_HASH",
          "cost": $HASH_COST,
          "expired_at": "0001-01-01T00:00:00Z",
          "created_at": "$NOW",
          "disabled_at": "0001-01-01T00:00:00Z"
        }
      ],
      "created": "$NOW",
      "last_modified": "$NOW",
      "roles": [{"name": "admin", "organization": "authp"}]
    }
  ]
}
ENDJSON
    chmod 600 "$USER_DB_PATH"

    echo "User bootstrap complete."
    echo "Admin username: $ADMIN_USERNAME"
    echo "Admin email: $ADMIN_EMAIL"
    echo "Enroll MFA in portal settings after first login."
else
    echo "users.json already exists, skipping user creation"
fi

# --- Wait for Unsloth Studio to be reachable ---
STUDIO_URL="http://${STUDIO_HOST}:${STUDIO_PORT}"
STUDIO_TIMEOUT="${STUDIO_TIMEOUT:-60}"
STUDIO_INTERVAL=2

echo "Waiting for Unsloth Studio at ${STUDIO_URL} (timeout: ${STUDIO_TIMEOUT}s)..."
start_ts=$(date +%s)
until curl -sf --max-time 3 "${STUDIO_URL}" >/dev/null 2>&1; do
    now_ts=$(date +%s)
    elapsed=$(( now_ts - start_ts ))
    if [[ $elapsed -ge $STUDIO_TIMEOUT ]]; then
        echo "ERROR: Unsloth Studio not reachable at ${STUDIO_URL} after ${STUDIO_TIMEOUT}s"
        exit 1
    fi
    echo "  Unsloth Studio not ready yet (${elapsed}s/${STUDIO_TIMEOUT}s), retrying in ${STUDIO_INTERVAL}s..."
    sleep "$STUDIO_INTERVAL"
done
echo "Unsloth Studio is reachable."

# --- Fetch Unsloth logo from running instance ---
ASSETS_DIR="/var/lib/caddy/assets"
mkdir -p "$ASSETS_DIR"

LOGO_FORMAT="none"

# Helper: fetch only if content type is an image (not HTML SPA shell)
fetch_if_image() {
    local url="$1" dest="$2"
    local content_type
    content_type=$(curl -sf --max-time 5 -o "$dest" -w "%{content_type}" "$url" 2>/dev/null) || return 1
    case "$content_type" in
        image/*) return 0 ;;
        *) rm -f "$dest"; return 1 ;;
    esac
}

for logo_path in "/static/logo.svg" "/static/img/logo.svg" "/static/logo.png" "/static/img/logo.png"; do
    if fetch_if_image "${STUDIO_URL}${logo_path}" "$ASSETS_DIR/logo.svg"; then
        echo "Fetched logo from ${STUDIO_URL}${logo_path}"
        LOGO_FORMAT="svg"
        break
    fi
done

if [[ "$LOGO_FORMAT" == "none" ]]; then
    for favicon_path in "/favicon.ico" "/favicon.png"; do
        if fetch_if_image "${STUDIO_URL}${favicon_path}" "$ASSETS_DIR/logo.png"; then
            echo "Fetched favicon from ${STUDIO_URL}${favicon_path}"
            LOGO_FORMAT="png"
            break
        fi
    done
fi

# --- Patch Caddyfile to only reference the fetched logo format ---
# Copy mounted Caddyfile to a writable location (bind mounts can't be overwritten with cp/sed -i)
CADDYFILE_SRC="/etc/caddy/Caddyfile"
CADDYFILE="/etc/caddy/Caddyfile.active"
cp "$CADDYFILE_SRC" "$CADDYFILE"

case "$LOGO_FORMAT" in
    svg)
        sed '/static_asset.*logo\.png/d' "$CADDYFILE" > "${CADDYFILE}.tmp"
        mv "${CADDYFILE}.tmp" "$CADDYFILE"
        ;;
    png)
        sed '/static_asset.*logo\.svg/d' "$CADDYFILE" | \
            sed 's|/auth/assets/images/logo.svg|/auth/assets/images/logo.png|g' > "${CADDYFILE}.tmp"
        mv "${CADDYFILE}.tmp" "$CADDYFILE"
        ;;
    none)
        sed '/static_asset.*logo\./d' "$CADDYFILE" | \
            sed '/logo url/d' > "${CADDYFILE}.tmp"
        mv "${CADDYFILE}.tmp" "$CADDYFILE"
        echo "Warning: Could not fetch logo from Unsloth instance, using default portal branding"
        ;;
esac

if [[ "${BOOTSTRAP_ONLY:-0}" == "1" ]]; then
    echo "BOOTSTRAP_ONLY=1 set, exiting after bootstrap"
    exit 0
fi

# Start Caddy with the patched configuration
exec caddy run --config /etc/caddy/Caddyfile.active --adapter caddyfile
