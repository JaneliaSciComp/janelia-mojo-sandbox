#!/usr/bin/env bash
#
# terminal-http.sh -- plain-HTTP web terminal (ttyd only, no Caddy/TLS of
# our own). For use behind a trusted proxy that terminates TLS itself --
# in particular, Fileglancer's own HTTPS-wrapping of a plain-HTTP service,
# which this script is meant to test against. If you need this sandbox to
# manage its own TLS termination directly (e.g. no Fileglancer, or an older
# Fileglancer without HTTPS-wrapping), use terminal-wrap.sh instead, which
# fronts the same ttyd session with a self-managed Caddy + self-signed
# cert.
#
# UNENCRYPTED: ttyd's own traffic between this host and whatever proxy sits
# in front of it is plain HTTP. Only run this where that hop is trusted
# (e.g. entirely within the Janelia cluster network, terminated by
# Fileglancer at its own edge).
#
# Auth model: same shared "classroom" HTTP Basic Auth credential as
# terminal-wrap.sh (see that script's header comment and the README's
# threat-model section) -- persisted at $WORK/.classroom-token, reused
# across restarts of the same --work dir.
#
# Usage:
#   ./terminal-http.sh
#   ./terminal-http.sh --work /scratch/$USER/mojo-work --keep-id   # instructor
#   ./terminal-http.sh --port 7681
set -euo pipefail
exec 3<&0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CALLER_PWD="$PWD"

# shellcheck source=common.sh
source "$HERE/common.sh"

# Shared classroom credential -- same file/format as terminal-wrap.sh, so
# switching between the plain-HTTP and self-managed-TLS variants for the
# same --work dir keeps the same login.
TOKEN_FILE="$WORK/.classroom-token"
if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN="$(cat "$TOKEN_FILE")"
else
    # No dependency on `openssl` here (unlike terminal-wrap.sh) -- this
    # script intentionally needs nothing beyond the default pixi
    # environment (no [feature.https] required), so the token comes from
    # python's stdlib instead.
    TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"
    printf '%s' "$TOKEN" > "$TOKEN_FILE"
fi
AUTH_USER="classroom"

_set_phase() {
    [[ -n "${FG_PHASE_PATH:-}" ]] && printf '%s' "$1" > "$FG_PHASE_PATH" 2>/dev/null
    return 0
}
_set_phase pulling_image

SHELL_FLAGS=(--work "$WORK")
[[ -n "$RO_PATHS" ]] && SHELL_FLAGS+=(--ro-paths "$RO_PATHS")
[[ "$KEEP_ID" == "1" ]] && SHELL_FLAGS+=(--keep-id)

HOST_NAME="$(hostname -f 2>/dev/null || hostname)"
LOCAL_URL="http://${AUTH_USER}:${TOKEN}@${HOST_NAME}:${PORT}/"

echo ">> Serving PLAIN HTTP web terminal on 0.0.0.0:${PORT} (work dir: $WORK)"
echo ">> Unencrypted -- only expose this behind a trusted proxy that"
echo ">> terminates TLS for you (e.g. Fileglancer's HTTPS-wrapping)."
echo ">> Login: ${AUTH_USER} / ${TOKEN}"

if [[ -n "${SERVICE_URL_PATH:-}" ]]; then
    # Running as a Fileglancer job: Fileglancer's own auto_url mechanism
    # publishes the externally-reachable (and, when its HTTPS-wrapping is
    # enabled, TLS-terminated) URL for a plain-HTTP service on its own --
    # deliberately NOT writing $SERVICE_URL_PATH here ourselves, to avoid
    # racing/conflicting with that.
    echo ">> Running under Fileglancer -- it will publish the externally-reachable URL itself."
else
    echo ">> Local URL: $LOCAL_URL"
    if command -v qr >/dev/null 2>&1; then
        echo ">> Scan to join (or open the URL above):"
        qr "$LOCAL_URL"
    fi
fi

_set_phase starting

exec "$HERE/podman/shell.sh" "${SHELL_FLAGS[@]}" \
    -- ttyd -i 0.0.0.0 -p "$PORT" -W -c "${AUTH_USER}:${TOKEN}" bash
