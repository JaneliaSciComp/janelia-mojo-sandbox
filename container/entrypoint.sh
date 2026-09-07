#!/usr/bin/env bash
#
# entrypoint.sh -- the image's baked ENTRYPOINT. Seeds /work/app with the
# user-editable Mojo pixi project (from the read-only reference copy at
# /opt/app/seed/app), installs/refreshes its pixi environment, puts that
# environment's bin/ on PATH, then execs whatever CMD was requested.
#
# Unlike JaneliaSciComp/marimo_ai_sandbox's entrypoint.sh (which only runs
# on the "serve Marimo" launch path -- a separate script, shell.sh, bypasses
# it entirely via --entrypoint override), THIS project has no such separate
# server-launch path: ttyd/shell is the only interface. So this script must
# run, unconditionally, on every single container launch -- whether the
# eventual command is an interactive `bash` (plain shell.sh) or the full
# ttyd argv (`shell.sh -- ttyd -i 127.0.0.1 -p 7681 -W bash`, via
# terminal-wrap.sh). container/podman/shell.sh is written to never override
# --entrypoint for exactly this reason -- see that script's own comments.
set -euo pipefail

APP_DIR="/work/app"
SEED_DIR="/opt/app/seed/app"

mkdir -p /work/home /work/tmp
export HOME="${HOME:-/work/home}"
export TMPDIR="${TMPDIR:-/work/tmp}"

# 1. Seed /work/app with the user-editable Mojo pixi project, once. Never
#    overwrites a student's own edits on a later launch (cp -n).
if [[ ! -f "$APP_DIR/pixi.toml" ]]; then
    mkdir -p "$APP_DIR"
    cp -n "$SEED_DIR"/* "$APP_DIR"/ 2>/dev/null || true
fi

# 2. Materialize/update the mojo toolchain on EVERY launch (not just the
#    first), so an edit to app/pixi.toml before a later shell/ttyd
#    invocation takes effect, and a stale/missing .pixi env self-heals.
#    Prefer the locked, reproducible install; fall back to a fresh resolve
#    if a student has hand-edited pixi.toml without updating pixi.lock.
cd "$APP_DIR"
if ! pixi install --locked; then
    echo "WARNING: pixi.lock stale/missing for $APP_DIR/pixi.toml -- falling back to an unlocked install" >&2
    pixi install
fi

# 3. container/app/pixi.toml declares no [environments] table, so the
#    resolved environment is always at .pixi/envs/default. Put its bin/
#    ahead of everything else so `mojo`, etc. resolve from the seeded
#    /work env, not the image's own baked infra-tools env.
export PATH="$APP_DIR/.pixi/envs/default/bin:$PATH"

# `mojo` cannot locate its standard library without MODULAR_HOME -- this is
# normally set by pixi's shell activation hook, which a plain PATH prepend
# skips entirely. Without it, `mojo run`/`mojo build` fail with "unable to
# locate module 'std'" even though `mojo --version` works fine.
export MODULAR_HOME="$APP_DIR/.pixi/envs/default/share/max"

# 4. Hand off to whatever CMD was requested.
exec "$@"
