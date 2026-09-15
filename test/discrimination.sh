#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"

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

COPY="$WORK_DIR/repo"

fresh_copy() {
    rm -rf "$COPY"
    mkdir -p "$COPY"
    ( cd "$REPO_ROOT" && tar -cf - .env.example compose.yaml compose.appbuilder.yaml \
        compose.compute.yaml compose.no-gpu.yaml Caddyfile caddy backup-files.sh \
        setup-autostart.sh ut-logs-archive ut-install appbuilder docs \
        README.md test 2>/dev/null ) | tar -xf - -C "$COPY" 2>/dev/null
}

# A check nobody has seen fail is a check nobody knows works. Each entry breaks
# one thing on a copy of the repository and expects the matching identifier.
discriminates() {
    local description=$1 expected=$2 mutation=$3
    fresh_copy
    ( cd "$COPY" && eval "$mutation" ) >/dev/null 2>&1
    find "$COPY" -name '*.bak' -delete 2>/dev/null

    local output
    output=$( cd "$COPY" && ./test/invariants.sh 2>&1 )

    if grep -q "$expected" <<< "$output"; then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        printf '%s      expected %s, got:%s\n' "$DIM" "$expected" "$NC"
        printf '%s      %s%s\n' "$DIM" "$(tail -4 <<< "$output" | tr '\n' ' ')" "$NC"
        FAILED=$((FAILED + 1))
        FAILURES+=("$description")
    fi
}

capability_discriminates() {
    local description=$1 expected=$2 mutation=$3
    fresh_copy
    ( cd "$COPY" && eval "$mutation" ) >/dev/null 2>&1
    find "$COPY" -name '*.bak' -delete 2>/dev/null

    local output
    output=$( cd "$COPY" && CAPABILITY_FILTER="$expected" OFFSITE_ENDPOINT="${OFFSITE_ENDPOINT:-}" ./test/capabilities.sh 2>&1 )

    if grep -q "✘ $expected" <<< "$output"; then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        printf '%s      "%s" was expected to fail and did not%s\n' "$DIM" "$expected" "$NC"
        FAILED=$((FAILED + 1))
        FAILURES+=("$description")
    fi
}

printf '%sEvery invariant, seen failing%s %s(each on a copy, nothing here is touched)%s\n\n' \
    "$BOLD" "$NC" "$DIM" "$NC"

discriminates "a secret shipped in the template" \
    "plaintext-secret:JWT_SECRET" \
    "sed -i.bak 's|^JWT_SECRET=.*|JWT_SECRET=\"a3f9c1d2e4b8\"|' .env.example"

discriminates "a secret defaulted in a compose file" \
    "compose-secret-default:JWT_SECRET" \
    "sed -i.bak 's|\${JWT_SECRET:?[^}]*}|\${JWT_SECRET:-shipped-value}|' compose.yaml"

discriminates "one variable with two different defaults" \
    "divergent-default:MONGODB_HOST" \
    "sed -i.bak 's|\${MONGODB_HOST:-mongodb}|\${MONGODB_HOST:-}|' compose.appbuilder.yaml"

# Guarded like the capability blocks: the list grows with the branch rather
# than failing on one that predates a check.
if grep -q 'check_required_variables_appear_in_the_template' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a required variable absent from the template" \
        "required-variable-missing:CA_PASSWORD" \
        "sed -i.bak '/^CA_PASSWORD=/d' .env.example"
fi

discriminates "a variable with no default and no value" \
    "undeclared-variable:SOMETHING_NOBODY_SET" \
    "sed -i.bak 's|^  redis:|  redis:\n    hostname: \${SOMETHING_NOBODY_SET}|' compose.yaml"

discriminates "a port published on every interface" \
    "unlisted-port:redis" \
    "sed -i.bak 's|^    expose:|    ports:\n      - \"6399:6379\"\n    expose:|' compose.yaml"

discriminates "verbose logs in the template" \
    "verbose-log-level:LOG_LEVEL" \
    "sed -i.bak 's|^LOG_LEVEL=.*|LOG_LEVEL=\"DEBUG\"|' .env.example"

discriminates "a documented path that does not exist" \
    "missing-documented-path:nowhere.yaml" \
    "printf '\nSee \`nowhere.yaml\` for details.\n' >> README.md"

printf '\n%sCapabilities, seen failing%s\n\n' "$BOLD" "$NC"

capability_discriminates "the authority removed from the stack" \
    "the appliance runs its own certificate authority" \
    "sed -i.bak 's|^  step-ca:|  step-ca:\n    profiles: [\"never-enabled\"]|' compose.yaml"

capability_discriminates "the authority root moved out of the backed-up path" \
    "its root sits where the file backup looks" \
    "sed -i.bak 's|\${DATA_ROOT:-/var/lib/understandtech}/ca:/home/step|step-ca-data:/home/step|' compose.yaml"

capability_discriminates "the machine surface pointed at something else" \
    "the machine-facing surface takes its certificate from that authority" \
    "sed -i.bak 's|step-ca:9000/acme|acme-v02.api.letsencrypt.org|' caddy/internal-surface.caddy"

capability_discriminates "a resource left unprefixed" \
    "overriding the prefixes isolates every resource" \
    "sed -i.bak 's|name: \${RESOURCE_PREFIX:-ut}-redis-data|name: ut-redis-data|' compose.yaml"

if grep -q 'mdns_applies' "$REPO_ROOT/setup-autostart.sh"; then
    capability_discriminates "the mDNS publisher installed on a real domain" \
        "a real domain installs no mDNS publisher" \
        "sed -i.bak 's|^    if ! mdns_applies; then|    if false; then|' setup-autostart.sh"

    capability_discriminates "the mDNS publisher skipped on a .local domain" \
        "a .local domain still publishes its names over mDNS" \
        "sed -i.bak 's|^    if ! mdns_applies; then|    if true; then|' setup-autostart.sh"

    capability_discriminates "a stale publisher left enabled after the move" \
        "moving off .local withdraws a publisher installed earlier" \
        "sed -i.bak 's|^        withdraw_mdns_publisher$|        :|' setup-autostart.sh"
fi

if grep -q 'read_domain' "$REPO_ROOT/ut-install"; then
    capability_discriminates "the address defaulted silently again" \
        "an unattended install falls back to the mDNS name" \
        "sed -i.bak 's|^DOMAIN=\"\${UT_DOMAIN:-}\"|DOMAIN=\"\${UT_DOMAIN:-understand.local}\"|' ut-install"

    capability_discriminates "the address given up front overwritten by the fallback" \
        "an address given up front is taken as it is" \
        "sed -i.bak 's|^    \[\[ -n \"\$DOMAIN\" \]\] \&\& return 0$|    :|' ut-install"

    capability_discriminates "the address already on the machine ignored" \
        "an address the machine already answers on is never replaced" \
        "sed -i.bak 's|^    suggested=\"\${current:-\$FALLBACK_DOMAIN}\"$|    suggested=\"\$FALLBACK_DOMAIN\"|' ut-install"

    capability_discriminates "the preflight resolving the fallback instead" \
        "the preflight resolves the address in use" \
        "sed -i.bak 's#candidate=\$(configured_domain)#candidate=\"\"#' ut-install"

    if command -v python3 >/dev/null 2>&1; then
        capability_discriminates "the typed answer discarded" \
            "the address typed at the prompt is the one it takes" \
            "sed -i.bak 's|^    DOMAIN=\"\${answer:-\$suggested}\"$|    DOMAIN=\"\$suggested\"|' ut-install"

        capability_discriminates "the prompt offering the fallback over the configured address" \
            "answering nothing at the prompt keeps what the machine already answers on" \
            "sed -i.bak 's|^    suggested=\"\${current:-\$FALLBACK_DOMAIN}\"$|    suggested=\"\$FALLBACK_DOMAIN\"|' ut-install"
    fi
fi

# This one has its own lever rather than a mutation: the check builds its
# destination, so breaking it means pointing it elsewhere. Sending a backup to
# somewhere that does not answer is also the failure an operator will actually
# meet.
OFFSITE_ENDPOINT=nowhere-at-all \
capability_discriminates "a backup destination that does not answer" \
    "backups can leave the machine" \
    "true"

printf '\n%s%d discriminate%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d do not%s\n' "$RED" "$FAILED" "$NC"
    printf '\nThese checks pass whatever happens, which makes them decoration:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
