#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/images.sh"
WORK_DIR="$(mktemp -d)"
VERSION="${VERSION:-0.0.0-test}"

cleanup() {
    docker run --rm -v "$WORK_DIR":/w "$ALPINE_IMAGE" sh -c 'rm -rf /w/..?* /w/.[!.]* /w/*' >/dev/null 2>&1
    [[ -n "${WITH_OPENSSL_IMAGE:-}" ]] && docker image rm "$WITH_OPENSSL_IMAGE" >/dev/null 2>&1
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

# The installer is under test here, not the compiler: stand-ins take the place
# of the two ut-send builds, so this suite needs no Go. A package that did not
# build stops the suite: every property below would otherwise pass on an
# install that never ran.
build_the_package() {
    local arch tool
    for tool in ut-send ut-setup; do
        install -d "$WORK_DIR/$tool-builds"
        for arch in arm64 amd64; do
            printf '#!/bin/sh\necho stand-in\n' > "$WORK_DIR/$tool-builds/$tool-linux-$arch"
        done
    done
    docker run --rm -v "$REPO_ROOT":/src:ro -v "$WORK_DIR":/out -w /src "$DEBIAN_IMAGE" \
        sh -c "OUT_DIR=/out UT_SEND_BUILDS=/out/ut-send-builds UT_SETUP_BUILDS=/out/ut-setup-builds ./packaging/build-deb.sh '$VERSION'" >/dev/null
    [[ -f "$WORK_DIR/understandtech_${VERSION}_all.deb" ]] || {
        echo "The package did not build — nothing below would mean anything." >&2
        exit 1
    }
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
    "compose --progress") case "$*" in *" pull") exit "${PULL_EXIT:-0}" ;; esac ;;
    "login "*)            cat > /stub/docker-login-stdin ;;
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
cp /etc/understandtech/local.env /w/$state/local-env 2>/dev/null || : > /w/$state/local-env
cp /opt/understandtech/.env /w/$state/checkout-env 2>/dev/null || : > /w/$state/checkout-env
cp /stub/docker-calls /w/$state/docker-calls 2>/dev/null || : > /w/$state/docker-calls
cp /stub/docker-login-stdin /w/$state/login-stdin 2>/dev/null || : > /w/$state/login-stdin
cp /etc/understandtech/license /w/$state/license 2>/dev/null || : > /w/$state/license
stat -c '%a %U' /etc/understandtech/license > /w/$state/license-mode 2>/dev/null || : > /w/$state/license-mode
chmod -R a+rw /w/$state
PROBE

    docker run --rm \
        -v "$WORK_DIR":/w -v "$WORK_DIR":/out \
        -e MONGO_VOLUME_EXISTS="${MONGO_VOLUME_EXISTS:-no}" \
        -e NETWORK_CREATE_EXIT="${NETWORK_CREATE_EXIT:-0}" \
        -e PULL_EXIT="${PULL_EXIT:-9}" \
        -e DISK_AVAIL_BYTES="${DISK_AVAIL_BYTES:-}" \
        "${WALK_IMAGE:-$DEBIAN_IMAGE}" bash /w/walk-$state.sh >/dev/null 2>&1
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
        # The packaged ut-license carries the real public key; these states swap
        # in one whose private half the suite holds, the way an issued key is.
        licensed|license_tampered|license_ended|licensed_offline|licensed_elsewhere)
            echo 'cp /w/licenses/ut-license /usr/bin/ut-license' ;;
        license_stored)
            echo 'cp /w/licenses/ut-license /usr/bin/ut-license && install -d -m 750 /etc/understandtech && install -m 600 /w/licenses/valid.lic /etc/understandtech/license' ;;
        already_set)   echo 'install -m 600 /usr/share/understandtech/release.env /etc/understandtech/.env' ;;
        no_settings_dir) echo 'rm -rf /etc/understandtech' ;;
        pools_full)    echo ': # the daemon refuses through the stub' ;;
        disk_too_small) echo ': # the free space is answered through the stub' ;;
        # Every other state stubs nvidia-smi, so a machine with no accelerator is
        # the one where that stub is taken away. Declared, the settings file says
        # the inference is elsewhere; undeclared, nothing does.
        no_accelerator_declared|no_accelerator_on_a_smaller_disk)
            echo 'rm -f /stub/nvidia-smi && install -d -m 750 /etc/understandtech && printf '"'"'COMPOSE_FILE="compose.yaml:compose.no-gpu.yaml"\n'"'"' > /etc/understandtech/.env' ;;
        no_accelerator_undeclared|no_accelerator_by_flag)
            echo 'rm -f /stub/nvidia-smi' ;;
        # local.env written before the first install, the way the warning itself
        # tells an operator to write it.
        no_accelerator_pointed_at_a_real_machine)
            echo 'rm -f /stub/nvidia-smi && install -d -m 750 /etc/understandtech && printf '"'"'VLLM_LLM_BASE_URL="https://inference.example.test/v1"\n'"'"' > /etc/understandtech/local.env' ;;
        # A release dated in the future is the same arithmetic as a clock in the
        # past, and it needs no stub around date, which everything else uses.
        clock_before_the_release)
            echo "sed -i 's|^UT_RELEASE_BUILT_AT=.*|UT_RELEASE_BUILT_AT=\"4102444800\"|' /usr/share/understandtech/release.env" ;;
        orphan_volume) echo ': # the volume is asserted through the stub' ;;
        volume_with_shipped_password)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'MONGODB_USERNAME="mongoadmin"\nMONGODB_PASSWORD="12345678"\n'"'"' > /etc/understandtech/local.env' ;;
        previous_checkout)
            echo 'install -d /opt/understandtech && printf '"'"'UT_DOMAIN="carried.example"\nJWT_SECRET="keptfromthecheckout0123456789abcdef0123456789ab"\nLOG_LEVEL="WARNING"\nAPP_BUILDER_TOKEN_ENCRYPTION_KEY="a2VwdGZyb210aGVjaGVja291dDAxMjM0NTY3ODlhYmM="\n'"'"' > /opt/understandtech/.env' ;;
        checkout_without_domain)
            echo 'install -d /opt/understandtech && printf '"'"'PUBLIC_BASE_URL="https://named.by.the.urls"\nBACKEND_URL="https://named.by.the.urls/api"\nJWT_SECRET="keptfromthecheckout0123456789abcdef0123456789ab"\n'"'"' > /opt/understandtech/.env' ;;
        # /w is bind-mounted from the host, so a directory under it sits on another
        # filesystem than the container's own disk — what a mounted NAS share is.
        backup_destination_mounted)
            echo 'install -d /w/backup_destination_mounted/nas && install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_DESTINATION="/w/backup_destination_mounted/nas"\n'"'"' > /etc/understandtech/local.env' ;;
        backup_destination_not_mounted)
            echo 'install -d /mnt/nas && install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_DESTINATION="/mnt/nas"\n'"'"' > /etc/understandtech/local.env' ;;
        # What an install that already sends its backup to a share leaves behind,
        # replayed for an update while nothing is mounted at that path.
        backup_destination_gone_on_an_update)
            echo 'install -d /mnt/nas && install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_DESTINATION="/mnt/nas"\nCOMPOSE_FILE="compose.yaml:compose.backup-mount.yaml"\n'"'"' > /etc/understandtech/local.env' ;;
        backup_over_sftp)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_REPOSITORY="sftp:backup@nas.example.test:/appliance"\n'"'"' > /etc/understandtech/local.env' ;;
        backup_in_two_places)
            echo 'install -d /w/backup_in_two_places/nas && install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_DESTINATION="/w/backup_in_two_places/nas"\nBACKUP_FILES_REPOSITORY="s3:https://s3.example.test/appliance"\n'"'"' > /etc/understandtech/local.env' ;;
        *)             echo ': ' ;;
    esac
}

output_of()   { cat "$WORK_DIR/$1/output.txt" 2>/dev/null; }
settings_of() { cat "$WORK_DIR/$1/env" 2>/dev/null; }

# Every state but install_runs_through stops at the pull. A pull the stub no
# longer recognises lets them all run through to the last screen, where the
# role line repeats what several properties look for.
the_walk_stops_where_the_images_would_download() {
    local output
    output=$(output_of bare)
    grep -q 'Image pull failed' <<< "$output" && ! grep -q 'Starting services' <<< "$output" && return 0
    echo "$output"
    return 1
}

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

the_builder_key_comes_from_the_checkout() {
    local settings
    settings=$(settings_of previous_checkout)
    grep -q '^APP_BUILDER_TOKEN_ENCRYPTION_KEY="a2VwdGZyb210aGVjaGVja291dDAxMjM0NTY3ODlhYmM="' <<< "$settings" && return 0
    echo "the key became $(grep -m1 '^APP_BUILDER_TOKEN_ENCRYPTION_KEY=' <<< "$settings") — every GitLab token the App Builder stored is now unreadable"
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

the_builder_key_is_one_fernet_accepts() {
    local key bytes
    key=$(grep -m1 '^APP_BUILDER_TOKEN_ENCRYPTION_KEY=' <<< "$(settings_of bare)" | cut -d= -f2- | tr -d '"')
    bytes=$(printf '%s' "$key" | tr -- '-_' '+/' | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    [[ ${#key} -eq 44 && "$bytes" == 32 ]] && return 0
    echo "APP_BUILDER_TOKEN_ENCRYPTION_KEY is '${key}' — Fernet wants 32 bytes in URL-safe base64"
    return 1
}

two_installs_do_not_share_a_secret() {
    local key a b
    for key in JWT_SECRET APP_BUILDER_TOKEN_ENCRYPTION_KEY; do
        a=$(grep -m1 "^${key}=" <<< "$(settings_of bare)" | cut -d= -f2-)
        b=$(grep -m1 "^${key}=" <<< "$(settings_of empty_settings)" | cut -d= -f2-)
        [[ -n "$a" && "$a" != "$b" ]] && continue
        echo "two separate installs produced the same ${key}"
        return 1
    done
    return 0
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

# The name in the Python traceback is OPENAI_API_KEY, which exists nowhere in
# this appliance. Saying OA_KEY before the pull is the difference between one
# sentence and eight minutes of reading container logs.
the_install_names_what_would_keep_the_platform_down() {
    local output
    output=$(output_of bare)
    grep -q 'OA_KEY has no value' <<< "$output" \
        && grep -q 'restart in a loop' <<< "$output" && return 0
    echo "$output"
    return 1
}

the_preflight_stops_on_a_clock_before_the_release() {
    local output
    output=$(output_of clock_before_the_release)
    grep -q 'before this release was built' <<< "$output" \
        && ! grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

a_mounted_backup_destination_is_used_and_marked() {
    local settings output
    settings=$(settings_of backup_destination_mounted)
    output=$(output_of backup_destination_mounted)
    grep -qE '^COMPOSE_FILE=.*compose\.backup-mount\.yaml' <<< "$settings" \
        && [[ -e "$WORK_DIR/backup_destination_mounted/nas/.understandtech-backup-destination" ]] \
        && grep -q 'Downloading images' <<< "$output" && return 0
    grep -E '^COMPOSE_FILE' <<< "$settings"
    echo "$output"
    return 1
}

a_destination_on_the_machine_s_own_disk_stops_the_install() {
    local output
    output=$(output_of backup_destination_not_mounted)
    grep -q "this machine's own disk" <<< "$output" \
        && grep -q 'empty BACKUP_FILES_DESTINATION' <<< "$output" \
        && ! grep -q 'Downloading images' <<< "$output" && return 0
    echo "$output"
    return 1
}

a_network_destination_gets_its_way_out_and_names_the_key_it_lacks() {
    local settings output
    settings=$(settings_of backup_over_sftp)
    output=$(output_of backup_over_sftp)
    grep -qE '^COMPOSE_FILE=.*compose\.backup-network\.yaml' <<< "$settings" \
        && grep -q 'no host key is pinned for nas.example.test' <<< "$output" \
        && grep -q 'Downloading images' <<< "$output" && return 0
    grep -E '^COMPOSE_FILE' <<< "$settings"
    echo "$output"
    return 1
}

the_default_destination_adds_no_way_out() {
    ! grep -q 'compose.backup-network.yaml' <<< "$(settings_of bare)" && return 0
    grep -E '^COMPOSE_FILE' <<< "$(settings_of bare)"
    return 1
}

two_destinations_stop_the_install() {
    local output
    output=$(output_of backup_in_two_places)
    grep -q 'both say where the backup goes' <<< "$output" \
        && ! grep -q 'Downloading images' <<< "$output" \
        && ! grep -q 'compose.backup-mount.yaml' "$WORK_DIR/backup_in_two_places/local-env" && return 0
    echo "$output"
    grep -E '^COMPOSE_FILE' "$WORK_DIR/backup_in_two_places/local-env"
    return 1
}

a_destination_gone_on_an_update_holds_nothing_back() {
    local output
    output=$(output_of backup_destination_gone_on_an_update)
    grep -q 'the backup writes nothing until it is back' <<< "$output" \
        && grep -q 'Downloading images' <<< "$output" && return 0
    echo "$output"
    return 1
}

the_install_goes_on_when_the_inference_is_elsewhere() {
    local output
    output=$(output_of no_accelerator_declared)
    grep -q 'the inference is served by another machine' <<< "$output" \
        && grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

# The other half of the pair, and the one that matters: a driver that stopped
# answering looks exactly like a machine that never had a GPU. Waiving the check
# on the absence alone would install a box that generates nothing.
the_preflight_stops_when_nothing_says_the_inference_is_elsewhere() {
    local output
    output=$(output_of no_accelerator_undeclared)
    grep -q 'No usable GPU detected' <<< "$output" \
        && ! grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

# Waiving the check and writing nothing was the first version of this, and it
# installed a machine that pulled the engines and then could not start them:
# `could not select device driver "nvidia"`, after the images were down.
the_flag_writes_a_configuration_that_asks_for_no_gpu() {
    local settings
    settings=$(settings_of no_accelerator_by_flag)
    grep -q 'compose.no-gpu.yaml' <<< "$settings" \
        && ! grep -qE '^COMPOSE_PROFILES="?nim' <<< "$settings" && return 0
    grep -E '^COMPOSE_FILE|^COMPOSE_PROFILES' <<< "$settings"
    return 1
}

# The release points VLLM_LLM_BASE_URL at nim-llm, a service a control plane
# never starts. Installing without saying so leaves a platform that comes up
# healthy and cannot answer anything a model has to write.
the_install_says_the_inference_url_points_nowhere() {
    local output
    output=$(output_of no_accelerator_by_flag)
    grep -q 'VLLM_LLM_BASE_URL still names' <<< "$output" && return 0
    echo "$output"
    return 1
}

the_install_says_nothing_when_the_address_is_already_set() {
    local output
    output=$(output_of no_accelerator_pointed_at_a_real_machine)
    grep -q 'Writing the configuration' <<< "$output" \
        && ! grep -q 'still names' <<< "$output" && return 0
    echo "$output"
    return 1
}

# The engines account for 43.1 GB of the 55.29 GB measured on a box in service.
# A machine that serves none of it should not be turned away over the storage
# they would have taken.
the_disk_floor_follows_what_the_machine_will_actually_hold() {
    local output
    output=$(output_of no_accelerator_on_a_smaller_disk)
    grep -q 'Disk: 91 GB free' <<< "$output" \
        && ! grep -q '250 GB needed' <<< "$output" \
        && grep -q 'Writing the configuration' <<< "$output" && return 0
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

# Matching the path alone was not enough: any message naming local.env satisfied
# it, and the preflight gained one. What this property means is that the run with
# no terminal said where the secrets went, so it asks for that sentence.
the_secrets_are_findable_without_a_terminal() {
    local output
    output=$(output_of install_runs_through)
    grep -q 'The secrets are in' <<< "$output" && return 0
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
    grep -qE 'License key from|license key is needed|No license key supplied' <<< "$output" && return 0
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

LICENSE_USER=licensed-user
LICENSE_TOKEN=license-carried-token-0001

# The walk installs the package with --force-depends, so openssl, which the
# package declares, is not there; a license check cannot run without it.
WITH_OPENSSL_IMAGE=""

prepare_licenses() {
    local work="$WORK_DIR/licenses"
    mkdir -p "$work"
    WITH_OPENSSL_IMAGE=$(docker build -q - 2>/dev/null <<DOCKERFILE
FROM ${DEBIAN_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
DOCKERFILE
) || { echo "Could not build the image the license walks run in." >&2; exit 1; }
    openssl ecparam -name prime256v1 -genkey -noout -out "$work/license.key" 2>/dev/null
    openssl ec -in "$work/license.key" -pubout -out "$work/license.pub" 2>/dev/null
    python3 - "$REPO_ROOT/ut-license" "$work/license.pub" "$work/ut-license" <<'SWAP'
import pathlib, re, sys
original, pub, out = (pathlib.Path(a) for a in sys.argv[1:4])
out.write_text(re.sub(r"LICENSE_PUBLIC_KEY='[^']*'",
                      "LICENSE_PUBLIC_KEY='" + pub.read_text().strip() + "'", original.read_text(), count=1))
SWAP
    chmod 755 "$work/ut-license"
    printf '%s\n' "$LICENSE_TOKEN" > "$work/token"
    # Signed here rather than by issue-license.sh, which asks GitHub about the
    # token first: the walk is about the installer, and runs with no network.
    printf 'version=1\ncustomer=Walk Customer\nissued=%s\nexpires=%s\nrights=platform\nregistry_user=%s\nregistry_token=%s\n' \
        "$(date -u +%F)" "$(( $(date -u +%Y) + 1 ))-12-31" "$LICENSE_USER" "$LICENSE_TOKEN" > "$work/valid.payload"
    openssl dgst -sha256 -sign "$work/license.key" -out "$work/valid.sig" "$work/valid.payload"
    printf 'UT1.%s.%s\n' "$(openssl base64 -A < "$work/valid.payload")" \
        "$(openssl base64 -A < "$work/valid.sig")" > "$work/valid.lic"
    python3 - "$work/valid.lic" "$work/tampered.lic" <<'TAMPER'
import base64, sys
fmt, payload, signature = open(sys.argv[1]).read().strip().split(".")
renamed = base64.b64decode(payload).replace(b"customer=Walk Customer", b"customer=Someone Else", 1)
open(sys.argv[2], "w").write(".".join([fmt, base64.b64encode(renamed).decode(), signature]) + "\n")
TAMPER
    printf 'version=1\ncustomer=Walk Customer\nissued=%s\nexpires=%s\nrights=platform\nregistry=registry.example.test\nregistry_user=%s\nregistry_token=%s\n' \
        "$(date -u +%F)" "$(( $(date -u +%Y) + 1 ))-12-31" "$LICENSE_USER" "$LICENSE_TOKEN" > "$work/elsewhere.payload"
    openssl dgst -sha256 -sign "$work/license.key" -out "$work/elsewhere.sig" "$work/elsewhere.payload"
    printf 'UT1.%s.%s\n' "$(openssl base64 -A < "$work/elsewhere.payload")" \
        "$(openssl base64 -A < "$work/elsewhere.sig")" > "$work/elsewhere.lic"
    # And an ended one, as a key issued last year would have been.
    printf 'version=1\ncustomer=Walk Customer\nissued=2019-01-01\nexpires=2020-01-01\nrights=platform\nregistry_user=%s\nregistry_token=%s\n' \
        "$LICENSE_USER" "$LICENSE_TOKEN" > "$work/ended.payload"
    openssl dgst -sha256 -sign "$work/license.key" -out "$work/ended.sig" "$work/ended.payload"
    printf 'UT1.%s.%s\n' "$(openssl base64 -A < "$work/ended.payload")" \
        "$(openssl base64 -A < "$work/ended.sig")" > "$work/ended.lic"
    chmod 644 "$work"/*.lic
}

of_state() { cat "$WORK_DIR/$1/$2" 2>/dev/null; }

logged_in_with_the_license() {
    local state=$1
    grep -q "^login ghcr.io -u ${LICENSE_USER} --password-stdin" <<< "$(of_state "$state" docker-calls)" \
        || { echo "no registry login as ${LICENSE_USER}:"; of_state "$state" docker-calls | grep login; output_of "$state" | tail -5; return 1; }
    [[ "$(of_state "$state" login-stdin)" == "$LICENSE_TOKEN" ]] && return 0
    echo "the registry login was not given the token the license carries"
    return 1
}

never_logged_in() {
    local state=$1
    grep -q '^login ' <<< "$(of_state "$state" docker-calls)" || return 0
    echo "it logged into the registry anyway"
    return 1
}

a_license_installs_with_the_token_it_carries() {
    reached_the_pull licensed && logged_in_with_the_license licensed
}

the_license_is_kept_for_root_alone() {
    [[ "$(of_state licensed license-mode)" == "600 root" ]] \
        || { echo "the stored license is '$(of_state licensed license-mode)', not 600 root"; return 1; }
    [[ "$(of_state licensed license)" == "$(cat "$WORK_DIR/licenses/valid.lic")" ]] && return 0
    echo "the stored license is not the key that was given"
    return 1
}

an_update_takes_the_license_already_there() {
    reached_the_pull license_stored && logged_in_with_the_license license_stored
}

an_altered_license_stops_before_any_login() {
    grep -q 'not issued by UnderstandTech' <<< "$(output_of license_tampered)" \
        && grep -q '^EXIT=1$' <<< "$(output_of license_tampered)" \
        || { echo "an altered key was not refused:"; output_of license_tampered | tail -5; return 1; }
    never_logged_in license_tampered
}

an_ended_license_stops_the_install_and_says_when() {
    grep -q 'ended on 2020-01-01' <<< "$(output_of license_ended)" \
        && grep -q '^EXIT=1$' <<< "$(output_of license_ended)" \
        || { echo "an ended license was not refused:"; output_of license_ended | tail -5; return 1; }
    never_logged_in license_ended
}

images_already_here_need_no_registry_login() {
    grep -q 'Licensed to Walk Customer' <<< "$(output_of licensed_offline)" \
        || { echo "the license was not checked:"; output_of licensed_offline | tail -5; return 1; }
    never_logged_in licensed_offline
}

the_carried_token_never_reaches_the_output() {
    local state
    for state in licensed license_stored license_tampered license_ended licensed_offline licensed_elsewhere; do
        grep -qF "$LICENSE_TOKEN" <<< "$(output_of "$state")" \
            && { echo "the registry token appears in the output of ${state}"; return 1; }
    done
    return 0
}

image_lines() { grep -E '^[A-Z0-9_]+_IMAGE=' | sort; }

a_license_naming_a_registry_pulls_every_image_from_it() {
    local written release line wrong=""
    written=$(settings_of licensed_elsewhere | image_lines)
    release=$(image_lines < "$REPO_ROOT/release.env")
    [[ -n "$written" ]] || { echo "no image was written:"; output_of licensed_elsewhere | tail -5; return 1; }
    while IFS= read -r line; do
        [[ "$line" == *'="registry.example.test/'* ]] || wrong="${wrong} ${line%%=*}"
    done <<< "$written"
    [[ -z "$wrong" ]] || { echo "still pulled from elsewhere:${wrong}"; return 1; }
    [[ "$(sed 's/.*@//' <<< "$written")" == "$(sed 's/.*@//' <<< "$release")" ]] \
        || { echo "an image lost the digest release.env pins"; return 1; }
    grep -q '^CADDY_IMAGE="registry.example.test/library/caddy:' <<< "$written" \
        && grep -q '^API_IMAGE="registry.example.test/understand-tech/ut-api-customer:' <<< "$written" \
        || { echo "an image is not under its own path:"; echo "$written" | head -4; return 1; }
    grep -q '^login registry.example.test ' <<< "$(of_state licensed_elsewhere docker-calls)" && return 0
    echo "it did not sign in to the registry the license names"
    return 1
}

a_license_naming_no_registry_leaves_the_images_where_they_are() {
    [[ "$(settings_of licensed | image_lines)" == "$(image_lines < "$REPO_ROOT/release.env")" ]] && return 0
    echo "the image names changed with a license that names no registry"
    return 1
}

a_token_alone_still_installs_and_says_so() {
    reached_the_pull bare \
        && grep -q 'accepted by this version only' <<< "$(output_of bare)" && return 0
    echo "a token on its own was refused, or nothing said a license key will be needed"
    output_of bare | grep -i -E 'token|license' | head -3
    return 1
}

printf '%sWalking a fresh install%s %s(the installer, from a machine in a known state)%s\n\n' \
    "$BOLD" "$NC" "$DIM" "$NC"

build_the_package
write_machine_stubs
prepare_licenses

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
run_install_from_state clock_before_the_release
run_install_from_state previous_checkout -
run_install_from_state checkout_without_domain -
run_install_from_state no_accelerator_declared
run_install_from_state no_accelerator_undeclared
# 91 GB: under the 250 GB an appliance needs, over the 60 GB a control plane does.
DISK_AVAIL_BYTES=$((91 * 1000 * 1000 * 1000)) \
    run_install_from_state no_accelerator_on_a_smaller_disk
INSTALL_COMMAND="ut-install --no-gpu" run_install_from_state no_accelerator_by_flag
INSTALL_COMMAND="ut-install --no-gpu" run_install_from_state no_accelerator_pointed_at_a_real_machine
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/valid.lic" \
    run_install_from_state licensed
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/tampered.lic" \
    run_install_from_state license_tampered
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/ended.lic" \
    run_install_from_state license_ended
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= run_install_from_state license_stored
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/elsewhere.lic" \
    run_install_from_state licensed_elsewhere
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/valid.lic --skip-pull --health-timeout 5" \
    run_install_from_state licensed_offline
run_install_from_state backup_destination_mounted
run_install_from_state backup_destination_not_mounted
run_install_from_state backup_destination_gone_on_an_update
run_install_from_state backup_over_sftp
run_install_from_state backup_in_two_places

printf '%sA machine with nothing on it%s\n' "$BOLD" "$NC"
property "the install reaches the point where it pulls images" \
    reached_the_pull bare
property "the walk stops where the images would download" \
    the_walk_stops_where_the_images_would_download
property "every variable the stack requires has a value" \
    every_required_setting_is_filled bare
property "what it wrote renders a stack" \
    the_settings_render_a_stack bare
property "the secrets are not the ones the template ships" \
    secrets_are_not_the_shipped_ones bare
property "the App Builder's token key is one Fernet accepts" \
    the_builder_key_is_one_fernet_accepts

property "it names the setting the platform will not start without" \
    the_install_names_what_would_keep_the_platform_down

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

printf '\n%sA machine whose clock is behind the release%s\n' "$BOLD" "$NC"
property "the preflight stops rather than issue certificates nothing will accept" \
    the_preflight_stops_on_a_clock_before_the_release

printf '\n%sA machine with no accelerator at all%s\n' "$BOLD" "$NC"
property "the install goes on when the inference is served elsewhere" \
    the_install_goes_on_when_the_inference_is_elsewhere
property "the preflight stops when nothing says the inference is elsewhere" \
    the_preflight_stops_when_nothing_says_the_inference_is_elsewhere
property "the disk floor follows what the machine will actually hold" \
    the_disk_floor_follows_what_the_machine_will_actually_hold
property "the flag writes a configuration that asks docker for no GPU" \
    the_flag_writes_a_configuration_that_asks_for_no_gpu
property "it says the inference address still points at nothing" \
    the_install_says_the_inference_url_points_nowhere
property "it stays quiet when the address already names another machine" \
    the_install_says_nothing_when_the_address_is_already_set

printf '\n%sAn install that still lives in a git checkout%s\n' "$BOLD" "$NC"
property "its settings are carried over, not regenerated" \
    the_checkout_settings_are_carried_over
property "the address it already answers on is kept" \
    the_address_comes_from_the_checkout
property "the checkout itself is left untouched" \
    the_checkout_is_left_alone
property "the App Builder's token key comes along, so stored GitLab tokens stay readable" \
    the_builder_key_comes_from_the_checkout
property "an install too old to name its address has it read from its URLs" \
    the_address_is_read_from_the_urls

printf '\n%sAn install with nobody watching%s\n' "$BOLD" "$NC"
property "it finishes, and says so" \
    an_install_that_worked_says_so
property "the secrets can be found afterwards" \
    the_secrets_are_findable_without_a_terminal
property "and none of them reached the log" \
    no_secret_reaches_the_log

printf '\n%sA license key%s\n' "$BOLD" "$NC"
property "a license key installs, and logs in with the token it carries" \
    a_license_installs_with_the_token_it_carries
property "the license is kept for updates, readable by root alone" \
    the_license_is_kept_for_root_alone
property "an update takes the license already on the machine" \
    an_update_takes_the_license_already_there
property "an altered license stops the install before any login" \
    an_altered_license_stops_before_any_login
property "a license that has ended stops the install, and says when" \
    an_ended_license_stops_the_install_and_says_when
property "with the images already here, a license needs no registry login" \
    images_already_here_need_no_registry_login
property "a license that names a registry pulls every image from it, digests kept" \
    a_license_naming_a_registry_pulls_every_image_from_it
property "a license that names no registry leaves the images where they are" \
    a_license_naming_no_registry_leaves_the_images_where_they_are
property "the token a license carries never reaches the output" \
    the_carried_token_never_reaches_the_output
property "a registry token alone still installs, and says a license will be needed" \
    a_token_alone_still_installs_and_says_so

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

printf '\n%sA backup sent to a directory the host mounts%s\n' "$BOLD" "$NC"
property "a destination on a disk of its own is used, and marked as mounted" \
    a_mounted_backup_destination_is_used_and_marked
property "one on the machine's own disk stops the install, and says how to get out" \
    a_destination_on_the_machine_s_own_disk_stops_the_install

printf '\n%sA backup sent over the network%s\n' "$BOLD" "$NC"
property "an S3 or SFTP destination gets its way out, and the missing host key is named" \
    a_network_destination_gets_its_way_out_and_names_the_key_it_lacks
property "the default destination adds no way out" \
    the_default_destination_adds_no_way_out
property "naming two destinations stops the install, before anything is written" \
    two_destinations_stop_the_install
property "a destination gone during an update holds the update back no more than it says so" \
    a_destination_gone_on_an_update_holds_nothing_back

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
