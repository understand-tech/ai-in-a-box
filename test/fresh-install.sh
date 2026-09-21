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

# The installer talks to a Docker daemon, to nvidia-smi and to df. Handing it the
# real ones would have it log into a registry and create volumes on whatever
# machine runs this; stubs answer the handful of questions it asks, and are what
# lets a starting state be set up at all — "a mongo volume is already there" is a
# sentence only a stub can say.
#
# df is stubbed for a second reason: the preflight needs 250 GB and a GitHub
# runner offers 91, so left alone this suite passes or fails on the disk of
# whoever runs it rather than on the installer. It was green here on 378 GB and
# red in CI on the same commit.
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
cat > /stub/df <<'DF'
#!/bin/sh
echo "Avail"
echo "${DISK_AVAIL_BYTES:-$((400 * 1000 * 1000 * 1000))}"
DF
chmod +x /stub/docker /stub/nvidia-smi /stub/df
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
    local state=$1 domain=${2:-box.example.test} domain_arg
    local probe="$WORK_DIR/$state"
    mkdir -p "$probe"

    # "-" leaves --domain off, which is the only way to see what the installer
    # decides on its own rather than what the caller told it.
    domain_arg="--domain $domain"
    [[ "$domain" == "-" ]] && domain_arg=""

    cat > "$WORK_DIR/walk-$state.sh" <<PROBE
set -u
. /w/stubs.sh
dpkg -i --force-depends /out/understandtech_${VERSION}_all.deb >/dev/null 2>&1

$(state_setup "$state")

UT_REGISTRY_TOKEN=${INSTALL_TOKEN-test-token} \\
    ${INSTALL_COMMAND:-ut-install} $domain_arg > /w/$state/output.txt 2>&1
printf 'EXIT=%s\n' "\$?" >> /w/$state/output.txt

cp /etc/understandtech/.env /w/$state/env 2>/dev/null || : > /w/$state/env
cp /opt/understandtech/.env /w/$state/checkout-env 2>/dev/null || : > /w/$state/checkout-env
chmod -R a+rw /w/$state
PROBE

    docker run --rm \
        -v "$WORK_DIR":/w -v "$WORK_DIR":/out \
        -e MONGO_VOLUME_EXISTS="${MONGO_VOLUME_EXISTS:-no}" \
        -e NETWORK_CREATE_EXIT="${NETWORK_CREATE_EXIT:-0}" \
        -e PULL_EXIT="${PULL_EXIT:-9}" \
        -e DISK_AVAIL_BYTES="${DISK_AVAIL_BYTES:-}" \
        debian:12-slim bash /w/walk-$state.sh >/dev/null 2>&1
}

state_setup() {
    case "$1" in
        bare)          echo ': # nothing beyond the package' ;;
        install_runs_through) echo ': # like bare, but the pull is allowed to succeed' ;;
        # A checkout of the repository, the way an operator who cloned it has one.
        # The package is installed too, which is what makes the choice interesting.
        launched_from_a_checkout|checkout_but_no_key)
            echo 'install -d /srv/clone && cp -a /usr/share/understandtech/. /srv/clone/ && install -d /srv/clone/.git && cp /usr/bin/ut-install /srv/clone/ut-install' ;;
        empty_settings) echo 'install -m 600 /dev/null /etc/understandtech/.env' ;;
        already_set)   echo 'install -m 600 /usr/share/understandtech/release.env /etc/understandtech/.env' ;;
        no_settings_dir) echo 'rm -rf /etc/understandtech' ;;
        pools_full)    echo ': # the daemon refuses through the stub' ;;
        disk_too_small) echo ': # the free space is answered through the stub' ;;
        orphan_volume) echo ': # the volume is asserted through the stub' ;;
        volume_with_shipped_password)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'MONGODB_USERNAME="mongoadmin"\nMONGODB_PASSWORD="12345678"\n'"'"' > /etc/understandtech/local.env' ;;
        previous_checkout)
            echo 'install -d /opt/understandtech && printf '"'"'UT_DOMAIN="carried.example"\nJWT_SECRET="keptfromthecheckout0123456789abcdef0123456789ab"\nLOG_LEVEL="WARNING"\n'"'"' > /opt/understandtech/.env' ;;
        checkout_without_domain)
            echo 'install -d /opt/understandtech && printf '"'"'PUBLIC_BASE_URL="https://named.by.the.urls"\nBACKEND_URL="https://named.by.the.urls/api"\nJWT_SECRET="keptfromthecheckout0123456789abcdef0123456789ab"\n'"'"' > /opt/understandtech/.env' ;;
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

checkout_of() { cat "$WORK_DIR/$1/checkout-env" 2>/dev/null; }

the_checkout_settings_are_carried_over() {
    local settings
    settings=$(settings_of previous_checkout)
    grep -q 'keptfromthecheckout' <<< "$settings" \
        || { echo "the secret was regenerated instead of carried over"; return 1; }
    grep -q '^LOG_LEVEL="WARNING"' <<< "$settings" \
        || { echo "a setting the customer had changed was lost"; return 1; }
    return 0
}

the_address_comes_from_the_checkout() {
    local settings
    settings=$(settings_of previous_checkout)
    grep -q '^UT_DOMAIN="carried.example"' <<< "$settings" && return 0
    echo "the address became $(grep -m1 '^UT_DOMAIN=' <<< "$settings")"
    return 1
}

the_address_is_read_from_the_urls() {
    local settings
    settings=$(settings_of checkout_without_domain)
    grep -q '^UT_DOMAIN="named.by.the.urls"' <<< "$settings" && return 0
    echo "the address became $(grep -m1 '^UT_DOMAIN=' <<< "$settings")"
    return 1
}

the_checkout_is_left_alone() {
    grep -q 'keptfromthecheckout' <<< "$(checkout_of previous_checkout)" && return 0
    echo "the checkout's own .env was changed or removed"
    return 1
}

secrets_are_not_the_shipped_ones() {
    local state=$1 mine
    if grep -q '^JWT_SECRET=' "$REPO_ROOT/release.env"; then
        echo "JWT_SECRET ships in release.env — it is meant to be generated, never shipped"
        return 1
    fi
    mine=$(grep -m1 '^JWT_SECRET=' <<< "$(settings_of "$state")" | cut -d= -f2- | tr -d '"')
    [[ ${#mine} -ge 32 ]] && return 0
    echo "JWT_SECRET is '${mine}' — too short to be a generated secret"
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

# 91 GB is what a GitHub runner actually offers, and what sent this suite red
# before df was stubbed. An operator reads the two numbers or has nothing to act
# on, so the refusal has to carry both.
the_preflight_stops_on_a_disk_too_small() {
    local output
    output=$(output_of disk_too_small)
    grep -qE 'Disk: 91 GB free on .* [0-9]+ GB needed' <<< "$output" \
        && ! grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
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

# The harness has no controlling terminal, which is the state every scripted
# install runs in — a CI job, an Ansible play, ssh without a tty.
an_install_that_worked_says_so() {
    local output
    output=$(output_of install_runs_through)
    grep -q 'Installation complete' <<< "$output" || { echo "the install did not finish"; return 1; }
    grep -q '^EXIT=0$' <<< "$output" && return 0
    echo "it finished and still reported failure:"
    grep -E '^\[fail\]|^EXIT=|/dev/tty' <<< "$output" | tail -5
    return 1
}

the_secrets_are_findable_without_a_terminal() {
    local output
    output=$(output_of install_runs_through)
    grep -qi 'local.env' <<< "$output" && return 0
    echo "nothing told the operator where the secrets are"
    return 1
}

no_secret_reaches_the_log() {
    local output secret
    output=$(output_of install_runs_through)
    for secret in ADMIN_SETUP_PASSWORD BACKUP_FILES_PASSWORD; do
        secret=$(grep -m1 -E "^${secret}=" "$WORK_DIR/install_runs_through/env" 2>/dev/null) || continue
        secret=${secret#*=}; secret=${secret%\"}; secret=${secret#\"}
        [[ -n "$secret" ]] || continue
        grep -qF "$secret" <<< "$output" && { echo "a generated secret appears in the install output"; return 1; }
    done
    return 0
}

a_checkout_under_foot_needs_no_token() {
    local output
    output=$(output_of launched_from_a_checkout)
    if grep -qE 'Registry token for|has to be cloned' <<< "$output"; then
        echo "it set out to clone the release it was already standing in"
        grep -E 'Registry token|has to be cloned' <<< "$output" | head -2
        return 1
    fi
    grep -q '/srv/clone' <<< "$output" && return 0
    echo "it did not take the checkout it was launched from"
    grep -E 'Directory|Release|Checkout' <<< "$output" | head -3
    return 1
}

# The other half of the same change: recognising a checkout must not become a
# way in without credentials.
a_machine_with_no_credentials_is_still_asked() {
    local output
    output=$(output_of checkout_but_no_key)
    grep -qE 'Registry token for|registry token is needed|No registry token supplied' <<< "$output" && return 0
    echo "it went ahead without ever asking for a key"
    tail -6 <<< "$output"
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

# The password a machine was installed with is the password of its database,
# whatever it looks like: mongo only ever reads it when it creates the volume.
a_shipped_password_is_still_a_password() {
    local output
    output=$(output_of volume_with_shipped_password)
    if grep -q 'holds no password for it' <<< "$output"; then
        echo "the install refused a database whose password it holds"
        echo "$output"
        return 1
    fi
    grep -q 'Database already initialised' <<< "$output" && return 0
    echo "$output"
    return 1
}

the_way_back_comes_before_the_way_out() {
    local output first_rm first_put
    output=$(output_of orphan_volume)
    first_put=$(grep -n 'MONGODB_USERNAME and MONGODB_PASSWORD' <<< "$output" | head -1 | cut -d: -f1)
    first_rm=$(grep -n 'docker volume rm' <<< "$output" | head -1 | cut -d: -f1)
    [[ -n "$first_put" && -n "$first_rm" ]] || { echo "$output"; return 1; }
    (( first_put < first_rm )) && return 0
    echo "destroying the volume is offered before putting the password back"
    return 1
}

printf '%sWalking a fresh install%s %s(the installer, from a machine in a known state)%s\n\n' \
    "$BOLD" "$NC" "$DIM" "$NC"

build_the_package
write_machine_stubs

run_install_from_state bare
PULL_EXIT=0 run_install_from_state install_runs_through
INSTALL_TOKEN= INSTALL_COMMAND=/srv/clone/ut-install \
    run_install_from_state launched_from_a_checkout
INSTALL_TOKEN= INSTALL_COMMAND=/srv/clone/ut-install \
    run_install_from_state checkout_but_no_key
run_install_from_state empty_settings
run_install_from_state already_set
run_install_from_state no_settings_dir
MONGO_VOLUME_EXISTS=yes run_install_from_state orphan_volume
MONGO_VOLUME_EXISTS=yes run_install_from_state volume_with_shipped_password -
NETWORK_CREATE_EXIT=1 run_install_from_state pools_full
DISK_AVAIL_BYTES=$((91 * 1000 * 1000 * 1000)) run_install_from_state disk_too_small
run_install_from_state previous_checkout -
run_install_from_state checkout_without_domain -

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

printf '\n%sA machine too small to hold the models%s\n' "$BOLD" "$NC"
property "the refusal names what is free and what is needed" \
    the_preflight_stops_on_a_disk_too_small

printf '\n%sAn install that still lives in a git checkout%s\n' "$BOLD" "$NC"
property "its settings are carried over, not regenerated" \
    the_checkout_settings_are_carried_over
property "the address it already answers on is kept" \
    the_address_comes_from_the_checkout
property "the checkout itself is left untouched" \
    the_checkout_is_left_alone
property "an install too old to name its address has it read from its URLs" \
    the_address_is_read_from_the_urls

printf '\n%sAn install with nobody watching%s\n' "$BOLD" "$NC"
property "it finishes, and says so" \
    an_install_that_worked_says_so
property "the secrets can be found afterwards" \
    the_secrets_are_findable_without_a_terminal
property "and none of them reached the log" \
    no_secret_reaches_the_log

printf '\n%sLaunched from a checkout%s\n' "$BOLD" "$NC"
property "it takes the checkout it is standing in, and asks for no token" \
    a_checkout_under_foot_needs_no_token
property "but a machine with no credentials is still asked for a key" \
    a_machine_with_no_credentials_is_still_asked

printf '\n%sA database nobody has the password for%s\n' "$BOLD" "$NC"
property "the install stops, and says which volume and what to do" \
    an_orphan_volume_stops_the_install
property "it offers the way back before the way out" \
    the_way_back_comes_before_the_way_out

printf '\n%sA database whose password happens to look shipped%s\n' "$BOLD" "$NC"
property "the install carries on, because that password is the right one" \
    a_shipped_password_is_still_a_password

printf '\n%s%d verified%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d failing%s\n' "$RED" "$FAILED" "$NC"
    printf '\nNot working:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
