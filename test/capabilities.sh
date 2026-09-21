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

the_wait_names_what_is_late() {
    local report
    report=$(installer_wait_over '/ut-mongodb|running|starting|control-plane
')
    grep -q 'still starting' <<< "$report" || { echo "$report"; return 1; }
    grep -q 'still starting.*ut-mongodb' <<< "$report" && return 0
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

say SAME_BYTES_TWICE "$([ "$(digest_of /out/first/understandtech_2026.09.1_all.deb)" \
    = "$(digest_of /out/second/understandtech_2026.09.1_all.deb)" ] && echo yes || echo no)"

apparent_kib() { find "$1" -type f -exec du -k --apparent-size {} + | awk '{ t += $1 } END { print t + 0 }'; }

sorted_checksums=$(dpkg-deb --ctrl-tarfile /out/understandtech_2026.09.1_all.deb 2>/dev/null \
    | tar -xO ./md5sums 2>/dev/null | sort -c -k2 >/dev/null 2>&1 && echo yes || echo no)
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

dpkg -i --force-depends /out/understandtech_2026.09.2_all.deb >/dev/null 2>&1
say UPGRADED_VERSION       "$(dpkg-query -W -f='${Version}' understandtech 2>/dev/null)"
say SETTINGS_AFTER_UPGRADE "$(cat /etc/understandtech/.env 2>/dev/null || echo gone)"
say RELEASE_AFTER_UPGRADE  "$(present_file /usr/share/understandtech/compose.yaml)"

dpkg --purge --force-depends understandtech >/dev/null 2>&1
say RELEASE_AFTER_PURGE  "$(present_dir /usr/share/understandtech)"
say SETTINGS_AFTER_PURGE "$(present_file /etc/understandtech/.env)"
say DATA_AFTER_PURGE     "$(present_file /var/lib/understandtech/app-data/one)"
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
            debian:12-slim bash /probe.sh > "$cached" 2>&1
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
        "$REPO_ROOT/backup-files.sh"
}

declared_dependencies() {
    grep -m1 '^Depends:' "$REPO_ROOT/packaging/build-deb.sh" \
        | sed 's/^Depends: //' | tr ',' '\n' | tr -d ' ' | grep -v '^$'
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

the_shipped_key_is_the_one_the_release_is_signed_with() {
    local embedded versioned
    embedded=$("$REPO_ROOT/ut-verify" --fingerprint)
    versioned="SHA256: $(openssl pkey -pubin -in "$REPO_ROOT/packaging/release.pub" -outform DER 2>/dev/null \
        | openssl dgst -sha256 -r | cut -d' ' -f1)"
    [[ "$embedded" == "$versioned" ]] && return 0
    echo "ut-verify carries ${embedded}, packaging/release.pub is ${versioned}"
    return 1
}

# GitHub reports an unparseable workflow after the push that broke it, on the
# run that was supposed to do the work.
every_workflow_parses() {
    local verdict read_count
    # --entrypoint: this image runs yq, so a bare "sh -c" would arrive as
    # arguments to yq and read nothing at all.
    verdict=$(docker run --rm --entrypoint sh \
        -v "$REPO_ROOT/.github/workflows":/w:ro mikefarah/yq:4 \
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
        -v "$REPO_ROOT/.github":/g:ro mikefarah/yq:4 \
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
    docker run -d --name "$store" --network "$net" \
        -e MINIO_ROOT_USER="$key" -e MINIO_ROOT_PASSWORD="$secret" \
        "$OBJECT_STORE_IMAGE" server /data >/dev/null 2>&1

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
    capability "the database leaves with them, not only the files" \
        the_database_leaves_the_machine_with_the_files
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
