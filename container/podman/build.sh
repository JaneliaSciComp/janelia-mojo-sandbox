#!/usr/bin/env bash
#
# build.sh -- build the Janelia Mojo Sandbox Podman image.
#
# Usage:
#   ./build.sh                  # builds janelia-mojo-sandbox:latest from Containerfile
#   IMAGE=foo:latest ./build.sh # custom image tag
#
set -euo pipefail

cd "$(dirname "$0")"

IMAGE="${IMAGE:-janelia-mojo-sandbox:latest}"
FILE="${FILE:-Containerfile}"

if [[ ! -f ../../pixi.lock ]]; then
    echo "pixi.lock not found -- run 'pixi install' at the repo root first." >&2
    exit 1
fi

# shellcheck source=lib.sh
source "./lib.sh"

# Redirects storage off NFS, reconciles staleness after a node reboot -- see
# lib.sh's podman_storage_setup. A build only needs the shared, durable
# store (no per-job isolation -- that's for concurrent `podman run`s, see
# shell.sh).
podman_storage_setup
trap 'rm -f "$PODMAN_STORAGE_CONF_FILE" 2>/dev/null; true' EXIT
echo ">> Using local Podman storage at ${PODMAN_STORAGE_ROOT}"

echo ">> Building Podman image ${IMAGE} from ${FILE} ..."
# --cgroup-manager=cgroupfs: no systemd user session on Janelia HPC compute nodes
# --events-backend=file:    no dbus session available
podman build \
    --cgroup-manager=cgroupfs \
    --events-backend=file \
    -t "${IMAGE}" -f "${FILE}" ../..

echo ">> Done. Image: ${IMAGE}"
echo ">> Run it with:  pixi run shell"
