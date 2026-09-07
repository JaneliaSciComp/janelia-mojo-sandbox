#!/usr/bin/env bash
#
# lib.sh -- Podman-specific hardening helpers, sourced by
# container/podman/{build,shell}.sh. Not meant to be executed directly.
#
# Ported near-verbatim from JaneliaSciComp/marimo_ai_sandbox's
# container/podman/lib.sh, which battle-tested storage isolation, staleness
# recovery, and the catatonit watchdog below on this same Janelia LSF
# cluster. Dropped relative to that reference: the network-egress allowlist
# wiring (podman_network_setup/podman_network_cleanup) and the registry
# pull/fallback logic in podman_resolve_image -- neither is needed for this
# project's v1 (see the project README/plan for why).

# _podman_storage_shared_setup -- redirects Podman storage off NFS
# (~/.local/share/containers, this host's default, doesn't support
# lsetxattr) to /scratch/$USER/podman-storage, and reconciles staleness
# (e.g. after a node reboot) before anything else runs.
#
# Sets:   PODMAN_STORAGE_ROOT, PODMAN_RUN_ROOT, PODMAN_STORAGE_CONF_FILE
# Exports: CONTAINERS_STORAGE_CONF
_podman_storage_shared_setup() {
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]] || [[ ! -d "$XDG_RUNTIME_DIR" ]]; then
        export XDG_RUNTIME_DIR="/tmp/podman-run-$(id -u)"
        mkdir -p "$XDG_RUNTIME_DIR"
        chmod 700 "$XDG_RUNTIME_DIR"
    fi

    PODMAN_STORAGE_ROOT="${PODMAN_STORAGE_ROOT:-/scratch/$(id -un)/podman-storage}"
    PODMAN_RUN_ROOT="${PODMAN_RUN_ROOT:-/tmp/podman-run-$(id -u)/run}"
    mkdir -p "$PODMAN_STORAGE_ROOT" "$PODMAN_RUN_ROOT"

    PODMAN_STORAGE_CONF_FILE="$(mktemp /tmp/podman-storage-XXXXXX.conf)"
    cat > "$PODMAN_STORAGE_CONF_FILE" <<EOF
[storage]
driver = "overlay"
graphRoot = "$PODMAN_STORAGE_ROOT"
runRoot  = "$PODMAN_RUN_ROOT"

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
ignore_chown_errors = "true"
EOF
    export CONTAINERS_STORAGE_CONF="$PODMAN_STORAGE_CONF_FILE"

    podman system migrate 2>/dev/null || true
    podman info >/dev/null 2>&1 || podman system reset -f
}

# podman_storage_setup -- for callers (build.sh) that only need the shared
# store above, no per-job isolation (a build only needs to land in the
# durable shared cache; it isn't a concurrency-hot-path the way running
# containers is).
podman_storage_setup() {
    _podman_storage_shared_setup
}

# podman_storage_setup_job -- for callers (shell.sh) that actually run a
# container. Adds an ISOLATED --root/--runroot for THIS invocation, keyed
# by $LSB_JOBID -- without this, two concurrent Podman jobs from the same
# user landing on the same GPU node can corrupt each other's storage.
# --storage-opt additionalimagestore points the per-job store back at the
# shared graphRoot as a READ-ONLY layer source, so a second job on the SAME
# node reuses the already-pulled/built image instead of paying for it again.
#
# Sets: PODMAN_GLOBAL_ARGS (array; prefix `podman build`/`podman run` with
#       this to use the per-job isolated store), PODMAN_JOB_STORAGE_DIR (the
#       dir podman_storage_cleanup removes).
podman_storage_setup_job() {
    _podman_storage_shared_setup

    local jobtag="${LSB_JOBID:-$$-$RANDOM}"
    PODMAN_JOB_STORAGE_DIR="/scratch/$(id -un)/podman-jobs/$jobtag"
    mkdir -p "$PODMAN_JOB_STORAGE_DIR/root" "$PODMAN_JOB_STORAGE_DIR/run"
    PODMAN_GLOBAL_ARGS=(
        --root "$PODMAN_JOB_STORAGE_DIR/root"
        --runroot "$PODMAN_JOB_STORAGE_DIR/run"
        --storage-opt "overlay.mount_program=/usr/bin/fuse-overlayfs"
        --storage-opt "overlay.ignore_chown_errors=true"
        --storage-opt "additionalimagestore=$PODMAN_STORAGE_ROOT"
    )
}

# podman_storage_cleanup -- retry-loop removal of a per-job storage dir.
#
# Uses `podman unshare rm -rf`, not a plain `rm -rf` -- without a requested
# /etc/subuid/subgid range (the default on this cluster), overlay diff-layer
# files land owned by a fake UID inside Podman's own single-mapping user
# namespace that only `podman unshare` can remove; a real user's plain
# `rm -rf` hits "Permission denied" on every file, every time.
#
# Retries for up to 30s in case the overlay unmount for a just-removed
# (--rm) container isn't finished the instant `podman run` returns. Leaving
# it (logged, not fatal) is cheap: only lock/metadata files, no image data
# (that lives in the shared additionalimagestore), and /scratch cleans
# itself up on its own cycle regardless.
podman_storage_cleanup() {
    local dir="${1:-${PODMAN_JOB_STORAGE_DIR:-}}"
    [[ -z "$dir" ]] && return 0
    for _ in $(seq 1 30); do
        podman unshare rm -rf "$dir" 2>/dev/null && break
        sleep 1
    done
    [[ -e "$dir" ]] && echo "note: couldn't clean up $dir (still busy after 30s) -- safe to remove later" >&2

    # Stop rootless Podman's pause process (`catatonit -P`, the long-lived
    # namespace keeper Podman daemonizes to PID 1 on this user's first
    # rootless invocation and never stops on its own). Inside an LSF job
    # this is not just cosmetic: LSF only marks a job finished once every
    # process it spawned is gone, and the pause process -- born inside the
    # job -- otherwise keeps the "finished" job in RUN forever.
    # `podman system migrate` is the sanctioned way to stop it (same call
    # _podman_storage_shared_setup already makes at startup). Safe with
    # respect to concurrent jobs on the same node: a running container
    # keeps its namespaces alive via its own processes, and the next
    # podman invocation just re-creates the pause process on demand.
    podman system migrate 2>/dev/null || true
    return 0
}

# _podman_resolve_catatonit_pid -- resolve the exact host PID of a
# container's own init process (catatonit) via `podman inspect --format
# '{{.State.Pid}}'`, given its --cidfile. Polls briefly since the cidfile
# only appears once the container has actually started.
#
# Echoes the PID on success, nothing on failure/timeout -- callers treat
# that as "can't track this one, skip cleanup" rather than a hard error.
_podman_resolve_catatonit_pid() {
    local cidfile="$1" cid pid
    for _ in $(seq 1 30); do
        [[ -s "$cidfile" ]] && break
        sleep 1
    done
    [[ -s "$cidfile" ]] || return 0
    cid="$(cat "$cidfile" 2>/dev/null)"
    [[ -z "$cid" ]] && return 0
    pid="$(podman "${PODMAN_GLOBAL_ARGS[@]}" inspect --format '{{.State.Pid}}' "$cid" 2>/dev/null)"
    [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$pid" != "0" ]] && echo "$pid"
}

# _podman_kill_if_orphaned_catatonit -- kill the given PID (resolved once,
# up front) only if it's both still alive and actually orphaned (reparented
# to PID 1). catatonit occasionally isn't reaped by Podman's own monitor
# before being reparented, which then blocks `podman run` itself from ever
# returning -- hanging the LSF job.
#
# NOTE this only covers the CONTAINER-INIT catatonit. Rootless Podman also
# runs a second, unrelated catatonit as its long-lived pause process
# (`catatonit -P`, PPID 1 by design, never exits on its own) -- that one is
# NOT an orphan to be reaped here; it's handled at job teardown by
# podman_storage_cleanup's `podman system migrate`.
_podman_kill_if_orphaned_catatonit() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    kill -0 "$pid" 2>/dev/null || return 0
    [[ "$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" == "1" ]] || return 0
    kill -9 "$pid" 2>/dev/null
    return 0
}

# podman_run_watched -- run `podman run` (prefixed with PODMAN_GLOBAL_ARGS)
# in the background with a concurrent catatonit watchdog, then wait and
# return its real exit code.
#
# Usage: podman_run_watched ARGS_ARRAY_NAME
#   ARGS_ARRAY_NAME names an array variable holding the full argument list
#   for `podman run` (everything after "run" itself).
#
# Requires the caller to have already run `exec 3<&0` at the very top of its
# own script (before any other redirection/backgrounding) -- bash silently
# redirects a backgrounded job's stdin from /dev/null otherwise, which would
# break piped input and interactive sessions alike.
#
# Returns the real exit code of `podman run` (does not exit the shell --
# caller does `podman_run_watched ARGS_VAR; exit $?`).
podman_run_watched() {
    local -n _args_ref="$1"
    local cid_dir cidfile
    cid_dir="$(mktemp -d /tmp/podman-cid-XXXXXX)"
    cidfile="$cid_dir/cid"

    podman "${PODMAN_GLOBAL_ARGS[@]}" run --cidfile "$cidfile" "${_args_ref[@]}" <&3 &
    local podman_pid=$!

    # Forward INT/TERM to the actual `podman run` process. Callers of this
    # function (shell.sh) are themselves often launched backgrounded by a
    # wrapper (terminal-wrap.sh's cleanup trap signals shell.sh's PID, not
    # this function's podman child) -- without this, killing the wrapper
    # leaves podman/ttyd/the container running as an orphan forever, which
    # is exactly the "LSF job stuck in RUN state" failure mode this
    # project's cleanup path exists to prevent.
    trap 'kill -TERM "$podman_pid" 2>/dev/null || true' INT TERM

    local catatonit_pid
    catatonit_pid="$(_podman_resolve_catatonit_pid "$cidfile")"

    (
        while kill -0 "$podman_pid" 2>/dev/null; do
            _podman_kill_if_orphaned_catatonit "$catatonit_pid"
            sleep 2
        done
    ) &
    local watchdog_pid=$!

    local exit_code=0
    # A caught INT/TERM interrupts `wait` early (128+signum) before podman
    # has actually finished exiting -- loop until it's truly gone so the
    # caller's post-return cleanup (storage removal) doesn't race with
    # podman's own in-flight `--rm` teardown.
    while kill -0 "$podman_pid" 2>/dev/null; do
        wait "$podman_pid" 2>/dev/null && exit_code=0 || exit_code=$?
    done
    trap - INT TERM
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null || true
    # One more check right after podman_pid itself has exited -- the race
    # where catatonit is orphaned right as/after `podman run` returns.
    _podman_kill_if_orphaned_catatonit "$catatonit_pid"
    rm -rf "$cid_dir"
    return "$exit_code"
}

# podman_resolve_image -- resolves $IMAGE to something runnable. Ported
# from marimo_ai_sandbox's lib.sh (same pattern, same rationale).
#
# Unless the caller explicitly set $IMAGE (env var or --image-style
# override), this checks the registry for updates on EVERY invocation via
# `podman pull` (cheap -- a manifest-digest check, not a re-download,
# unless the image actually changed) rather than only pulling if nothing
# is cached at all, which would otherwise silently reuse a local image
# cached from before a pixi.toml/Containerfile change forever, since
# nothing would ever re-validate it once it existed once. This also means
# a node's very first launch of this app doesn't pay for a multi-minute
# from-scratch build (apt-get, pixi install, mojo) when a fast registry
# pull would do -- ttyd/Caddy only wait ~30s for the backend, so a cold
# build can otherwise show up as several minutes of confusing 502s.
#
# Usage: podman_resolve_image REMOTE_IMAGE LOCAL_IMAGE IMAGE_WAS_EXPLICIT
#   REMOTE_IMAGE       the ghcr.io reference to check/pull
#   LOCAL_IMAGE        the local-build fallback tag
#   IMAGE_WAS_EXPLICIT "1" if the caller's $IMAGE was set by the user
#                      (env var override) rather than defaulted -- skips
#                      the registry entirely in that case, building only
#                      if that exact image is missing (the existing
#                      "IMAGE=janelia-mojo-sandbox:latest ...to skip the
#                      registry" escape hatch, preserved as-is)
#
# Calls the caller's `_set_phase` if defined (shell.sh, terminal-wrap.sh,
# terminal-http.sh all define one) to report "pulling_image" the same way
# their other phases are reported.
#
# Sets: RESOLVED_IMAGE -- the image reference the caller should actually run
podman_resolve_image() {
    local remote="$1" local_image="$2" explicit="$3"
    RESOLVED_IMAGE="$remote"

    if [[ "$explicit" == "1" ]]; then
        podman image exists "$RESOLVED_IMAGE" &>/dev/null || bash "$(dirname "${BASH_SOURCE[0]}")/build.sh"
        return 0
    fi

    echo ">> Checking '$RESOLVED_IMAGE' for updates ..."
    declare -F _set_phase &>/dev/null && _set_phase pulling_image
    if ! podman pull "$RESOLVED_IMAGE"; then
        if podman image exists "$RESOLVED_IMAGE" &>/dev/null; then
            echo ">> Pull failed (offline/registry unreachable?) -- reusing existing cached '$RESOLVED_IMAGE'." >&2
        else
            echo ">> Pull failed and no local copy exists -- building '$local_image' from source instead ..." >&2
            RESOLVED_IMAGE="$local_image"
            podman image exists "$RESOLVED_IMAGE" &>/dev/null || bash "$(dirname "${BASH_SOURCE[0]}")/build.sh"
        fi
    fi
}
