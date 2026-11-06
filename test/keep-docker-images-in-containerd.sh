#!/usr/bin/env bash
# The runner's Docker keeps its images where a box's does: a folder loads only
# into containerd's store, and Docker on a fresh runner may still be on overlay2.

set -euo pipefail

settings=/etc/docker/daemon.json
current='{}'
[[ -s "$settings" ]] && current=$(sudo cat "$settings")
sudo mkdir -p "$(dirname "$settings")"
jq '.features["containerd-snapshotter"] = true' <<< "$current" | sudo tee "$settings" >/dev/null
sudo systemctl restart docker
docker info --format '{{json .DriverStatus}}' | grep -q 'io.containerd.snapshotter' \
    || { echo "Docker did not move to containerd's store" >&2; exit 1; }
echo "Docker keeps its images in containerd's store"
