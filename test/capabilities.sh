#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"

trap 'rm -rf "$WORK_DIR"' EXIT

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; NC=""
fi

PASSED=0
FAILED=0
FAILURES=()

group() { printf '\n%s%s%s\n' "$BOLD" "$1" "$NC"; }

capability() {
    local description=$1; shift
    local output
    if output=$("$@" 2>&1); then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        printf '%s      %s%s\n' "$DIM" "${output//$'\n'/$'\n'      }" "$NC"
        FAILED=$((FAILED + 1))
        FAILURES+=("$description")
    fi
}

# A .env with only what compose needs to render: image references and replica
# counts. Everything else is left to its default, which is the point — these
# checks exercise what an untouched install produces.
prepare_env() {
    cp "$REPO_ROOT"/compose*.yaml "$WORK_DIR/"
    {
        echo 'WORKER_REPLICAS=2'
        echo 'WORKER_CUSTOMER_REPLICAS=2'
        echo 'BACKUP_FILES_PASSWORD=capability-test'
        grep -ohE '\$\{[A-Z_]+_IMAGE' "$REPO_ROOT"/compose*.yaml | tr -d '${' | sort -u | sed 's/$/=test:1/'
    } > "$WORK_DIR/.env"
}

compose_services() {
    ( cd "$WORK_DIR" && COMPOSE_PROFILES="${PROFILES:-}" docker compose "$@" config --services 2>/dev/null | sort )
}

compose_config() {
    ( cd "$WORK_DIR" && docker compose "$@" config 2>/dev/null )
}

lists_service() {
    local service=$1; shift
    compose_services "$@" | grep -qx "$service"
}

# The compute role needs COMPOSE_PROFILES on top of COMPOSE_FILE: leaving it out
# starts nothing at all, since the inference engines are the only services the
# overlay keeps and they sit behind their profile.
with_profiles() {
    local profiles=$1; shift
    PROFILES="$profiles" "$@"
}

omits_service() {
    local service=$1; shift
    ! compose_services "$@" | grep -qx "$service"
}

requests_no_gpu() {
    ! compose_config "$@" | grep -q 'driver: nvidia'
}

renders_valid_configuration() {
    ( cd "$WORK_DIR" && docker compose "$@" config >/dev/null )
}

names_are_unchanged_by_default() {
    local rendered
    rendered=$(compose_config -f compose.yaml)
    grep -q 'container_name: ut-caddy' <<< "$rendered" \
        && grep -q 'name: ut-mongodb-data' <<< "$rendered" \
        && grep -q 'name: ut-backend-network' <<< "$rendered" \
        && grep -q '/var/lib/understandtech' <<< "$rendered"
}

overrides_isolate_every_resource() {
    local rendered
    rendered=$( cd "$WORK_DIR" && \
        COMPOSE_PROJECT_NAME=isolated RESOURCE_PREFIX=isolated CONTAINER_PREFIX=isolated \
        DATA_ROOT=/var/lib/isolated MONGODB_HOST_PORT=27118 \
        docker compose -f compose.yaml config 2>/dev/null )
    ! grep -qE 'name: ut-mongodb-data|name: ut-backend-network|/var/lib/understandtech' <<< "$rendered"
}

files_are_backed_up_and_restore_identically() {
    local repo="$WORK_DIR/repo" src="$WORK_DIR/src" out="$WORK_DIR/out"
    mkdir -p "$src/app-data" "$src/appbuilder/workspaces/an-app/mongo-data" "$out"
    head -c 200000 /dev/urandom > "$src/app-data/document.bin"
    echo "metadata" > "$src/app-data/notes.txt"
    echo "live database file" > "$src/appbuilder/workspaces/an-app/mongo-data/wt.wt"

    docker run --rm -v "$src":/data:ro -v "$repo":/backup \
        -v "$REPO_ROOT/backup-files.sh":/usr/local/bin/backup-files:ro \
        -e RESTIC_REPOSITORY=/backup/restic -e RESTIC_PASSWORD=capability-test \
        --entrypoint /usr/local/bin/backup-files "$RESTIC_IMAGE" >/dev/null 2>&1 || return 1

    docker run --rm -v "$repo":/backup -v "$out":/out \
        -e RESTIC_REPOSITORY=/backup/restic -e RESTIC_PASSWORD=capability-test \
        "$RESTIC_IMAGE" restore latest --target /out >/dev/null 2>&1 || return 1

    diff -r "$src/app-data" "$out/data/app-data" >/dev/null || return 1

    # The exclusion is part of the capability, not an implementation detail: a
    # database file copied while it is written restores into a corrupt state, so
    # its absence is what the check asserts.
    [[ ! -e "$out/data/appbuilder/workspaces/an-app/mongo-data" ]]
}

a_missing_backup_is_visible() {
    local dir="$WORK_DIR/hc" status
    mkdir -p "$dir"
    docker rm -f ut-capability-hc >/dev/null 2>&1
    docker run -d --name ut-capability-hc -v "$dir":/backup \
        --health-cmd "find /backup -name 'mongo_*.archive.gz' -mtime -2 | grep -q ." \
        --health-interval 3s --health-retries 2 --health-start-period 1s \
        alpine sleep 120 >/dev/null 2>&1 || return 1

    sleep 14
    status=$(docker inspect ut-capability-hc --format '{{.State.Health.Status}}')
    [[ "$status" == "unhealthy" ]] || { docker rm -f ut-capability-hc >/dev/null 2>&1; return 1; }

    touch "$dir/mongo__fresh.archive.gz"
    sleep 12
    status=$(docker inspect ut-capability-hc --format '{{.State.Health.Status}}')
    docker rm -f ut-capability-hc >/dev/null 2>&1
    [[ "$status" == "healthy" ]]
}

prepare_env

group "Deployment topologies"
capability "the default role renders a valid stack" \
    renders_valid_configuration -f compose.yaml
capability "the App Builder overlay renders on top of it" \
    renders_valid_configuration -f compose.yaml -f compose.appbuilder.yaml
capability "the control-plane role leaves out the inference engines" \
    omits_service nim-llm -f compose.yaml

group "Backward compatibility"
capability "an untouched install keeps its container, volume, network and data names" \
    names_are_unchanged_by_default

if [[ -f "$REPO_ROOT/compose.compute.yaml" ]]; then
    group "Multi-machine roles"
    capability "a compute node serves inference" \
        with_profiles nim lists_service nim-llm -f compose.yaml -f compose.compute.yaml
    capability "a compute node runs no database" \
        omits_service mongodb -f compose.yaml -f compose.compute.yaml
    capability "overriding the prefixes isolates every resource" \
        overrides_isolate_every_resource
fi

if [[ -f "$REPO_ROOT/compose.no-gpu.yaml" ]]; then
    capability "a machine without a GPU requests no NVIDIA device" \
        requests_no_gpu -f compose.yaml -f compose.no-gpu.yaml
fi

if [[ -f "$REPO_ROOT/backup-files.sh" ]]; then
    RESTIC_IMAGE=$(grep -m1 -oE 'restic/restic:[0-9.]+' "$REPO_ROOT/compose.yaml" || echo restic/restic:latest)
    group "Backup"
    capability "files are backed up and restore identically" \
        files_are_backed_up_and_restore_identically
    capability "a missing backup is visible, and recovers when one appears" \
        a_missing_backup_is_visible
fi

printf '\n%s%d verified%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d failing%s\n' "$RED" "$FAILED" "$NC"
    printf '\nNot working:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
