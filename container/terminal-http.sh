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

# Prefer Fileglancer's own minted hostname (FG_HOSTNAME) when present -- it's
# what Fileglancer's HTTPS proxy (JaneliaSciComp/fileglancer#440) validates
# a published upstream against (service_proxy_upstream_zone/_networks), so
# using our own `hostname -f` here could mismatch (FQDN vs short name) and
# get the proxied URL refused.
HOST_NAME="${FG_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
# No embedded userinfo (classroom:token@) -- Fileglancer's proxy resolver
# requires a bare `host:port` netloc and hard-refuses anything else
# (fileglancer/apps/serviceproxy.py's _UPSTREAM_RE), so a userinfo-bearing
# URL here gets a 403 (nginx then shows its own 503 page) even though the
# service itself is up. The credential is still enforced by ttyd's Basic
# Auth -- printed below for the student to enter by hand when prompted.
LOCAL_URL="http://${HOST_NAME}:${PORT}/"

echo ">> Serving PLAIN HTTP web terminal on 0.0.0.0:${PORT} (work dir: $WORK)"
echo ">> Unencrypted -- only expose this behind a trusted proxy that"
echo ">> terminates TLS for you (e.g. Fileglancer's HTTPS-wrapping)."
echo ">> Login: ${AUTH_USER} / ${TOKEN}"
echo ">> Local URL: $LOCAL_URL"

if [[ -n "${SERVICE_URL_PATH:-}" ]]; then
    # Fileglancer's HTTPS proxy (docs/ServiceProxy.md in JaneliaSciComp/
    # fileglancer) only ever REPUBLISHES over HTTPS whatever raw URL a job
    # writes here itself -- it does not detect a listening port on its own.
    # Write it plainly once; Fileglancer re-publishes it at a signed
    # per-job HTTPS subdomain if apps.service_proxy_domain is configured,
    # or shows this raw URL unchanged otherwise.
    printf '%s' "$LOCAL_URL" > "$SERVICE_URL_PATH"
    echo ">> Published to Fileglancer: $SERVICE_URL_PATH"
else
    if command -v qr >/dev/null 2>&1; then
        echo ">> Scan to join (or open the URL above):"
        qr "$LOCAL_URL"
    fi
fi

_set_phase starting

exec "$HERE/podman/shell.sh" "${SHELL_FLAGS[@]}" \
    -- ttyd -i 0.0.0.0 -p "$PORT" -W -c "${AUTH_USER}:${TOKEN}" bash
