#!/usr/bin/env bash
#
# shell.sh -- open an interactive shell inside the sandbox via Podman, with
# a read-only view of the host filesystem and a single writable /work.
# Also used, via a command override, to run ttyd for
# container/terminal-wrap.sh.
#
# IMPORTANT: unlike JaneliaSciComp/marimo_ai_sandbox's shell.sh, this script
# NEVER overrides `--entrypoint`. The image's baked
# ENTRYPOINT ["/opt/app/entrypoint.sh"] (see container/entrypoint.sh) must
# always run first -- it seeds /work/app and installs the Mojo pixi
# environment on every launch, and there is no separate "server" launch
# path in this project that would otherwise have done that seeding. The
# desired command (plain `bash`, or `ttyd ... bash`) is passed as trailing
# CMD args instead, and entrypoint.sh execs into it once seeding is done.
#
# Usage:
#   ./shell.sh
#   ./shell.sh --work /scratch/$USER/mojo-work
#   ./shell.sh --ro-paths "/groups/scicompsoft /nrs/scicompsoft"
#   ./shell.sh --keep-id                     # instructor use -- see common.sh
#   ./shell.sh -- ttyd -i 127.0.0.1 -p 7681 -W bash   # used by terminal-wrap.sh
#   IMAGE=janelia-mojo-sandbox:latest ./shell.sh
set -euo pipefail

# Save the real stdin before podman run backgrounds (needed for lib.sh's
# podman_run_watched catatonit watchdog) -- bash silently redirects a
# backgrounded job's stdin from /dev/null otherwise, breaking the
# interactive session.
exec 3<&0

# Captured before the cd below so common.sh can resolve a relative --work
# path against where the user actually ran this from, not this script's dir.
_CALLER_PWD="$PWD"

cd "$(dirname "$0")"

IMAGE="${IMAGE:-janelia-mojo-sandbox:latest}"

# shellcheck source=../common.sh
source "../common.sh"
# shellcheck source=lib.sh
source "./lib.sh"

podman_resolve_image
podman_storage_setup_job

cleanup() {
    podman_storage_cleanup
    rm -f "$PODMAN_STORAGE_CONF_FILE" 2>/dev/null
    true
}
trap cleanup EXIT

BIND_ARGS=(); for p in "${BIND_PAIRS[@]}"; do BIND_ARGS+=(-v "$p"); done
ENV_ARGS=(-e "HOME=/work/home" -e "TMPDIR=/work/tmp")

# CDI (Container Device Interface), not the older --gpus flag -- this
# host's GPU access is provisioned via nvidia-container-toolkit's CDI spec
# (/etc/cdi/nvidia.yaml), which rootless Podman supports directly.
GPU_ARGS=(); [[ "$HAS_GPU" == "1" ]] && GPU_ARGS+=(--device nvidia.com/gpu=all)

# Instructor-only, opt-in: runs the container as your real host uid/gid
# instead of root-mapped-through-the-user-namespace. Requires an
# /etc/subuid//etc/subgid range. See common.sh's doc comment.
KEEP_ID_ARGS=(); [[ "$KEEP_ID" == "1" ]] && KEEP_ID_ARGS+=(--userns=keep-id --user "$(id -u):$(id -g)")

# Default: interactive bash. Override via a literal `--` (see usage above),
# captured into TRAILING_ARGS by common.sh -- e.g.
# `./shell.sh -- ttyd -i 127.0.0.1 -p 7681 -W bash` (terminal-wrap.sh).
if [[ "${#TRAILING_ARGS[@]}" -eq 0 ]]; then
    TRAILING_ARGS=(bash)
fi

echo ">> Launching sandbox (work dir: $WORK)"
echo ">> Read-only host binds:${RO_PATHS:- (none)}"
[[ "$HAS_GPU" == "1" ]] && echo ">> GPU detected -- passing --device nvidia.com/gpu=all"

PODMAN_RUN_ARGS=(
    --rm -it
    --read-only
    --tmpfs /tmp
    --tmpfs /run
    --cgroup-manager=cgroupfs
    --events-backend=file
    # Shares the host's network namespace, so ttyd binding to
    # 127.0.0.1/0.0.0.0 *inside* the container lands on the actual host
    # network stack -- required for terminal-wrap.sh's Caddy (running on
    # the host) to reach it, and for Fileglancer's own reverse proxy to
    # reach a plain-HTTP ttyd directly. This project has no per-container
    # network namespace/egress-allowlist feature, so this is unconditional.
    --net=host
    -w /work
    "${BIND_ARGS[@]}"
    "${ENV_ARGS[@]}"
    "${GPU_ARGS[@]}"
    "${KEEP_ID_ARGS[@]}"
    "$IMAGE"
    "${TRAILING_ARGS[@]}"
)

podman_run_watched PODMAN_RUN_ARGS
exit $?
