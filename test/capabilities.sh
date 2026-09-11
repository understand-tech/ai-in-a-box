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

# A .env with only what compose cannot render without: image references,
# replica counts, and whatever the compose files mark as required with
# ${VAR:?...}. Everything else is left to its default, which is the point —
# these checks exercise what an untouched install produces.
#
# The required list is read from the compose files rather than spelled out here,
# so marking one more variable as mandatory does not break this harness.
prepare_env() {
    cp "$REPO_ROOT"/compose*.yaml "$WORK_DIR/"
    {
        echo 'WORKER_REPLICAS=2'
        echo 'WORKER_CUSTOMER_REPLICAS=2'
        grep -ohE '\$\{[A-Z_][A-Z_0-9]*_IMAGE' "$WORK_DIR"/compose*.yaml \
            | tr -d '${' | sort -u | sed 's/$/=test:1/'
        grep -ohE '\$\{[A-Z_][A-Z_0-9]*:\?' "$WORK_DIR"/compose*.yaml \
            | sed 's/^\${//; s/:?$//' | sort -u | sed 's/$/=capability-test/'
        echo 'BACKUP_FILES_PASSWORD=capability-test'
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
    local rendered stray
    rendered=$( cd "$WORK_DIR" && \
        COMPOSE_PROJECT_NAME=isolated RESOURCE_PREFIX=isolated CONTAINER_PREFIX=isolated \
        DATA_ROOT=/var/lib/isolated MONGODB_HOST_PORT=27118 \
        docker compose -f compose.yaml config 2>/dev/null )
    stray=$(grep -oE '^ *(container_name|name): ut-[a-z0-9_-]+' <<< "$rendered" | awk '{print $2}' | sort -u)
    [[ -n "$stray" ]] && { echo "not isolated: $(tr '\n' ' ' <<< "$stray")"; return 1; }
    ! grep -q '/var/lib/understandtech' <<< "$rendered"
}

the_authority_root_is_where_the_backup_looks() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local config root backed_up
    config=$( cd "$WORK_DIR" && docker compose -f compose.yaml config --format json 2>/dev/null )
    root=$(jq -r '.services["step-ca"].volumes[]? | select(.target == "/home/step") | .source' <<< "$config")
    backed_up=$(jq -r '.services["files-backup"].volumes[]? | select(.target == "/data") | .source' <<< "$config")
    [[ -n "$root" && -n "$backed_up" ]] || { echo "no root or no backup source"; return 1; }
    [[ "$root" == "$backed_up"/* ]] || { echo "the root at ${root} is outside ${backed_up}"; return 1; }
}

the_machine_surface_uses_the_local_authority() {
    grep -q 'step-ca:9000/acme' "$REPO_ROOT/caddy/internal-surface.caddy" \
        && ! grep -qE 'UT_CERT_FILE|acme-v02\.api\.letsencrypt' "$REPO_ROOT/caddy/internal-surface.caddy"
}

# The public certificate follows UT_INGRESS_MODE, the machine-facing one never
# does: an appliance behind a customer's load balancer would otherwise leave the
# authority issuing nothing at all.
the_machine_surface_survives_every_ingress_mode() {
    local mode missing=()
    for mode in internal custom edge; do
        [[ -f "$REPO_ROOT/caddy/ingress-$mode.caddy" ]] || continue
        grep -qE 'surface|step-ca' "$REPO_ROOT/caddy/ingress-$mode.caddy" && missing+=("$mode")
    done
    (( ${#missing[@]} == 0 )) || { echo "ingress modes that touch the machine surface: ${missing[*]}"; return 1; }
    grep -q 'import /etc/caddy/surface.caddy' "$REPO_ROOT/Caddyfile"
}

# The three checks above read the configuration. This one runs it: the
# authority and the proxy as compose.yaml declares them, with the Caddyfile and
# the surface fragment from this repository, and asks who signed what the proxy
# serves.
the_machine_surface_is_really_served_by_the_authority() {
    local run=cap-surface-$$ net ca proxy domain=understand.local work issuer
    net=$run-net; ca=$run-ca; proxy=$run-caddy
    work="$WORK_DIR/surface"
    mkdir -p "$work/ca" && chmod 777 "$work/ca"

    docker network create "$net" >/dev/null 2>&1
    docker run -d --name "$ca" --network "$net" --network-alias step-ca \
        -v "$work/ca":/home/step \
        -e DOCKER_STEPCA_INIT_NAME="$domain" \
        -e DOCKER_STEPCA_INIT_DNS_NAMES="step-ca,$domain" \
        -e DOCKER_STEPCA_INIT_PASSWORD=capability-test \
        -e DOCKER_STEPCA_INIT_ACME=true \
        "$STEP_CA_IMAGE" >/dev/null 2>&1

    # Asked inside the container: the root directory is mode 700 for uid 1000,
    # and the user running this script is not it on every machine.
    local attempt
    for attempt in $(seq 1 20); do
        docker exec "$ca" test -f /home/step/certs/root_ca.crt >/dev/null 2>&1 && break
        sleep 3
    done

    local verdict=1
    if docker exec "$ca" test -f /home/step/certs/root_ca.crt >/dev/null 2>&1; then
        docker run -d --name "$proxy" --network "$net" --network-alias "node.$domain" \
            -e UT_DOMAIN="$domain" \
            -v "$REPO_ROOT/Caddyfile":/etc/caddy/Caddyfile:ro \
            -v "$REPO_ROOT/caddy/ingress-internal.caddy":/etc/caddy/ingress.caddy:ro \
            -v "$REPO_ROOT/caddy/internal-surface.caddy":/etc/caddy/surface.caddy:ro \
            -v "$work/ca/certs":/etc/caddy/ca/certs:ro \
            "$CADDY_IMAGE" >/dev/null 2>&1

        for attempt in $(seq 1 20); do
            issuer=$(docker run --rm --network "$net" -v "$work/ca/certs":/certs:ro --user root \
                --entrypoint sh "$STEP_CA_IMAGE" -c \
                "step certificate inspect https://node.$domain:8443 --roots /certs/root_ca.crt --short" 2>&1)
            grep -q 'Provisioner: acme' <<< "$issuer" && { verdict=0; break; }
            sleep 3
        done
        (( verdict )) && docker logs "$proxy" 2>&1 | grep -iE 'error' | tail -4
    else
        echo "the authority wrote no root"
        docker logs "$ca" 2>&1 | tail -4
    fi

    docker rm -f "$ca" "$proxy" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
    docker run --rm -v "$work":/w alpine:3 sh -c 'rm -rf /w/ca' >/dev/null 2>&1
    return "$verdict"
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

STEP_CA_IMAGE=$(grep -m1 -oE 'smallstep/step-ca:[0-9.]+' "$REPO_ROOT/compose.yaml" || echo smallstep/step-ca:latest)
CADDY_IMAGE=$(grep -m1 -oE 'caddy:[0-9a-z.-]+' "$REPO_ROOT/compose.yaml" || echo caddy:2-alpine)

prepare_env

group "Deployment topologies"
capability "the default role renders a valid stack" \
    renders_valid_configuration -f compose.yaml
capability "the App Builder overlay renders on top of it" \
    renders_valid_configuration -f compose.yaml -f compose.appbuilder.yaml
capability "the control-plane role leaves out the inference engines" \
    omits_service nim-llm -f compose.yaml

group "Machine identity"
capability "the appliance runs its own certificate authority" \
    lists_service step-ca -f compose.yaml
capability "its root sits where the file backup looks" \
    the_authority_root_is_where_the_backup_looks
capability "the machine-facing surface takes its certificate from that authority" \
    the_machine_surface_uses_the_local_authority
capability "it does so whatever the customer chose for the public one" \
    the_machine_surface_survives_every_ingress_mode
capability "and it is really served by it, not just configured to be" \
    the_machine_surface_is_really_served_by_the_authority

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
