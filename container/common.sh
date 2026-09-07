#!/usr/bin/env bash
#
# common.sh -- sourced by container/podman/shell.sh and
# container/terminal-wrap.sh. Not meant to be executed directly.
#
# Adapted from JaneliaSciComp/marimo_ai_sandbox's container/common.sh, with
# the ENABLE_BSUB / LSF bsub-wrapper machinery removed entirely: this
# project has no bsub re-entry wrapper (bsub+rootless-Podman is confirmed
# broken on this cluster via LSF's eauth/Kerberos), so there is nothing for
# it to wire up.
#
# Reads (uses defaults if unset):
#   WORK, PORT, HTTPS_PORT, RO_PATHS
#   KEEP_ID -- "1" to run the container as your real host uid/gid
#   (--userns=keep-id --user "$(id -u):$(id -g)") instead of root mapped
#   through the user namespace. Requires an /etc/subuid//etc/subgid range
#   for your account. Intended for the INSTRUCTOR's shared-session launch,
#   not for students launching their own instance (most student accounts
#   have no subuid range). Default unset/off.
#
# Also accepts on the caller's "$@" (highest precedence, overrides the env
# var and conf/config.toml; consumed here, remaining args are left in "$@"
# for the caller to forward on, and anything after a literal "--" is
# captured into TRAILING_ARGS untouched):
#   --work PATH         or   --work=PATH
#   --port PORT          or   --port=PORT
#   --https-port PORT    or   --https-port=PORT
#   --ro-paths PATHS     or   --ro-paths=PATHS   (space-separated)
#   --ro-path-1 PATH     or   --ro-path-1=PATH   (single-directory slots, for
#   --ro-path-2 PATH     or   --ro-path-2=PATH   Fileglancer's directory picker
#   --ro-path-3 PATH     or   --ro-path-3=PATH   -- see below)
#   --keep-id                                    (no value; same as KEEP_ID=1)
#
# Sets:
#   WORK, PORT, HTTPS_PORT, RO_PATHS, KEEP_ID
#   BIND_PAIRS    -- "src:dst[:options]" strings; caller prefixes with -v
#   HAS_GPU       -- "1" if an NVIDIA GPU was detected on this host, else "0"
#   TRAILING_ARGS -- array; everything after a literal "--" on the command
#                    line (e.g. `shell.sh -- ttyd -p 7681 -W bash`)
#
# Side-effects:
#   Creates $WORK/home and $WORK/tmp.

set -euo pipefail

TRAILING_ARGS=()
_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --work)
            [[ -n "${2:-}" ]] && WORK="$2"
            shift 2
            ;;
        --work=*)
            _val="${1#--work=}"
            [[ -n "$_val" ]] && WORK="$_val"
            shift
            ;;
        --port)
            [[ -n "${2:-}" ]] && PORT="$2"
            shift 2
            ;;
        --port=*)
            _val="${1#--port=}"
            [[ -n "$_val" ]] && PORT="$_val"
            shift
            ;;
        --https-port)
            [[ -n "${2:-}" ]] && HTTPS_PORT="$2"
            shift 2
            ;;
        --https-port=*)
            _val="${1#--https-port=}"
            [[ -n "$_val" ]] && HTTPS_PORT="$_val"
            shift
            ;;
        --ro-paths)
            [[ -n "${2:-}" ]] && RO_PATHS="$2"
            shift 2
            ;;
        --ro-paths=*)
            _val="${1#--ro-paths=}"
            [[ -n "$_val" ]] && RO_PATHS="$_val"
            shift
            ;;
        --ro-path-[0-9])
            [[ -n "${2:-}" ]] && _RO_PATH_SLOTS="${_RO_PATH_SLOTS:-}${_RO_PATH_SLOTS:+ }$2"
            shift 2
            ;;
        --ro-path-[0-9]=*)
            _val="${1#--ro-path-*=}"
            [[ -n "$_val" ]] && _RO_PATH_SLOTS="${_RO_PATH_SLOTS:-}${_RO_PATH_SLOTS:+ }$_val"
            shift
            ;;
        --keep-id)
            KEEP_ID=1
            shift
            ;;
        --)
            shift
            TRAILING_ARGS=("$@")
            break
            ;;
        *)
            _args+=("$1")
            shift
            ;;
    esac
done
set -- "${_args[@]}"
unset _args _val

# common.sh's own path is always <repo_root>/container/common.sh regardless
# of which script sources it or what that script's $PWD happens to be
# (shell.sh cd's to container/podman/ first; terminal-wrap.sh doesn't cd at
# all) -- so resolve the project root from BASH_SOURCE, not $PWD.
_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load conf/config.toml if present, setting WORK/PORT/HTTPS_PORT/RO_PATHS
# from it (only when not already set from the environment or "$@" above).
# Run via the top-level pixi environment's own python3 (guaranteed to have
# tomllib -- see pixi.toml's `python` dependency), not a bare system
# python3, which may be too old or simply absent on a given node.
_CONFIG="${CONFIG_TOML:-$_PROJECT_ROOT/conf/config.toml}"
if [[ -f "$_CONFIG" ]]; then
    _toml_all="$(cd "$_PROJECT_ROOT" && pixi run python3 -c "
import tomllib
with open('$_CONFIG', 'rb') as f:
    d = tomllib.load(f)
print(d.get('work', ''))
print(d.get('port', ''))
print(d.get('https_port', ''))
print(' '.join(d.get('ro_paths', [])))
" 2>/dev/null)" || _toml_all=""
    _toml_work="$(sed -n '1p' <<< "$_toml_all")"
    _toml_port="$(sed -n '2p' <<< "$_toml_all")"
    _toml_https_port="$(sed -n '3p' <<< "$_toml_all")"
    _toml_ro="$(sed -n '4p' <<< "$_toml_all")"
    [[ -n "$_toml_work" ]] && WORK="${WORK:-$_toml_work}"
    [[ -n "$_toml_port" ]] && PORT="${PORT:-$_toml_port}"
    [[ -n "$_toml_https_port" ]] && HTTPS_PORT="${HTTPS_PORT:-$_toml_https_port}"
    [[ -n "$_toml_ro" ]] && RO_PATHS="${RO_PATHS:-$_toml_ro}"
    unset _toml_all _toml_work _toml_port _toml_https_port _toml_ro
fi
unset _CONFIG

# --ro-path-1/2/3 (Fileglancer's directory-picker slots) are always additive
# on top of RO_PATHS, however RO_PATHS itself got set (env var,
# conf/config.toml, or --ro-paths).
if [[ -n "${_RO_PATH_SLOTS:-}" ]]; then
    RO_PATHS="${RO_PATHS:-}${RO_PATHS:+ }$_RO_PATH_SLOTS"
fi
unset _RO_PATH_SLOTS

WORK="${WORK:-$_PROJECT_ROOT/work}"
PORT="${PORT:-7681}"
HTTPS_PORT="${HTTPS_PORT:-}"
RO_PATHS="${RO_PATHS:-}"
KEEP_ID="${KEEP_ID:-0}"
unset _PROJECT_ROOT

# A relative WORK is resolved against the caller's original directory
# (captured by the calling script before its own `cd`), not this script's
# own dir.
[[ "$WORK" != /* ]] && WORK="${_CALLER_PWD:-$PWD}/$WORK"

# Prepare the writable work dir.
mkdir -p "$WORK"/home "$WORK"/tmp

# ---------------------------------------------------------------------------
# BIND_PAIRS -- one "src:dst[:options]" entry per mount. Caller prefixes
# each with `-v` for `podman run`.
# ---------------------------------------------------------------------------
BIND_PAIRS=("$WORK:/work:rw")

# Read-only host paths, refusing bare autofs parents: a read-only bind of an
# autofs PARENT is not recursive and silently leaves its nested, per-lab NFS
# mounts writable underneath -- a real sandbox-escape class, not a
# hypothetical. Leaf paths (e.g. /groups/scicompsoft) are fine.
for _p in $RO_PATHS; do
    case "$_p" in
        /groups|/nrs|/scratch|/misc|/nearline|/tier2)
            echo "ERROR: '$_p' is an autofs parent; a read-only bind will NOT protect its" >&2
            echo "       nested per-lab NFS mounts. Use leaf paths, e.g. ${_p}/<lab>." >&2
            exit 1
            ;;
    esac
    if [[ -d "$_p" ]]; then
        BIND_PAIRS+=("$_p:$_p:ro")
    else
        echo "note: skipping missing read-only path: $_p" >&2
    fi
done
unset _p

# ---------------------------------------------------------------------------
# HAS_GPU -- detected at launch time (not assumed), so the same command
# works unchanged on GPU and non-GPU nodes. `nvidia-smi -L` fails fast and
# silently if no driver/GPU is present, unlike a bare `nvidia-smi`.
# ---------------------------------------------------------------------------
HAS_GPU=0
if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null; then
    HAS_GPU=1
fi
