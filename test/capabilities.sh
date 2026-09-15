#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"

# The restic and step-ca containers run as root and write into WORK_DIR, so the
# shell that created it cannot remove what they left.
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

write_mdns_probe() {
    cat > "$WORK_DIR/mdns-probe.sh" <<'PROBE'
set -u
mkdir -p /fix /stub
printf 'UT_DOMAIN="%s"\n' "$DOMAIN" > /fix/.env

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
    local domain=$1 already_enabled=${2:-no}
    write_mdns_probe
    docker run --rm \
        -v "$REPO_ROOT/setup-autostart.sh":/setup-autostart.sh:ro \
        -v "$WORK_DIR/mdns-probe.sh":/mdns-probe.sh:ro \
        -e DOMAIN="$domain" -e ALREADY_ENABLED="$already_enabled" \
        bash:5 bash /mdns-probe.sh 2>&1
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

# The default repository sits in the same volume as the database archives, so it
# protects against a mistake and not against losing the machine. This exercises
# the other half — a backup leaving for an S3 destination, and coming back from
# it alone.
backups_reach_an_offsite_destination() {
    local run=cap-offsite-$$ net store bucket=appliance-backups
    local key=capability-key secret=capability-secret-value
    local work="$WORK_DIR/offsite" source="$WORK_DIR/offsite/data" restored="$WORK_DIR/offsite/out"
    net=$run-net; store=$run-store
    mkdir -p "$source/app-data" "$source/ca/certs" "$restored"

    head -c 200000 /dev/urandom > "$source/app-data/document.bin"
    echo "customer notes" > "$source/app-data/notes.txt"
    head -c 2000 /dev/urandom > "$source/ca/certs/root_ca.crt"

    docker network create "$net" >/dev/null 2>&1
    docker run -d --name "$store" --network "$net" \
        -e MINIO_ROOT_USER="$key" -e MINIO_ROOT_PASSWORD="$secret" \
        "$OBJECT_STORE_IMAGE" server /data >/dev/null 2>&1

    # Answering on HTTP is the readiness signal, not the container running: the
    # process is up well before it serves. Asking here also bounds the failure —
    # restic retries an unreachable endpoint for minutes, and an unreachable
    # endpoint is what a failure of this check looks like.
    local attempt ready=1
    for attempt in $(seq 1 20); do
        if docker run --rm --network "$net" "$CURL_IMAGE" \
            -sf -m 5 "http://${OFFSITE_ENDPOINT:-$store}:9000/minio/health/live" >/dev/null 2>&1; then
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
# quay.io, not docker.io: the minio/minio repository on Docker Hub answers
# "pull access denied" now.
OBJECT_STORE_IMAGE=quay.io/minio/minio:latest
CURL_IMAGE=curlimages/curl:latest

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
    capability "moving off .local withdraws a publisher installed earlier" \
        moving_off_local_withdraws_the_publisher
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

    if command -v python3 >/dev/null 2>&1; then
        capability "the address typed at the prompt is the one it takes" \
            an_answer_at_the_prompt_is_taken
        capability "answering nothing at the prompt keeps what the machine already answers on" \
            an_empty_answer_keeps_the_configured_address
    fi
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
    capability "backups can leave the machine, and come back from where they went" \
        backups_reach_an_offsite_destination
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
