#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"
VERSION="${VERSION:-0.0.0-test}"

cleanup() {
    docker run --rm -v "$WORK_DIR":/w alpine:3 sh -c 'rm -rf /w/..?* /w/.[!.]* /w/*' >/dev/null 2>&1
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; NC=""
fi

PASSED=0
FAILED=0
FAILURES=()

property() {
    local description=$1; shift
    # PROPERTY_FILTER runs one line instead of all of them: the discrimination
    # harness breaks one thing at a time.
    [[ -n "${PROPERTY_FILTER:-}" && "$description" != *"$PROPERTY_FILTER"* ]] && return 0
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

build_the_package() {
    docker run --rm -v "$REPO_ROOT":/src:ro -v "$WORK_DIR":/out -w /src debian:12-slim \
        sh -c "OUT_DIR=/out ./packaging/build-deb.sh '$VERSION'" >/dev/null
}

# The installer talks to a Docker daemon and to nvidia-smi. Handing it the real
# ones would have it log into a registry and create volumes on whatever machine
# runs this; stubs answer the handful of questions it asks, and are what lets a
# starting state be set up at all — "a mongo volume is already there" is a
# sentence only a stub can say.
write_machine_stubs() {
    cat > "$WORK_DIR/stubs.sh" <<'STUBS'
mkdir -p /stub
cat > /stub/docker <<'DOCKER'
#!/bin/sh
printf '%s\n' "$*" >> /stub/docker-calls
case "$1 $2" in
    "version --format")   echo "29.0.0" ;;
    "compose version")    echo "v5.0.0" ;;
    "info --format")      echo '{"nvidia":{}}' ;;
    "volume inspect")     [ "${MONGO_VOLUME_EXISTS:-no}" = yes ] ;;
    "network inspect")    exit 1 ;;
    "network create")     exit "${NETWORK_CREATE_EXIT:-0}" ;;
    "compose pull")       exit "${PULL_EXIT:-0}" ;;
    *)                    exit 0 ;;
esac
DOCKER
cat > /stub/nvidia-smi <<'NVIDIA'
#!/bin/sh
case "$1" in
    -L) echo "GPU 0: NVIDIA GB10 (UUID: GPU-test)" ;;
    *)  echo "NVIDIA GB10" ;;
esac
NVIDIA
chmod +x /stub/docker /stub/nvidia-smi
mkdir -p /etc/cdi && : > /etc/cdi/nvidia.yaml
: > /stub/docker-calls
export PATH=/stub:$PATH
STUBS
}

# Each case is a machine in a known state. The installer is run to the point
# where it would pull images, which is as far as this can go: the images are
# private and weigh tens of gigabytes. Everything that has ever broken here
# broke before that line.
run_install_from_state() {
    local state=$1 domain=${2:-box.example.test}
    local probe="$WORK_DIR/$state"
    mkdir -p "$probe"

    cat > "$WORK_DIR/walk-$state.sh" <<PROBE
set -u
. /w/stubs.sh
dpkg -i --force-depends /out/understandtech_${VERSION}_all.deb >/dev/null 2>&1

$(state_setup "$state")

UT_REGISTRY_TOKEN=test-token PULL_EXIT=9 \\
    ut-install --domain $domain > /w/$state/output.txt 2>&1
printf 'EXIT=%s\n' "\$?" >> /w/$state/output.txt

cp /etc/understandtech/.env /w/$state/env 2>/dev/null || : > /w/$state/env
chmod -R a+rw /w/$state
PROBE

    docker run --rm \
        -v "$WORK_DIR":/w -v "$WORK_DIR":/out \
        -e MONGO_VOLUME_EXISTS="${MONGO_VOLUME_EXISTS:-no}" \
        -e NETWORK_CREATE_EXIT="${NETWORK_CREATE_EXIT:-0}" \
        debian:12-slim bash /w/walk-$state.sh >/dev/null 2>&1
}

state_setup() {
    case "$1" in
        bare)          echo ': # nothing beyond the package' ;;
        empty_settings) echo 'install -m 600 /dev/null /etc/understandtech/.env' ;;
        already_set)   echo 'install -m 600 /usr/share/understandtech/.env.example /etc/understandtech/.env' ;;
        no_settings_dir) echo 'rm -rf /etc/understandtech' ;;
        pools_full)    echo ': # the daemon refuses through the stub' ;;
        orphan_volume) echo ': # the volume is asserted through the stub' ;;
        *)             echo ': ' ;;
    esac
}

output_of()   { cat "$WORK_DIR/$1/output.txt" 2>/dev/null; }
settings_of() { cat "$WORK_DIR/$1/env" 2>/dev/null; }

reached_the_pull() {
    local state=$1
    grep -q 'Downloading images' <<< "$(output_of "$state")" && return 0
    echo "$(output_of "$state")"
    return 1
}

setting_is_filled() {
    local state=$1 key=$2 value
    value=$(grep -m1 "^${key}=" <<< "$(settings_of "$state")" | cut -d= -f2- | tr -d '"')
    [[ -n "$value" ]] && return 0
    echo "${key} is empty or absent in the settings written from state '${state}'"
    return 1
}

every_required_setting_is_filled() {
    local state=$1 key missing=()
    while read -r key; do
        [[ -n "$key" ]] || continue
        setting_is_filled "$state" "$key" >/dev/null || missing+=("$key")
    done <<< "$(grep -ohE '\$\{[A-Z_][A-Z0-9_]*:\?' "$REPO_ROOT"/compose*.yaml \
        | sed 's/^\${//; s/:?$//' | sort -u)"
    (( ${#missing[@]} == 0 )) && return 0
    echo "nothing filled these in: ${missing[*]}"
    echo "$(output_of "$state")"
    return 1
}

the_settings_render_a_stack() {
    local state=$1 render
    render="$WORK_DIR/render-$state"
    mkdir -p "$render"
    cp "$REPO_ROOT"/compose*.yaml "$render/"
    settings_of "$state" > "$render/.env"
    ( cd "$render" && docker compose config >/dev/null 2>"$WORK_DIR/render-err.txt" ) && return 0
    head -3 "$WORK_DIR/render-err.txt"
    return 1
}

secrets_are_not_the_shipped_ones() {
    local state=$1 shipped
    shipped=$(grep -m1 '^JWT_SECRET=' "$REPO_ROOT/.env.example" | cut -d= -f2- | tr -d '"')
    local mine
    mine=$(grep -m1 '^JWT_SECRET=' <<< "$(settings_of "$state")" | cut -d= -f2- | tr -d '"')
    [[ -n "$mine" && "$mine" != "$shipped" ]] && return 0
    echo "JWT_SECRET is '${mine}', the template ships '${shipped}'"
    return 1
}

two_installs_do_not_share_a_secret() {
    local a b
    a=$(grep -m1 '^JWT_SECRET=' <<< "$(settings_of bare)" | cut -d= -f2-)
    b=$(grep -m1 '^JWT_SECRET=' <<< "$(settings_of empty_settings)" | cut -d= -f2-)
    [[ -n "$a" && "$a" != "$b" ]] && return 0
    echo "two separate installs produced the same JWT_SECRET"
    return 1
}

running_it_again_changes_nothing() {
    local before after
    before=$(settings_of already_set | grep -c .)
    run_install_from_state already_set >/dev/null 2>&1
    after=$(settings_of already_set | grep -c .)
    [[ "$before" == "$after" ]] && return 0
    echo "the settings went from ${before} lines to ${after} on a second run"
    return 1
}

the_preflight_stops_on_full_pools() {
    local output
    output=$(output_of pools_full)
    grep -q 'address pools are full' <<< "$output" \
        && grep -q 'docker network prune' <<< "$output" \
        && ! grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

an_orphan_volume_stops_the_install() {
    local output
    output=$(output_of orphan_volume)
    grep -q 'holds no password for it' <<< "$output" \
        && grep -q 'docker volume rm' <<< "$output" && return 0
    echo "$output"
    return 1
}

printf '%sWalking a fresh install%s %s(the installer, from a machine in a known state)%s\n\n' \
    "$BOLD" "$NC" "$DIM" "$NC"

build_the_package
write_machine_stubs

run_install_from_state bare
run_install_from_state empty_settings
run_install_from_state already_set
run_install_from_state no_settings_dir
MONGO_VOLUME_EXISTS=yes run_install_from_state orphan_volume
NETWORK_CREATE_EXIT=1 run_install_from_state pools_full

printf '%sA machine with nothing on it%s\n' "$BOLD" "$NC"
property "the install reaches the point where it pulls images" \
    reached_the_pull bare
property "every variable the stack requires has a value" \
    every_required_setting_is_filled bare
property "what it wrote renders a stack" \
    the_settings_render_a_stack bare
property "the secrets are not the ones the template ships" \
    secrets_are_not_the_shipped_ones bare

printf '\n%sA settings file that exists but says nothing%s\n' "$BOLD" "$NC"
property "it is filled rather than kept" \
    every_required_setting_is_filled empty_settings
property "and the result still renders" \
    the_settings_render_a_stack empty_settings

printf '\n%sA machine where the settings directory is gone%s\n' "$BOLD" "$NC"
property "it is recreated rather than reported as a broken link" \
    reached_the_pull no_settings_dir

printf '\n%sTwo machines are not the same machine%s\n' "$BOLD" "$NC"
property "two installs do not share a secret" \
    two_installs_do_not_share_a_secret

printf '\n%sA machine already configured%s\n' "$BOLD" "$NC"
property "running the installer again changes nothing" \
    running_it_again_changes_nothing

printf '\n%sA machine whose Docker address pools are full%s\n' "$BOLD" "$NC"
property "the preflight stops before anything is written" \
    the_preflight_stops_on_full_pools

printf '\n%sA database nobody has the password for%s\n' "$BOLD" "$NC"
property "the install stops, and says which volume and what to do" \
    an_orphan_volume_stops_the_install

printf '\n%s%d verified%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d failing%s\n' "$RED" "$FAILED" "$NC"
    printf '\nNot working:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
