#!/usr/bin/env bash
#
# terminal-wrap.sh -- serves a browser-based terminal (ttyd) inside the
# sandbox, fronted by a local Caddy TLS-terminating reverse proxy, and
# prints/saves a QR code for the published URL so a class can join with a
# phone camera or by scanning a projected screen.
#
# Auth model: ttyd's own HTTP Basic Auth, one SHARED credential per launch
# (username "classroom", a random token persisted at
# $WORK/.classroom-token and reused across restarts of the same --work
# dir) -- the whole class uses the same URL+credential. This is a
# deliberate, documented reduction relative to per-student auth: anyone
# with the URL/QR code has the same shell access as everyone else. See the
# repo README's threat-model section.
#
# Usage:
#   ./terminal-wrap.sh
#   ./terminal-wrap.sh --work /scratch/$USER/mojo-work --keep-id   # instructor
#   ./terminal-wrap.sh --ro-paths "/groups/scicompsoft" --https-port 8443
set -euo pipefail
exec 3<&0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CALLER_PWD="$PWD"

# shellcheck source=common.sh
source "$HERE/common.sh"
# shellcheck source=caddy-lib.sh
source "$HERE/caddy-lib.sh"

INTERNAL_PORT="$PORT"
HTTPS_PORT="${HTTPS_PORT:-$(caddy_free_port)}"

# Shared classroom credential: generated once per --work dir, reused across
# restarts so a re-launched session keeps the same login (matching
# marimo_ai_sandbox's per-session-token model, just shared class-wide
# rather than per-student).
TOKEN_FILE="$WORK/.classroom-token"
if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN="$(cat "$TOKEN_FILE")"
else
    TOKEN="$(openssl rand -hex 16)"
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

# ttyd runs INSIDE the sandbox via shell.sh's command-override support, so
# it gets the exact same read-only-host/writable-/work/GPU handling an
# interactive shell.sh session does.
"$HERE/podman/shell.sh" "${SHELL_FLAGS[@]}" \
    -- ttyd -i 127.0.0.1 -p "$INTERNAL_PORT" -W -c "${AUTH_USER}:${TOKEN}" bash &
TTYD_PID=$!

cleanup() {
    kill "$TTYD_PID" "${CADDY_PID:-}" "${PUBLISHER_PID:-}" 2>/dev/null || true
    wait "$TTYD_PID" "${CADDY_PID:-}" "${PUBLISHER_PID:-}" 2>/dev/null || true
    rm -f "${CADDYFILE:-}"
}
trap cleanup EXIT INT TERM

echo ">> Waiting (up to 30s) for the web terminal to accept connections on 127.0.0.1:${INTERNAL_PORT} ..."
_terminal_up=0
for _ in $(seq 1 30); do
    if curl -sf -o /dev/null -u "${AUTH_USER}:${TOKEN}" "http://127.0.0.1:$INTERNAL_PORT" 2>/dev/null; then
        _terminal_up=1
        break
    fi
    sleep 1
done
if [[ "$_terminal_up" -eq 1 ]]; then
    echo ">> Web terminal is accepting connections."
else
    echo ">> Web terminal hasn't responded yet after 30s (still building/starting); continuing -- Caddy will 502 until it's up."
fi
_set_phase starting

CERT_DIR="${FG_WORK_DIR:-$WORK}/https-cert"
caddy_generate_cert "$CERT_DIR" mojo-terminal-https

FULL_URL="https://${AUTH_USER}:${TOKEN}@${FG_HOSTNAME:-$HOST_NAME}:${HTTPS_PORT}/"

echo ">> HTTPS terminal: $FULL_URL"
echo ">> Cert: $CERT_FILE -- install it in your browser's trust store to avoid the untrusted-certificate warning."
caddy_start "$HTTPS_PORT" "$INTERNAL_PORT"

caddy_publish_service_url "$HTTPS_PORT" "$TTYD_PID" "$FULL_URL"

# QR code for the shared classroom login: an ASCII/ANSI rendering straight
# to this job's log (for the instructor to screenshare/project) and also
# saved to $WORK/qr.txt (so it can be `cat`'d again from inside the sandbox
# terminal, since $WORK is bind-mounted there -- the log can be inconvenient
# to scroll back through mid-class), plus a PNG saved under $WORK for anyone
# who wants a cleaner image to display separately. All three encode the same
# credential-embedded URL -- scanning (or reading) any of them gets a
# student straight into the shared session with no separate login step.
#
# --ascii is required here: `qr` decides PNG-vs-ASCII by checking whether
# its own stdout is a tty, and under Fileglancer/LSF this script's stdout
# is always redirected to a log file, so without --ascii it silently dumps
# raw PNG bytes into the job log instead of a scannable code. The ASCII
# output has no ANSI escapes (plain UTF-8 block characters), so it's safe
# to tee straight into a text file.
echo ">> Scan to join (or open the URL above):"
qr --ascii "$FULL_URL" | tee "$WORK/qr.txt"
echo ">> QR code (ASCII) also saved to $WORK/qr.txt -- cat it from inside the sandbox terminal if needed."
qr --output="$WORK/qrcode.png" "$FULL_URL" 2>/dev/null || true
echo ">> QR code (PNG) also saved to $WORK/qrcode.png"

# Wait on EITHER the web terminal or Caddy, not just Caddy -- if the
# container itself exits (e.g. crash), tear the whole job down instead of
# leaving Caddy running (and the LSF job stuck) forever.
#
# `|| true` and the 0/1 exit codes below: `wait -n` can legitimately return
# nonzero ("no such job") if the dying process was already reaped by the
# time this line runs, which would otherwise abort the script here under
# `set -e` before cleanup/messaging runs.
wait -n "$TTYD_PID" "$CADDY_PID" 2>/dev/null || true
if ! kill -0 "$TTYD_PID" 2>/dev/null; then
    echo ">> Web terminal exited -- shutting down Caddy and this job too."
    _exit=0
else
    echo ">> Caddy exited unexpectedly -- shutting down the web terminal too."
    _exit=1
fi
wait "${PUBLISHER_PID:-}" 2>/dev/null || true
exit "$_exit"
