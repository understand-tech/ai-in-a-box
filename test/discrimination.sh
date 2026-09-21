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
    ( cd "$REPO_ROOT" && tar -cf - release.env compose.yaml compose.appbuilder.yaml \
        compose.compute.yaml compose.no-gpu.yaml Caddyfile caddy backup-files.sh \
        setup-autostart.sh ut-logs-archive ut-install ut-certificate ut-verify appbuilder docs \
        packaging README.md test .github 2>/dev/null ) | tar -xf - -C "$COPY" 2>/dev/null
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

    # The filter matches anywhere in a capability's description, so the failing
    # line is found the same way rather than assuming the filter starts it.
    if grep '✘' <<< "$output" | grep -qF "$expected"; then
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

discriminates "a secret given a value by the release" \
    "plaintext-secret:OA_KEY" \
    "printf 'OA_KEY=\"a3f9c1d2e4b8\"\n' >> release.env"

if grep -q 'check_release_env_ships_no_secret' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a secret declared in what the release decides" \
        "secret-in-release-env:JWT_SECRET" \
        "printf 'JWT_SECRET=\"a3f9c1d2e4b8\"\n' >> release.env"

    discriminates "a secret the nominative list never named" \
        "secret-in-release-env:HF_API_TOKEN" \
        "printf 'HF_API_TOKEN=\"\"\n' >> release.env"
fi

discriminates "a secret defaulted in a compose file" \
    "compose-secret-default:JWT_SECRET" \
    "sed -i.bak 's|\${JWT_SECRET:?[^}]*}|\${JWT_SECRET:-shipped-value}|' compose.yaml"

if grep -q 'check_healthcheck_asks_for_a_certified_name' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a healthcheck asking for a name the certificate does not carry" \
        "healthcheck-name-not-certified:localhost" \
        "sed -i.bak 's|https://step-ca:9000|https://localhost:9000|' compose.yaml"
fi

if grep -q 'check_no_service_starts_slower_than_the_installer_waits' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a service given longer to start than the install waits" \
        "start-period-outlasts-the-install:mongodb-backup" \
        "sed -i.bak 's|^      start_period: 10m$|      start_period: 25h|' compose.yaml"

    # The same mutation hits files-backup too: both are expected, since one
    # value shared by two services is two problems, not one.
    discriminates "the second service sharing that value, named too" \
        "start-period-outlasts-the-install:files-backup" \
        "sed -i.bak 's|^      start_period: 10m$|      start_period: 25h|' compose.yaml"
fi

if grep -q 'check_every_service_declares_its_role' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a service whose role label was dropped" \
        "service-without-a-role:nim-llm" \
        "sed -i.bak '/^  nim-llm:\$/,/^      ut.role:/ s|^      ut.role: \"inference\"\$||' compose.yaml"

    # A role nobody knows is worse than no role at all: ut-install would read it,
    # find no match, and silently fall back to waiting for the service.
    discriminates "a role spelled in a way nothing reads" \
        "service-with-an-unknown-role:nim-llm" \
        "sed -i.bak '/^  nim-llm:\$/,/^      ut.role:/ s|ut.role: \"inference\"|ut.role: \"inferences\"|' compose.yaml"
fi

if grep -q 'check_the_first_backup_is_not_deferred_to_a_clock_time' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "the first backup put back on a clock time" \
        "first-backup-deferred:1520" \
        "sed -i.bak 's|\${BACKUP_BEGIN:-+0}|\${BACKUP_BEGIN:-1520}|' compose.yaml"
fi

discriminates "one variable with two different defaults" \
    "divergent-default:MONGODB_HOST" \
    "sed -i.bak 's|\${MONGODB_HOST:-mongodb}|\${MONGODB_HOST:-}|' compose.appbuilder.yaml"

# Guarded like the capability blocks: the list grows with the branch rather
# than failing on one that predates a check.
if grep -q 'check_required_variables_appear_in_the_template' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a required variable that nothing declares and nothing generates" \
        "required-variable-missing:SOMETHING_REQUIRED" \
        "sed -i.bak 's|^  redis:|  redis:\n    hostname: \${SOMETHING_REQUIRED:?nobody sets this}|' compose.yaml"
fi

discriminates "a variable with no default and no value" \
    "undeclared-variable:SOMETHING_NOBODY_SET" \
    "sed -i.bak 's|^  redis:|  redis:\n    hostname: \${SOMETHING_NOBODY_SET}|' compose.yaml"

discriminates "a port published on every interface" \
    "unlisted-port:redis" \
    "sed -i.bak 's|^    expose:|    ports:\n      - \"6399:6379\"\n    expose:|' compose.yaml"

discriminates "verbose logs in the template" \
    "verbose-log-level:LOG_LEVEL" \
    "sed -i.bak 's|^LOG_LEVEL=.*|LOG_LEVEL=\"DEBUG\"|' release.env"

discriminates "an image named by a tag the registry can repoint" \
    "unpinned-image:NIM_IMAGE" \
    "sed -i.bak 's|^NIM_IMAGE=.*|NIM_IMAGE=\"ghcr.io/understand-tech/nim/nvidia/model-free-nim:2.0.9\"|' release.env"

discriminates "a documented path that does not exist" \
    "missing-documented-path:nowhere.yaml" \
    "printf '\nSee \`nowhere.yaml\` for details.\n' >> README.md"

install_walk_discriminates() {
    local description=$1 expected=$2 mutation=$3
    fresh_copy
    ( cd "$COPY" && eval "$mutation" ) >/dev/null 2>&1
    find "$COPY" -name '*.bak' -delete 2>/dev/null

    local output
    output=$( cd "$COPY" && PROPERTY_FILTER="$expected" ./test/fresh-install.sh 2>&1 )

    if grep '✘' <<< "$output" | grep -qF "$expected"; then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        printf '%s      "%s" was expected to fail and did not%s\n' "$DIM" "$expected" "$NC"
        FAILED=$((FAILED + 1))
        FAILURES+=("$description")
    fi
}

ingress_discriminates() {
    local description=$1 expected=$2 mutation=$3
    fresh_copy
    ( cd "$COPY" && eval "$mutation" ) >/dev/null 2>&1
    find "$COPY" -name '*.bak' -delete 2>/dev/null

    local output
    output=$( cd "$COPY" && SURFACE_FILTER="$expected" ./test/ingress.sh 2>&1 )

    if grep '✘' <<< "$output" | grep -qF "$expected"; then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        printf '%s      "%s" was expected to fail and did not%s\n' "$DIM" "$expected" "$NC"
        FAILED=$((FAILED + 1))
        FAILURES+=("$description")
    fi
}

printf '\n%sCapabilities, seen failing%s\n\n' "$BOLD" "$NC"

if grep -q 'role_is_waited_for' "$REPO_ROOT/ut-install"; then
    capability_discriminates "the install waiting for the models again" \
        "handed back while the models are still loading" \
        "sed -i.bak 's|^    \\[\\[ \"\$1\" != \"inference\" \\]\\]\$|    return 0|' ut-install"

    capability_discriminates "nothing waited for at all" \
        "a control plane service still starting is waited for" \
        "sed -i.bak 's|^    \\[\\[ \"\$1\" != \"inference\" \\]\\]\$|    return 1|' ut-install"

    # An engine that gave up and one still loading must not leave by the same
    # door: treating both as loading is how an install claims a success it does
    # not have.
    capability_discriminates "an engine that failed treated as one still loading" \
        "inference engine that failed is not reported as a success" \
        "sed -i.bak 's|elif \\[\\[ \"\$health\" == \"starting\" \\]\\]; then|elif true; then|' ut-install"

    capability_discriminates "the wait counting without naming" \
        "names what is late" \
        "sed -i.bak 's|still starting: %s (%dm elapsed)|still starting (%dm elapsed)|; s|\"\$(names_in \"\$pending\")\" \\\\||' ut-install"
fi

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

if [[ -x "$REPO_ROOT/packaging/build-deb.sh" ]]; then
    capability_discriminates "a command left out of the package" \
        "the release installs as a package" \
        "sed -i.bak 's|install -m 755 \"\$REPO_ROOT/ut-install\" \"\$root/usr/bin/\"|true|' packaging/build-deb.sh"

    capability_discriminates "the settings directory left world-readable" \
        "the settings directory is prepared" \
        "sed -i.bak 's|install -d -m 750 /etc/understandtech|install -d -m 755 /etc/understandtech|' packaging/build-deb.sh"

    capability_discriminates "the settings unreachable from the project directory" \
        "the settings are read from where the release lives" \
        "sed -i.bak 's|ln -s \"/\$CONFIG_DIR/.env\" \"\$root/\$SHARE_DIR/.env\"|true|' packaging/build-deb.sh"

    capability_discriminates "an upgrade that empties the customer's settings" \
        "an upgrade replaces the release and keeps the settings" \
        "sed -i.bak 's|    install -d -m 750 /etc/understandtech|    install -d -m 750 /etc/understandtech\n    : > /etc/understandtech/.env|' packaging/build-deb.sh"

    capability_discriminates "a removal that takes the settings and the data with it" \
        "removing the package leaves the settings and the data behind" \
        "sed -i.bak 's|^# /etc/understandtech and /var/lib/understandtech are deliberately left behind:|rm -rf /etc/understandtech /var/lib/understandtech|' packaging/build-deb.sh"

    capability_discriminates "the installed command cloning over its own release" \
        "installed from the package, it clones nothing" \
        "sed -i.bak 's|        INSTALL_DIR=\"\$PACKAGE_SHARE_DIR\"|        INSTALL_DIR=\"\$CHECKOUT_INSTALL_DIR\"|' ut-install"

    capability_discriminates "the registry token asked for on every run" \
        "a registry login already stored is not asked for a second time" \
        "sed -i.bak 's|^release_is_present() { checkout_exists .. release_comes_from_the_package_manager; }|release_is_present() { checkout_exists; }|' ut-install"

    capability_discriminates "a dependency nobody calls" \
        "every dependency it declares" \
        "sed -i.bak 's|^Depends: openssl|Depends: curl, openssl|' packaging/build-deb.sh"

    capability_discriminates "a build that stamps the hour it ran at" \
        "the same tree builds the same bytes twice" \
        "sed -i.bak 's|^PACKAGE=|unset SOURCE_DATE_EPOCH\nPACKAGE=|' packaging/build-deb.sh"

    capability_discriminates "checksums left in the order the filesystem gave them" \
        "the checksums are written in one order" \
        "sed -i.bak 's/| LC_ALL=C sort -z | xargs -0 md5sum/| xargs -0 md5sum/' packaging/build-deb.sh"

    capability_discriminates "a size read off the block count" \
        "the installed size does not come from a block count" \
        "sed -i.bak 's|^    size=\$(installed_size_in_kib \"\$root\")\$|    size=\$(du -sk \"\$root\" \| cut -f1)|' packaging/build-deb.sh"
fi

if [[ -x "$REPO_ROOT/packaging/pin-images.sh" ]]; then
    capability_discriminates "a registry that answers nothing, taken for an answer" \
        "a tag gains a digest without losing its version" \
        "sed -i.bak 's|^digest_of() {\$|digest_of() { return 0;|' packaging/pin-images.sh"

    capability_discriminates "a digest appended to a reference that had one" \
        "an image that already names its content is left alone" \
        "sed -i.bak 's|^already_pinned() {\$|already_pinned() { return 1;|' packaging/pin-images.sh"
fi

if [[ -x "$REPO_ROOT/packaging/release-bom.sh" ]]; then
    capability_discriminates "a bill of materials that lists no image at all" \
        "a release names every image it ships" \
        "sed -i.bak 's|^image_lines() {\$|image_lines() { return 0;|' packaging/release-bom.sh"

    capability_discriminates "a tag described as though it named one image" \
        "it refuses to describe an image that can move" \
        "sed -i.bak 's|^refuse_images_that_can_move() {\$|refuse_images_that_can_move() { return 0;|' packaging/release-bom.sh"

    capability_discriminates "a release that ships no bill of materials" \
        "and the release publishes what it is made of" \
        "sed -i.bak '/release-bom.sh/d' .github/workflows/release.yml"

    # What actually stopped v2026.09.5-rc3: the document was valid CycloneDX and
    # attestation still refused it, for the one field it happens to read.
    capability_discriminates "a document attestation would call unsupported" \
        "it carries the three fields attestation reads" \
        "sed -i.bak '/\"serialNumber\"/d' packaging/release-bom.sh"

    capability_discriminates "a serial number drawn afresh every run" \
        "and two runs of one release write the same document" \
        "sed -i.bak 's|understandtech-appliance \${VERSION}|understandtech-appliance \${VERSION}\${RANDOM}|' packaging/release-bom.sh"
fi

if [[ -x "$REPO_ROOT/ut-verify" ]]; then
    capability_discriminates "a verification that refuses what the release signed" \
        "a package the release signed is accepted" \
        "sed -i.bak 's|-signature \"\$signature\"|-signature /dev/null|' ut-verify"

    capability_discriminates "a verification that accepts anything" \
        "not signed at all is refused" \
        "sed -i.bak 's|^    if openssl dgst .*; then$|    if true; then|' ut-verify"

    # The regression this guards is a key fetched rather than carried: it
    # passes on a developer's machine and fails on the only machine that counts.
    capability_discriminates "a key fetched instead of carried" \
        "and it verifies with no network at all" \
        "sed -i.bak 's|^RELEASE_PUBLIC_KEY=.*|RELEASE_PUBLIC_KEY=\$(wget -qO- https://example.invalid/key)|' ut-verify"

    capability_discriminates "a shipped key that is not the signing key" \
        "the key ut-verify carries is the key the release is signed with" \
        "openssl ecparam -name prime256v1 -genkey -noout -out /tmp/other-\$\$.pem 2>/dev/null && openssl ec -in /tmp/other-\$\$.pem -pubout -out packaging/release.pub 2>/dev/null"
fi

if [[ -d "$REPO_ROOT/.github/workflows" ]]; then
    capability_discriminates "a workflow GitHub cannot read" \
        "every workflow is one GitHub can read" \
        "printf 'NOT_INDENTED\n' >> .github/workflows/release.yml"
fi

if [[ -f "$REPO_ROOT/.github/dependabot.yml" ]]; then
    capability_discriminates "an update channel that never looks at the actions" \
        "the pinned actions have a way to move" \
        "sed -i.bak 's|github-actions|npm|' .github/dependabot.yml"

    capability_discriminates "an update channel GitHub cannot read" \
        "the pinned actions have a way to move" \
        "printf 'NOT_INDENTED\n' >> .github/dependabot.yml"
fi

if [[ -f "$REPO_ROOT/.github/workflows/release.yml" ]]; then
    capability_discriminates "a release that lets the build time float" \
        "the release fixes the date it builds with" \
        "sed -i.bak '/SOURCE_DATE_EPOCH/d' .github/workflows/release.yml"

    capability_discriminates "a release resting on our own key alone" \
        "the release attests what it built" \
        "sed -i.bak '/attest-build-provenance/d' .github/workflows/release.yml"
fi

# This one has its own lever rather than a mutation: the check builds its
# destination, so breaking it means pointing it elsewhere. Sending a backup to
# somewhere that does not answer is also the failure an operator will actually
# meet.
OFFSITE_ENDPOINT=nowhere-at-all \
capability_discriminates "a backup destination that does not answer" \
    "backups can leave the machine" \
    "true"

capability_discriminates "the dumps looked for where they are not" \
    "the database leaves with them" \
    "sed -i.bak 's|BACKUP_DUMPS:-/backup|BACKUP_DUMPS:-/nowhere|' backup-files.sh"

if [[ -x "$REPO_ROOT/test/fresh-install.sh" ]]; then
    printf '\n%sA fresh install, seen failing%s\n\n' "$BOLD" "$NC"

    install_walk_discriminates "writing through a link whose directory is gone" \
        "it is recreated rather than reported as a broken link" \
        "sed -i.bak 's|^    install -d -m 750 |    : |' ut-install"

    install_walk_discriminates "an empty settings file kept as if configured" \
        "and the result still renders" \
        "sed -i.bak 's|^render_settings() {$|render_settings() { return 0;|' ut-install"

    install_walk_discriminates "a disk floor that lets every machine through" \
        "the refusal names what is free and what is needed" \
        "sed -i.bak 's|^MIN_DISK_BYTES=.*|MIN_DISK_BYTES=0|' ut-install"

    # The clock check reads one value out of release.env. Make that read fail and
    # it skips in silence, which is the shape the defect would really take.
    install_walk_discriminates "a clock nothing compares to anything" \
        "the preflight stops rather than issue certificates nothing will accept" \
        "sed -i.bak 's|^release_declares() {\$|release_declares() { return 1;|' ut-install"
fi

if grep -q 'checkouts_holding_settings' "$REPO_ROOT/ut-install"; then
    install_walk_discriminates "an install blind to the checkout it replaces" \
        "its settings are carried over, not regenerated" \
        "sed -i.bak 's|^checkouts_holding_settings() {\$|checkouts_holding_settings() { return 0;|' ut-install"

    install_walk_discriminates "the address decided again instead of read" \
        "the address it already answers on is kept" \
        "sed -i.bak 's|^configured_domain() {\$|configured_domain() { return 0;|' ut-install"

    install_walk_discriminates "an address no URL is allowed to name" \
        "an install too old to name its address has it read from its URLs" \
        "sed -i.bak 's|^domain_named_by_the_urls() {\$|domain_named_by_the_urls() { return 1;|' ut-install"

    install_walk_discriminates "a migration that takes the checkout with it" \
        "the checkout itself is left untouched" \
        "sed -i.bak 's|migrate_existing_settings_into_local \"\$source_settings\" \"\$local_file\"|& \&\& rm -f \"\$source_settings\"|' ut-install"

    install_walk_discriminates "a required variable nobody generates" \
        "every variable the stack requires has a value" \
        "sed -i.bak 's| CA_PASSWORD GPU_VM_API_TOKEN)| CA_PASSWORD)|' ut-install"

if grep -q 'check_the_package_stamps_the_commit_it_was_built_from' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a package that says nothing about the code inside it" \
        "package-version-without-commit" \
        "sed -i.bak 's|UT_RELEASE_VERSION=\\\\\"\${stamp}|UT_RELEASE_VERSION=\\\\\"\${version}|' packaging/build-deb.sh"
fi

if grep -q 'if ! terminal_is_reachable' "$REPO_ROOT/ut-install"; then
    install_walk_discriminates "a terminal assumed rather than opened" \
        "it finishes, and says so" \
        "sed -i.bak 's|^terminal_is_reachable() .*$|terminal_is_reachable() { [[ -w /dev/tty ]]; }|' ut-install"

    install_walk_discriminates "an install that finishes without saying where the secrets are" \
        "the secrets can be found afterwards" \
        "sed -i.bak 's|^        log_info \"No terminal here.*$|        :|' ut-install"
fi

if grep -q 'looks_like_a_checkout' "$REPO_ROOT/ut-install"; then
    install_walk_discriminates "an installer blind to the checkout it stands in" \
        "it takes the checkout it is standing in, and asks for no token" \
        "sed -i.bak 's|^    \[\[ -f \"\$1/compose.yaml\" && -d \"\$1/.git\" \]\]$|    false|' ut-install"

    # The guard this change stands next to without touching. A neighbouring
    # correction that quietly opens the way in is exactly what it must not do.
    install_walk_discriminates "a way in that no longer needs a key" \
        "but a machine with no credentials is still asked for a key" \
        "sed -i.bak 's|^    release_is_present && registry_credentials_stored && return 1$|    release_is_present \&\& return 1|' ut-install"
fi

    install_walk_discriminates "a database nobody has the password for, accepted" \
        "the install stops, and says which volume and what to do" \
        "sed -i.bak 's|^    \[\[ -n \"\$(env_get \"\$env_file\" MONGODB_PASSWORD .*$|    true|' ut-install"

    install_walk_discriminates "a password refused for the way it looks" \
        "the install carries on, because that password is the right one" \
        "sed -i.bak 's#^    \[\[ -n .*MONGODB_PASSWORD.*\$#    ! is_shipped_placeholder \"\$(env_get \"\$env_file\" MONGODB_PASSWORD || true)\"#' ut-install"

    install_walk_discriminates "full address pools noticed only when it is too late" \
        "the preflight stops before anything is written" \
        "sed -i.bak 's|^    elif docker_can_still_allocate_a_network; then$|    elif true; then|' ut-install"

    install_walk_discriminates "two machines given the same secret" \
        "two installs do not share a secret" \
        "sed -i.bak 's|^random_alphanumeric() {$|random_alphanumeric() { printf %s the-same-everywhere; return 0;|' ut-install"
fi

if [[ -x "$REPO_ROOT/test/ingress.sh" ]]; then
    printf '\n%sThe front door, seen failing%s\n\n' "$BOLD" "$NC"

    ingress_discriminates "a surface whose upstream no longer exists" \
        "https://llms.box.example.test is served" \
        "sed -i.bak 's|reverse_proxy app-llms:80|reverse_proxy nowhere:80|' Caddyfile"

    # The defect this caught the day it was written: a redirect URI that the
    # ingress sends to the frontend, where no callback is ever handled.
    # custom mode falling back to the appliance's own authority is invisible: the
    # browser is happy and the operator's fleet still needs an import.
    ingress_discriminates "custom mode quietly serving its own certificate" \
        "it serves the certificate it was given" \
        "sed -i.bak '/fullchain.pem/ s|.*|    tls internal|' caddy/ingress-custom.caddy"

    ingress_discriminates "an upstream proxy no longer believed about the scheme" \
        "it believes a trusted proxy about the scheme" \
        "sed -i.bak '/trusted_proxies/d' caddy/ingress-edge.caddy"

    ingress_discriminates "a documented redirect URI that never reaches the API" \
        "the documented OIDC redirect URI reaches the platform API" \
        "sed -i.bak 's|/api/openid/callback|/en/login/openid-auth|' docs/first-run-configuration.md"
fi

printf '\n%s%d discriminate%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d do not%s\n' "$RED" "$FAILED" "$NC"
    printf '\nThese checks pass whatever happens, which makes them decoration:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
