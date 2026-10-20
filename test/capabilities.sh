#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/images.sh"
WORK_DIR="$(mktemp -d)"

# The restic and step-ca containers run as root and write into WORK_DIR, so the
# shell that created it cannot remove what they left.
cleanup() {
    [[ -s "$WORK_DIR/license/image" ]] && docker image rm "$(cat "$WORK_DIR/license/image")" >/dev/null 2>&1
    docker run --rm -v "$WORK_DIR":/w "$ALPINE_IMAGE" sh -c 'rm -rf /w/..?* /w/.[!.]* /w/*' >/dev/null 2>&1
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

group() { printf '\n%s%s%s\n' "$BOLD" "$1" "$NC"; }

capability() {
    local description=$1; shift
    # CAPABILITY_FILTER runs one line instead of all of them: the discrimination
    # harness breaks one thing at a time, and re-running the whole list for each
    # costs a minute a mutation.
    [[ -n "${CAPABILITY_FILTER:-}" && "$description" != *"$CAPABILITY_FILTER"* ]] && return 0
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

with_a_backup_destination() {
    BACKUP_FILES_DESTINATION="$WORK_DIR/mounted" "$@"
}

with_a_network_repository() {
    BACKUP_FILES_REPOSITORY="sftp:backup@nas.example.test:/appliance" BACKUP_FILES_SSH_DIR="$WORK_DIR/backup-ssh" "$@"
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

# A panel with no GPU runs no llm. The builder waited for it, so the whole
# project was refused and nothing started — the App Builder included.
app_builder_runs_without_a_gpu() {
    local files=(-f compose.yaml -f compose.no-gpu.yaml -f compose.appbuilder.yaml)
    renders_valid_configuration "${files[@]}" && lists_service app-builder "${files[@]}" && return 0
    ( cd "$WORK_DIR" && docker compose "${files[@]}" config 2>&1 >/dev/null | tail -3 )
    return 1
}

write_mdns_probe() {
    cat > "$WORK_DIR/mdns-probe.sh" <<'PROBE'
set -u
mkdir -p /fix /stub
printf 'UT_DOMAIN="%s"\nCOMPOSE_FILE="%s"\n' "$DOMAIN" "$COMPOSE_FILE" > /fix/.env

cat > /stub/systemctl <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> /stub/calls
case "$1" in
    is-enabled) [ "${ALREADY_ENABLED}" = yes ] ;;
    is-active)  exit 1 ;;
    *)          exit 0 ;;
esac
STUB
chmod +x /stub/systemctl
: > /stub/calls

PATH=/stub:$PATH bash /setup-autostart.sh --mdns --dir /fix 2>&1
printf 'EXIT=%s\n' "$?"
printf -- '--- installed ---\n'
ls /usr/local/bin/ut-mdns-alias /etc/systemd/system/ut-mdns-alias.service 2>/dev/null
printf -- '--- systemctl ---\n'
cat /stub/calls
PROBE
}

installing_mdns_reports() {
    local domain=$1 already_enabled=${2:-no} compose_file=${3:-compose.yaml}
    write_mdns_probe
    docker run --rm \
        -v "$REPO_ROOT/setup-autostart.sh":/setup-autostart.sh:ro \
        -v "$WORK_DIR/mdns-probe.sh":/mdns-probe.sh:ro \
        -e DOMAIN="$domain" -e ALREADY_ENABLED="$already_enabled" -e COMPOSE_FILE="$compose_file" \
        "$BASH_IMAGE" bash /mdns-probe.sh 2>&1
}

a_local_domain_publishes_over_mdns() {
    local report
    report=$(installing_mdns_reports understand.local)
    if grep -q '^/usr/local/bin/ut-mdns-alias$' <<< "$report" \
        && grep -q '^/etc/systemd/system/ut-mdns-alias.service$' <<< "$report" \
        && grep -q '^enable ut-mdns-alias$' <<< "$report"; then
        return 0
    fi
    echo "$report"
    return 1
}

a_real_domain_installs_no_mdns_publisher() {
    local report installed
    report=$(installing_mdns_reports box.example.com)
    installed=${report#*--- installed ---}
    installed=${installed%%--- systemctl ---*}
    if grep -q 'ut-mdns-alias' <<< "$installed"; then
        echo "the publisher was installed anyway:"; echo "$report"; return 1
    fi
    if grep -q 'apt-get install.*avahi' <<< "$report"; then
        echo "Avahi is still asked for:"; echo "$report"; return 1
    fi
    if ! grep -q '^EXIT=0$' <<< "$report"; then
        echo "$report"; return 1
    fi
}

# Two boxes on one .local network: a compute node publishing the platform's names
# would answer for them with its own address, and browsers would reach either box.
a_compute_node_publishes_none_of_the_platform_s_names() {
    local report installed
    report=$(installing_mdns_reports understand.local yes compose.yaml:compose.compute.yaml)
    installed=${report#*--- installed ---}
    installed=${installed%%--- systemctl ---*}
    if grep -q 'ut-mdns-alias' <<< "$installed" || ! grep -q '^disable --now ut-mdns-alias$' <<< "$report"; then
        echo "a compute node on .local kept or installed the publisher:"; echo "$report"; return 1
    fi
    grep -q '^EXIT=0$' <<< "$report" || { echo "$report"; return 1; }
}

# The platform's names on a compute node would send an operator to create DNS
# records for satellites that machine never serves.
a_compute_node_asks_only_for_its_inference_name() {
    local report
    report=$(docker run --rm -i -v "$REPO_ROOT":/src:ro "$BASH_IMAGE" bash -s 2>&1 <<'PROBE'
mkdir -p /fix /stub
cp /src/compose.yaml /src/compose.compute.yaml /fix/ && cp -r /src/caddy /fix/
printf 'UT_DOMAIN="compute.example.com"\nCOMPOSE_FILE="compose.yaml:compose.compute.yaml"\nUT_INFERENCE_ADDRESS="inference.example.com"\n' > /fix/.env
printf '#!/bin/sh\nexit 0\n' > /stub/docker
printf '#!/bin/sh\nexit 0\n' > /stub/systemctl
chmod +x /stub/docker /stub/systemctl
PATH=/stub:$PATH bash /src/setup-autostart.sh --install --dir /fix 2>&1
PROBE
)
    grep -qF 'https://inference.example.com:8444' <<< "$report" && ! grep -q 'llms\.compute' <<< "$report" && return 0
    grep -E 'compute node|llms|8444|ERROR' <<< "$report" | head -5
    return 1
}

# A folder written the way ut-get --prepare writes it, then loaded the way a box
# with no network loads it, ut-install's own functions on both sides. The two
# images are first removed, so whatever starts afterwards came from the folder.
folder_load_report() {
    local probe="$WORK_DIR/folder-probe" tamper=${1:-}
    rm -rf "$probe"; mkdir -p "$probe/folder" "$probe/install" "$probe/auth"
    printf 'BUSYBOX_IMAGE="%s"\nALPINE_INDEX_IMAGE="%s"\nUT_RELEASE_VERSION="0.0.0"\n' "$BUSYBOX_IMAGE" "$ALPINE_INDEX_IMAGE" > "$probe/install/release.env"
    : > "$probe/install/.env"; : > "$probe/install/local.env"
    printf '{"auths":{}}\n' > "$probe/auth/auth.json"
    (
        set +u; source "$REPO_ROOT/ut-get"
        printf '%s\n' "${BUSYBOX_IMAGE%%:*}@${BUSYBOX_IMAGE#*@}" "${ALPINE_INDEX_IMAGE%%:*}@${ALPINE_INDEX_IMAGE#*@}" \
            | copy_the_images_into "$probe/folder" "$probe/auth"
        copy_the_tools_into "$probe/folder" "$probe/auth"
    ) >/dev/null 2>&1 || { echo "PREPARE FAILED"; return 0; }
    [[ -n "$tamper" ]] && eval "$tamper"
    docker rmi -f "$BUSYBOX_IMAGE" "$ALPINE_INDEX_IMAGE" >/dev/null 2>&1
    docker image ls --digests --format '{{.Repository}}@{{.Digest}}' \
        | grep -F -e "${BUSYBOX_IMAGE%%:*}@${BUSYBOX_IMAGE#*@}" -e "${ALPINE_INDEX_IMAGE%%:*}@${ALPINE_INDEX_IMAGE#*@}" | sed 's/^/STILL THERE: /'
    (
        set +u; UT_INSTALL_DIR="$probe/install" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
        set +eE; trap - ERR
        INSTALL_DIR="$probe/install"; IMAGES_FROM="$probe/folder"; DO_PULL=false
        die_on_a_folder_that_misses_an_image && step_images_from_a_folder
    ) 2>&1
    echo "--- local.env"; cat "$probe/install/local.env"
    echo "--- run"
    local ref
    for ref in $(sed -n 's/^[A-Z_]*_IMAGE="\(.*\)"$/\1/p' "$probe/install/local.env"); do
        docker run --rm --pull never --network none "$ref" true && echo "$ref: ran"
    done
}

images_from_a_folder_start_under_their_digest() {
    local report
    report=$(folder_load_report)
    grep -qE '^BUSYBOX_IMAGE="127\.0\.0\.1:15000/prometheus/busybox@sha256:[0-9a-f]{64}"$' <<< "$report" \
        && grep -qE '^ALPINE_INDEX_IMAGE="127\.0\.0\.1:15000/linuxcontainers/alpine@sha256:[0-9a-f]{64}"$' <<< "$report" \
        && [[ $(grep -c ': ran$' <<< "$report") -eq 2 ]] \
        && ! grep -q 'STILL THERE' <<< "$report" && return 0
    echo "$report" | tail -15
    return 1
}

a_folder_image_the_release_does_not_name_is_refused() {
    local report
    report=$(folder_load_report 'sed -i.bak "s/linux/linux /" "$probe"/folder/images/ghcr.io_linuxcontainers_alpine/*/named.json; rm -f "$probe"/folder/images/*/*/named.json.bak')
    grep -q 'missing or not the one the release names' <<< "$report" \
        && ! grep -q 'IMAGE="127.0.0.1:15000' <<< "$report" && return 0
    echo "$report" | tail -8
    return 1
}

a_tool_the_release_does_not_name_is_refused() {
    local report
    report=$(folder_load_report 'docker pull -q "$BUSYBOX_IMAGE" >/dev/null && docker tag "$BUSYBOX_IMAGE" ghcr.io/distribution/distribution:3.0.0 && docker save -o "$probe/folder/tools/distribution.tar" ghcr.io/distribution/distribution:3.0.0 && docker rmi ghcr.io/distribution/distribution:3.0.0 >/dev/null')
    grep -q 'is not the ghcr.io/distribution/distribution:3.0.0 this release loads images with' <<< "$report" \
        && ! grep -q 'IMAGE="127.0.0.1:15000' <<< "$report" && return 0
    echo "$report" | tail -8
    return 1
}

the_folder_tools_are_those_ut_get_carries() {
    local key installer getter
    for key in FOLDER_REGISTRY_TOOL FOLDER_SKOPEO_TOOL; do
        installer=$(sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "$REPO_ROOT/ut-install")
        getter=$(sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "$REPO_ROOT/ut-get")
        [[ -n "$installer" && "$installer" == "$getter" ]] || { echo "${key}: ut-install '${installer}', ut-get '${getter}'"; return 1; }
    done
}

moving_off_local_withdraws_the_publisher() {
    local report
    report=$(installing_mdns_reports box.example.com yes)
    if grep -q '^disable --now ut-mdns-alias$' <<< "$report"; then
        return 0
    fi
    echo "$report"
    return 1
}

installer_domain_decision() {
    local given=$1 already_configured=${2:-} decide=${3:-read_domain} probe
    probe=$(mktemp -d "$WORK_DIR/installer.XXXXXX")
    [[ -n "$already_configured" ]] && printf 'UT_DOMAIN="%s"\n' "$already_configured" > "$probe/.env"
    env UT_DOMAIN="$given" UT_INSTALL_DIR="$probe" DECIDE="$decide" bash -c '
        set +u
        source "$1/ut-install" >/dev/null 2>&1
        set +eE
        trap - ERR
        if [[ "$DECIDE" == read_domain ]]; then
            read_domain < /dev/null 2>&1
        else
            DOMAIN=$("$DECIDE")
        fi
        printf "DOMAIN=%s\n" "$DOMAIN"
    ' _ "$REPO_ROOT"
}

# A stand-in ut-send: answers status with what it is given, records every
# configure call one argument per line, and fails when told to.
reporting_probe() {
    local said=$1 configure_exit=${2:-0} probe
    probe=$(mktemp -d "$WORK_DIR/reporting.XXXXXX")
    cat > "$probe/ut-send" <<STANDIN
#!/usr/bin/env bash
if [[ "\$1" == status ]]; then echo "${said}"; exit 0; fi
printf '%s\n' "\$@" > "$probe/configure-call"
exit ${configure_exit}
STANDIN
    chmod +x "$probe/ut-send"
    printf '%s' "$probe"
}

installer_reporting() {
    local probe=$1 run=$2
    shift 2
    env UT_SEND="$probe/ut-send" UT_INSTALL_DIR="$probe" RUN="$run" "$@" bash -c '
        set +u
        source "$1/ut-install" >/dev/null 2>&1
        set +eE
        trap - ERR
        terminal_is_reachable() { return 1; }
        eval "$RUN"
        echo "exit=$?"
    ' _ "$REPO_ROOT"
}

no_answer_and_no_terminal_sends_nothing() {
    local probe report
    probe=$(reporting_probe "Reporting: not decided")
    report=$(installer_reporting "$probe" step_reporting < /dev/null 2>&1)
    [[ "$(cat "$probe/configure-call" 2>/dev/null)" == $'configure\n--consent\nno' ]] && return 0
    echo "$report"
    echo "ut-send was asked: $(tr '\n' ' ' < "$probe/configure-call" 2>/dev/null)"
    return 1
}

an_answer_already_given_is_not_asked_again() {
    local probe report
    probe=$(reporting_probe "Reporting: off")
    report=$(installer_reporting "$probe" step_reporting < /dev/null 2>&1)
    [[ ! -e "$probe/configure-call" ]] && return 0
    echo "it set the answer again: $(tr '\n' ' ' < "$probe/configure-call")"
    return 1
}

the_prompt_and_the_flags_hand_ut_send_the_same_thing() {
    local by_flags by_prompt
    by_flags=$(reporting_probe "Reporting: not decided")
    installer_reporting "$by_flags" step_reporting UT_REPORTING=yes < /dev/null >/dev/null 2>&1
    installer_reporting "$by_flags" 'REPORTING=yes REPORTING_RECEIVER=https://receiver.example.test:8444 REPORTING_TOKEN_FILE=/root/token REPORTING_RECEIVER_CERT=/root/receiver.pem step_reporting' \
        < /dev/null >/dev/null 2>&1
    by_prompt=$(reporting_probe "Reporting: not decided")
    printf '\nmaybe\nyes\nhttps://receiver.example.test:8444\n/root/token\n/root/receiver.pem\n' \
        | installer_reporting "$by_prompt" 'ask_about_reporting && step_reporting' >/dev/null 2>&1
    if [[ -s "$by_flags/configure-call" ]] && cmp -s "$by_flags/configure-call" "$by_prompt/configure-call"; then
        return 0
    fi
    echo "flags:  $(tr '\n' ' ' < "$by_flags/configure-call" 2>/dev/null)"
    echo "prompt: $(tr '\n' ' ' < "$by_prompt/configure-call" 2>/dev/null)"
    return 1
}

reporting_that_fails_does_not_stop_the_install() {
    local probe report
    probe=$(reporting_probe "Reporting: not decided" 1)
    report=$(installer_reporting "$probe" step_reporting UT_REPORTING=yes < /dev/null 2>&1)
    grep -q '^exit=0$' <<< "$report" && grep -q 'could not be set up' <<< "$report" && return 0
    echo "$report"
    return 1
}

a_period_given_to_the_installer_reaches_ut_send() {
    local probe report
    probe=$(reporting_probe "Reporting: not decided")
    report=$(installer_reporting "$probe" 'REPORTING_EVERY=5 step_reporting' UT_REPORTING=yes < /dev/null 2>&1)
    [[ "$(cat "$probe/configure-call" 2>/dev/null)" == $'configure\n--consent\nyes\n--every\n5' ]] && return 0
    echo "$report"
    echo "ut-send was asked: $(tr '\n' ' ' < "$probe/configure-call" 2>/dev/null)"
    return 1
}

an_address_given_up_front_is_taken_as_it_is() {
    local report
    report=$(installer_domain_decision box.example.com)
    if grep -q '^DOMAIN=box.example.com$' <<< "$report" && ! grep -q 'mDNS' <<< "$report"; then
        return 0
    fi
    echo "$report"
    return 1
}

an_unattended_install_falls_back_and_says_so() {
    local report
    report=$(installer_domain_decision "")
    if grep -q '^DOMAIN=understand.local$' <<< "$report" && grep -q 'mDNS-only' <<< "$report"; then
        return 0
    fi
    echo "$report"
    return 1
}

the_preflight_checks_the_address_in_use() {
    local report
    report=$(installer_domain_decision "" box.example.com domain_to_check)
    if grep -q '^DOMAIN=box.example.com$' <<< "$report"; then
        return 0
    fi
    echo "$report"
    return 1
}

installer_domain_answer() {
    local answer=$1 already_configured=${2:-} probe
    probe=$(mktemp -d "$WORK_DIR/prompt.XXXXXX")
    [[ -n "$already_configured" ]] && printf 'UT_DOMAIN="%s"\n' "$already_configured" > "$probe/.env"
    cat > "$probe/run.sh" <<EOF
set +u
UT_INSTALL_DIR="$probe" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
set +eE
trap - ERR
read_domain
printf 'DOMAIN=%s\n' "\$DOMAIN"
EOF
    python3 "$SCRIPT_DIR/answer-a-prompt.py" "$probe/run.sh" "$answer" | tr -d '\r'
}

# step_wait_healthy is never reached by fresh-install.sh, which stops where the
# installer would pull images. Driving the function directly, with the container
# list it reads replaced, is the only way to watch it decide.
installer_wait_over() {
    local lines=$1 probe
    probe=$(mktemp -d "$WORK_DIR/wait.XXXXXX")
    cat > "$probe/run.sh" <<EOF
set +u
UT_INSTALL_DIR="$probe" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
set +eE
trap - ERR
HEALTH_TIMEOUT=1
container_health_lines() { printf '%s' '$lines'; }
step_wait_healthy
printf 'EXIT=%s\n' "\$?"
EOF
    bash "$probe/run.sh" 2>&1 | tr -d '\r'
}

the_platform_is_ready_while_inference_still_loads() {
    local report
    report=$(installer_wait_over '/ut-caddy|running|healthy|control-plane
/understandtech-nim-llm-1|running|starting|inference
')
    grep -q 'The platform is ready' <<< "$report" \
        && grep -q 'nim-llm' <<< "$report" \
        && return 0
    echo "$report"
    return 1
}

a_control_plane_service_is_still_waited_for() {
    local report
    report=$(installer_wait_over '/ut-mongodb|running|starting|control-plane
')
    grep -q 'The platform is ready' <<< "$report" && { echo "$report"; return 1; }
    grep -q 'ut-mongodb' <<< "$report" && return 0
    echo "$report"
    return 1
}

a_service_without_a_role_is_waited_for() {
    local report
    report=$(installer_wait_over '/ut-something|running|starting|
')
    grep -q 'The platform is ready' <<< "$report" && { echo "$report"; return 1; }
    grep -q 'ut-something' <<< "$report" && return 0
    echo "$report"
    return 1
}

an_inference_engine_that_failed_is_not_a_success() {
    local report
    report=$(installer_wait_over '/ut-caddy|running|healthy|control-plane
/understandtech-nim-llm-1|running|unhealthy|inference
')
    grep -q '^EXIT=0$' <<< "$report" && { echo "$report"; return 1; }
    grep -q 'nim-llm' <<< "$report" && return 0
    echo "$report"
    return 1
}

a_backup_that_does_not_work_does_not_hold_the_install_back() {
    local report
    report=$(installer_wait_over '/ut-caddy|running|healthy|control-plane
/ut-files-backup|running|unhealthy|backup
/ut-mongodb-backup|running|starting|backup
')
    grep -q 'The platform is ready' <<< "$report" \
        && grep -q 'The backup is not working yet' <<< "$report" \
        && grep -q 'ut-files-backup' <<< "$report" \
        && grep -q 'ut-mongodb-backup' <<< "$report" && return 0
    echo "$report"
    return 1
}

the_wait_names_what_is_late() {
    local report
    report=$(installer_wait_over '/ut-mongodb|running|starting|control-plane
')
    grep -q 'still starting' <<< "$report" || { echo "$report"; return 1; }
    grep -q 'still starting.*ut-mongodb' <<< "$report" && return 0
    echo "$report"
    return 1
}

# The pull is never reached by fresh-install.sh either. compose_in_dir is
# replaced by one that answers as Compose v5.0.2 did on .40: JSON on stderr.
installer_pull_over() {
    local probe
    probe=$(mktemp -d "$WORK_DIR/pull.XXXXXX")
    cat > "$probe/run.sh" <<'EOF'
set +u
UT_INSTALL_DIR="$PROBE" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
set +eE
trap - ERR
compose_in_dir() {
    case "$*" in
        "--progress json version") return "${JSON_REFUSED:-0}" ;;
        "config --images")         printf 'ghcr.io/x/api:1\nghcr.io/x/caddy:2\nghcr.io/x/mongo:3\n' ;;
        "--progress json pull")
            printf '%s\n' >&2 \
                '{"id":"Image ghcr.io/x/api:1","status":"Working","text":"Pulling"}' \
                '{"id":"159d7ed29e1f","parent_id":"Image ghcr.io/x/api:1","status":"Done","text":"Download complete","details":"0B","percent":100}' \
                '{"id":"Image ghcr.io/x/api:1","status":"Done","text":"Pulled"}' \
                '{"id":"Image ghcr.io/x/caddy:2","status":"Done","text":"Pulled"}'
            [[ -z "${PULL_FAILS:-}" ]] || { echo "Error response from daemon: denied" >&2; return 1; }
            [[ -z "${COMPOSE_REFUSES:-}" ]] || { echo '{"error":true,"message":"service \"app-builder\" depends on undefined service \"llm\": invalid compose project"}' >&2; return 1; }
            return 0 ;;
        "pull") echo "COMPOSE'S OWN OUTPUT" ;;
    esac
}
( step_pull )
printf 'EXIT=%s\n' "$?"
EOF
    PROBE="$probe" REPO_ROOT="$REPO_ROOT" bash "$probe/run.sh" 2>&1
}

the_pull_says_each_image_as_it_lands() {
    local report
    report=$(installer_pull_over)
    grep -q '1/3  ghcr.io/x/api:1  (0 min)' <<< "$report" \
        && grep -q '2/3  ghcr.io/x/caddy:2' <<< "$report" \
        && ! grep -q '159d7ed29e1f' <<< "$report" \
        && ! grep -q '"status"' <<< "$report" \
        && ! grep -q $'\033' <<< "$report" \
        && grep -q 'EXIT=0' <<< "$report" && return 0
    echo "$report"
    return 1
}

a_pull_that_fails_still_stops_the_install() {
    local report
    report=$(PULL_FAILS=1 installer_pull_over)
    grep -q 'Image pull failed' <<< "$report" \
        && grep -q 'Error response from daemon: denied' <<< "$report" \
        && ! grep -q 'EXIT=0' <<< "$report" && return 0
    echo "$report"
    return 1
}

a_project_compose_refuses_is_named() {
    local report
    report=$(COMPOSE_REFUSES=1 installer_pull_over)
    grep -q 'depends on undefined service' <<< "$report" \
        && grep -q 'Image pull failed' <<< "$report" && return 0
    echo "$report"
    return 1
}

a_compose_without_json_progress_pulls_as_before() {
    local report
    report=$(JSON_REFUSED=1 installer_pull_over)
    grep -q "COMPOSE'S OWN OUTPUT" <<< "$report" && grep -q 'EXIT=0' <<< "$report" && return 0
    echo "$report"
    return 1
}

installer_summary_with() {
    local loading=$1 probe
    probe=$(mktemp -d "$WORK_DIR/summary.XXXXXX")
    cat > "$probe/run.sh" <<'EOF'
set +u
UT_INSTALL_DIR="$PROBE" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
set +eE
trap - ERR
DOMAIN=box.test
INFERENCE_STILL_LOADING="$LOADING"
LOG_FILE=/dev/null
SECONDS=1530
print_summary
EOF
    PROBE="$probe" REPO_ROOT="$REPO_ROOT" LOADING="$loading" bash "$probe/run.sh" 2>&1
}

the_last_screen_says_how_long_where_to_go_and_what_still_loads() {
    local report quiet
    report=$(installer_summary_with "ut-nim-llm")
    quiet=$(installer_summary_with "")
    grep -q 'Installation complete in 25 min' <<< "$report" \
        && grep -q 'Open https://box.test .*first-run wizard' <<< "$(tr '\n' ' ' <<< "$report")" \
        && grep -q 'Inference      still loading: ut-nim-llm' <<< "$report" \
        && ! grep -q 'Inference' <<< "$quiet" \
        && ! grep -q $'\033' <<< "$report" && return 0
    echo "$report"
    return 1
}

an_answer_at_the_prompt_is_taken() {
    local report
    report=$(installer_domain_answer ia.exemple.fr)
    if grep -q '^DOMAIN=ia.exemple.fr$' <<< "$report"; then
        return 0
    fi
    echo "$report"
    return 1
}

an_empty_answer_keeps_the_configured_address() {
    local report
    report=$(installer_domain_answer "" box.example.com)
    if grep -q '^DOMAIN=box.example.com$' <<< "$report" \
        && grep -q 'Leave empty to keep box.example.com' <<< "$report"; then
        return 0
    fi
    echo "$report"
    return 1
}

an_address_already_configured_is_kept() {
    local report
    report=$(installer_domain_decision "" box.example.com)
    if grep -q '^DOMAIN=box.example.com$' <<< "$report"; then
        return 0
    fi
    echo "$report"
    return 1
}

write_package_probe() {
    cat > "$WORK_DIR/package-probe.sh" <<'PROBE'
set -u
export OUT_DIR=/out
# The package is under test here, not the compiler: stand-ins take the place of
# the two ut-send builds, so this suite needs no Go.
export UT_SEND_BUILDS=/ut-send-builds UT_SETUP_BUILDS=/ut-setup-builds
mkdir -p "$UT_SEND_BUILDS" "$UT_SETUP_BUILDS"
for arch in arm64 amd64; do
    printf '#!/bin/sh\necho %s\n' "$arch" > "$UT_SEND_BUILDS/ut-send-linux-$arch"
    printf '#!/bin/sh\necho %s\n' "$arch" > "$UT_SETUP_BUILDS/ut-setup-linux-$arch"
done
/src/packaging/build-deb.sh 2026.09.1 >/dev/null
/src/packaging/build-deb.sh 2026.09.2 >/dev/null

OUT_DIR=/out/first  SOURCE_DATE_EPOCH=1750000000 /src/packaging/build-deb.sh 2026.09.1 >/dev/null
# Back to back the two builds share a second, so their file times match by luck
# and the comparison passes whether the date is fixed or not.
sleep 2
OUT_DIR=/out/second SOURCE_DATE_EPOCH=1750000000 /src/packaging/build-deb.sh 2026.09.1 >/dev/null

say() { printf '%s=%s\n' "$1" "$2"; }
present_dir()  { [ -d "$1" ] && echo present || echo gone; }
present_file() { [ -f "$1" ] && echo present || echo gone; }
digest_of()    { sha256sum < "$1" | cut -d' ' -f1; }

# Two packages that were never built have the same digest — the empty one — so
# each comparison first asks whether there is anything to compare.
first=/out/first/understandtech_2026.09.1_all.deb
second=/out/second/understandtech_2026.09.1_all.deb
say SAME_BYTES_TWICE "$([ -f "$first" ] && [ -f "$second" ] \
    && [ "$(digest_of "$first")" = "$(digest_of "$second")" ] && echo yes || echo no)"

apparent_kib() { find "$1" -type f -exec du -k --apparent-size {} + | awk '{ t += $1 } END { print t + 0 }'; }

checksums=$(dpkg-deb --ctrl-tarfile /out/understandtech_2026.09.1_all.deb 2>/dev/null | tar -xO ./md5sums 2>/dev/null)
sorted_checksums=$([ -n "$checksums" ] && printf '%s\n' "$checksums" | sort -c -k2 >/dev/null 2>&1 && echo yes || echo no)
say MD5SUMS_IN_ONE_ORDER "$sorted_checksums"

mkdir -p /unpacked
dpkg-deb -x /out/understandtech_2026.09.1_all.deb /unpacked
declared_size=$(dpkg-deb -f /out/understandtech_2026.09.1_all.deb Installed-Size)
say SIZE_FREE_OF_THE_FILESYSTEM \
    "$([ "$declared_size" = "$(apparent_kib /unpacked)" ] && echo yes || echo no)"

dpkg -i --force-depends /out/understandtech_2026.09.1_all.deb >/dev/null 2>&1
say INSTALLED_VERSION "$(dpkg-query -W -f='${Version}' understandtech 2>/dev/null)"
say RELEASE_FILE      "$(present_file /usr/share/understandtech/compose.yaml)"
say COMMAND           "$([ -x /usr/bin/ut-install ] && echo present || echo gone)"
say UT_SEND           "$([ -x /usr/bin/ut-send ] && [ -x /usr/lib/understandtech/ut-send-linux-arm64 ] \
    && [ -x /usr/lib/understandtech/ut-send-linux-amd64 ] && echo both || echo missing)"
say UT_SETUP          "$([ -x /usr/bin/ut-setup ] && [ -x /usr/lib/understandtech/ut-setup-linux-arm64 ] \
    && [ -x /usr/lib/understandtech/ut-setup-linux-amd64 ] && echo both || echo missing)"
say CONFIG_DIR_MODE   "$(stat -c '%a' /etc/understandtech 2>/dev/null)"
say DATA_DIR          "$(present_dir /var/lib/understandtech)"
say SETTINGS_SHIPPED  "$(dpkg -L understandtech | grep -c '^/etc/understandtech/.' || true)"

printf 'UT_DOMAIN="box.client.fr"\n' > /etc/understandtech/.env
say READ_THROUGH_LINK "$(cat /usr/share/understandtech/.env 2>/dev/null || echo unreadable)"

ask_the_installed_command() {
    bash -c '
        set +u
        source /usr/bin/ut-install >/dev/null 2>&1
        set +eE
        trap - ERR
        resolve_install_dir
        printf "%s " "$INSTALL_DIR"
        release_comes_from_the_package_manager && printf "skipped" || printf "clones"
    '
}
say INSTALL_DIR_AND_FETCH "$(ask_the_installed_command)"

mkdir -p /root/.docker
printf '{"auths":{"ghcr.io":{}}}\n' > /root/.docker/config.json
say TOKEN_ASKED_AGAIN "$(bash -c '
    set +u
    source /usr/bin/ut-install >/dev/null 2>&1
    set +eE
    trap - ERR
    resolve_install_dir
    token_required && echo yes || echo no
')"

mkdir -p /var/lib/understandtech/app-data
echo document > /var/lib/understandtech/app-data/one
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> /systemctl-calls\n' > /usr/local/bin/systemctl
chmod +x /usr/local/bin/systemctl
mkdir -p /etc/systemd/system
touch /etc/systemd/system/ut-send.timer /etc/systemd/system/ut-send.service

dpkg -i --force-depends /out/understandtech_2026.09.2_all.deb >/dev/null 2>&1
say UPGRADED_VERSION       "$(dpkg-query -W -f='${Version}' understandtech 2>/dev/null)"
say SETTINGS_AFTER_UPGRADE "$(cat /etc/understandtech/.env 2>/dev/null || echo gone)"
say RELEASE_AFTER_UPGRADE  "$(present_file /usr/share/understandtech/compose.yaml)"
say TIMER_AFTER_UPGRADE    "$(present_file /etc/systemd/system/ut-send.timer)"

dpkg --purge --force-depends understandtech >/dev/null 2>&1
say RELEASE_AFTER_PURGE  "$(present_dir /usr/share/understandtech)"
say SETTINGS_AFTER_PURGE "$(present_file /etc/understandtech/.env)"
say DATA_AFTER_PURGE     "$(present_file /var/lib/understandtech/app-data/one)"
say TIMER_AFTER_PURGE    "$(present_file /etc/systemd/system/ut-send.timer)$(grep -q '^disable --now ut-send.timer$' /systemctl-calls 2>/dev/null && echo ',stopped')"
PROBE
}

# One container answers every question below: building, installing, upgrading
# and purging costs about twenty seconds, and asking it four times costs four
# times that for the same answers.
package_lifecycle_report() {
    local cached="$WORK_DIR/package-lifecycle.txt"
    if [[ ! -s "$cached" ]]; then
        write_package_probe
        mkdir -p "$WORK_DIR/pkg"
        docker run --rm \
            -v "$REPO_ROOT":/src:ro \
            -v "$WORK_DIR/pkg":/out \
            -v "$WORK_DIR/package-probe.sh":/probe.sh:ro \
            "$DEBIAN_IMAGE" bash /probe.sh > "$cached" 2>&1
    fi
    cat "$cached"
}

reports() {
    local key=$1 expected=$2 report
    report=$(package_lifecycle_report)
    if grep -qx "${key}=${expected}" <<< "$report"; then
        return 0
    fi
    echo "expected ${key}=${expected}, report was:"
    echo "$report"
    return 1
}

the_release_installs_to_its_own_place() {
    reports RELEASE_FILE present \
        && reports COMMAND present \
        && reports INSTALLED_VERSION 2026.09.1
}

the_settings_directory_is_prepared_but_never_filled() {
    reports CONFIG_DIR_MODE 750 && reports SETTINGS_SHIPPED 0
}

the_settings_are_read_from_where_the_release_lives() {
    reports READ_THROUGH_LINK 'UT_DOMAIN="box.client.fr"'
}

an_upgrade_replaces_the_release_and_keeps_the_settings() {
    reports UPGRADED_VERSION 2026.09.2 \
        && reports RELEASE_AFTER_UPGRADE present \
        && reports SETTINGS_AFTER_UPGRADE 'UT_DOMAIN="box.client.fr"'
}

the_installed_command_takes_the_release_that_is_there() {
    reports INSTALL_DIR_AND_FETCH '/usr/share/understandtech skipped'
}

a_registry_login_already_stored_is_not_asked_for_again() {
    reports TOKEN_ASKED_AGAIN no
}

an_upgrade_keeps_the_reporting_timer_and_removal_stops_it() {
    reports TIMER_AFTER_UPGRADE present \
        && reports TIMER_AFTER_PURGE gone,stopped
}

removing_the_package_leaves_the_settings_and_the_data() {
    reports RELEASE_AFTER_PURGE gone \
        && reports SETTINGS_AFTER_PURGE present \
        && reports DATA_AFTER_PURGE present
}

# A dependency nobody calls is a package installed on the customer's machine for
# nothing; one that is called without a guard and not declared is an install
# that fails on a machine missing it.
shipped_commands() {
    printf '%s\n' "$REPO_ROOT/ut-install" "$REPO_ROOT/ut-certificate" \
        "$REPO_ROOT/ut-logs-archive" "$REPO_ROOT/setup-autostart.sh" \
        "$REPO_ROOT/backup-files.sh" "$REPO_ROOT/ut-license"
}

declared_dependencies() {
    grep -m1 '^Depends:' "$REPO_ROOT/packaging/build-deb.sh" \
        | sed 's/^Depends: //; s/([^)]*)//g' | tr ',' '\n' | tr -d ' ' | grep -v '^$'
}

every_declared_dependency_is_really_used() {
    local dependency unused=()
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        grep -qhE "(^|[^-[:alnum:]])${dependency}[[:space:]]" $(shipped_commands) \
            || unused+=("$dependency")
    done < <(declared_dependencies)
    (( ${#unused[@]} == 0 )) && return 0
    echo "declared but never called: ${unused[*]}"
    return 1
}

# ut-verify is the trust anchor of an offline install, so the key it carries and
# the key the release is signed with have to be the same one — and a signature
# is only worth what it refuses.
signature_verdicts() {
    local work="$WORK_DIR/signing"
    mkdir -p "$work"
    if [[ ! -s "$work/verdicts.txt" ]]; then
        openssl ecparam -name prime256v1 -genkey -noout -out "$work/release.key" 2>/dev/null
        openssl ec -in "$work/release.key" -pubout -out "$work/release.pub" 2>/dev/null
        openssl ecparam -name prime256v1 -genkey -noout -out "$work/other.key" 2>/dev/null

        # ut-verify carries its key in a variable, so the probe swaps in one it
        # holds the private half of, and signs with that half.
        python3 - "$REPO_ROOT/ut-verify" "$work/release.pub" "$work/ut-verify" <<'SWAP'
import pathlib, re, sys
original, pub, out = (pathlib.Path(a) for a in sys.argv[1:4])
text = original.read_text()
swapped = re.sub(r"RELEASE_PUBLIC_KEY='[^']*'",
                 "RELEASE_PUBLIC_KEY='" + pub.read_text().strip() + "'", text, count=1)
out.write_text(swapped)
SWAP
        chmod +x "$work/ut-verify"

        head -c 200000 /dev/urandom > "$work/package.deb"
        openssl dgst -sha256 -sign "$work/release.key" -out "$work/package.deb.sig" "$work/package.deb"

        {
            printf 'SIGNED_BY_THE_RELEASE_KEY=%s\n' \
                "$("$work/ut-verify" "$work/package.deb" >/dev/null 2>&1 && echo accepted || echo refused)"

            cp "$work/package.deb" "$work/tampered.deb"
            printf 'x' >> "$work/tampered.deb"
            cp "$work/package.deb.sig" "$work/tampered.deb.sig"
            printf 'TAMPERED_PACKAGE=%s\n' \
                "$("$work/ut-verify" "$work/tampered.deb" >/dev/null 2>&1 && echo accepted || echo refused)"

            cp "$work/package.deb" "$work/foreign.deb"
            openssl dgst -sha256 -sign "$work/other.key" -out "$work/foreign.deb.sig" "$work/foreign.deb"
            printf 'SIGNED_BY_ANOTHER_KEY=%s\n' \
                "$("$work/ut-verify" "$work/foreign.deb" >/dev/null 2>&1 && echo accepted || echo refused)"

            cp "$work/package.deb" "$work/unsigned.deb"
            printf 'NO_SIGNATURE_AT_ALL=%s\n' \
                "$("$work/ut-verify" "$work/unsigned.deb" >/dev/null 2>&1 && echo accepted || echo refused)"
        } > "$work/verdicts.txt"
    fi
    cat "$work/verdicts.txt"
}

verdict_is() {
    local key=$1 expected=$2 verdicts
    verdicts=$(signature_verdicts)
    grep -qx "${key}=${expected}" <<< "$verdicts" && return 0
    echo "expected ${key}=${expected}, verdicts were:"; echo "$verdicts"; return 1
}

a_package_the_release_signed_is_accepted() {
    verdict_is SIGNED_BY_THE_RELEASE_KEY accepted
}

a_package_nobody_signed_is_refused() {
    verdict_is TAMPERED_PACKAGE refused \
        && verdict_is SIGNED_BY_ANOTHER_KEY refused \
        && verdict_is NO_SIGNATURE_AT_ALL refused
}

# Seen on a machine where mktemp was refused: --fingerprint printed the hash of
# an empty file and exited 0, which is what a trust anchor must never do.
a_key_that_cannot_be_read_never_fingerprints_as_nothing() {
    local tool said
    for tool in ut-verify ut-license; do
        [[ -x "$REPO_ROOT/$tool" ]] || continue
        said=$(docker run --rm -e TMPDIR=/nonexistent -v "$REPO_ROOT":/src:ro "$DEBIAN_IMAGE" \
            bash "/src/$tool" --fingerprint 2>&1; echo "STATUS=$?")
        if grep -q 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' <<< "$said" \
            || grep -q 'STATUS=0' <<< "$said"; then
            echo "${tool} --fingerprint with no temporary file said: ${said}"
            return 1
        fi
    done
    return 0
}

# ut-verify exists because dpkg verifies nothing on its own and a customer's box
# has no network. That second half had never been exercised: every run of it so
# far had one. mongo:8.2 is the only image this suite already pulls that ships
# the openssl CLI — which is the point, since --network none cannot install it.
a_package_verifies_with_no_network_at_all() {
    local work="$WORK_DIR/signing" said
    signature_verdicts >/dev/null
    said=$(docker run --rm --network none -v "$work":/w:ro --entrypoint sh "$MONGODB_IMAGE" \
        -c '/w/ut-verify /w/package.deb' 2>&1)
    grep -q 'is signed by' <<< "$said" && return 0
    echo "with no network at all, ut-verify said: ${said:-nothing}"
    return 1
}

the_shipped_key_is_the_one_the_release_is_signed_with() {
    local embedded versioned
    embedded=$("$REPO_ROOT/ut-verify" --fingerprint)
    versioned="SHA256: $(openssl pkey -pubin -in "$REPO_ROOT/packaging/release.pub" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -r | cut -d' ' -f1)"
    [[ "$embedded" == "$versioned" ]] && return 0
    echo "ut-verify carries ${embedded}, packaging/release.pub is ${versioned}"
    return 1
}

# ut-get is the first thing a customer runs, as root, on a release fetched or
# carried in — so like ut-verify it is only worth what it refuses to install.
# apt-get and ut-install are stubs that write down how they were called.
launcher_verdicts() {
    local work="$WORK_DIR/launcher" signing="$WORK_DIR/signing" case package
    mkdir -p "$work/bin"
    if [[ ! -s "$work/verdicts.txt" ]]; then
        signature_verdicts >/dev/null
        python3 - "$REPO_ROOT/ut-get" "$signing/release.pub" "$work/ut-get" <<'SWAP'
import pathlib, re, sys
original, pub, out = (pathlib.Path(a) for a in sys.argv[1:4])
text = original.read_text()
swapped = re.sub(r"RELEASE_PUBLIC_KEY='[^']*'",
                 "RELEASE_PUBLIC_KEY='" + pub.read_text().strip() + "'", text, count=1)
out.write_text(swapped)
SWAP
        chmod +x "$work/ut-get"
        for stub in apt-get ut-install ut-setup; do
            printf '#!/bin/sh\necho "%s $*" >> "/w/calls-$CASE"\n' "$stub" > "$work/bin/$stub"
            chmod +x "$work/bin/$stub"
        done

        package=understandtech_9.9.9_all.deb
        mkdir -p "$work/signed" "$work/tampered" "$work/foreign" "$work/unsigned" "$work/browser"
        cp "$signing/package.deb" "$work/signed/$package"
        cp "$signing/package.deb.sig" "$work/signed/$package.sig"
        cp "$signing/package.deb" "$work/browser/$package"
        cp "$signing/package.deb.sig" "$work/browser/$package.sig"
        cp "$signing/package.deb" "$work/tampered/$package"
        printf 'x' >> "$work/tampered/$package"
        cp "$signing/package.deb.sig" "$work/tampered/$package.sig"
        cp "$signing/package.deb" "$work/foreign/$package"
        cp "$signing/foreign.deb.sig" "$work/foreign/$package.sig"
        cp "$signing/package.deb" "$work/unsigned/$package"

        for case in signed tampered foreign unsigned; do
            docker run --rm --network none -v "$work":/w -e CASE="$case" -e PATH=/w/bin:/usr/bin:/bin \
                --entrypoint bash "$MONGODB_IMAGE" /w/ut-get --from "/w/$case" --domain box.test >/dev/null 2>&1
            printf '%s=%s\n' "$case" "$(tr '\n' ';' < "$work/calls-$case" 2>/dev/null || echo nothing)"
        done > "$work/verdicts.txt"
        docker run --rm --network none -v "$work":/w -e CASE=browser -e PATH=/w/bin:/usr/bin:/bin \
            --entrypoint bash "$MONGODB_IMAGE" /w/ut-get --from /w/browser --browser >/dev/null 2>&1
        printf 'browser=%s\n' "$(tr '\n' ';' < "$work/calls-browser" 2>/dev/null || echo nothing)" >> "$work/verdicts.txt"
    fi
    cat "$work/verdicts.txt"
}

launcher_verdict_is() {
    local key=$1 expected=$2 verdicts
    verdicts=$(launcher_verdicts)
    grep -qxF "${key}=${expected}" <<< "$verdicts" && return 0
    echo "expected ${key}=${expected}, verdicts were:"; echo "$verdicts"; return 1
}

a_signed_release_is_installed_then_handed_to_ut_install() {
    launcher_verdict_is signed \
        "apt-get install -y /w/signed/understandtech_9.9.9_all.deb;ut-install --domain box.test;"
}

the_launcher_continues_in_the_browser_when_asked() {
    launcher_verdict_is browser "apt-get install -y /w/browser/understandtech_9.9.9_all.deb;ut-setup ;"
}

the_launcher_installs_nothing_unsigned() {
    launcher_verdict_is tampered nothing \
        && launcher_verdict_is foreign nothing \
        && launcher_verdict_is unsigned nothing
}

# The same launcher, fetching from a local HTTPS server laid out like GitHub's
# releases: /latest redirects to the tag, assets sit under /download/<tag>/.
# The client is Debian with curl, which the image the offline probe uses lacks.
download_verdicts() {
    local work="$WORK_DIR/download" signing="$WORK_DIR/signing" net="ut-get-download-$$"
    local client="ut-get-client-$$" server="ut-get-server-$$" version dir
    mkdir -p "$work/bin" "$work/tls"
    if [[ ! -s "$work/verdicts.txt" ]]; then
        launcher_verdicts >/dev/null
        cp "$WORK_DIR/launcher/ut-get" "$work/ut-get"
        cp "$WORK_DIR/launcher/bin/apt-get" "$WORK_DIR/launcher/bin/ut-install" "$work/bin/"

        for version in 2026.99.1 2026.98.1 2026.97.1; do
            dir="$work/site/releases/download/v${version}"
            mkdir -p "$dir"
            cp "$signing/package.deb" "$dir/understandtech_${version}_all.deb"
            cp "$signing/package.deb.sig" "$dir/understandtech_${version}_all.deb.sig"
        done
        printf 'x' >> "$work/site/releases/download/v2026.97.1/understandtech_2026.97.1_all.deb"
        printf 'v2026.99.1' > "$work/latest"

        cat > "$work/serve.py" <<'SERVE'
import http.server, pathlib, ssl
class Releases(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory="/w/site", **kwargs)
    def do_GET(self):
        if self.path == "/releases/latest":
            tag = pathlib.Path("/w/latest").read_text().strip()
            self.send_response(302)
            self.send_header("Location", "https://releases.test/releases" + ("/tag/" + tag if tag else ""))
            self.end_headers()
            return
        super().do_GET()
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(("", 443), Releases)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/w/tls/server.pem", "/w/tls/server.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
SERVE

        docker network create "$net" >/dev/null
        docker run -d --name "$client" --network "$net" -v "$work":/w "$DEBIAN_IMAGE" sleep 600 >/dev/null
        docker exec "$client" bash -c '
            for attempt in 1 2 3; do
                apt-get update -qq && apt-get install -y -qq --no-install-recommends curl openssl ca-certificates && break
                sleep 5
            done >/dev/null 2>&1
            cd /w/tls
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 \
                -subj /CN=test-releases-ca -keyout ca.key -out ca.pem
            openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
                -subj /CN=releases.test -keyout server.key -out server.csr
            openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 \
                -extfile <(printf "subjectAltName=DNS:releases.test") -out server.pem
            chmod 644 server.key' >/dev/null 2>&1
        docker run -d --name "$server" --network "$net" --network-alias releases.test -v "$work":/w:ro \
            "$PYTHON_IMAGE" python3 /w/serve.py >/dev/null
        sleep 2

        launch() {
            local case=$1; shift
            docker exec -e CASE="$case" -e PATH=/w/bin:/usr/bin:/bin \
                -e UT_RELEASES_URL=https://releases.test/releases -e CURL_CA_BUNDLE=/w/tls/ca.pem \
                "$client" /w/ut-get "$@" > "$work/said-$case" 2>&1
            printf '%s=%s\n' "$case" "$(tr '\n' ';' < "$work/calls-$case" 2>/dev/null || echo nothing)"
        }
        {
            launch latest --domain box.test
            launch pinned --version 2026.98.1 --domain box.test
            launch tampered --version 2026.97.1 --domain box.test
            printf '' > "$work/latest"
            launch unpublished --domain box.test
            launch notaversion --version ../2026.98.1 --domain box.test
            docker rm -f "$server" >/dev/null 2>&1
            launch offline --version 2026.98.1 --domain box.test
            grep -q 'has published no release yet' "$work/said-unpublished" && echo 'unpublished_said=no release yet'
            grep -q 'is not a release version' "$work/said-notaversion" && echo 'notaversion_said=not a version'
        } > "$work/verdicts.txt"
        docker rm -f "$client" "$server" >/dev/null 2>&1
        docker network rm "$net" >/dev/null 2>&1
    fi
    cat "$work/verdicts.txt"
}

download_verdict_is() {
    local key=$1 expected=$2 verdicts
    verdicts=$(download_verdicts)
    grep -qxF "${key}=${expected}" <<< "$verdicts" && return 0
    echo "expected ${key}=${expected}, verdicts were:"; echo "$verdicts"
    return 1
}

DOWNLOADED=/var/cache/understandtech/releases

the_latest_release_is_downloaded_checked_and_installed() {
    download_verdict_is latest \
        "apt-get install -y ${DOWNLOADED}/2026.99.1/understandtech_2026.99.1_all.deb;ut-install --domain box.test;"
}

a_named_version_is_installed_rather_than_the_latest() {
    download_verdict_is pinned \
        "apt-get install -y ${DOWNLOADED}/2026.98.1/understandtech_2026.98.1_all.deb;ut-install --domain box.test;"
}

a_downloaded_release_that_was_altered_installs_nothing() {
    download_verdict_is tampered nothing
}

with_no_release_published_or_no_version_nothing_is_fetched() {
    download_verdict_is unpublished nothing \
        && download_verdict_is unpublished_said "no release yet" \
        && download_verdict_is notaversion nothing \
        && download_verdict_is notaversion_said "not a version"
}

a_release_already_downloaded_installs_again_offline() {
    download_verdict_is offline \
        "apt-get install -y ${DOWNLOADED}/2026.98.1/understandtech_2026.98.1_all.deb;ut-install --domain box.test;"
}

# The install command fetches ut-get from the release itself, so a release
# that does not carry it breaks the first command a customer types.
the_release_publishes_the_launcher() {
    local publish
    publish=$(sed -n '/gh release create/,/SHA256SUMS$/p' "$REPO_ROOT/.github/workflows/release.yml")
    grep -q 'dist/ut-get' <<< "$publish" && return 0
    echo "release.yml does not publish ut-get, which the install command downloads first"
    return 1
}

# The manual install checks SHA256SUMS, which fails on a sound release as soon
# as it lists a file the page does not download — ut-get once did exactly that.
release_file_kinds() {
    tr ' ' '\n' | grep -vE '^(SHA256SUMS)?$' | sed -e 's/^understandtech_[^.]*//' -e 's/^_all//' | sort -u
}

the_install_page_downloads_every_file_the_sums_list() {
    local listed downloaded
    listed=$(sed -n 's/.*sha256sum \(.*\) > SHA256SUMS.*/\1/p' "$REPO_ROOT/.github/workflows/release.yml" \
        | release_file_kinds)
    downloaded=$(sed -n '/^for f in understandtech_/,/; do$/p' "$REPO_ROOT/docs/install.md" \
        | sed -e 's/^for f in//' -e 's/; do$//' -e 's/\\$//' | tr -s ' \n' ' ' | release_file_kinds)
    [[ -n "$listed" && "$listed" == "$downloaded" ]] && return 0
    echo "SHA256SUMS lists:"; echo "$listed"; echo "docs/install.md downloads:"; echo "$downloaded"
    return 1
}

the_launcher_carries_the_key_ut_verify_carries() {
    local in_launcher in_verify
    in_launcher=$(sed -n "/^RELEASE_PUBLIC_KEY='/,/'\$/p" "$REPO_ROOT/ut-get")
    in_verify=$(sed -n "/^RELEASE_PUBLIC_KEY='/,/'\$/p" "$REPO_ROOT/ut-verify")
    [[ -n "$in_launcher" && "$in_launcher" == "$in_verify" ]] && return 0
    echo "ut-get carries:"; echo "$in_launcher"; echo "ut-verify carries:"; echo "$in_verify"
    return 1
}

# A license file is what lets a box pull the release, so like the package it is
# only worth what it refuses — and its license carries a registry token that
# must never come back out on a screen, in a log or on a command line.
LICENSE_TEST_TOKEN=ghp_licenseTestTokenNeverPrinted0001

# GitHub and ghcr stand-ins on the loopback, one scenario per path prefix:
# good, broad (more than read:packages), forever (no end), short (ends before
# the license), long (outlives any license), blind (cannot pull), refused (401). Each answers only when it is
# sent the credential the real one would expect.
start_a_fake_github() {
    local work=$1 next_year=$2
    cat > "$work/fake-github.py" <<'FAKE'
import base64, http.server, json, sys
token, user, year, portfile = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
basic = "Basic " + base64.b64encode(f"{user}:{token}".encode()).decode()

class Answer(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, code, headers=(), body=b""):
        self.send_response(code)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def route(self):
        scenario, _, rest = self.path.lstrip("/").partition("/")
        sent = self.headers.get("Authorization", "")
        if rest == "user":
            if sent != "Bearer " + token or scenario == "refused":
                return self.answer(401)
            headers = [("X-OAuth-Scopes", "read:packages, repo" if scenario == "broad" else "read:packages")]
            if scenario != "forever":
                end = {"short": f"{year}-01-01", "long": "9999-12-31"}.get(scenario, f"{year + 1}-12-31")
                headers.append(("GitHub-Authentication-Token-Expiration", end + " 00:00:00 UTC"))
            return self.answer(200, headers)
        if rest.startswith("token"):
            if sent != basic:
                return self.answer(401)
            return self.answer(200, [("Content-Type", "application/json")],
                               json.dumps({"token": "pull-" + scenario}).encode())
        if rest.startswith("v2/") and scenario.startswith("zot"):
            if sent != basic or scenario == "zotblind":
                return self.answer(403)
            return self.answer(200)
        if rest.startswith("v2/"):
            if sent != "Bearer pull-" + scenario or scenario == "blind":
                return self.answer(403)
            return self.answer(200)
        return self.answer(404)

    do_GET = route
    do_HEAD = route

server = http.server.HTTPServer(("127.0.0.1", 0), Answer)
open(portfile, "w").write(str(server.server_port))
server.serve_forever()
FAKE
    python3 "$work/fake-github.py" "$LICENSE_TEST_TOKEN" dgx-access "${next_year%%-*}" "$work/fake-port" &
    FAKE_GITHUB_PID=$!
    local waited=0
    until [[ -s "$work/fake-port" ]]; do
        sleep 0.2; waited=$((waited + 1))
        (( waited < 50 )) || { echo "the fake GitHub never started" >&2; return 1; }
    done
    FAKE_GITHUB="http://127.0.0.1:$(cat "$work/fake-port")"
}

issued_against() {
    local scenario=$1; shift
    UT_GITHUB_API="$FAKE_GITHUB/$scenario" UT_GHCR="$FAKE_GITHUB/$scenario" UT_REGISTRY_URL="$FAKE_GITHUB/$scenario" \
        "$REPO_ROOT/packaging/issue-license.sh" --ledger "$WORK_DIR/issuance/ledger.tsv" "$@"
}

payload_field_of() {
    cut -d. -f2 "$1" 2>/dev/null | openssl base64 -d -A 2>/dev/null | sed -n "s/^$2=//p"
}

issuance_verdicts() {
    local work="$WORK_DIR/issuance"
    mkdir -p "$work"
    if [[ ! -s "$work/verdicts.txt" ]]; then
        openssl ecparam -name prime256v1 -genkey -noout -out "$work/signing.key" 2>/dev/null
        printf '%s\n' "$LICENSE_TEST_TOKEN" > "$work/token"

        local next_year scenario
        next_year="$(( $(date -u +%Y) + 1 ))-12-31"
        start_a_fake_github "$work" "$next_year" || return 1
        {
            printf 'issued=%s\n' \
                "$(issued_against good --customer "Test Customer" --expires "$next_year" --token-file "$work/token" \
                    --signing-key "$work/signing.key" >/dev/null 2>&1 && echo issued || echo refused)"
            printf 'issued_without_an_end=%s\n' \
                "$(issued_against long --customer "Test Customer" --token-file "$work/token" \
                    --signing-key "$work/signing.key" >/dev/null 2>&1 && echo issued || echo refused)"
            printf 'issued_to_nobody=%s\n' \
                "$(issued_against long --expires "$next_year" --token-file "$work/token" \
                    --signing-key "$work/signing.key" >/dev/null 2>&1 && echo issued || echo refused)"
            issued_against zot --registry registry.example.test --customer "Test Customer" --expires "$next_year" \
                --token-file "$work/token" --signing-key "$work/signing.key" > "$work/zot.lic" 2>/dev/null
            printf 'zot_issued=%s\n' "$(payload_field_of "$work/zot.lic" registry | grep . || echo none)"
            printf 'zot_blind=%s\n' \
                "$(issued_against zotblind --registry registry.example.test --customer "Test Customer" --expires "$next_year" \
                    --token-file "$work/token" --signing-key "$work/signing.key" >/dev/null 2>&1 && echo issued || echo refused)"
            for scenario in broad forever short blind refused; do
                printf 'token_%s=%s\n' "$scenario" \
                    "$(issued_against "$scenario" --customer "Test Customer" --expires "$next_year" \
                        --token-file "$work/token" --signing-key "$work/signing.key" >/dev/null 2>&1 \
                        && echo issued || echo refused)"
            done
        } > "$work/verdicts.txt"
        kill "$FAKE_GITHUB_PID" 2>/dev/null
    fi
    cat "$work/verdicts.txt"
}

issuance_verdict_is() {
    local key=$1 expected=$2 verdicts
    verdicts=$(issuance_verdicts)
    grep -qx "${key}=${expected}" <<< "$verdicts" && return 0
    echo "expected ${key}=${expected}, verdicts were:"; echo "$verdicts"; return 1
}

a_license_is_issued_only_for_a_narrow_token_that_outlives_it() {
    issuance_verdict_is issued issued \
        && issuance_verdict_is token_broad refused \
        && issuance_verdict_is token_forever refused \
        && issuance_verdict_is token_short refused \
        && issuance_verdict_is token_blind refused \
        && issuance_verdict_is token_refused refused
}

every_license_issued_is_written_down_never_its_token() {
    local ledger="$WORK_DIR/issuance/ledger.tsv" fingerprint
    issuance_verdicts >/dev/null
    fingerprint=$(printf '%s' "$LICENSE_TEST_TOKEN" | openssl dgst -sha256 -r | cut -c1-16)
    grep -qF "$LICENSE_TEST_TOKEN" "$ledger" 2>/dev/null \
        && { echo "the ledger holds the token itself"; return 1; }
    [[ $(grep -c "	Test Customer	.*	${fingerprint}	" "$ledger" 2>/dev/null) -eq 2 ]] && return 0
    echo "expected the two licenses issued, and only those, in the ledger:"
    cat "$ledger" 2>/dev/null || echo "no ledger"
    return 1
}

a_license_for_another_registry_names_it_and_is_checked_there() {
    issuance_verdict_is zot_issued registry.example.test \
        && issuance_verdict_is zot_blind refused
}

# ut-install pulls under the names image_in_registry gives, and issue-license.sh
# checks the account against the names its own copy gives: they have to agree.
both_tools_name_every_image_alike() {
    local reference installer issuer differ=""
    eval "$(sed -n '/^image_in_registry() {/,/^}/p' "$REPO_ROOT/ut-install" | sed 's/^image_in_registry()/installer_names()/')"
    eval "$(sed -n '/^image_in_registry() {/,/^}/p' "$REPO_ROOT/packaging/issue-license.sh" | sed 's/^image_in_registry()/issuer_names()/')"
    while IFS= read -r reference; do
        installer=$(REGISTRY=reg.example.test installer_names "$reference")
        issuer=$(registry=reg.example.test issuer_names "$reference")
        [[ "$installer" == "$issuer" ]] || differ="${differ} ${reference}: ${installer} / ${issuer};"
    done < <(grep -oE '^[A-Z0-9_]+_IMAGE="[^"]+"' "$REPO_ROOT/release.env" | cut -d'"' -f2)
    [[ -z "$differ" ]] || { echo "the two tools name images differently:${differ}"; return 1; }
    [[ "$(REGISTRY=reg.example.test installer_names 'caddy:2-alpine@sha256:ab')" == "reg.example.test/library/caddy:2-alpine@sha256:ab" ]] \
        && [[ "$(REGISTRY=reg.example.test installer_names 'ghcr.io/understand-tech/ut-api-customer:2.1@sha256:ab')" == "reg.example.test/understand-tech/ut-api-customer:2.1@sha256:ab" ]] \
        && [[ "$(REGISTRY=reg.example.test installer_names 'smallstep/step-ca:0.30.2@sha256:ab')" == "reg.example.test/smallstep/step-ca:0.30.2@sha256:ab" ]] \
        && return 0
    echo "the mapping does not keep each image under its own path"
    return 1
}

a_license_without_a_customer_or_an_end_is_never_issued() {
    issuance_verdict_is issued_without_an_end refused \
        && issuance_verdict_is issued_to_nobody refused
}

# ut-license runs where the box runs it, on Debian with its openssl and jq,
# whatever openssl the machine that runs the suite has.
license_image() {
    local work="$WORK_DIR/license"
    mkdir -p "$work"
    if [[ ! -s "$work/image" ]]; then
        docker build -q - > "$work/image" 2>/dev/null <<DOCKERFILE || { rm -f "$work/image"; return 1; }
FROM ${DEBIAN_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends openssl jq curl python3 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
    fi
    cat "$work/image"
}

license_verdicts() {
    local work="$WORK_DIR/license" image
    mkdir -p "$work"
    if [[ ! -s "$work/verdicts.txt" ]]; then
        image=$(license_image) || { echo "the image the license checks run in did not build" >&2; return 1; }
        docker run --rm -i -v "$REPO_ROOT":/src:ro -v "$work":/w -e KEYGEN_TEST_TOKEN="$LICENSE_TEST_TOKEN" \
            "$image" bash -s > "$work/verdicts.txt" 2> "$work/verdicts.err" <<'LAB'
set -u
. /src/test/keygen.sh
prepare_license_lab /src /w/lab
: > /w/keygen-requests
python3 /w/lab/fake-keygen.py "$KEYGEN_TEST_PORT" /w/keygen-requests /w/lab/certificates &
for _ in $(seq 50); do curl -s -o /dev/null "http://127.0.0.1:$KEYGEN_TEST_PORT/" && break; sleep 0.1; done
export PATH=/w/lab/argv:$PATH
for name in valid tampered foreign garbage elsewhere clock ended suspended file_ended; do
    status=0
    /w/lab/ut-license check "/w/lab/files/$name.lic" > "/w/said-check-$name" 2>&1 || status=$?
    printf 'check_%s=%s\n' "$name" "$([ "$status" = 0 ] && echo accepted || echo refused)"
    printf 'check_%s_status=%s\n' "$name" "$status"
done
/w/lab/ut-license check /w/lab/keys/old_format.key > /w/said-check-old_format 2>&1 && verdict=accepted || verdict=refused
printf 'check_old_format=%s\n' "$verdict"
/w/lab/ut-license-without-a-serial check /w/lab/files/machine_id.lic > /w/said-check-machine_id 2>&1 \
    && verdict=accepted || verdict=refused
printf 'check_machine_id=%s\n' "$verdict"
for name in fresh active registry elsewhere ended suspended unknown old_format injected; do
    /w/lab/ut-license activate "/w/lab/keys/$name.key" "/w/activated-$name.lic" > "/w/said-activate-$name" 2>&1 \
        && verdict=activated || verdict=refused
    printf 'activate_%s=%s\n' "$name" "$verdict"
done
printf 'activated_mode=%s\n' "$(stat -c %a /w/activated-fresh.lic 2>/dev/null || echo none)"
printf 'activated_checks=%s\n' "$(/w/lab/ut-license check /w/activated-fresh.lic >/dev/null 2>&1 && echo yes || echo no)"
printf 'registry=%s\n' "$(/w/lab/ut-license field registry /w/activated-registry.lic 2>/dev/null || echo none)"
given=$(/w/lab/ut-license field registry_token /w/lab/files/valid.lic 2>/dev/null)
printf 'token_given=%s\n' "$([ "$given" = "$KEYGEN_TEST_TOKEN" ] && echo yes || echo no)"
LAB
    fi
    cat "$work/verdicts.txt"
}

license_verdict_is() {
    local key=$1 expected=$2 verdicts
    verdicts=$(license_verdicts)
    grep -qx "${key}=${expected}" <<< "$verdicts" && return 0
    echo "expected ${key}=${expected}, verdicts were:"; echo "$verdicts"
    tail -5 "$WORK_DIR/license/verdicts.err" 2>/dev/null
    return 1
}

license_said() {
    local name=$1 words=$2 said
    said=$(cat "$WORK_DIR/license/said-$name" 2>/dev/null)
    grep -qF "$words" <<< "$said" && return 0
    echo "${name} was expected to say '${words}', and said: ${said:-nothing}"
    return 1
}

a_license_file_keygen_signed_for_this_machine_is_accepted() {
    license_verdict_is check_valid accepted && license_said check-valid 'Licensed to Test Customer'
}

a_license_file_nobody_signed_is_refused() {
    license_verdict_is check_tampered refused && license_verdict_is check_foreign refused \
        && license_verdict_is check_garbage refused \
        && license_said check-tampered 'not issued by UnderstandTech' \
        && license_said check-foreign 'not issued by UnderstandTech'
}

a_license_file_made_for_another_machine_is_refused() {
    license_verdict_is check_elsewhere refused && license_said check-elsewhere 'made for another machine'
}

a_clock_set_before_the_file_is_named() {
    license_verdict_is check_clock refused && license_said check-clock "machine's clock says"
}

an_ended_or_suspended_license_is_refused_with_whom_to_ask() {
    license_verdict_is check_ended refused && license_said check-ended 'ended on' \
        && license_said check-ended 'contact@understand.tech' \
        && license_verdict_is check_suspended refused && license_said check-suspended 'is suspended'
}

a_license_file_past_its_end_says_how_to_get_a_new_one() {
    license_verdict_is check_file_ended refused && license_said check-file_ended 'run ut-install with network'
}

# 2 says the file is genuine and this machine's, so that ut-install may renew it
# from Keygen; 1 says it is refused, and nothing goes on the network.
a_file_that_only_needs_renewing_is_told_apart_from_a_refused_one() {
    local name
    for name in ended suspended file_ended; do
        license_verdict_is "check_${name}_status" 2 || return 1
    done
    for name in tampered foreign garbage elsewhere clock; do
        license_verdict_is "check_${name}_status" 1 || return 1
    done
}

a_key_of_the_old_format_checked_as_a_license_file_says_what_to_ask_for() {
    license_verdict_is check_old_format refused && license_said check-old_format 'old format'
}

a_machine_without_a_serial_binds_to_its_machine_id_and_says_so() {
    license_verdict_is check_machine_id accepted && license_said check-machine_id 'which a reinstall changes'
}

a_key_that_would_carry_curl_settings_is_refused() {
    license_verdict_is activate_injected refused && license_said activate-injected 'not a license key'
}

activating_binds_the_license_to_this_machine() {
    license_verdict_is activate_fresh activated && license_verdict_is activate_active activated \
        && license_verdict_is activated_mode 600 && license_verdict_is activated_checks yes
}

a_license_that_cannot_be_activated_here_says_why() {
    license_verdict_is activate_elsewhere refused && license_said activate-elsewhere 'activated on another machine' \
        && license_verdict_is activate_ended refused && license_said activate-ended 'ended on 2020-01-01' \
        && license_verdict_is activate_suspended refused && license_said activate-suspended 'is suspended' \
        && license_verdict_is activate_unknown refused && license_said activate-unknown 'no such license key' \
        && license_verdict_is activate_old_format refused && license_said activate-old_format 'old format'
}

a_license_naming_a_registry_hands_it_to_the_installer() {
    license_verdict_is registry registry.example.test && license_verdict_is token_given yes
}

the_license_key_and_its_token_never_come_out() {
    local work="$WORK_DIR/license" said
    license_verdicts >/dev/null
    said=$(cat "$work"/said-* 2>/dev/null)
    grep -qF "$LICENSE_TEST_TOKEN" <<< "$said" && { echo "the registry token came out of ut-license"; return 1; }
    grep -qE 'TEST-(FRESH|ACTIVE|REGISTRY|ELSEWHERE|ENDED|SUSPENDED|UNKNOWN)' <<< "$said" \
        && { echo "a license key came out of ut-license"; return 1; }
    grep -q 'SECRET_ON_A_COMMAND_LINE' "$work/keygen-requests" 2>/dev/null \
        && { echo "a license key or the token sat on a command line while ut-license asked Keygen"; return 1; }
    [[ -s "$work/lab/argv.log" ]] || { echo "no program ut-license ran wrote its arguments down"; return 1; }
    grep -qE "${LICENSE_TEST_TOKEN}|TEST-(FRESH|ACTIVE|REGISTRY|ELSEWHERE|ENDED|SUSPENDED|UNKNOWN)" "$work/lab/argv.log" \
        && { echo "a program ut-license ran was given a license key or the token:"; \
             grep -E "${LICENSE_TEST_TOKEN}|TEST-" "$work/lab/argv.log" | head -3; return 1; }
    grep -q 'licenses/actions/validate-key' "$work/keygen-requests" 2>/dev/null && return 0
    echo "the fake Keygen was never asked: $(tail -3 "$work/verdicts.err" 2>/dev/null)"
    return 1
}

the_shipped_key_is_the_one_licenses_are_signed_with() {
    local embedded versioned
    embedded=$("$REPO_ROOT/ut-license" --fingerprint)
    versioned="SHA256: $(openssl pkey -pubin -in "$REPO_ROOT/packaging/license.pub" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -r | cut -d' ' -f1)"
    [[ "$embedded" == "$versioned" ]] && return 0
    echo "ut-license carries ${embedded}, packaging/license.pub is ${versioned}"
    return 1
}

boot_unit() {
    docker run --rm -i -v "$REPO_ROOT":/src:ro "$BASH_IMAGE" bash -s 2>&1 <<'PROBE'
set -u
mkdir -p /fix /stub
cp /src/compose.yaml /fix/
printf 'UT_DOMAIN="box.example.com"\n' > /fix/.env
printf '#!/bin/sh\nexit 0\n' > /stub/docker
printf '#!/bin/sh\nexit 0\n' > /stub/systemctl
chmod +x /stub/docker /stub/systemctl
PATH=/stub:$PATH bash /src/setup-autostart.sh --install --dir /fix >/dev/null 2>&1
cat /etc/systemd/system/understandtech.service
PROBE
}

# The boot line is run as systemd would, against a license that ended yesterday:
# it has to say so, and it has to let the stack come up.
an_ended_license_is_said_at_boot_and_never_stops_the_stack() {
    local work="$WORK_DIR/license" line command said status
    license_verdicts >/dev/null

    line=$(grep '^ExecStartPre=.*ut-license' <<< "$(boot_unit)") \
        || { echo "the boot service does not check the license"; return 1; }
    [[ "$line" == ExecStartPre=-* ]] \
        || { echo "a failing license check would stop the boot: ${line}"; return 1; }
    command=${line#ExecStartPre=-}
    command=${command//\/etc\/understandtech\/machine.lic/\/w\/lab\/files\/ended.lic}
    command=${command//ut-license check/\/w\/lab\/ut-license check}
    command=${command#/bin/sh -c \'}
    command=${command%\'}
    said=$(docker run --rm --network none -v "$work":/w:ro "$(license_image)" sh -c "$command" 2>&1; echo "STATUS=$?")
    grep -q 'ended on' <<< "$said" \
        || { echo "nothing said the license ended: ${said}"; return 1; }
    grep -q 'STATUS=0' <<< "$said" && return 0
    echo "the boot line failed: ${said}"
    return 1
}

a_license_checks_with_no_network_at_all() {
    local work="$WORK_DIR/license" said
    license_verdicts >/dev/null
    said=$(docker run --rm --network none -v "$work":/w:ro "$(license_image)" \
        /w/lab/ut-license check /w/lab/files/valid.lic 2>&1)
    grep -q 'Licensed to Test Customer' <<< "$said" && return 0
    echo "with no network at all, ut-license said: ${said:-nothing}"
    return 1
}

# GitHub reports an unparseable workflow after the push that broke it, on the
# run that was supposed to do the work.
every_workflow_parses() {
    local verdict read_count
    # --entrypoint: this image runs yq, so a bare "sh -c" would arrive as
    # arguments to yq and read nothing at all.
    verdict=$(docker run --rm --entrypoint sh \
        -v "$REPO_ROOT/.github/workflows":/w:ro "$YQ_IMAGE" \
        -c 'n=0; for f in /w/*.yml; do [ -f "$f" ] || continue; n=$((n+1));
            yq eval "." "$f" >/dev/null 2>&1 || echo "broken:$f"; done; echo "count:$n"')

    if grep -q '^broken:' <<< "$verdict"; then
        echo "$verdict"; return 1
    fi
    # A missing directory is one docker creates empty, and a check that reads
    # nothing passes without reading anything.
    read_count=$(sed -n 's/^count://p' <<< "$verdict")
    [[ "${read_count:-0}" -ge 1 ]] && return 0
    echo "no workflow was read — verdict was: ${verdict:-<empty>}"
    return 1
}

# Pinning an action to a commit is what stops a tag being moved under us, and it
# is also what freezes the version for good. A channel GitHub cannot read fails
# silently: the pins simply never move, and nothing says so.
the_pinned_actions_have_a_way_to_move() {
    local declared
    declared=$(docker run --rm --entrypoint sh \
        -v "$REPO_ROOT/.github":/g:ro "$YQ_IMAGE" \
        -c 'yq eval ".updates[].package-ecosystem" /g/dependabot.yml 2>/dev/null')

    grep -qx 'github-actions' <<< "$declared" && return 0
    echo "nothing updates the pinned actions — dependabot.yml declared: ${declared:-<nothing>}"
    return 1
}

# Building the same bytes twice is only worth anything if the release asks for
# it: with the build time left free, what was signed can never be rebuilt.
the_release_fixes_the_date_it_builds_with() {
    grep -q 'SOURCE_DATE_EPOCH' "$REPO_ROOT/.github/workflows/release.yml" && return 0
    echo "release.yml lets dpkg-deb stamp the build time — the published package cannot be rebuilt"
    return 1
}

# ut-verify and release.pub travel beside the package they check, so our own key
# proves nothing to someone handed all three at once.
the_release_attests_what_it_built() {
    grep -q 'attest-build-provenance' "$REPO_ROOT/.github/workflows/release.yml" && return 0
    echo "nothing ties the package to this workflow except our own signature"
    return 1
}

pinning_report() {
    local probe="$WORK_DIR/pinning"
    mkdir -p "$probe/stub"
    printf '#!/bin/sh\necho sha256:%s\n' "$(printf '1%.0s' $(seq 64))" > "$probe/stub/docker"
    chmod +x "$probe/stub/docker"
    {
        printf 'LOOSE_IMAGE="registry.test/thing:1.2"\n'
        printf 'FIRM_IMAGE="registry.test/other:3@sha256:%s"\n' "$(printf '2%.0s' $(seq 64))"
    } > "$probe/release.env"
    PATH="$probe/stub:$PATH" RELEASE_ENV="$probe/release.env" \
        "$REPO_ROOT/packaging/pin-images.sh" >/dev/null 2>&1
    cat "$probe/release.env"
}

# A digest names the content, a tag names the version. Dropping the tag would
# make release.env unreadable to whoever has to say which version a box runs.
a_tag_gains_a_digest_without_losing_its_version() {
    local report
    report=$(pinning_report)
    grep -q "^LOOSE_IMAGE=\"registry.test/thing:1.2@sha256:1" <<< "$report" && return 0
    echo "the tag was not pinned, or the version was lost:"
    echo "$report"
    return 1
}

an_image_already_pinned_is_left_alone() {
    local report
    report=$(pinning_report)
    grep -q "^FIRM_IMAGE=\"registry.test/other:3@sha256:2\{64\}\"$" <<< "$report" && return 0
    echo "an image that already named its content was rewritten:"
    echo "$report"
    return 1
}

# A bill of materials listing fewer images than the stack runs is worse than
# none: what is missing from it reads as absent from the product.
a_release_names_every_image_it_ships() {
    local declared listed
    declared=$(grep -cE '^[A-Z_]*_IMAGE="' "$REPO_ROOT/release.env")
    listed=$("$REPO_ROOT/packaging/release-bom.sh" 9999.99.9 2>/dev/null | grep -c '"type": "container"')
    [[ "$declared" == "$listed" ]] && return 0
    echo "release.env declares ${declared} images, the bill of materials lists ${listed}"
    return 1
}

a_bill_of_materials_refuses_an_image_that_can_move() {
    local probe="$WORK_DIR/bom"
    mkdir -p "$probe"
    printf 'LOOSE_IMAGE="registry.test/thing:1.2"\n' > "$probe/release.env"
    RELEASE_ENV="$probe/release.env" "$REPO_ROOT/packaging/release-bom.sh" 9999.99.9 >/dev/null 2>&1 \
        || return 0
    echo "it described a tag as though it named one image"
    return 1
}

# actions/attest reads three fields and nothing else: bomFormat, specVersion and
# serialNumber. A document missing the third is refused as "unsupported format",
# which is how release v2026.09.5-rc3 stopped after building and signing.
a_bill_of_materials_carries_what_attestation_reads() {
    local bom
    bom=$("$REPO_ROOT/packaging/release-bom.sh" 9999.99.9 2>/dev/null)
    grep -q '"bomFormat"' <<< "$bom" \
        && grep -q '"specVersion"' <<< "$bom" \
        && grep -q '"serialNumber": "urn:uuid:[0-9a-f-]*"' <<< "$bom" && return 0
    echo "actions/attest would refuse this as an unsupported format:"
    head -6 <<< "$bom"
    return 1
}

# Two runs of the same release must produce the same document, or nobody can
# check the published one against the release it describes.
a_bill_of_materials_is_the_same_twice() {
    local once twice
    once=$("$REPO_ROOT/packaging/release-bom.sh" 9999.99.9 2>/dev/null)
    twice=$("$REPO_ROOT/packaging/release-bom.sh" 9999.99.9 2>/dev/null)
    [[ "$once" == "$twice" ]] && return 0
    echo "two runs of the same release produced different documents"
    return 1
}

the_release_publishes_what_it_is_made_of() {
    grep -q 'release-bom.sh' "$REPO_ROOT/.github/workflows/release.yml" && return 0
    echo "the release ships no bill of materials"
    return 1
}

names_are_unchanged_by_default() {
    local rendered
    rendered=$(compose_config -f compose.yaml)
    grep -q 'container_name: ut-caddy' <<< "$rendered" \
        && grep -q 'name: ut-mongodb-data' <<< "$rendered" \
        && grep -q 'name: ut-backend-network' <<< "$rendered" \
        && grep -q '/var/lib/understandtech' <<< "$rendered"
}

# A compute node is the one role whose engine other machines reach, so it is the
# one where the engine may only be reached through the surface that checks a key.
the_compute_engine_is_reached_only_through_its_key() {
    local config engine
    if ( cd "$WORK_DIR" && VLLM_API_KEY= docker compose -f compose.yaml -f compose.compute.yaml config >/dev/null 2>&1 ); then
        echo "a compute node rendered without an engine key"
        return 1
    fi
    config=$(VLLM_API_KEY=k compose_config -f compose.yaml -f compose.compute.yaml)
    grep -q 'caddy/inference-surface.caddy' <<< "$config" \
        || { echo "the compute node's Caddy does not mount the inference surface"; return 1; }
    grep -q 'published: "8444"' <<< "$config" \
        || { echo "the compute node publishes no inference surface"; return 1; }
    engine=$(COMPOSE_PROFILES=nim VLLM_API_KEY=k compose_config -f compose.yaml -f compose.compute.yaml \
        | awk '/^  nim-llm:/ { on = 1; next } on && /^  [a-z]/ { on = 0 } on')
    grep -q '^    ports:' <<< "$engine" || return 0
    echo "the engine publishes a port of its own on a compute node, which checks no key:"
    grep -A6 'ports:' <<< "$engine"
    return 1
}

# SSL_CERT_FILE replaces a Python service's trust store, so each service that
# calls the engine must get the node's root, and must keep the public ones.
every_engine_caller_trusts_the_compute_node() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local config service missing=""
    config=$( cd "$WORK_DIR" && UT_INFERENCE_CA_BUNDLE=/etc/understandtech/inference-ca-bundle.pem \
        docker compose -f compose.yaml -f compose.no-gpu.yaml -f compose.remote-inference.yaml config --format json 2>/dev/null )
    for service in $(jq -r '.services | to_entries[] | select(.value.environment.VLLM_LLM_BASE_URL != null) | .key' <<< "$config"); do
        jq -e --arg s "$service" '.services[$s]
            | .environment.SSL_CERT_FILE == "/etc/understandtech/inference-ca-bundle.pem"
              and .environment.REQUESTS_CA_BUNDLE == "/etc/understandtech/inference-ca-bundle.pem"
              and any(.volumes[]?; .source == "/etc/understandtech/inference-ca-bundle.pem")' <<< "$config" >/dev/null \
            || missing+=" ${service}"
    done
    [[ -n "$config" && -z "$missing" ]] && return 0
    echo "these services call the engine without trusting the compute node:${missing:- (nothing rendered)}"
    return 1
}

VLLM_TEST_ARGS='--trust-remote-code --max-model-len 262144 --override-generation-config {"temperature":0.2,"top_p":0.9} --speculative-config {"method":"dflash","num_speculative_tokens":7}'

rendered_vllm_engine() {
    ( cd "$WORK_DIR" && COMPOSE_PROFILES=nim VLLM_ENGINE_IMAGE="registry.example/vllm@sha256:$(printf '%064d' 0)" \
        VLLM_ENGINE_MODEL=org/model VLLM_ENGINE_ARGS="$VLLM_TEST_ARGS" \
        docker compose -f compose.yaml -f compose.engine-vllm.yaml config --format json 2>/dev/null )
}

# The engine keeps everything a box reads it by: name, GPU, cache, and no port of its own.
a_model_on_vllm_runs_in_place_of_nim() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local engine
    engine=$(rendered_vllm_engine | jq '.services["nim-llm"]')
    jq -e --arg image "registry.example/vllm@sha256:$(printf '%064d' 0)" '
        .image == $image
        and (.entrypoint | join(" ") | test("vllm serve"))
        and (.healthcheck.test | join(" ") | test("localhost:8000/health"))
        and any(.deploy.resources.reservations.devices[]?; .driver == "nvidia")
        and ((.ports // []) | length) == 0
        and any(.volumes[]?; .target == "/opt/nim/.cache")' <<< "$engine" >/dev/null && return 0
    echo "the vLLM engine renders as: $(jq -c '{image, entrypoint, healthcheck: .healthcheck.test, ports}' <<< "$engine" 2>/dev/null)"
    return 1
}

# vLLM reads JSON straight from its arguments, so each one must reach it whole.
# A stub vllm prints what it was given, one argument per line.
each_argument_reaches_vllm_intact() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local script received expected
    script=$(rendered_vllm_engine | jq -r '.services["nim-llm"].entrypoint[2]' | sed 's/\$\$/$/g')
    received=$(docker run --rm -e VLLM_ENGINE_MODEL=org/model -e VLLM_ENGINE_ARGS="$VLLM_TEST_ARGS" \
        --entrypoint /bin/sh "$ALPINE_IMAGE" -c '
            mkdir -p /stub && printf "#!/bin/sh\nfor a in \"\$@\"; do echo \"\$a\"; done\n" > /stub/vllm && chmod +x /stub/vllm
            PATH=/stub:$PATH; '"$script" 2>&1)
    expected=$(printf '%s\n' serve org/model --served-model-name org/model --host 0.0.0.0 --port 8000 \
        --trust-remote-code --max-model-len 262144 \
        --override-generation-config '{"temperature":0.2,"top_p":0.9}' \
        --speculative-config '{"method":"dflash","num_speculative_tokens":7}')
    [[ "$received" == "$expected" ]] && return 0
    echo "vllm received:"; echo "$received"
    return 1
}

# Docker publishes no port for a container whose networks are all internal: such
# a declaration reads as a way in and gives none.
no_port_is_declared_where_docker_publishes_none() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local files config dead=""
    for files in "compose.yaml" "compose.yaml compose.appbuilder.yaml" "compose.yaml compose.compute.yaml"; do
        config=$( cd "$WORK_DIR" && COMPOSE_PROFILES=nim VLLM_API_KEY=k \
            docker compose $(printf -- '-f %s ' $files) config --format json 2>/dev/null )
        [[ -n "$config" ]] || { echo "nothing rendered from ${files}"; return 1; }
        dead+=$(jq -r --arg files "$files" '.networks as $n | .services | to_entries[]
            | select((.value.ports // []) | length > 0)
            | select(.value.network_mode == null)
            | select([(.value.networks // {"default": null}) | keys[] | ($n[.] // {}).internal // false] | all)
            | "\(.key), from \($files)"' <<< "$config")$'\n'
    done
    [[ -z "${dead//$'\n'/}" ]] && return 0
    echo "declared and never published:"; printf '%s' "$dead" | grep .
    return 1
}

overrides_isolate_every_resource() {
    local rendered stray
    rendered=$( cd "$WORK_DIR" && \
        COMPOSE_PROJECT_NAME=isolated RESOURCE_PREFIX=isolated CONTAINER_PREFIX=isolated \
        DATA_ROOT=/var/lib/isolated \
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

the_https_authority_is_where_the_backup_looks() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local config mounted
    config=$( cd "$WORK_DIR" && docker compose -f compose.yaml config --format json 2>/dev/null )
    mounted=$(jq -r '.services["files-backup"].volumes[]? | select(.source == "caddy-data") | .target' <<< "$config")
    [[ -n "$mounted" ]] || { echo "files-backup does not mount caddy-data"; return 1; }
    grep -q "BACKUP_HTTPS_AUTHORITY:-${mounted}/caddy/pki/authorities/local}" "$REPO_ROOT/backup-files.sh" \
        || { echo "backup-files.sh does not look under ${mounted}"; return 1; }
}

the_https_authority_is_backed_up_and_restores_identically() {
    local repo="$WORK_DIR/https-repo" caddy="$WORK_DIR/https-caddy" source="$WORK_DIR/https-source" out="$WORK_DIR/https-out"
    local authority="$caddy/caddy/pki/authorities/local"
    mkdir -p "$authority" "$source/app-data" "$out"
    head -c 800 /dev/urandom > "$authority/root.crt"
    head -c 300 /dev/urandom > "$authority/root.key"
    echo "metadata" > "$source/app-data/notes.txt"

    docker run --rm -v "$source":/data:ro -v "$caddy":/caddy:ro -v "$repo":/backup \
        -v "$REPO_ROOT/backup-files.sh":/usr/local/bin/backup-files:ro \
        -e RESTIC_REPOSITORY=/backup/restic -e RESTIC_PASSWORD=capability-test \
        --entrypoint /usr/local/bin/backup-files "$RESTIC_IMAGE" >/dev/null 2>&1 || { echo "the backup failed"; return 1; }
    docker run --rm -v "$repo":/backup -v "$out":/out \
        -e RESTIC_REPOSITORY=/backup/restic -e RESTIC_PASSWORD=capability-test \
        "$RESTIC_IMAGE" restore latest --target /out >/dev/null 2>&1 || { echo "the restore failed"; return 1; }
    docker run --rm -v "$caddy":/before:ro -v "$out":/after:ro "$ALPINE_IMAGE" \
        diff -r /before/caddy/pki/authorities/local /after/caddy/caddy/pki/authorities/local >/dev/null 2>&1 \
        || { echo "the authority did not come back as it was"; return 1; }
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
            -v "$REPO_ROOT/caddy/no-inference-surface.caddy":/etc/caddy/inference.caddy:ro \
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
    docker run --rm -v "$work":/w "$ALPINE_IMAGE" sh -c 'rm -rf /w/ca' >/dev/null 2>&1
    return "$verdict"
}

# Both directions of the same guard. A run that reaches the authority with an
# impossible name burns a rate limit and reports something obscure; refusing
# first costs nothing and names the reason.
public_certificates_are_refused_where_impossible() {
    local probe="$WORK_DIR/acme-local" output
    mkdir -p "$probe"
    cat > "$probe/.env" <<'EOF'
UT_DOMAIN="understand.local"
UT_ACME_EMAIL="ops@example.com"
UT_ACME_DNS_PROVIDER="cloudflare"
UT_ACME_DNS_ENV="CF_DNS_API_TOKEN=probe"
EOF
    output=$( UT_INSTALL_DIR="$probe" "$REPO_ROOT/ut-certificate" --check 2>&1 ) && {
        echo "a .local domain was accepted"; return 1; }
    grep -q 'no public authority issues' <<< "$output"
}

public_certificates_need_their_configuration() {
    local probe="$WORK_DIR/acme-real" output
    mkdir -p "$probe"
    printf 'UT_DOMAIN="box.example.com"\n' > "$probe/.env"
    output=$( UT_INSTALL_DIR="$probe" "$REPO_ROOT/ut-certificate" --check 2>&1 ) && {
        echo "an empty configuration was accepted"; return 1; }
    grep -q 'UT_ACME_DNS_PROVIDER is not set' <<< "$output" \
        && grep -q 'builder.box.example.com' <<< "$output" \
        && grep -q '\*.apps.box.example.com' <<< "$output"
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

# Restic and the script against an S3 endpoint, on a network this check creates
# itself: it says nothing about whether the deployed service can reach one.
the_backup_round_trips_through_an_s3_endpoint() {
    local run=cap-offsite-$$ net store bucket=appliance-backups
    local key=capability-key secret=capability-secret-value
    local work="$WORK_DIR/offsite" source="$WORK_DIR/offsite/data" restored="$WORK_DIR/offsite/out"
    net=$run-net; store=$run-store
    mkdir -p "$source/app-data" "$source/ca/certs" "$restored"

    head -c 200000 /dev/urandom > "$source/app-data/document.bin"
    echo "customer notes" > "$source/app-data/notes.txt"
    head -c 2000 /dev/urandom > "$source/ca/certs/root_ca.crt"

    docker network create "$net" >/dev/null 2>&1
    docker run -d --name "$store" --network "$net" --tmpfs /data \
        "$OBJECT_STORE_IMAGE" serve s3 /data --auth-key "$key,$secret" --addr :9000 >/dev/null 2>&1

    # Answering on HTTP is the readiness signal, not the container running: the
    # process is up well before it serves. Asking here also bounds the failure —
    # restic retries an unreachable endpoint for minutes, and an unreachable
    # endpoint is what a failure of this check looks like.
    local attempt ready=1
    for attempt in $(seq 1 20); do
        if [[ "$(docker run --rm --network "$net" "$CURL_IMAGE" -s -m 5 -o /dev/null -w '%{http_code}' \
            "http://${OFFSITE_ENDPOINT:-$store}:9000/" 2>/dev/null)" =~ ^[1-5][0-9][0-9]$ ]]; then
            ready=0; break
        fi
        sleep 2
    done
    if (( ready )); then
        echo "the destination never answered"
        docker rm -f "$store" >/dev/null 2>&1
        docker network rm "$net" >/dev/null 2>&1
        return 1
    fi
    docker exec "$store" mkdir -p "/data/$bucket" >/dev/null 2>&1

    # Bounded, because restic retries an unreachable endpoint for a long time
    # and an unreachable endpoint is exactly what a failure of this check looks
    # like. Unbounded, one broken destination stalls the whole run.
    offsite() {
        docker run --rm --network "$net" -v "$source":/data:ro -v "$restored":/out \
            -v "$REPO_ROOT/backup-files.sh":/usr/local/bin/backup-files:ro \
            -e RESTIC_REPOSITORY="s3:http://${OFFSITE_ENDPOINT:-$store}:9000/$bucket" \
            -e RESTIC_PASSWORD=capability-test \
            -e AWS_ACCESS_KEY_ID="$key" -e AWS_SECRET_ACCESS_KEY="$secret" \
            --entrypoint sh "$RESTIC_IMAGE" -c "timeout 90 $1"
    }

    local verdict=1 before after
    before=$( cd "$source" && find . -type f | sort | while read -r f; do
        printf '%s %s\n' "$f" "$(cksum < "$f" | cut -d' ' -f1)"; done | cksum | cut -d' ' -f1 )

    if offsite /usr/local/bin/backup-files >/dev/null 2>&1 \
        && offsite "restic restore latest --target /out" >/dev/null 2>&1; then
        after=$( cd "$restored/data" && find . -type f | sort | while read -r f; do
            printf '%s %s\n' "$f" "$(cksum < "$f" | cut -d' ' -f1)"; done | cksum | cut -d' ' -f1 )
        [[ "$before" == "$after" && -f "$restored/data/ca/certs/root_ca.crt" ]] && verdict=0
    fi

    docker rm -f "$store" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
    return "$verdict"
}

the_database_leaves_the_machine_with_the_files() {
    local run=cap-dump-offsite-$$ net store bucket=appliance-dumps
    local key=capability-key secret=capability-secret-value
    local source="$WORK_DIR/dump-offsite/data" dumps="$WORK_DIR/dump-offsite/backup"
    local restored="$WORK_DIR/dump-offsite/out"
    local archive=mongo_ut-db_2026-09-16.archive.gz
    net=$run-net; store=$run-store
    mkdir -p "$source/app-data" "$dumps" "$restored"

    echo "customer notes" > "$source/app-data/notes.txt"
    head -c 50000 /dev/urandom > "$dumps/$archive"

    docker network create "$net" >/dev/null 2>&1
    docker run -d --name "$store" --network "$net" --tmpfs /data \
        "$OBJECT_STORE_IMAGE" serve s3 /data --auth-key "$key,$secret" --addr :9000 >/dev/null 2>&1

    local attempt ready=1
    for attempt in $(seq 1 20); do
        if [[ "$(docker run --rm --network "$net" "$CURL_IMAGE" -s -m 5 -o /dev/null -w '%{http_code}' \
            "http://${OFFSITE_ENDPOINT:-$store}:9000/" 2>/dev/null)" =~ ^[1-5][0-9][0-9]$ ]]; then
            ready=0; break
        fi
        sleep 2
    done
    if (( ready )); then
        echo "the destination never answered"
        docker rm -f "$store" >/dev/null 2>&1
        docker network rm "$net" >/dev/null 2>&1
        return 1
    fi
    docker exec "$store" mkdir -p "/data/$bucket" >/dev/null 2>&1

    # The dump volume is mounted where the stack mounts it, so this exercises
    # backup-files.sh as it runs on a box rather than a rearranged copy of it.
    offsite_with_dumps() {
        docker run --rm --network "$net" -v "$source":/data:ro -v "$dumps":/backup \
            -v "$restored":/out \
            -v "$REPO_ROOT/backup-files.sh":/usr/local/bin/backup-files:ro \
            -e RESTIC_REPOSITORY="s3:http://${OFFSITE_ENDPOINT:-$store}:9000/$bucket" \
            -e RESTIC_PASSWORD=capability-test \
            -e AWS_ACCESS_KEY_ID="$key" -e AWS_SECRET_ACCESS_KEY="$secret" \
            --entrypoint sh "$RESTIC_IMAGE" -c "timeout 90 $1"
    }

    local verdict=1
    if offsite_with_dumps /usr/local/bin/backup-files >/dev/null 2>&1 \
        && offsite_with_dumps "restic restore latest --target /out" >/dev/null 2>&1; then
        [[ -f "$restored/backup/$archive" && -f "$restored/data/app-data/notes.txt" ]] && verdict=0
    fi

    if (( verdict )); then
        echo "the database dump is not in what left the machine"
    fi

    docker rm -f "$store" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
    return "$verdict"
}

# A network declared internal has no gateway: a container that sits only on
# such networks reaches nothing beyond the machine.
the_backup_has_no_way_off_the_machine() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local config mode open
    config=$( cd "$WORK_DIR" && docker compose "$@" config --format json 2>/dev/null )
    [[ -n "$config" ]] || { echo "the stack does not render"; return 1; }
    mode=$(jq -r '.services["files-backup"].network_mode // empty' <<< "$config")
    [[ -z "$mode" ]] || { echo "files-backup runs with network_mode $mode"; return 1; }
    open=$(jq -r '.networks as $declared
        | .services["files-backup"].networks // {"default": null}
        | keys[]
        | select($declared[.].internal != true)' <<< "$config")
    [[ -z "$open" ]] || { echo "files-backup sits on a network with a way out: $(tr '\n' ' ' <<< "$open")"; return 1; }
}

rendered_backup_destination() {
    local destination=$1
    ( cd "$WORK_DIR" && BACKUP_FILES_DESTINATION="$destination" \
        docker compose -f compose.yaml -f compose.backup-mount.yaml config --format json 2>/dev/null )
}

backup_into() {
    local source=$1 destination=$2 target=$3 repository=$4 marker=$5
    docker run --rm -v "$source":/data:ro -v "$destination":"$target" \
        -v "$REPO_ROOT/backup-files.sh":/usr/local/bin/backup-files:ro \
        -e RESTIC_REPOSITORY="$repository" -e RESTIC_PASSWORD=capability-test \
        -e BACKUP_DESTINATION_MARKER="$marker" \
        --entrypoint /usr/local/bin/backup-files "$RESTIC_IMAGE" 2>&1
}

the_backup_lands_on_the_mounted_destination() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local destination="$WORK_DIR/mounted" source="$WORK_DIR/mounted-source" config target repository marker
    mkdir -p "$destination" "$source/app-data"
    echo "customer notes" > "$source/app-data/notes.txt"
    config=$(rendered_backup_destination "$destination")
    [[ -n "$config" ]] || { echo "the stack does not render with a destination"; return 1; }
    target=$(jq -r --arg d "$destination" '.services["files-backup"].volumes[]? | select(.source == $d) | .target' <<< "$config")
    repository=$(jq -r '.services["files-backup"].environment.RESTIC_REPOSITORY' <<< "$config")
    marker=$(jq -r '.services["files-backup"].environment.BACKUP_DESTINATION_MARKER // empty' <<< "$config")
    [[ -n "$target" && "$repository" == "$target"/* ]] || { echo "the repository ${repository} is not on the destination"; return 1; }
    [[ -n "$marker" ]] && touch "$destination/${marker#"$target"/}"

    backup_into "$source" "$destination" "$target" "$repository" "$marker" >/dev/null || { echo "the backup failed"; return 1; }

    docker run --rm -v "$destination":/only-the-destination:ro \
        -e RESTIC_REPOSITORY="/only-the-destination/${repository#"$target"/}" -e RESTIC_PASSWORD=capability-test \
        "$RESTIC_IMAGE" snapshots --no-lock --json 2>/dev/null | grep -q '"time"' \
        || { echo "nothing readable on the destination alone"; return 1; }
}

# An unmounted destination is an empty directory on the local disk: a backup
# written there dies with the machine it was meant to outlive.
the_backup_refuses_a_destination_that_is_not_mounted() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local destination="$WORK_DIR/unmounted" source="$WORK_DIR/unmounted-source" config target repository marker output
    mkdir -p "$destination" "$source/app-data"
    echo "customer notes" > "$source/app-data/notes.txt"
    config=$(rendered_backup_destination "$destination")
    [[ -n "$config" ]] || { echo "the stack does not render with a destination"; return 1; }
    target=$(jq -r --arg d "$destination" '.services["files-backup"].volumes[]? | select(.source == $d) | .target' <<< "$config")
    repository=$(jq -r '.services["files-backup"].environment.RESTIC_REPOSITORY' <<< "$config")
    marker=$(jq -r '.services["files-backup"].environment.BACKUP_DESTINATION_MARKER // empty' <<< "$config")
    [[ -n "$target" && -n "$marker" ]] || { echo "the destination carries no marker to check"; return 1; }

    output=$(backup_into "$source" "$destination" "$target" "$repository" "$marker") \
        && { echo "the backup went ahead"; return 1; }
    [[ -z "$(ls -A "$destination")" ]] || { echo "written anyway: $(ls -A "$destination" | tr '\n' ' ')"; return 1; }
    grep -q 'not mounted' <<< "$output" || { echo "$output"; return 1; }
}

the_network_destination_gets_a_way_out_of_its_own() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local config open sharing
    config=$( cd "$WORK_DIR" && docker compose "$@" config --format json 2>/dev/null )
    [[ -n "$config" ]] || { echo "the stack does not render with a network destination"; return 1; }
    open=$(jq -r '.networks as $declared
        | .services["files-backup"].networks // {} | keys[]
        | select($declared[.].internal != true)' <<< "$config")
    [[ $(grep -c . <<< "$open") == 1 ]] || { echo "networks with a way out: $(tr '\n' ' ' <<< "$open")"; return 1; }
    sharing=$(jq -r --arg net "$open" '.services | to_entries[]
        | select(.key != "files-backup" and ((.value.networks // {}) | has($net))) | .key' <<< "$config")
    [[ -z "$sharing" ]] || { echo "${open} is shared with: $(tr '\n' ' ' <<< "$sharing")"; return 1; }
}

backup_over_sftp() {
    local source=$1 ssh_dir=$2 repository=$3 network=$4 config target
    config=$( cd "$WORK_DIR" && BACKUP_FILES_REPOSITORY="$repository" BACKUP_FILES_SSH_DIR="$ssh_dir" \
        docker compose -f compose.yaml -f compose.backup-network.yaml config --format json 2>/dev/null )
    target=$(jq -r --arg d "$ssh_dir" '.services["files-backup"].volumes[]? | select(.source == $d) | .target' <<< "$config")
    [[ -n "$target" ]] || { echo "the SSH directory is not handed to files-backup"; return 1; }
    docker run --rm --network "$network" -v "$source":/data:ro -v "$ssh_dir":"$target":ro \
        -v "$REPO_ROOT/backup-files.sh":/usr/local/bin/backup-files:ro \
        -e RESTIC_REPOSITORY="$repository" -e RESTIC_PASSWORD=capability-test \
        --entrypoint sh "$RESTIC_IMAGE" -c "timeout 90 /usr/local/bin/backup-files" 2>&1
}

# Written through a container: on Docker Desktop and OrbStack, a file rewritten
# from the host can reach the next container as it was before the rewrite.
pin_host_keys() {
    docker run --rm -i -v "$1":/k "$ALPINE_IMAGE" sh -c 'cat > /k/known_hosts'
}

# The image answers ssh-keyscan while it is still creating its account, and a
# session opened then is closed on it: "server unexpectedly closed connection".
# Ready means an SFTP session opens with the test's key. Bounded by the clock,
# as mongo_ready is, since a runner pulling the image takes most of a minute.
sftp_server_ready() {
    local server=$1 net=$2 ssh_dir=$3 deadline=$((SECONDS + 150)) scanned
    while (( SECONDS < deadline )); do
        [[ "$(docker inspect -f '{{.State.Running}}' "$server" 2>/dev/null)" == true ]] || { sleep 2; continue; }
        scanned=$(docker run --rm --network "$net" --entrypoint ssh-keyscan "$RESTIC_IMAGE" \
            -p 2222 -t ed25519 "$server" 2>/dev/null)
        if [[ -n "$scanned" ]] && echo bye | docker run --rm -i --network "$net" -v "$ssh_dir":/k:ro --entrypoint sftp "$RESTIC_IMAGE" \
                -b - -P 2222 -i /k/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                "backup@$server" >/dev/null 2>&1; then
            printf '%s\n' "$scanned"
            return 0
        fi
        sleep 2
    done
    return 1
}

the_sftp_destination_has_to_prove_who_it_is() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local run=cap-sftp-$$ net server ssh_dir="$WORK_DIR/sftp-ssh" source="$WORK_DIR/sftp-source" scanned="" attempt output verdict=1
    local repository
    net=$run-net; server=$run-server
    repository="sftp://backup@${server}:2222/backups"
    mkdir -p "$ssh_dir" "$source/app-data"
    echo "customer notes" > "$source/app-data/notes.txt"

    docker network create "$net" >/dev/null 2>&1
    docker run --rm -v "$ssh_dir":/k --entrypoint ssh-keygen "$RESTIC_IMAGE" \
        -q -t ed25519 -N '' -f /k/id_ed25519 -C capability >/dev/null 2>&1
    docker run --rm -v "$WORK_DIR":/w --entrypoint ssh-keygen "$RESTIC_IMAGE" \
        -q -t ed25519 -N '' -f /w/impostor -C impostor >/dev/null 2>&1
    docker run -d --name "$server" --network "$net" -e USER_NAME=backup \
        -e PUBLIC_KEY="$(cat "$ssh_dir/id_ed25519.pub")" "$SFTP_SERVER_IMAGE" >/dev/null 2>&1

    scanned=$(sftp_server_ready "$server" "$net" "$ssh_dir")

    if [[ -n "$scanned" ]]; then
        printf '[%s]:2222 %s\n' "$server" "$(cut -d' ' -f1,2 "$WORK_DIR/impostor.pub")" | pin_host_keys "$ssh_dir"
        if output=$(backup_over_sftp "$source" "$ssh_dir" "$repository" "$net"); then
            echo "a host whose key was not the pinned one was trusted"
        elif ! grep -qE 'Host key verification failed|HOST IDENTIFICATION HAS CHANGED' <<< "$output"; then
            echo "$output"
        else
            printf '%s\n' "$scanned" | pin_host_keys "$ssh_dir"
            output=$(backup_over_sftp "$source" "$ssh_dir" "$repository" "$net") && verdict=0 \
                || echo "the pinned host was refused: $(tail -3 <<< "$output")"
        fi
    else
        echo "the SFTP server never opened a session: $(docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}}' "$server" 2>&1); $(docker logs "$server" 2>&1 | tail -3 | tr '\n' ' ')"
    fi

    docker rm -f "$server" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
    return "$verdict"
}

an_unreachable_destination_is_named() {
    local output
    output=$(docker run --rm -v "$REPO_ROOT/backup-files.sh":/usr/local/bin/backup-files:ro \
        -e RESTIC_REPOSITORY='sftp:nobody@127.0.0.1:/appliance' -e RESTIC_PASSWORD=capability-test \
        --entrypoint /usr/local/bin/backup-files "$RESTIC_IMAGE" 2>&1) && { echo "the backup reported success"; return 1; }
    grep -q 'cannot reach the repository at sftp:nobody@127.0.0.1:/appliance' <<< "$output" || { echo "$output"; return 1; }
}

a_password_that_does_not_open_the_repository_is_named() {
    local repo="$WORK_DIR/locked-repository" output
    mkdir -p "$repo"
    docker run --rm -v "$repo":/r -e RESTIC_REPOSITORY=/r/restic -e RESTIC_PASSWORD=the-old-machine \
        "$RESTIC_IMAGE" init >/dev/null 2>&1 || { echo "no repository to test against"; return 1; }
    output=$(docker run --rm -v "$repo":/r -v "$REPO_ROOT/backup-files.sh":/usr/local/bin/backup-files:ro \
        -e RESTIC_REPOSITORY=/r/restic -e RESTIC_PASSWORD=this-machine \
        --entrypoint /usr/local/bin/backup-files "$RESTIC_IMAGE" 2>&1) && { echo "the backup reported success"; return 1; }
    grep -q 'BACKUP_FILES_PASSWORD does not open the repository at /r/restic' <<< "$output" || { echo "$output"; return 1; }
}

# The image starts mongod once to create the root account, stops it, and starts
# it again: a ping answered during the first start is answered by a server
# about to go away.
#
# Bounded by the clock rather than by a count of tries: on a loaded x86 runner
# each try is several seconds of mongosh, and sixty of them ran out while two
# servers were still starting. A server that died is not waited for.
mongo_ready() {
    local node=$1 user=$2 password=$3 started=$SECONDS deadline=$((SECONDS + 180))
    while (( SECONDS < deadline )); do
        [[ "$(docker inspect -f '{{.State.Running}}' "$node" 2>/dev/null)" == true ]] || break
        docker logs "$node" 2>&1 | grep -q 'init process complete' \
            && docker exec "$node" mongosh --quiet -u "$user" -p "$password" --authenticationDatabase admin \
                --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -qx 1 && return 0
        sleep 1
    done
    echo "$node never came up: $(docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' "$node" 2>&1), after $((SECONDS - started))s"
    docker logs --tail 5 "$node" 2>&1 | sed 's/^/    /'
    return 1
}

# A whole-server dump carries the admin database. Restored whole on a machine
# installed afresh, it brings back the accounts of the machine it came from, and
# every service of this one is locked out. The flags are the guide's own.
the_guide_s_restore_keeps_this_machine_s_accounts() {
    local run=cap-elsewhere-$$ net source target count exclusion=()
    net=$run-net; source=$run-source; target=$run-target
    grep -qF -- "--nsExclude 'admin.*'" "$REPO_ROOT/docs/restore.md" && exclusion=(--nsExclude 'admin.*')

    docker network create "$net" >/dev/null 2>&1
    docker run -d --name "$source" --network "$net" -e MONGO_INITDB_ROOT_USERNAME=elsewhere \
        -e MONGO_INITDB_ROOT_PASSWORD=elsewhere-password "$MONGODB_IMAGE" >/dev/null 2>&1
    docker run -d --name "$target" --network "$net" -e MONGO_INITDB_ROOT_USERNAME=here \
        -e MONGO_INITDB_ROOT_PASSWORD=here-password "$MONGODB_IMAGE" >/dev/null 2>&1

    if mongo_ready "$source" elsewhere elsewhere-password && mongo_ready "$target" here here-password; then
        docker exec "$source" mongosh --quiet -u elsewhere -p elsewhere-password --authenticationDatabase admin \
            --eval 'db.getSiblingDB("ut-db").documents.insertMany([{n: 1}, {n: 2}, {n: 3}])' >/dev/null 2>&1
        docker exec "$source" mongodump --quiet --gzip --archive=/tmp/elsewhere.gz \
            -u elsewhere -p elsewhere-password --authenticationDatabase admin >/dev/null 2>&1
        docker cp "$source:/tmp/elsewhere.gz" "$WORK_DIR/elsewhere.gz" >/dev/null 2>&1
        docker cp "$WORK_DIR/elsewhere.gz" "$target:/tmp/elsewhere.gz" >/dev/null 2>&1
        docker exec "$target" mongorestore --quiet --gzip --archive=/tmp/elsewhere.gz --drop \
            ${exclusion[@]+"${exclusion[@]}"} -u here -p here-password --authenticationDatabase admin >/dev/null 2>&1
        count=$(docker exec "$target" mongosh --quiet -u here -p here-password --authenticationDatabase admin \
            --eval 'db.getSiblingDB("ut-db").documents.countDocuments()' 2>&1 | tail -1)
    fi

    docker rm -f "$source" "$target" >/dev/null 2>&1
    docker network rm "$net" >/dev/null 2>&1
    [[ "${count:-}" == 3 ]] || { echo "this machine's account after the restore: ${count:-nothing}"; return 1; }
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
capability "the App Builder renders on a machine without a GPU, and still runs there" \
    app_builder_runs_without_a_gpu
capability "the control-plane role leaves out the inference engines" \
    omits_service nim-llm -f compose.yaml
capability "a machine that runs an engine records its load" \
    with_profiles nim lists_service metrics -f compose.yaml
capability "a machine without a GPU still records what its gateway and front door served" \
    lists_service metrics -f compose.yaml -f compose.no-gpu.yaml

group "Machine identity"
capability "the appliance runs its own certificate authority" \
    lists_service step-ca -f compose.yaml
capability "its root sits where the file backup looks" \
    the_authority_root_is_where_the_backup_looks
capability "the machine-facing surface takes its certificate from that authority" \
    the_machine_surface_uses_the_local_authority
capability "it does so whatever the customer chose for the public one" \
    the_machine_surface_survives_every_ingress_mode

if [[ -x "$REPO_ROOT/ut-certificate" ]]; then
    group "Public certificate"
    capability "a name no authority can certify is refused before anything is asked" \
        public_certificates_are_refused_where_impossible
    capability "an incomplete configuration is named, with every hostname it would request" \
        public_certificates_need_their_configuration
fi
capability "and it is really served by it, not just configured to be" \
    the_machine_surface_is_really_served_by_the_authority

if [[ -f "$REPO_ROOT/setup-autostart.sh" ]]; then
    group "Name resolution"
    capability "a real domain installs no mDNS publisher and asks for no Avahi" \
        a_real_domain_installs_no_mdns_publisher
    capability "a .local domain still publishes its names over mDNS" \
        a_local_domain_publishes_over_mdns
    capability "a compute node on .local publishes none of the platform's names" \
        a_compute_node_publishes_none_of_the_platform_s_names
    capability "a compute node asks for no DNS record but its inference name" \
        a_compute_node_asks_only_for_its_inference_name
    capability "moving off .local withdraws a publisher installed earlier" \
        moving_off_local_withdraws_the_publisher
fi

if grep -q 'step_images_from_a_folder' "$REPO_ROOT/ut-install"; then
    group "A box with no network"
    capability "images from a prepared folder start under the digest the release names, offline" \
        images_from_a_folder_start_under_their_digest
    capability "a folder holding an image the release does not name is refused" \
        a_folder_image_the_release_does_not_name_is_refused
    capability "a folder whose tool is not the one the release names is refused" \
        a_tool_the_release_does_not_name_is_refused
    capability "ut-get prepares with the tools ut-install loads with" \
        the_folder_tools_are_those_ut_get_carries
fi

if [[ -x "$REPO_ROOT/ut-install" ]]; then
    capability "an address given up front is taken as it is" \
        an_address_given_up_front_is_taken_as_it_is
    capability "an unattended install falls back to the mDNS name, and says so" \
        an_unattended_install_falls_back_and_says_so
    capability "an address the machine already answers on is never replaced by the fallback" \
        an_address_already_configured_is_kept
    capability "the preflight resolves the address in use, not the fallback" \
        the_preflight_checks_the_address_in_use
    capability "the platform is handed back while the models are still loading" \
        the_platform_is_ready_while_inference_still_loads
    capability "a control plane service still starting is waited for" \
        a_control_plane_service_is_still_waited_for
    capability "a service that declares no role is waited for" \
        a_service_without_a_role_is_waited_for
    capability "an inference engine that failed is not reported as a success" \
        an_inference_engine_that_failed_is_not_a_success
    capability "the wait names what is late, not just how many" \
        the_wait_names_what_is_late
    capability "a backup that does not work yet does not hold the install back, and is named" \
        a_backup_that_does_not_work_does_not_hold_the_install_back
    capability "the download says each image as it lands, out of how many and since when" \
        the_pull_says_each_image_as_it_lands
    capability "a download that fails still stops the install" \
        a_pull_that_fails_still_stops_the_install
    capability "a project Compose refuses is named, not only the pull that failed" \
        a_project_compose_refuses_is_named
    capability "a Compose without JSON progress downloads as before" \
        a_compose_without_json_progress_pulls_as_before
    capability "the last screen says how long it took, where to go, and what is still loading" \
        the_last_screen_says_how_long_where_to_go_and_what_still_loads

    if command -v python3 >/dev/null 2>&1; then
        capability "the address typed at the prompt is the one it takes" \
            an_answer_at_the_prompt_is_taken
        capability "answering nothing at the prompt keeps what the machine already answers on" \
            an_empty_answer_keeps_the_configured_address
    fi
fi

if [[ -x "$REPO_ROOT/packaging/pin-images.sh" ]]; then
    group "What a version names"
    capability "a tag gains a digest without losing its version" \
        a_tag_gains_a_digest_without_losing_its_version
    capability "an image that already names its content is left alone" \
        an_image_already_pinned_is_left_alone
fi

if [[ -x "$REPO_ROOT/packaging/release-bom.sh" ]]; then
    capability "a release names every image it ships" \
        a_release_names_every_image_it_ships
    capability "it refuses to describe an image that can move" \
        a_bill_of_materials_refuses_an_image_that_can_move
    capability "it carries the three fields attestation reads" \
        a_bill_of_materials_carries_what_attestation_reads
    capability "and two runs of one release write the same document" \
        a_bill_of_materials_is_the_same_twice
    capability "and the release publishes what it is made of" \
        the_release_publishes_what_it_is_made_of
fi

if grep -q '^step_reporting()' "$REPO_ROOT/ut-install"; then
    group "Asking before sending usage reports"
    capability "with no answer and no terminal to ask on, nothing is sent" \
        no_answer_and_no_terminal_sends_nothing
    capability "an answer given once is not asked for again" \
        an_answer_already_given_is_not_asked_again
    capability "the prompt and the options hand ut-send the same answers" \
        the_prompt_and_the_flags_hand_ut_send_the_same_thing
    capability "reporting that cannot be set up does not stop the install" \
        reporting_that_fails_does_not_stop_the_install
    capability "a period given to the installer reaches ut-send" \
        a_period_given_to_the_installer_reaches_ut_send
fi

if [[ -x "$REPO_ROOT/packaging/build-deb.sh" ]]; then
    group "Distribution"
    capability "the same tree builds the same bytes twice" \
        reports SAME_BYTES_TWICE yes
    # Two builds here agree because they share a filesystem. What the published
    # v2026.09.5-rc5 and a rebuild of its own commit did not share was the
    # block size and the directory order, and those two are the whole gap.
    capability "the checksums are written in one order, not the filesystem's" \
        reports MD5SUMS_IN_ONE_ORDER yes
    capability "the installed size does not come from a block count" \
        reports SIZE_FREE_OF_THE_FILESYSTEM yes
    capability "the release installs as a package, in its own place" \
        the_release_installs_to_its_own_place
    capability "it carries ut-send for both architectures it serves" \
        reports UT_SEND both
    capability "it carries ut-setup for both architectures it serves" \
        reports UT_SETUP both
    capability "the settings directory is prepared, and the package puts nothing in it" \
        the_settings_directory_is_prepared_but_never_filled
    capability "the settings are read from where the release lives" \
        the_settings_are_read_from_where_the_release_lives
    capability "an upgrade replaces the release and keeps the settings" \
        an_upgrade_replaces_the_release_and_keeps_the_settings
    capability "installed from the package, it clones nothing and uses what is there" \
        the_installed_command_takes_the_release_that_is_there
    capability "a registry login already stored is not asked for a second time" \
        a_registry_login_already_stored_is_not_asked_for_again
    capability "removing the package leaves the settings and the data behind" \
        removing_the_package_leaves_the_settings_and_the_data
    capability "an upgrade keeps the reporting timer, and removing the package stops it" \
        an_upgrade_keeps_the_reporting_timer_and_removal_stops_it
    capability "every dependency it declares is one the shipped tools really call" \
        every_declared_dependency_is_really_used
fi

if [[ -x "$REPO_ROOT/ut-verify" ]]; then
    group "Offline verification"
    capability "a package the release signed is accepted" \
        a_package_the_release_signed_is_accepted
    capability "one that was altered, signed by another key, or not signed at all is refused" \
        a_package_nobody_signed_is_refused
    capability "the key ut-verify carries is the key the release is signed with" \
        the_shipped_key_is_the_one_the_release_is_signed_with
    capability "a key that cannot be read never fingerprints as the hash of nothing" \
        a_key_that_cannot_be_read_never_fingerprints_as_nothing
    capability "and it verifies with no network at all" \
        a_package_verifies_with_no_network_at_all
fi

if [[ -x "$REPO_ROOT/ut-get" ]]; then
    group "Installing from a release"
    capability "with no network at all, a release we signed is installed, then handed to ut-install" \
        a_signed_release_is_installed_then_handed_to_ut_install
    capability "nothing is installed from a release that was altered, signed by another key, or not signed at all" \
        the_launcher_installs_nothing_unsigned
    capability "the key ut-get carries is the key ut-verify carries" \
        the_launcher_carries_the_key_ut_verify_carries
    capability "with --browser, it hands over to ut-setup instead of ut-install" \
        the_launcher_continues_in_the_browser_when_asked
    capability "the latest release is downloaded, checked, installed, then handed to ut-install" \
        the_latest_release_is_downloaded_checked_and_installed
    capability "a release named by --version is installed rather than the latest" \
        a_named_version_is_installed_rather_than_the_latest
    capability "a downloaded release that was altered installs nothing" \
        a_downloaded_release_that_was_altered_installs_nothing
    capability "with no release published, or a version that is not one, nothing is fetched and the reason is said" \
        with_no_release_published_or_no_version_nothing_is_fetched
    capability "a release already downloaded installs again with its server gone" \
        a_release_already_downloaded_installs_again_offline
    capability "every release publishes ut-get beside the package" \
        the_release_publishes_the_launcher
    capability "the manual install downloads every file SHA256SUMS lists" \
        the_install_page_downloads_every_file_the_sums_list
fi

if [[ -x "$REPO_ROOT/ut-license" ]]; then
    group "License keys"
    capability "a license file Keygen signed for this machine is accepted" \
        a_license_file_keygen_signed_for_this_machine_is_accepted
    capability "one that was altered, signed by another key, or is not a license file at all is refused" \
        a_license_file_nobody_signed_is_refused
    capability "a license file made for another machine is refused, and says so" \
        a_license_file_made_for_another_machine_is_refused
    capability "a clock set before the file was issued is named, not taken for a bad license" \
        a_clock_set_before_the_file_is_named
    capability "a license that ended or is suspended is refused, and says whom to ask" \
        an_ended_or_suspended_license_is_refused_with_whom_to_ask
    capability "a license file past its own end says how to get a new one" \
        a_license_file_past_its_end_says_how_to_get_a_new_one
    capability "a genuine file that only needs renewing is told apart from a refused one" \
        a_file_that_only_needs_renewing_is_told_apart_from_a_refused_one
    capability "a key of the old format, checked as a license file, says what to ask for" \
        a_key_of_the_old_format_checked_as_a_license_file_says_what_to_ask_for
    capability "a machine without a serial number binds to its machine id, and says a reinstall changes it" \
        a_machine_without_a_serial_binds_to_its_machine_id_and_says_so
    capability "a key that would carry settings to curl is refused" \
        a_key_that_would_carry_curl_settings_is_refused
    capability "activating binds the license to this machine, or takes the one already bound" \
        activating_binds_the_license_to_this_machine
    capability "a license activated elsewhere, ended, suspended, unknown or of the old format says why it is not activated" \
        a_license_that_cannot_be_activated_here_says_why
    capability "a license that names a registry hands it, and its token, to the installer" \
        a_license_naming_a_registry_hands_it_to_the_installer
    capability "the license key and its registry token never come out, nor reach a command line" \
        the_license_key_and_its_token_never_come_out
    capability "the key ut-license carries is the key licenses are signed with" \
        the_shipped_key_is_the_one_licenses_are_signed_with
    capability "and a license file checks with no network at all" \
        a_license_checks_with_no_network_at_all
    capability "a license with no customer or no end date is never issued" \
        a_license_without_a_customer_or_an_end_is_never_issued
    capability "a license is issued only for a read-only token that pulls the release and outlives it" \
        a_license_is_issued_only_for_a_narrow_token_that_outlives_it
    capability "every license issued is written down, and never its token" \
        every_license_issued_is_written_down_never_its_token
    capability "a license for another registry names it, and is checked against it" \
        a_license_for_another_registry_names_it_and_is_checked_there
    capability "the installer and the issuer name every image of the release alike" \
        both_tools_name_every_image_alike
    capability "at boot, a license that has ended is said, and the stack still starts" \
        an_ended_license_is_said_at_boot_and_never_stops_the_stack
fi

if [[ -d "$REPO_ROOT/.github/workflows" ]]; then
    capability "every workflow is one GitHub can read" \
        every_workflow_parses
fi

if [[ -f "$REPO_ROOT/.github/dependabot.yml" ]]; then
    capability "the pinned actions have a way to move" \
        the_pinned_actions_have_a_way_to_move
fi

if [[ -f "$REPO_ROOT/.github/workflows/release.yml" ]]; then
    capability "the release fixes the date it builds with" \
        the_release_fixes_the_date_it_builds_with
    capability "the release attests what it built" \
        the_release_attests_what_it_built
fi

group "Backward compatibility"
capability "an untouched install keeps its container, volume, network and data names" \
    names_are_unchanged_by_default

if [[ -f "$REPO_ROOT/compose.compute.yaml" ]]; then
    group "Multi-machine roles"
    capability "a compute node serves inference" \
        with_profiles nim lists_service nim-llm -f compose.yaml -f compose.compute.yaml
    capability "a compute node runs no database" \
        omits_service mongodb -f compose.yaml -f compose.compute.yaml
    capability "a compute node records the load of what it serves" \
        with_profiles nim lists_service metrics -f compose.yaml -f compose.compute.yaml
    capability "a compute node lets other machines reach its engine only with its key" \
        the_compute_engine_is_reached_only_through_its_key
    capability "every service that calls a compute node trusts its root" \
        every_engine_caller_trusts_the_compute_node
    capability "a model on vLLM runs in place of NIM, with the same GPU and cache, and no port of its own" \
        a_model_on_vllm_runs_in_place_of_nim
    capability "each argument of the model reaches vLLM whole, JSON included" \
        each_argument_reaches_vllm_intact
    capability "no service declares a port Docker never publishes" \
        no_port_is_declared_where_docker_publishes_none
    capability "overriding the prefixes isolates every resource" \
        overrides_isolate_every_resource
fi

if [[ -f "$REPO_ROOT/compose.no-gpu.yaml" ]]; then
    capability "a machine without a GPU requests no NVIDIA device" \
        requests_no_gpu -f compose.yaml -f compose.no-gpu.yaml
fi

if [[ -f "$REPO_ROOT/backup-files.sh" ]]; then
    group "Backup"
    capability "files are backed up and restore identically" \
        files_are_backed_up_and_restore_identically
    capability "a missing backup is visible, and recovers when one appears" \
        a_missing_backup_is_visible
    capability "the backup has no way off the machine" \
        the_backup_has_no_way_off_the_machine -f compose.yaml
    capability "the backup round-trips through an S3 endpoint, and comes back from it alone" \
        the_backup_round_trips_through_an_s3_endpoint
    capability "a backup lands on the destination the host mounts, and reads back from it alone" \
        the_backup_lands_on_the_mounted_destination
    capability "a destination that is not mounted is refused, and nothing is written" \
        the_backup_refuses_a_destination_that_is_not_mounted
    capability "the backup has no way off the machine, with a mounted destination too" \
        with_a_backup_destination the_backup_has_no_way_off_the_machine -f compose.yaml -f compose.backup-mount.yaml
    capability "a database restored on another machine, as the guide says, keeps that machine's accounts" \
        the_guide_s_restore_keeps_this_machine_s_accounts
    capability "the authority that signs the HTTPS certificate sits where the backup looks" \
        the_https_authority_is_where_the_backup_looks
    capability "that authority is backed up and restores identically" \
        the_https_authority_is_backed_up_and_restores_identically
    capability "an S3 or SFTP destination gives the backup one way out, its own" \
        with_a_network_repository the_network_destination_gets_a_way_out_of_its_own -f compose.yaml -f compose.backup-network.yaml
    capability "an SFTP destination is trusted only under the host key pinned for it" \
        the_sftp_destination_has_to_prove_who_it_is
    capability "a destination that does not answer is named, and nothing is written" \
        an_unreachable_destination_is_named
    capability "a password that does not open the repository is named as such" \
        a_password_that_does_not_open_the_repository_is_named
    capability "the database leaves with them, not only the files" \
        the_database_leaves_the_machine_with_the_files
fi

# A status tool that says nothing is wrong when there is nothing to check is
# worse than none: it would answer "serving" on a machine that was never
# installed.
ut_status_refuses() {
    local dir=$1 expected=$2 output
    output=$( "$REPO_ROOT/ut-status" --dir "$dir" 2>&1 ) && return 1
    grep -q "$expected" <<< "$output" && return 0
    echo "$output"
    return 1
}

a_directory_with_no_install_is_refused() {
    local dir
    dir=$(mktemp -d)
    ut_status_refuses "$dir" "No install in"
}

an_install_that_was_never_configured_is_refused() {
    local dir
    dir=$(mktemp -d)
    cp "$REPO_ROOT/compose.yaml" "$dir/"
    ut_status_refuses "$dir" "was it ever installed"
}

history_probe() {
    local probe
    probe=$(mktemp -d "$WORK_DIR/history.XXXXXX")
    cp "$REPO_ROOT/compose.yaml" "$probe/"
    printf 'UT_RELEASE_VERSION="2026.10.1+abc1234"\n' > "$probe/release.env"
    printf 'DATA_ROOT="%s/data"\nCOMPOSE_PROJECT_NAME="history-probe"\n' "$probe" > "$probe/.env"
    printf '%s' "$probe"
}

# Each value of exits is one run of the installer ending with that status, while
# the step it had announced last was the one given.
install_history_after() {
    local probe=$1 exits=$2 step=$3
    cat > "$probe/run.sh" <<EOF
set +u
UT_INSTALL_DIR="$probe" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
set +eE
trap - ERR
for status in $exits; do
    ( trap record_this_install EXIT; log_step "$step" >/dev/null; exit "\$status" )
done
EOF
    bash "$probe/run.sh" >/dev/null 2>&1
    cat "$probe/data/install-history.jsonl" 2>/dev/null
}

the_installer_keeps_every_run_from_its_first_step() {
    sed -n '/^main() {/,/^}/p' "$REPO_ROOT/ut-install" \
        | sed -n '/start_logging/,/preflight/p' | grep -q 'trap record_this_install EXIT'
}

a_failed_install_is_kept_with_the_step_it_stopped_at() {
    local history
    history=$(install_history_after "$(history_probe)" 1 "Pulling images")
    grep -q '"tool":"ut-install","outcome":"failed","step":"Pulling images","release":"2026.10.1+abc1234"' <<< "$history" \
        && return 0
    echo "${history:-no history written}"
    return 1
}

a_second_install_is_added_after_the_first() {
    local history
    history=$(install_history_after "$(history_probe)" "1 0" "Starting the platform")
    [[ $(grep -c '"tool":"ut-install"' <<< "$history") -eq 2 ]] \
        && tail -1 <<< "$history" | grep -q '"outcome":"done","step":""' \
        && return 0
    echo "${history:-no history written}"
    return 1
}

a_status_verdict_is_kept_beside_the_installs() {
    local probe status expected history
    probe=$(history_probe)
    mkdir -p "$probe/data"
    "$REPO_ROOT/ut-status" --dir "$probe" >/dev/null 2>&1 && status=0 || status=$?
    expected="not-serving"
    (( status == 0 )) && expected="serving"
    history=$(cat "$probe/data/install-history.jsonl" 2>/dev/null)
    grep -qE "\"tool\":\"ut-status\",\"outcome\":\"${expected}\",\"available_bytes\":([0-9]+|null)}" <<< "$history" && return 0
    echo "exit ${status}, history: ${history:-none}"
    return 1
}

ut_status_says_whether_reports_go_out() {
    local probe output
    probe=$(reporting_probe "Reporting: on, to receiver.example.test:8444, every 15 minutes
  no timer runs it: nothing is collected or sent until ut-send configure --consent yes is given again")
    output=$(UT_SEND="$probe/ut-send" "$REPO_ROOT/ut-status" --dir "$(history_probe)" 2>&1)
    grep -q '\[ ok \] Reporting: on, to receiver.example.test:8444, every 15 minutes$' <<< "$output" \
        && grep -q '\[warn\] no timer runs it' <<< "$output" && return 0
    echo "$output"
    return 1
}

# ut-status runs where ut-license can, in the license image, with a docker that
# answers nothing, as it does on a machine where the project has no container.
license_status_with() {
    local machine_file=$1 probe=$2
    docker run --rm -v "$REPO_ROOT":/src:ro -v "$WORK_DIR":"$WORK_DIR" -v "$WORK_DIR/license":/w:ro \
        -e UT_LICENSE_STORE=/w/lab/keys/active.key -e UT_MACHINE_FILE="/w/lab/files/${machine_file}.lic" \
        -e UT_LICENSE_TOOL=/w/lab/ut-license "$(license_image)" bash -c \
        'mkdir -p /stub && printf "#!/bin/sh\nexit 0\n" > /stub/docker && chmod +x /stub/docker && PATH=/stub:$PATH bash /src/ut-status --dir "$0"' \
        "$probe" 2>&1
}

ut_status_says_how_the_license_stands() {
    local probe current ended
    license_verdicts >/dev/null
    probe=$(history_probe)
    current=$(license_status_with valid "$probe")
    grep -q '\[ ok \] Licensed to Test Customer until ' <<< "$current" \
        || { echo "a current license was not said:"; echo "$current"; return 1; }
    ended=$(license_status_with ended "$probe")
    grep -q '\[warn\] The license of Test Customer ended on ' <<< "$ended" \
        || { echo "an ended license was not warned about:"; echo "$ended"; return 1; }
    grep -qF "$LICENSE_TEST_TOKEN" <<< "${current}${ended}" || return 0
    echo "the registry token came out of ut-status"
    return 1
}

if [[ -x "$REPO_ROOT/ut-status" ]]; then
    group "Telling whether an install serves"
    capability "it says how the license stands, and warns when it has ended" \
        ut_status_says_how_the_license_stands
    capability "it says whether usage reports go out, and warns when nothing sends them" \
        ut_status_says_whether_reports_go_out
    capability "a directory with no install is refused, not called healthy" \
        a_directory_with_no_install_is_refused
    capability "an install that was never configured is refused" \
        an_install_that_was_never_configured_is_refused
    capability "a status verdict is kept beside the installs" \
        a_status_verdict_is_kept_beside_the_installs
fi

REPORT_KEYS="schema generated_at install_id window_days release images service image capacity engine hours hour requests running_peak waiting_peak saturated_minutes first_token_within_1s first_token_within_2_5s prompts_le_500 prompts_le_2000 prompts_le_10000 users_by_hour users history at tool outcome step warnings memory host total_bytes available_bytes services current_bytes peak_bytes limit_bytes started_at"

ut_report_refuses() {
    local dir=$1 expected=$2 output
    output=$( "$REPO_ROOT/ut-report" --dir "$dir" --out "$dir" 2>&1 ) && return 1
    [[ ! -e "$dir/report.json" ]] || { echo "a report was written anyway"; return 1; }
    grep -q "$expected" <<< "$output" && return 0
    echo "$output"
    return 1
}

a_directory_with_no_install_gets_no_report() {
    ut_report_refuses "$(mktemp -d)" "No install in"
}

an_install_never_configured_gets_no_report() {
    local dir
    dir=$(mktemp -d)
    cp "$REPO_ROOT/compose.yaml" "$dir/"
    ut_report_refuses "$dir" "was it ever installed"
}

# What ut-report gathers is replaced here: the format is under test, not the
# stack it reads. Each argument is what one source answers, as "hour value" lines.
report_from() {
    local probe=$1 requests=$2 users=$3 ttft=$4
    cat > "$probe/run.sh" <<EOF
set +u
UT_INSTALL_DIR="$probe" source "$REPO_ROOT/ut-report" >/dev/null 2>&1
set +eE
trap - ERR
engines_recorded() { printf '${ENGINES-nim-llm:8000\\n}'; }
an_engine_runs_here() { return 0; }
hourly() {
    case "\$1" in
        *request_success*)    printf '$requests' ;;
        *time_to_first_token*) printf '$ttft' ;;
        *sum_over_time*)      printf '1759651200 17\n' ;;
        *)                    printf '1759651200 2\n' ;;
    esac
}
users_by_hour() { printf '$users'; }
recorder_storage() { printf '${RECORDER_STORAGE-}'; }
recorder_retention() { printf '${RECORDER_RETENTION-5w or 1GiB}'; }
the_database_runs_here() { return 0; }
running_images() { printf 'api ghcr.io/understand-tech/ut-api-customer:2.1-arm64@sha256:0000\n'; }
host_memory() { printf '128000000000 23000000000\n'; }
service_memory() { printf '${SERVICE_MEMORY-api 537022464 596684800 4294967296 2026-10-06T09:45:26Z\\nnim-llm 7500000000 92000000000 max 2026-10-06T09:45:26Z\\n}'; }
write_report "$probe/out"
EOF
    bash "$probe/run.sh" >/dev/null 2>&1
    cat "$probe/out/report.json" 2>/dev/null
}

a_served_hour() { report_from "$(history_probe)" '1759651200 5\n' '1759651200 3\n' '1759651200 0.8\n'; }

the_report_holds_no_key_outside_its_schema() {
    local report key unknown=""
    report=$(a_served_hour)
    [[ -n "$report" ]] || { echo "no report written"; return 1; }
    for key in $(grep -oE '"[a-z_0-9]+":' <<< "$report" | tr -d '":' | sort -u); do
        grep -qw "$key" <<< "$REPORT_KEYS" || unknown+=" $key"
    done
    [[ -z "$unknown" ]] && return 0
    echo "keys outside the schema:${unknown}"
    return 1
}

the_report_names_no_user() {
    local report
    report=$(a_served_hour)
    [[ -n "$report" ]] || { echo "no report written"; return 1; }
    local address='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    grep -qE "$address" <<< "$report" || return 0
    grep -oE "$address" <<< "$report"
    return 1
}

requests_served_with_no_user_counted_are_flagged() {
    local report
    report=$(report_from "$(history_probe)" '1759651200 5\n' '' '1759651200 0.8\n')
    grep -q '"users-missing' <<< "$report" && return 0
    echo "${report:-no report written}"
    return 1
}

a_series_the_recorder_does_not_have_is_flagged() {
    local report
    report=$(report_from "$(history_probe)" '1759651200 5\n' '1759651200 3\n' '')
    grep -q '"series-missing:nim-llm:8000:first_token_within_2_5s' <<< "$report" && return 0
    echo "${report:-no report written}"
    return 1
}

the_minutes_requests_waited_are_counted() {
    local report
    report=$(a_served_hour)
    grep -q '"saturated_minutes": 17' <<< "$report" && return 0
    echo "${report:-no report written}"
    return 1
}

an_engine_nobody_recorded_is_flagged() {
    local report
    report=$(ENGINES="" report_from "$(history_probe)" '' '' '')
    grep -q '"recorder-missing' <<< "$report" && return 0
    echo "${report:-no report written}"
    return 1
}

# A recorder that filled 100 MiB in two days needs 1.7 GiB for five weeks: its
# 1 GiB cap would start dropping days long before then.
a_recorder_that_will_outgrow_its_cap_is_flagged_before_it_does() {
    local report started
    started=$(( $(date +%s) - 2 * 86400 ))
    report=$(RECORDER_STORAGE="$(( 100 * 1048576 )) ${started}" report_from "$(history_probe)" '1759651200 5\n' '1759651200 3\n' '1759651200 0.8\n')
    grep -q '"recorder-budget-short' <<< "$report" && return 0
    echo "${report:-no report written}"
    return 1
}

# 512 MiB at 15 MB a day lasts 35.5 days: under the 36 of 5w1d, above the 35 a
# reader that dropped the trailing 1d would compare it with.
a_cap_written_in_other_units_is_read_the_same() {
    local report started
    started=$(( $(date +%s) - 2 * 86400 ))
    report=$(RECORDER_STORAGE="30247836 ${started}" RECORDER_RETENTION="5w1d or 512MiB" \
        report_from "$(history_probe)" '1759651200 5\n' '1759651200 3\n' '1759651200 0.8\n')
    grep -q '"recorder-budget-short' <<< "$report" && return 0
    echo "${report:-no report written}"
    return 1
}

a_recorder_well_within_its_cap_raises_nothing() {
    local report started
    started=$(( $(date +%s) - 2 * 86400 ))
    report=$(RECORDER_STORAGE="$(( 4 * 1048576 )) ${started}" report_from "$(history_probe)" '1759651200 5\n' '1759651200 3\n' '1759651200 0.8\n')
    [[ -n "$report" ]] || { echo "no report written"; return 1; }
    grep -q '"recorder-budget-short' <<< "$report" || return 0
    echo "$report"
    return 1
}

# An hour of data is mostly write-ahead log: dividing it by an hour would
# forecast a recorder ten times hungrier than it is.
a_recorder_too_young_to_judge_raises_nothing() {
    local report started
    started=$(( $(date +%s) - 3600 ))
    report=$(RECORDER_STORAGE="$(( 100 * 1048576 )) ${started}" report_from "$(history_probe)" '1759651200 5\n' '1759651200 3\n' '1759651200 0.8\n')
    [[ -n "$report" ]] || { echo "no report written"; return 1; }
    grep -q '"recorder-budget-short' <<< "$report" || return 0
    echo "$report"
    return 1
}

the_report_gives_each_service_its_memory_peak_and_limit() {
    local report
    report=$(a_served_hour)
    grep -q '"service": "api", "current_bytes": 537022464, "peak_bytes": 596684800, "limit_bytes": 4294967296' <<< "$report" \
        && grep -q '"service": "nim-llm", "current_bytes": 7500000000, "peak_bytes": 92000000000, "limit_bytes": null' <<< "$report" \
        && grep -q '"host": {"total_bytes": 128000000000, "available_bytes": 23000000000}' <<< "$report" \
        && return 0
    echo "${report:-no report written}"
    return 1
}

a_memory_peak_nobody_can_read_is_flagged() {
    local report
    report=$(SERVICE_MEMORY='api 537022464 - 4294967296 2026-10-06T09:45:26Z\\n' report_from "$(history_probe)" '1759651200 5\n' '1759651200 3\n' '1759651200 0.8\n')
    grep -q '"peak_bytes": null' <<< "$report" && grep -q '"memory-peak-unknown:api' <<< "$report" && return 0
    echo "${report:-no report written}"
    return 1
}

the_manifest_checksum_is_the_reports() {
    local probe expected listed
    probe=$(history_probe)
    report_from "$probe" '1759651200 5\n' '1759651200 3\n' '1759651200 0.8\n' >/dev/null
    expected=$(openssl dgst -sha256 -r "$probe/out/report.json" 2>/dev/null | cut -d' ' -f1)
    listed=$(grep 'report.json' "$probe/out/SHA256SUMS" 2>/dev/null | cut -d' ' -f1)
    [[ -n "$expected" && "$expected" == "$listed" ]] && grep -q "$expected" "$probe/out/MANIFEST.txt" && return 0
    echo "report ${expected:-missing}, listed ${listed:-nothing}"
    return 1
}

# The one path report_from replaces: the real recorder, asked the way ut-report
# asks it, about an engine that answers with what NIM answers.
the_report_finds_the_engine_the_recorder_holds() {
    local probe project found="" tries
    probe=$(history_probe)
    project="report-probe-$$"
    mkdir -p "$probe/metrics"
    cp "$REPO_ROOT/metrics/prometheus.yml" "$probe/metrics/"
    printf '# TYPE vllm:num_requests_running gauge\nvllm:num_requests_running{model_name="m"} 0\n' > "$probe/engine-metrics"
    cat > "$probe/serve.py" <<'EOF'
import http.server
body = open("/p/engine-metrics", "rb").read()
class Engine(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=1.0.0; charset=utf-8")
        self.end_headers()
        self.wfile.write(body)
http.server.HTTPServer(("", 8000), Engine).serve_forever()
EOF
    cat > "$probe/compose.yaml" <<EOF
name: ${project}
services:
  nim-llm:
    image: ${PYTHON_IMAGE}
    command: ["python", "/p/serve.py"]
    volumes: ["./:/p:ro"]
  metrics:
    image: $(grep -m1 '^PROMETHEUS_IMAGE=' "$REPO_ROOT/release.env" | cut -d'"' -f2)
    command: ["--config.file=/etc/prometheus/prometheus.yml", "--storage.tsdb.path=/prometheus"]
    volumes: ["./metrics/prometheus.yml:/etc/prometheus/prometheus.yml:ro"]
EOF
    ( cd "$probe" && docker compose up -d >/dev/null 2>&1 )
    for tries in 1 2 3 4 5 6 7 8; do
        sleep 5
        found=$(UT_INSTALL_DIR="$probe" bash -c 'set +u; source "$1" >/dev/null 2>&1; set +eE; trap - ERR; engines_recorded' _ "$REPO_ROOT/ut-report")
        [[ -n "$found" ]] && break
    done
    ( cd "$probe" && docker compose down -v >/dev/null 2>&1 )
    [[ "$found" == "nim-llm:8000" ]] && return 0
    echo "engines found: ${found:-none}"
    return 1
}

if [[ -x "$REPO_ROOT/ut-report" ]]; then
    group "Reporting what decides the size of a box"
    capability "the report finds the engine the recorder holds" \
        the_report_finds_the_engine_the_recorder_holds
    capability "a directory with no install gets no report" \
        a_directory_with_no_install_gets_no_report
    capability "an install never configured gets no report" \
        an_install_never_configured_gets_no_report
    capability "the report holds no key outside its schema" \
        the_report_holds_no_key_outside_its_schema
    capability "the report names no user" \
        the_report_names_no_user
    capability "requests served with no user counted are flagged" \
        requests_served_with_no_user_counted_are_flagged
    capability "a series the recorder does not have is flagged" \
        a_series_the_recorder_does_not_have_is_flagged
    capability "the minutes requests waited for the engine are counted, hour by hour" \
        the_minutes_requests_waited_are_counted
    capability "an engine nobody recorded is flagged" \
        an_engine_nobody_recorded_is_flagged
    capability "a recorder that will outgrow its cap is flagged before it does" \
        a_recorder_that_will_outgrow_its_cap_is_flagged_before_it_does
    capability "a cap written in other units is read the same" \
        a_cap_written_in_other_units_is_read_the_same
    capability "a recorder well within its cap raises nothing" \
        a_recorder_well_within_its_cap_raises_nothing
    capability "a recorder too young to judge raises nothing" \
        a_recorder_too_young_to_judge_raises_nothing
    capability "the report gives each service its memory peak and limit" \
        the_report_gives_each_service_its_memory_peak_and_limit
    capability "a memory peak nobody can read is flagged" \
        a_memory_peak_nobody_can_read_is_flagged
    capability "the manifest carries the report's checksum" \
        the_manifest_checksum_is_the_reports
fi

# setup-autostart.sh run for real in a container, with docker and systemctl
# answering yes. TOOL_BESIDE says whether ut-status sits next to the release, as
# in a checkout, or only on the PATH, as the package installs it.
status_timer_report() {
    local tool_beside=$1
    cat > "$WORK_DIR/timer-probe.sh" <<'PROBE'
set -u
mkdir -p /fix /stub /usr/local/bin
cp /src/compose.yaml /fix/
printf 'UT_DOMAIN="box.example.com"\n' > /fix/.env
printf '#!/bin/sh\nexit 0\n' > /stub/docker
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> /stub/calls\nexit 0\n' > /stub/systemctl
chmod +x /stub/docker /stub/systemctl
if [ "$TOOL_BESIDE" = yes ]; then
    cp /src/ut-status /fix/ut-status
else
    cp /src/ut-status /usr/local/bin/ut-status
fi
PATH=/stub:$PATH bash /src/setup-autostart.sh --install --dir /fix >/dev/null 2>&1
printf -- '--- service ---\n'; cat /etc/systemd/system/ut-status.service 2>/dev/null
printf -- '--- timer ---\n'; cat /etc/systemd/system/ut-status.timer 2>/dev/null
printf -- '--- systemctl ---\n'; cat /stub/calls
PATH=/stub:$PATH bash /src/setup-autostart.sh --uninstall --dir /fix >/dev/null 2>&1
printf -- '--- after uninstall ---\n'
ls /etc/systemd/system/ut-status.service /etc/systemd/system/ut-status.timer 2>/dev/null
printf 'END\n'
PROBE
    docker run --rm -i -e TOOL_BESIDE="$tool_beside" -v "$REPO_ROOT":/src:ro \
        "$BASH_IMAGE" bash -s < "$WORK_DIR/timer-probe.sh" 2>&1
}

the_status_check_runs_every_hour() {
    local report
    report=$(status_timer_report yes)
    grep -q '^OnCalendar=hourly$' <<< "$report" \
        && grep -q '^ExecStart=/fix/ut-status --dir /fix$' <<< "$report" \
        && grep -q '^enable --now ut-status.timer$' <<< "$report" \
        && return 0
    echo "$report"
    return 1
}

the_package_s_status_tool_is_the_one_scheduled() {
    local report
    report=$(status_timer_report no)
    grep -q '^ExecStart=/usr/local/bin/ut-status --dir /fix$' <<< "$report" && return 0
    echo "$report"
    return 1
}

removing_the_units_removes_the_status_check() {
    local report left
    report=$(status_timer_report yes)
    left=${report#*--- after uninstall ---}
    left=${left%END*}
    grep -q 'ut-status.timer' <<< "${report%%--- after uninstall ---*}" || { echo "$report"; return 1; }
    [[ -z "${left//[[:space:]]/}" ]] && return 0
    echo "still installed:${left}"
    return 1
}

if grep -q 'ut-status' "$REPO_ROOT/setup-autostart.sh"; then
    group "Checking every hour whether the install serves"
    capability "the status check runs every hour" \
        the_status_check_runs_every_hour
    capability "installed from the package, the status check runs the packaged tool" \
        the_package_s_status_tool_is_the_one_scheduled
    capability "removing the units removes the status check" \
        removing_the_units_removes_the_status_check
fi

group "Keeping the history of an install"
capability "every install run is kept, from its first step" \
    the_installer_keeps_every_run_from_its_first_step
capability "a failed install is kept, with the step it stopped at" \
    a_failed_install_is_kept_with_the_step_it_stopped_at
capability "a second install is added after the first, never over it" \
    a_second_install_is_added_after_the_first

printf '\n%s%d verified%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d failing%s\n' "$RED" "$FAILED" "$NC"
    printf '\nNot working:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
