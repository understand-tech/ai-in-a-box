#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/images.sh"
WORK_DIR="$(mktemp -d)"

cleanup() {
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

COPY="$WORK_DIR/repo"

fresh_copy() {
    rm -rf "$COPY"
    mkdir -p "$COPY"
    ( cd "$REPO_ROOT" && tar -cf - release.env compose.yaml compose.appbuilder.yaml \
        compose.compute.yaml compose.no-gpu.yaml compose.backup-mount.yaml compose.backup-network.yaml compose.remote-inference.yaml compose.engine-vllm.yaml models \
        Caddyfile caddy metrics backup-files.sh \
        setup-autostart.sh bin go.mod cmd appbuilder docs \
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

discriminates "the App Builder's token key defaulted in its overlay" \
    "compose-secret-default:APP_BUILDER_TOKEN_ENCRYPTION_KEY" \
    "sed -i.bak 's|\${APP_BUILDER_TOKEN_ENCRYPTION_KEY:-}|\${APP_BUILDER_TOKEN_ENCRYPTION_KEY:-shipped-value}|' compose.appbuilder.yaml"

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

if grep -q 'check_every_service_declares_a_healthcheck' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a service whose healthcheck was dropped" \
        "service-without-a-healthcheck:workers" \
        "sed -i.bak '/^  workers:\$/,/^    logging:/ s|^    healthcheck:\$|    healthcheck_dropped:|' compose.yaml"
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

discriminates "the recorder published on every interface" \
    "unlisted-port:metrics:9090:9090" \
    "sed -i.bak '/^  metrics:\$/,/^    expose:/ s|^    expose:|    ports:\n      - \"9090:9090\"\n    expose:|' compose.yaml"

if grep -q 'check_the_recorder_is_bounded' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "the recorder kept by age alone" \
        "recorder-unbounded-in-size" \
        "sed -i.bak '/--storage.tsdb.retention.size=/d' compose.yaml"

    discriminates "the recorder kept by size alone" \
        "recorder-unbounded-in-time" \
        "sed -i.bak '/--storage.tsdb.retention.time=/d' compose.yaml"
fi

if grep -q 'check_services_that_mount_a_release_file_follow_the_release' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a service reading a release file that no release recreates" \
        "release-file-without-release-label:metrics" \
        "sed -i.bak '/ut.role: \"metrics\"/{n;/ut.release/d;}' compose.yaml"
fi

if grep -q 'check_the_package_ships_what_the_stack_mounts' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a mounted file left out of the package" \
        "mounted-but-not-shipped:metrics" \
        "sed -i.bak '/REPO_ROOT\\/metrics/d' packaging/build-deb.sh"
fi

if grep -q 'check_every_tool_ships' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "an operator tool left out of the package" \
        "tool-not-shipped:ut-report" \
        "sed -i.bak '/REPO_ROOT\\/bin\\/ut-report/d' packaging/build-deb.sh"
fi

discriminates "an operator tool left at the root of the repository" \
    "tool-at-the-root:ut-status" \
    "cp bin/ut-status ut-status"

if grep -q 'check_ut_send_uses_only_the_standard_library' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a Go module pulled into ut-send" \
        "ut-send-dependency" \
        "printf 'require example.com/anything v1.0.0\\n' >> go.mod"
fi

if grep -q 'check_the_install_starts_the_stack_as_boot_does' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "an install that leaves a retired service running" \
        "install-keeps-retired-containers" \
        "sed -i.bak 's|compose_in_dir up -d --remove-orphans|compose_in_dir up -d|' bin/ut-install"
fi

discriminates "verbose logs in the template" \
    "verbose-log-level:LOG_LEVEL" \
    "sed -i.bak 's|^LOG_LEVEL=.*|LOG_LEVEL=\"DEBUG\"|' release.env"

discriminates "an image named by a tag the registry can repoint" \
    "unpinned-image:NIM_IMAGE" \
    "sed -i.bak 's|^NIM_IMAGE=.*|NIM_IMAGE=\"ghcr.io/understand-tech/nim/nvidia/model-free-nim:2.0.9\"|' release.env"

discriminates "a compose image named by a tag the registry can repoint" \
    "unpinned-compose-image:caddy" \
    "sed -i.bak 's|\${CADDY_IMAGE:-[^}]*}|caddy:2-alpine|' compose.yaml"

if grep -q 'check_every_setting_reaches_something' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a setting the stack never reads" \
        "setting-reaches-nothing:DEAD_SETTING" \
        "printf 'DEAD_SETTING=\"nothing reads this\"\n' >> release.env"
fi

if grep -q 'check_the_gateway_trusts_the_app_builder_key' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a gateway that stopped trusting the app builder's key" \
        "gateway-does-not-trust-the-app-builder:api-customer" \
        "sed -i.bak '/^  api-customer:\$/,/^  [a-z]/ s|^      GATEWAY_TRUSTED_PROXY_KEYS:.*\$||' compose.yaml"
fi

discriminates "a documented path that does not exist" \
    "missing-documented-path:nowhere.yaml" \
    "printf '\nSee \`nowhere.yaml\` for details.\n' >> README.md"

discriminates "a stand-in answering a port no healthcheck asks for" \
    "stub-answers-no-port-for-a-healthcheck" \
    "sed -i.bak 's|^:8501 {|:9501 {|' test/stub.caddy"

discriminates "a stand-in kept for a service that is gone" \
    "stub-overlay-names-a-service-that-is-gone" \
    "sed -i.bak 's|^  admin-portal:|  admin-portal-renamed:|' compose.yaml"

discriminates "a healthcheck moved to a route the stand-in answers 404 on" \
    "stub-serves-no-route-for-a-healthcheck" \
    "sed -i.bak 's|http://localhost:8501/api/docs|http://localhost:8501/api/healthz|' compose.yaml"


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

migration_discriminates() {
    local description=$1 expected=$2 mutation=$3
    fresh_copy
    ( cd "$COPY" && eval "$mutation" ) >/dev/null 2>&1
    find "$COPY" -name '*.bak' -delete 2>/dev/null

    local output
    output=$( cd "$COPY" && MIGRATION_HISTORY="$REPO_ROOT" ./test/migration.sh 2>&1 )

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

if grep -q 'role_is_waited_for' "$REPO_ROOT/bin/ut-install"; then
    capability_discriminates "the install waiting for the models again" \
        "handed back while the models are still loading" \
        "sed -i.bak 's|^    \\[\\[ \"\$1\" != \"inference\".*|    return 0|' bin/ut-install"

    capability_discriminates "nothing waited for at all" \
        "a control plane service still starting is waited for" \
        "sed -i.bak 's|^    \\[\\[ \"\$1\" != \"inference\".*|    return 1|' bin/ut-install"

    # An engine that gave up and one still loading must not leave by the same
    # door: treating both as loading is how an install claims a success it does
    # not have.
    capability_discriminates "an engine that failed treated as one still loading" \
        "inference engine that failed is not reported as a success" \
        "sed -i.bak 's|elif \\[\\[ \"\$health\" == \"starting\" \\]\\]; then|elif true; then|' bin/ut-install"

    capability_discriminates "the wait counting without naming" \
        "names what is late" \
        "sed -i.bak 's|still starting: %s (%dm elapsed)|still starting (%dm elapsed)|; s|\"\$(names_in \"\$pending\")\" \\\\||' bin/ut-install"
fi

if grep -q 'say_each_image_as_it_lands' "$REPO_ROOT/bin/ut-install"; then
    capability_discriminates "every layer counted as an image" \
        "the download says each image as it lands" \
        "sed -i.bak '/^        \[\[ \"\$line\" == \*'\"'\"'\"id\":\"Image '\"'\"'\* \]\] || continue\$/d' bin/ut-install"

    capability_discriminates "a failed download that goes on" \
        "a download that fails still stops the install" \
        "sed -i.bak 's#^        compose_in_dir --progress json pull 2>\\&1 | #        { compose_in_dir --progress json pull 2>\\&1 || true; } | #' bin/ut-install"

    capability_discriminates "progress read where Compose does not write it" \
        "the download says each image as it lands" \
        "sed -i.bak 's#compose_in_dir --progress json pull 2>\\&1 | #compose_in_dir --progress json pull | #' bin/ut-install"

    capability_discriminates "a project Compose refuses that goes unsaid" \
        "a project Compose refuses is named" \
        "sed -i.bak 's#^        if \[\[ \"\$line\" == \*'\"'\"'\"error\":true'\"'\"'\* \]\]; then\$#        if false; then#' bin/ut-install"

    capability_discriminates "JSON progress asked of a Compose that refuses it" \
        "a Compose without JSON progress downloads as before" \
        "sed -i.bak 's|^    if compose_reports_progress_as_json; then\$|    if true; then|' bin/ut-install"

    capability_discriminates "a last screen that forgets how long it took" \
        "the last screen says how long it took" \
        "sed -i.bak 's|Installation complete in \$(( SECONDS / 60 )) min|Installation complete|' bin/ut-install"
fi

capability_discriminates "a builder that waits for an llm a panel does not run" \
    "the App Builder renders on a machine without a GPU" \
    "sed -i.bak '/^        required: false\$/d' compose.appbuilder.yaml"

capability_discriminates "the authority removed from the stack" \
    "the appliance runs its own certificate authority" \
    "sed -i.bak 's|^  step-ca:|  step-ca:\n    profiles: [\"never-enabled\"]|' compose.yaml"

capability_discriminates "the recorder left out where an engine runs" \
    "a machine that runs an engine records its load" \
    "sed -i.bak 's|^  metrics:\$|  metrics:\n    profiles: [\"never-enabled\"]|' compose.yaml"

capability_discriminates "the recorder tied to the engine again" \
    "a machine without a GPU still records what its gateway and front door served" \
    "sed -i.bak 's|^  metrics:\$|  metrics:\n    profiles: [\"nim\", \"nim-llm\"]|' compose.yaml"

capability_discriminates "a compute node that opens its engine port to the network" \
    "a compute node lets other machines reach its engine only with its key" \
    "printf '  nim-llm:\\n    ports: !override\\n      - \"0.0.0.0:8001:8000\"\\n' >> compose.compute.yaml"

capability_discriminates "an engine port declared again, which Docker never publishes" \
    "a model on vLLM runs in place of NIM, with the same GPU and cache, and no port of its own" \
    "sed -i.bak 's|^    # No ports: Docker publishes none for a container on internal networks only.\$|    ports:\\n      - \"127.0.0.1:8001:8000\"|' compose.yaml"

capability_discriminates "a compute node that starts without an engine key" \
    "a compute node lets other machines reach its engine only with its key" \
    "sed -i.bak 's|VLLM_API_KEY: \${VLLM_API_KEY:?ut-install generates it}|VLLM_API_KEY: \${VLLM_API_KEY:-}|' compose.compute.yaml"

capability_discriminates "the arguments of a vLLM model passed as one" \
    "each argument of the model reaches vLLM whole, JSON included" \
    "sed -i.bak 's|--port 8000 \\\$\\\$VLLM_ENGINE_ARGS|--port 8000 \\\\\"\$\$VLLM_ENGINE_ARGS\\\\\"|' compose.engine-vllm.yaml"

capability_discriminates "a vLLM engine that names its model by its local path" \
    "each argument of the model reaches vLLM whole, JSON included" \
    "sed -i.bak 's|--served-model-name [^ ]* ||' compose.engine-vllm.yaml"

capability_discriminates "a vLLM engine checked where NIM answers" \
    "a model on vLLM runs in place of NIM, with the same GPU and cache, and no port of its own" \
    "sed -i.bak '/localhost:8000\\/health/d; /^    healthcheck:\$/d' compose.engine-vllm.yaml"

capability_discriminates "a caller of the compute node left on the public roots" \
    "every service that calls a compute node trusts its root" \
    "sed -i.bak '/^  api-customer: \\*trusts-the-compute-node\$/d' compose.remote-inference.yaml"

if grep -q 'record_this_install' "$REPO_ROOT/bin/ut-install"; then
    capability_discriminates "an install run nobody keeps" \
        "every install run is kept, from its first step" \
        "sed -i.bak '/trap record_this_install EXIT/d' bin/ut-install"

    capability_discriminates "a failed install kept as a success" \
        "a failed install is kept, with the step it stopped at" \
        "sed -i.bak 's|outcome=\"failed\"|outcome=\"done\"|' bin/ut-install"

    capability_discriminates "the history written over at each install" \
        "a second install is added after the first, never over it" \
        "sed -i.bak 's|>> \"\\\$history\"|> \"\\\$history\"|' bin/ut-install"

    capability_discriminates "a verdict kept without the memory left" \
        "a status verdict is kept beside the installs" \
        "sed -i.bak 's/,\"available_bytes\":%s//' bin/ut-status"

    capability_discriminates "a status verdict nobody keeps" \
        "a status verdict is kept beside the installs" \
        "sed -i.bak '/keep_the_verdict \"/d' bin/ut-status"

    capability_discriminates "a timer that does not run, said as if all were well" \
        "it says whether usage reports go out" \
        "sed -i.bak 's/) log_warn \"\$line\" ;;/) log_info \"\$line\" ;;/' bin/ut-status"
fi

if [[ -x "$REPO_ROOT/bin/ut-report" ]]; then
    capability_discriminates "a report written where nothing was installed" \
        "a directory with no install gets no report" \
        "sed -i.bak 's|^    \[\[ -f \"\$INSTALL_DIR/compose.yaml\" \]\].*|    :|' bin/ut-report"

    capability_discriminates "the recorder asked at an address it does not answer" \
        "the report finds the engine the recorder holds" \
        "sed -i.bak 's|\"query?query=|\"query=|' bin/ut-report"

    capability_discriminates "a report that names who asked" \
        "the report holds no key outside its schema" \
        "sed -i.bak 's|\"install_id\": \"%s\",|\"install_id\": \"%s\", \"user\": \"someone@example.com\",|' bin/ut-report"

    capability_discriminates "requests with nobody behind them, unremarked" \
        "requests served with no user counted are flagged" \
        "sed -i.bak '/users-missing:/d' bin/ut-report"

    capability_discriminates "a missing series reported as a quiet hour" \
        "a series the recorder does not have is flagged" \
        "sed -i.bak '/series-missing:/d' bin/ut-report"

    capability_discriminates "the minutes requests waited left out of the report" \
        "the minutes requests waited for the engine are counted" \
        "sed -i.bak 's/ waiting_peak saturated_minutes / waiting_peak /' bin/ut-report"

    capability_discriminates "a stopped recorder reported as an idle machine" \
        "an engine nobody recorded is flagged" \
        "sed -i.bak '/recorder-missing:/d' bin/ut-report"

    capability_discriminates "a forecast that never warns" \
        "a recorder that will outgrow its cap is flagged before it does" \
        "sed -i.bak 's|if (kept < wanted)|if (kept < 0)|' bin/ut-report"

    capability_discriminates "a retention read up to its first unit only" \
        "a cap written in other units is read the same" \
        "sed -i.bak 's|while (match(d,|if (match(d,|' bin/ut-report"

    capability_discriminates "a forecast drawn from an hour of write-ahead log" \
        "a recorder too young to judge raises nothing" \
        "sed -i.bak 's|covered < 1 |covered < 0 |' bin/ut-report"

    capability_discriminates "a report silent about memory" \
        "the report gives each service its memory peak and limit" \
        "sed -i.bak '/\"memory\": %s/d' bin/ut-report"

    capability_discriminates "an unreadable memory peak reported as nothing" \
        "a memory peak nobody can read is flagged" \
        "sed -i.bak '/memory-peak-unknown:/d' bin/ut-report"

    capability_discriminates "a manifest that vouches for nothing" \
        "the manifest carries the report's checksum" \
        "sed -i.bak 's|sha256 \${checksum}|sha256 unknown|' bin/ut-report"
fi

if grep -q 'install_status_timer' "$REPO_ROOT/setup-autostart.sh"; then
    capability_discriminates "the hourly status check never installed" \
        "the status check runs every hour" \
        "sed -i.bak '/^    install_status_timer\$/d' setup-autostart.sh"

    capability_discriminates "the status check pointed at a tool the package does not ship" \
        "installed from the package, the status check runs the packaged tool" \
        "sed -i.bak 's/command -v ut-status/command -v ut-status-gone/' setup-autostart.sh"

    capability_discriminates "the status check left behind by an uninstall" \
        "removing the units removes the status check" \
        "sed -i.bak '/rm -f .*STATUS_TIMER_FILE/d' setup-autostart.sh"
fi

capability_discriminates "the authority root moved out of the backed-up path" \
    "its root sits where the file backup looks" \
    "sed -i.bak 's|\${DATA_ROOT:-/var/lib/understandtech}/ca:/home/step|step-ca-data:/home/step|' compose.yaml"

capability_discriminates "the machine surface pointed at something else" \
    "the machine-facing surface takes its certificate from that authority" \
    "sed -i.bak 's|step-ca:9000/acme|acme-v02.api.letsencrypt.org|' caddy/internal-surface.caddy"

capability_discriminates "a folder image taken without proving it is the one the release names" \
    "a folder holding an image the release does not name is refused" \
    "sed -i.bak 's/\\[\\[ \"\\\$(sha256_of \"\\\$dir\/named.json\")\" == \"\\\${reference#\\*@}\" \\]\\] || return 1/:/' bin/ut-install"

capability_discriminates "a weight placed without checking its content" \
    "a weight that is not the file the release lists is refused" \
    "sed -i.bak 's/ || \\[\\[ \"\\\$(sha256_of \"\\\$file\")\" != \"sha256:\\\$sha\" \\]\\]; then/; then/' bin/ut-install"

capability_discriminates "a weight downloaded without checking its content" \
    "a download that is not the listed file is refused" \
    "sed -i.bak 's/ || \"\\\$(sha256_of_file \"\\\$target.part\")\" != \"\\\$sha\" \\]\\]; then/ ]]; then/' bin/ut-get"

capability_discriminates "weights placed with the engine still free to download" \
    "weights from a folder land where each service looks" \
    "sed -i.bak '/env_set \"\\\$local_file\" HF_HUB_OFFLINE \"1\"/d' bin/ut-install"

capability_discriminates "an engine cache with no revision to resolve" \
    "weights from a folder land where each service looks" \
    "sed -i.bak '/printf .=%s %s.refs.main/d' bin/ut-install"

capability_discriminates "engine weights left to root" \
    "weights from a folder land where each service looks" \
    "sed -i.bak 's|copy_into_a_volume \"\\\$(volume_ready nim-llm-cache)\" \"1000:1000\"|copy_into_a_volume \"\\\$(volume_ready nim-llm-cache)\" \"\"|' bin/ut-install"

capability_discriminates "a model prepared with no weights for it" \
    "a model whose weights the release does not list is not prepared" \
    "sed -i.bak 's|^die_on_a_model_the_bill_does_not_carry() {\$|die_on_a_model_the_bill_does_not_carry() { return 0;|' bin/ut-get"

capability_discriminates "a bill of materials that forgets the weights" \
    "the bill of materials lists every weight the release pins" \
    "sed -i.bak 's|^weight_lines() {\$|weight_lines() { return 0;|' packaging/release-bom.sh"

capability_discriminates "a folder taken whatever processor it was prepared for" \
    "a folder prepared for another processor is refused" \
    "sed -i.bak 's|^die_on_a_folder_for_another_architecture() {\$|die_on_a_folder_for_another_architecture() { return 0;|' bin/ut-install"

capability_discriminates "a folder tool loaded whatever it turns out to be" \
    "a folder whose tool is not the one the release names is refused" \
    "sed -i.bak 's/^        \\[\\[ -n \"\\\$config\" && /        [[ -n \"\$config\" || /' bin/ut-install"

capability_discriminates "folder images named by tag rather than by digest" \
    "images from a prepared folder start under the digest the release names" \
    "sed -i.bak 's|        env_set \"\\\$local_file\" \"\\\$key\" \"\\\$local_name\"|        env_set \"\\\$local_file\" \"\\\$key\" \"\\\${local_name%@*}:from-a-folder\"|' bin/ut-install"

capability_discriminates "a registry token read under a key Keygen never writes" \
    "a folder is prepared with the registry access the license key reads" \
    "sed -i.bak 's#metadata.registryToken#metadata.registry_token#' bin/ut-get"

capability_discriminates "the license key handed to curl on its command line, to prepare" \
    "a folder is prepared with the registry access the license key reads" \
    "sed -i.bak 's#\"\${KEYGEN_API}/me\"#\"\${KEYGEN_API}/me?k=\${key}\"#' bin/ut-get"

capability_discriminates "a license file carried in the folder, and left there" \
    "the license file carried in a folder goes to ut-install" \
    "sed -i.bak 's#|| printf .%s. \"\${found\[0\]}\"#|| :#' bin/ut-get"

capability_discriminates "two license files in a folder, one taken at random" \
    "the license file carried in a folder goes to ut-install" \
    "sed -i.bak 's#(( \${\#found\[@\]} <= 1 )) ||#true ||#' bin/ut-get"

capability_discriminates "ut-get preparing with another tool than ut-install loads with" \
    "ut-get prepares with the tools ut-install loads with" \
    "sed -i.bak 's|^FOLDER_SKOPEO_TOOL=.*|FOLDER_SKOPEO_TOOL=\"quay.io/skopeo/stable:v1.19.0@sha256:0000000000000000000000000000000000000000000000000000000000000000\"|' bin/ut-get"

capability_discriminates "a database port declared again, which Docker never publishes" \
    "no service declares a port Docker never publishes" \
    "sed -i.bak 's|^    container_name: \${CONTAINER_PREFIX:-ut}-mongodb\$|&\\n    ports:\\n      - \"127.0.0.1:27018:27017\"|' compose.yaml"

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

    capability_discriminates "a compute node publishing the control plane's names" \
        "a compute node on .local publishes none of the platform's names" \
        "sed -i.bak 's|^    if this_machine_is_a_compute_node; then\$|    if false; then|' setup-autostart.sh"

    capability_discriminates "a compute node asking for the platform's DNS records" \
        "a compute node asks for no DNS record but its inference name" \
        "sed -i.bak 's|^    if this_machine_is_a_compute_node; then\$|    if false; then|' setup-autostart.sh"

    capability_discriminates "a stale publisher left enabled after the move" \
        "moving off .local withdraws a publisher installed earlier" \
        "sed -i.bak 's|^        withdraw_mdns_publisher$|        :|' setup-autostart.sh"
fi

if grep -q 'read_domain' "$REPO_ROOT/bin/ut-install"; then
    capability_discriminates "the address defaulted silently again" \
        "an unattended install falls back to the mDNS name" \
        "sed -i.bak 's|^DOMAIN=\"\${UT_DOMAIN:-}\"|DOMAIN=\"\${UT_DOMAIN:-understand.local}\"|' bin/ut-install"

    capability_discriminates "the address given up front overwritten by the fallback" \
        "an address given up front is taken as it is" \
        "sed -i.bak 's|^    \[\[ -n \"\$DOMAIN\" \]\] \&\& return 0$|    :|' bin/ut-install"

    capability_discriminates "the address already on the machine ignored" \
        "an address the machine already answers on is never replaced" \
        "sed -i.bak 's|^    suggested=\"\${current:-\$FALLBACK_DOMAIN}\"$|    suggested=\"\$FALLBACK_DOMAIN\"|' bin/ut-install"

    capability_discriminates "the preflight resolving the fallback instead" \
        "the preflight resolves the address in use" \
        "sed -i.bak 's#candidate=\$(configured_domain)#candidate=\"\"#' bin/ut-install"

    if command -v python3 >/dev/null 2>&1; then
        capability_discriminates "the typed answer discarded" \
            "the address typed at the prompt is the one it takes" \
            "sed -i.bak 's|^    DOMAIN=\"\${answer:-\$suggested}\"$|    DOMAIN=\"\$suggested\"|' bin/ut-install"

        capability_discriminates "the prompt offering the fallback over the configured address" \
            "answering nothing at the prompt keeps what the machine already answers on" \
            "sed -i.bak 's|^    suggested=\"\${current:-\$FALLBACK_DOMAIN}\"$|    suggested=\"\$FALLBACK_DOMAIN\"|' bin/ut-install"
    fi
fi

if grep -q '^step_reporting()' "$REPO_ROOT/bin/ut-install"; then
    capability_discriminates "reports switched on when nobody was there to answer" \
        "with no answer and no terminal to ask on, nothing is sent" \
        "sed -i.bak 's|^            REPORTING=\"no\"\$|            REPORTING=\"yes\"|' bin/ut-install"

    capability_discriminates "the question asked again on every run" \
        "an answer given once is not asked for again" \
        "sed -i.bak 's|^    \\[\\[ \"\\\$said\" != \"Reporting: not decided\" \\]\\]\$|    false|' bin/ut-install"

    capability_discriminates "a prompt that takes Enter for an answer" \
        "the prompt and the options hand ut-send the same answers" \
        "sed -i.bak 's|^    while \\[\\[ \"\\\$answer\" != \"yes\" \\&\\& \"\\\$answer\" != \"no\" \\]\\]; do\$|    while false; do|' bin/ut-install"

    capability_discriminates "an install stopped by reports it could not set up" \
        "reporting that cannot be set up does not stop the install" \
        "sed -i.bak 's|^    log_warn \"Usage reports could not be set up|    die \"Usage reports could not be set up|' bin/ut-install"

    capability_discriminates "a period the installer keeps to itself" \
        "a period given to the installer reaches ut-send" \
        "sed -i.bak '/--every \"\$REPORTING_EVERY\"/d' bin/ut-install"
fi

if [[ -x "$REPO_ROOT/packaging/build-deb.sh" ]]; then
    capability_discriminates "a command left out of the package" \
        "the release installs as a package" \
        "sed -i.bak 's|install -m 755 \"\$REPO_ROOT/bin/ut-install\" \"\$root/usr/bin/\"|true|' packaging/build-deb.sh"

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
        "sed -i.bak 's|        INSTALL_DIR=\"\$PACKAGE_SHARE_DIR\"|        INSTALL_DIR=\"\$CHECKOUT_INSTALL_DIR\"|' bin/ut-install"

    capability_discriminates "the registry token asked for on every run" \
        "a registry login already stored is not asked for a second time" \
        "sed -i.bak 's|^release_is_present() { checkout_exists .. release_comes_from_the_package_manager; }|release_is_present() { checkout_exists; }|' bin/ut-install"

    capability_discriminates "a dependency nobody calls" \
        "every dependency it declares" \
        "sed -i.bak 's|^Depends: openssl|Depends: rsync, openssl|' packaging/build-deb.sh"

    capability_discriminates "a package that never builds, compared with itself" \
        "the same tree builds the same bytes twice" \
        "sed -i.bak 's|^main \"\$@\"\$|exit 1|' packaging/build-deb.sh"

    capability_discriminates "checksums read from a package that never built" \
        "the checksums are written in one order" \
        "sed -i.bak 's|^main \"\$@\"\$|exit 1|' packaging/build-deb.sh"

    capability_discriminates "a build that stamps the hour it ran at" \
        "the same tree builds the same bytes twice" \
        "sed -i.bak 's|^PACKAGE=|unset SOURCE_DATE_EPOCH\nPACKAGE=|' packaging/build-deb.sh"

    capability_discriminates "checksums left in the order the filesystem gave them" \
        "the checksums are written in one order" \
        "sed -i.bak 's/| LC_ALL=C sort -z | xargs -0 md5sum/| xargs -0 md5sum/' packaging/build-deb.sh"

    capability_discriminates "a package upgrade that takes the reporting timer away" \
        "an upgrade keeps the reporting timer" \
        "sed -i.bak 's|^if \[ \"\$1\" = remove \]|if [ \"\$1\" != failed-upgrade ]|' packaging/build-deb.sh"

    capability_discriminates "a package removal that leaves the reporting timer running" \
        "an upgrade keeps the reporting timer" \
        "sed -i.bak 's|^    systemctl disable --now ut-send.timer|    true|' packaging/build-deb.sh"

    capability_discriminates "a package that leaves ut-setup's builds behind" \
        "it carries ut-setup for both architectures" \
        "sed -i.bak '/stage_builds_of \"\$root\" ut-setup/d' packaging/build-deb.sh"

    capability_discriminates "a package that leaves ut-send's builds behind" \
        "it carries ut-send for both architectures" \
        "sed -i.bak '/stage_builds_of \"\$root\" ut-send/d' packaging/build-deb.sh"

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

if [[ -x "$REPO_ROOT/bin/ut-verify" ]]; then
    capability_discriminates "a verification that refuses what the release signed" \
        "a package the release signed is accepted" \
        "sed -i.bak 's|-signature \"\$signature\"|-signature /dev/null|' bin/ut-verify"

    capability_discriminates "a verification that accepts anything" \
        "not signed at all is refused" \
        "sed -i.bak 's|^    if openssl dgst .*; then$|    if true; then|' bin/ut-verify"

    capability_discriminates "a fingerprint taken of a key file never written" \
        "never fingerprints as the hash of nothing" \
        "sed -i.bak -e 's/ || return 1\$//' -e 's/ || fail \"Cannot write the key to a temporary file\"//' -e 's/|| { rm -f \"\$key\"; fail \"openssl could not read the key\"; }/|| true/' bin/ut-verify"

    # The regression this guards is a key fetched rather than carried: it
    # passes on a developer's machine and fails on the only machine that counts.
    capability_discriminates "a key fetched instead of carried" \
        "and it verifies with no network at all" \
        "sed -i.bak 's|^RELEASE_PUBLIC_KEY=.*|RELEASE_PUBLIC_KEY=\$(wget -qO- https://example.invalid/key)|' bin/ut-verify"

    capability_discriminates "a shipped key that is not the signing key" \
        "the key ut-verify carries is the key the release is signed with" \
        "openssl ecparam -name prime256v1 -genkey -noout -out /tmp/other-\$\$.pem 2>/dev/null && openssl ec -in /tmp/other-\$\$.pem -pubout -out packaging/release.pub 2>/dev/null"
fi

if [[ -x "$REPO_ROOT/bin/ut-get" ]]; then
    capability_discriminates "a launcher that installs whatever it is given" \
        "nothing is installed from a release that was altered" \
        "sed -i.bak 's|^    if openssl dgst .*; then$|    if true; then|' bin/ut-get"

    capability_discriminates "a launcher that installs before it checks" \
        "nothing is installed from a release that was altered" \
        "sed -i.bak 's|^    verify_signature \"\$package\" \\\\$|    true \\\\|' bin/ut-get"

    capability_discriminates "a launcher that drops what it was asked to pass on" \
        "a release we signed is installed, then handed to ut-install" \
        "sed -i.bak 's|^    exec \"\$NEXT\" .*|    exec \"\$NEXT\"|' bin/ut-get"

    capability_discriminates "a launcher that ignores --browser" \
        "with --browser, it hands over to ut-setup" \
        "sed -i.bak 's|--browser) NEXT=ut-setup ;;|--browser) ;;|' bin/ut-get"

    capability_discriminates "a launcher that carries another key than ut-verify" \
        "the key ut-get carries is the key ut-verify carries" \
        "sed -i.bak 's|^62Aggan6|62Aggan7|' bin/ut-get"

    capability_discriminates "a launcher that always takes the latest" \
        "a release named by --version is installed rather than the latest" \
        "sed -i.bak 's|^            --version) VERSION=.*|            --version) shift ;;|' bin/ut-get"

    capability_discriminates "a launcher that downloads again what it has" \
        "a release already downloaded installs again with its server gone" \
        "sed -i.bak '/^        \[\[ -f \"\$dir\/\$name\" \]\] \&\& continue$/d' bin/ut-get"

    capability_discriminates "a launcher that takes any version it is given" \
        "nothing is fetched and the reason is said" \
        "sed -i.bak 's|^is_a_release_version() {.*|is_a_release_version() { return 0; }|' bin/ut-get"

    capability_discriminates "a release that does not publish the launcher" \
        "every release publishes ut-get beside the package" \
        "sed -i.bak '/^            dist\/ut-get \\\\$/d' .github/workflows/release.yml"

    capability_discriminates "an install page that skips a file the sums list" \
        "the manual install downloads every file SHA256SUMS lists" \
        "sed -i.bak 's| ut-verify ut-get release.pub SHA256SUMS; do| ut-verify release.pub SHA256SUMS; do|' docs/install.md"

    capability_discriminates "a launcher that reads a version where GitHub names none" \
        "nothing is fetched and the reason is said" \
        "sed -i.bak 's|^    \[\[ \"\$tag_url\" == \*/releases/tag/v\* \]\] \\\\$|    true \\\\|' bin/ut-get"
fi

if [[ -x "$REPO_ROOT/bin/ut-license" ]]; then
    capability_discriminates "an unreachable Keygen taken for a refusal" \
        "a machine that cannot reach Keygen says so apart" \
        "sed -i.bak 's#; exit 3; }\$#; exit 1; }#' bin/ut-license"

    capability_discriminates "a license file sent back that anyone can read" \
        "a machine activated from its request alone gets a license file it accepts" \
        "sed -i.bak 's#(umask 077 \&\& printf#(umask 022 \&\& printf#' packaging/activate-a-machine.sh"

    capability_discriminates "a license looked up by its machine alone" \
        "a machine activated from its request alone gets a license file it accepts" \
        "sed -i.bak 's#metadata%5Bcustomer%5D=\${customer}\&##' packaging/activate-a-machine.sh"

    capability_discriminates "an unreachable Keygen taken for a refusal" \
        "a machine that cannot reach Keygen says so apart" \
        "sed -i.bak 's#; exit 3; }\$#; exit 1; }#' bin/ut-license"

    capability_discriminates "a license file sent back that anyone can read" \
        "a machine activated from its request alone gets a license file it accepts" \
        "sed -i.bak 's#(umask 077 \&\& printf#(umask 022 \&\& printf#' packaging/activate-a-machine.sh"

    capability_discriminates "a license looked up by its machine alone" \
        "a machine activated from its request alone gets a license file it accepts" \
        "sed -i.bak 's#metadata%5Bcustomer%5D=\${customer}\&##' packaging/activate-a-machine.sh"

    capability_discriminates "a suspended license, still taken" \
        "a license that ended or is suspended is refused" \
        "sed -i.bak 's#elif (\$license.status // \"\") == \"SUSPENDED\" or (\$license.status // \"\") == \"BANNED\" then \"suspended\"#elif false then \"suspended\"#' bin/ut-license"

    capability_discriminates "a key of the old format sent to Keygen as if it were one" \
        "says why it is not activated" \
        "sed -i.bak 's#\[\[ \"\$key\" != UT1.\* \]\] || fail#true || fail#' bin/ut-license"

    capability_discriminates "a key of the old format read as a forged license file" \
        "checked as a license file, says what to ask for" \
        "sed -i.bak '/head -c 4 \"\$machine_file\"/d' bin/ut-license"

    capability_discriminates "a key that passes its settings to curl" \
        "a key that would carry settings to curl is refused" \
        "sed -i.bak 's#\[\[ \"\$key\" =~ .* \]\] || fail#true || fail#' bin/ut-license"

    capability_discriminates "a license file written for anyone to read" \
        "activating binds the license to this machine" \
        "sed -i.bak 's#install -m 600 \"\$staged\"#install -m 644 \"\$staged\"#' bin/ut-license"

    capability_discriminates "an activation and a check that compute two fingerprints" \
        "activating binds the license to this machine" \
        "sed -i.bak 's#^    fingerprint=\$(machine_fingerprint)\$#    fingerprint=\$(machine_fingerprint)x#' bin/ut-license"

    capability_discriminates "a file that only needs renewing, refused like a forged one" \
        "only needs renewing is told apart from a refused one" \
        "sed -i.bak 's#^renewable() { warn \"\$\*\"; exit 2; }#renewable() { warn \"\$*\"; exit 1; }#' bin/ut-license"

    capability_discriminates "a license check that refuses what Keygen signed" \
        "a license file Keygen signed for this machine is accepted" \
        "sed -i.bak 's|-sigfile \"\$work/signature\"|-sigfile /dev/null|' bin/ut-license"

    capability_discriminates "a license check that accepts any file that parses" \
        "is not a license file at all is refused" \
        "sed -i.bak '/openssl pkeyutl -verify/d' bin/ut-license"

    capability_discriminates "a license file that works on any machine" \
        "a license file made for another machine is refused" \
        "sed -i.bak 's#if .data.attributes.fingerprint != \$fingerprint then \"elsewhere\"#if false then \"elsewhere\"#' bin/ut-license"

    capability_discriminates "a clock behind the file, taken for a good one" \
        "a clock set before the file was issued is named" \
        "sed -i.bak 's#elif now + \$tolerance < (.meta.issued | epoch) then \"clock\"#elif false then \"clock\"#' bin/ut-license"

    capability_discriminates "a license that ended, still taken" \
        "a license that ended or is suspended is refused" \
        "sed -i.bak 's#and (\$license.expiry | epoch) < now then \"ended\"#and false then \"ended\"#' bin/ut-license"

    capability_discriminates "a license file that never ends" \
        "a license file past its own end says how to get a new one" \
        "sed -i.bak 's#elif (.meta.expiry | epoch) < now then \"file_ended\"#elif false then \"file_ended\"#' bin/ut-license"

    capability_discriminates "an activation that does not say the license is bound elsewhere" \
        "says why it is not activated" \
        "sed -i.bak 's#FINGERPRINT_SCOPE_MISMATCH|TOO_MANY_MACHINES|MACHINE_LIMIT_EXCEEDED|FINGERPRINT_TAKEN)#NEVER)#' bin/ut-license"

    capability_discriminates "a license key handed to curl on its command line" \
        "nor reach a command line" \
        "sed -i.bak 's#\"\${KEYGEN_API}\${path}\"#\"\${KEYGEN_API}\${path}?k=\${key}\"#' bin/ut-license"

    capability_discriminates "a license check that shows what the license carries" \
        "never come out, nor reach a command line" \
        "sed -i.bak 's#^    valid_dataset \"\$machine_file\" \"\$dataset\"\$#&; cat \"\$dataset\" >\&2#' bin/ut-license"

    capability_discriminates "a license that quietly defaults to an end date nobody chose" \
        "no machine or no end date is never issued" \
        "sed -i.bak 's|^customer=\"\" machine=\"\" expires=\"\"|customer=\"\" machine=\"\" expires=\"2999-12-31\"|' packaging/issue-license.sh"

    capability_discriminates "a shipped license key that is not the one Keygen signs with" \
        "the key ut-license carries is the key licenses are signed with" \
        "openssl genpkey -algorithm ed25519 -out /tmp/other-\$\$.pem 2>/dev/null && openssl pkey -in /tmp/other-\$\$.pem -pubout -out packaging/license.pub 2>/dev/null"

    capability_discriminates "a boot that no longer says the license ended" \
        "at boot, a license that has ended is said" \
        "sed -i.bak '/ut-license check/d' setup-autostart.sh"

    capability_discriminates "a boot that stops on a license that ended" \
        "at boot, a license that has ended is said" \
        "sed -i.bak 's|^ExecStartPre=-/bin/sh|ExecStartPre=/bin/sh|' setup-autostart.sh"

    capability_discriminates "a boot line that fails when the license ended" \
        "at boot, a license that has ended is said" \
        "sed -i.bak 's|/etc/understandtech/machine.lic; exit 0|/etc/understandtech/machine.lic|' setup-autostart.sh"

    capability_discriminates "a status that never mentions the license" \
        "it says how the license stands" \
        "sed -i.bak '/^    say_how_the_license_stands\$/d' bin/ut-status"

    capability_discriminates "a status that calls an ended license fine" \
        "it says how the license stands" \
        "sed -i.bak 's|log_warn \"\${line#|log_info \"\${line#|' bin/ut-status"

    capability_discriminates "a license issued without a machine" \
        "no machine or no end date is never issued" \
        "sed -i.bak 's#\[\[ \"\$machine\" =~ ^\[a-z0-9\]\[a-z0-9-\]\*\$ \]\]#true#' packaging/issue-license.sh"

    capability_discriminates "a license issued under whatever policy comes first" \
        "a license is issued in Keygen, under the policy" \
        "sed -i.bak 's#select(.attributes.name == \$name)#select(true)#' packaging/issue-license.sh"

    capability_discriminates "a license issued and its key printed nowhere" \
        "a license is issued in Keygen, under the policy" \
        "sed -i.bak 's#^jq -r .key <<< \"\$issued\"\$#:#' packaging/issue-license.sh"

    capability_discriminates "a metadata key ut-license does not read" \
        "the license issued carries what ut-license reads" \
        "sed -i.bak 's#registryToken: \.#registry_token: .#' packaging/issue-license.sh"

    capability_discriminates "the Keygen token handed to curl on its command line" \
        "the issuer puts no token on a command line" \
        "sed -i.bak 's#\"\${KEYGEN_API}\${path}\"#\"\${KEYGEN_API}\${path}?t=\${keygen_token}\"#' packaging/issue-license.sh"

    capability_discriminates "a token that can write is taken for one that reads" \
        "a read-only token that pulls the release and outlives it" \
        "sed -i.bak 's|\[\[ \"\$scopes\" == \"read:packages\" \]\]|true|' packaging/issue-license.sh"

    capability_discriminates "a license that outlives its token" \
        "a read-only token that pulls the release and outlives it" \
        "sed -i.bak 's|\[\[ \"\$token_ends\" < \"\$expires\" \]\] \\\\|false \\\\|' packaging/issue-license.sh"

    capability_discriminates "a token never tried against the release" \
        "a read-only token that pulls the release and outlives it" \
        "sed -i.bak '/^    check_the_token_pulls_the_release\$/d' packaging/issue-license.sh"

    capability_discriminates "a ledger that keeps the token" \
        "every license issued is written down, and never its token" \
        "sed -i.bak 's|\"\$registry_user\" \"\$fingerprint\"|\"\$registry_user\" \"\$token\"|' packaging/issue-license.sh"

    capability_discriminates "a license issued and never written down" \
        "every license issued is written down, and never its token" \
        "sed -i.bak 's|^write_it_down |: |' packaging/issue-license.sh"

    capability_discriminates "an installer that drops library/ from Docker Hub's short names" \
        "the installer and the issuer name every image of the release alike" \
        "sed -i.bak 's|reference=\"library/\${reference}\"|reference=\"\${reference}\"|' bin/ut-install"

    capability_discriminates "a license for another registry issued without trying it" \
        "a license for another registry names it, and is checked against it" \
        "sed -i.bak '/^    check_the_account_pulls_the_release_from /d' packaging/issue-license.sh"
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
    "round-trips through an S3 endpoint" \
    "true"

capability_discriminates "the backup given a network with a way out" \
    "the backup has no way off the machine" \
    "sed -i.bak '/^  files-backup:/,/^  [a-z]/ s/- ut-backend-network/- ut-frontend-network/' compose.yaml"

capability_discriminates "the repository left on the machine's own disk" \
    "lands on the destination the host mounts" \
    "sed -i.bak 's|RESTIC_REPOSITORY: /destination/restic|RESTIC_REPOSITORY: /backup/restic|' compose.backup-mount.yaml"

capability_discriminates "a backup written where nothing is mounted" \
    "not mounted is refused" \
    "sed -i.bak '/BACKUP_DESTINATION_MARKER:-/,/^fi\$/d' backup-files.sh"

capability_discriminates "a guide that restores a foreign database whole" \
    "restored on another machine, as the guide says" \
    "sed -i.bak \"s| --nsExclude 'admin.\\*'||\" docs/restore.md"

capability_discriminates "the HTTPS authority left out of what the backup sees" \
    "signs the HTTPS certificate sits where the backup looks" \
    "sed -i.bak '/      - caddy-data:\/caddy:ro/d' compose.yaml"

capability_discriminates "the HTTPS authority seen but not saved" \
    "that authority is backed up and restores identically" \
    "sed -i.bak 's/^    set -- \"\\\$@\" \"\\\$HTTPS_AUTHORITY\"\$/    :/' backup-files.sh"

capability_discriminates "a network destination left on the internal network" \
    "gives the backup one way out, its own" \
    "sed -i.bak 's|      - ut-backup-network|      - ut-backend-network|' compose.backup-network.yaml"

capability_discriminates "an SFTP destination without the keys to check it" \
    "trusted only under the host key pinned for it" \
    "sed -i.bak '/\/root\/.ssh:ro/d' compose.backup-network.yaml"

capability_discriminates "a destination that does not answer, left unnamed" \
    "does not answer is named" \
    "sed -i.bak '/cannot reach the repository/d' backup-files.sh"

capability_discriminates "a password that does not fit, taken for a missing repository" \
    "does not open the repository is named" \
    "sed -i.bak '/does not open the repository/d' backup-files.sh"

capability_discriminates "the dumps looked for where they are not" \
    "the database leaves with them" \
    "sed -i.bak 's|BACKUP_DUMPS:-/backup|BACKUP_DUMPS:-/nowhere|' backup-files.sh"

if [[ -x "$REPO_ROOT/test/fresh-install.sh" ]]; then
    printf '\n%sA fresh install, seen failing%s\n\n' "$BOLD" "$NC"

    install_walk_discriminates "a login with some other token than the license's" \
        "logs in with the token it carries" \
        "sed -i.bak 's|^    REGISTRY_TOKEN=\$(\"\$tool\" field registry_token \"\$machine\" 2>/dev/null)|    REGISTRY_TOKEN=some-other-token|' bin/ut-install"

    install_walk_discriminates "a license file read without being checked" \
        "an altered license file stops the install before any request" \
        "sed -i.bak 's|^        \"\$tool\" check \"\$machine\" \|\| checked=\$?|        true|' bin/ut-install"

    install_walk_discriminates "a license file replaced from Keygen rather than checked" \
        "an altered license file stops the install before any request" \
        "sed -i.bak 's|^    if \[\[ -s \"\$MACHINE_FILE\" \]\] \&\& stored_license_is \"\$key\"; then|    if false; then|' bin/ut-install"

    install_walk_discriminates "a license file that ended, refused instead of renewed" \
        "a license file that has ended is renewed from Keygen" \
        "sed -i.bak 's|(( checked == 0 \|\| checked == 2 ))|(( checked == 0 ))|' bin/ut-install"

    install_walk_discriminates "a machine with no network told nothing of what to do" \
        "a machine that cannot reach Keygen writes its request" \
        "sed -i.bak 's#^            ask_for_the_license_by_file \"\$tool\"\$#            :#' bin/ut-install"

    install_walk_discriminates "a request that carries the license key" \
        "a machine that cannot reach Keygen writes its request" \
        "sed -i.bak 's#\"\$tool\" request > \"\$LICENSE_REQUEST\"#{ \"\$tool\" request; cat \"\$LICENSE_FILE\"; } > \"\$LICENSE_REQUEST\"#' bin/ut-install"

    install_walk_discriminates "a license file given by hand, taken unchecked" \
        "an altered license file sent back is refused" \
        "sed -i.bak '/cat \"\$MACHINE_FILE_GIVEN\" > \"\$machine\"/{n;s/\"\$tool\" check/true/;}' bin/ut-install"

    install_walk_discriminates "a machine with no network told nothing of what to do" \
        "a machine that cannot reach Keygen writes its request" \
        "sed -i.bak 's#^            ask_for_the_license_by_file \"\$tool\"\$#            :#' bin/ut-install"

    install_walk_discriminates "a request that carries the license key" \
        "a machine that cannot reach Keygen writes its request" \
        "sed -i.bak 's#\"\$tool\" request > \"\$LICENSE_REQUEST\"#{ \"\$tool\" request; cat \"\$LICENSE_FILE\"; } > \"\$LICENSE_REQUEST\"#' bin/ut-install"

    install_walk_discriminates "a license file given by hand, taken unchecked" \
        "an altered license file sent back is refused" \
        "sed -i.bak '/cat \"\$MACHINE_FILE_GIVEN\" > \"\$machine\"/{n;s/\"\$tool\" check/true/;}' bin/ut-install"

    install_walk_discriminates "a license that is not kept for the next update" \
        "kept for updates, readable by root alone" \
        "sed -i.bak 's|^    install -m 600 \"\$key\" \"\$LICENSE_STORE\"|    :|' bin/ut-install"

    install_walk_discriminates "a license file that is not kept for the next update" \
        "kept for updates, readable by root alone" \
        "sed -i.bak 's|^    install -m 600 \"\$machine\" \"\$MACHINE_FILE\"|    :|' bin/ut-install"

    install_walk_discriminates "a registry login with the images already here" \
        "a license needs no registry login" \
        "sed -i.bak 's|^    if ! \$DO_PULL; then\$|    if false; then|' bin/ut-install"

    install_walk_discriminates "the carried token written to the log" \
        "never reach the output" \
        "sed -i.bak 's|^    REGISTRY_USER=\${licensed_user:-\$REGISTRY_USER}|&; log_info \"\$REGISTRY_TOKEN\"|' bin/ut-install"

    install_walk_discriminates "a token alone accepted without a word" \
        "a registry token alone still installs, and says a license will be needed" \
        "sed -i.bak 's|is accepted by this version only|works|' bin/ut-install"

    install_walk_discriminates "a registry the license names, then ignored" \
        "a license that names a registry pulls every image from it" \
        "sed -i.bak '/^        REGISTRY=\$licensed_registry\$/d' bin/ut-install"

    install_walk_discriminates "a login to the licensed registry, and images still named elsewhere" \
        "a license that names a registry pulls every image from it" \
        "sed -i.bak 's|\"\$REGISTRY\" != \"ghcr.io\" \&\& \"\$line\"|\"\$REGISTRY\" == \"never\" \&\& \"\$line\"|' bin/ut-install"

    install_walk_discriminates "writing through a link whose directory is gone" \
        "it is recreated rather than reported as a broken link" \
        "sed -i.bak 's|^    install -d -m 750 |    : |' bin/ut-install"

    install_walk_discriminates "an empty settings file kept as if configured" \
        "and the result still renders" \
        "sed -i.bak 's|^render_settings() {$|render_settings() { return 0;|' bin/ut-install"

    install_walk_discriminates "a disk floor that lets every machine through" \
        "the refusal names what is free and what is needed" \
        "sed -i.bak 's|^MIN_DISK_BYTES=.*|MIN_DISK_BYTES=0|' bin/ut-install"

    # The clock check reads one value out of release.env. Make that read fail and
    # it skips in silence, which is the shape the defect would really take.
    install_walk_discriminates "an install that lets the operator find out from a traceback" \
        "it gives the API the OA_KEY it needs to start" \
        "sed -i.bak 's|^give_the_api_the_openai_key_it_needs_to_start() {\$|give_the_api_the_openai_key_it_needs_to_start() { return 0;|' bin/ut-install"

    install_walk_discriminates "an OpenAI key replaced by the placeholder" \
        "an OpenAI key already given is never replaced" \
        "sed -i.bak '/^    \\[\\[ -n \"\\\$(env_get \"\\\$env_file\" OA_KEY/d' bin/ut-install"

    install_walk_discriminates "a model on vLLM left on NIM's engine" \
        "a model on vLLM brings its engine, and its arguments whole" \
        "sed -i.bak '/^        vllm:\\*) env_set /d' bin/ut-install"

    install_walk_discriminates "a model's arguments rewritten in double quotes" \
        "a model on vLLM brings its engine, and its arguments whole" \
        "sed -i.bak 's|\"\\\$chosen\"\\*=\\*) put_the_line_in_place_of_its_key \"\\\$local_file\" \"\\\$line\" ;;|\"\$chosen\"*=*) env_set \"\$local_file\" \"\${line%%=*}\" \"\${line#*=}\" ;;|' bin/ut-install"

    install_walk_discriminates "a model chosen without its proof" \
        "a model is chosen only on a GPU it is proven on" \
        "sed -i.bak 's| \\&\\& \\[\\[ -f \"\\\$(proof_of \"\\\$id\" \"\\\$engine\" \"\\\$family\")\" \\]\\]||' bin/ut-install"

    install_walk_discriminates "a model kept by its values rather than its name" \
        "a model kept by name follows its entry on the next install" \
        "sed -i.bak '/MODEL_ID=\\\$(env_get \"\\\$local_file\" UT_MODEL/d' bin/ut-install"

    install_walk_discriminates "a control plane asked for an engine it does not run" \
        "a control plane takes the names of a model served elsewhere, and no engine" \
        "sed -i.bak 's|^    if ! this_machine_goes_without_its_accelerator \\&\\& \\[\\[ -z \"\\\$INFERENCE_FROM\" \\]\\]; then\$|    if true; then|' bin/ut-install"

    install_walk_discriminates "a model nobody listed taken at its word" \
        "a model nobody listed is refused before anything is written" \
        "sed -i.bak 's|^die_on_a_model_nobody_listed() {\$|die_on_a_model_nobody_listed() { return 0;|' bin/ut-install"

    install_walk_discriminates "allowed origins left on the old address" \
        "the allowed origins follow the address when it changes" \
        "sed -i.bak '/^        move_the_allowed_origins_to_the_new_domain /d' bin/ut-install"

    install_walk_discriminates "an engine key nobody generates" \
        "the engine gets a key of its own" \
        "sed -i.bak 's| VLLM_API_KEY)|)|' bin/ut-install"

    install_walk_discriminates "an engine key an older release shipped, kept as it was" \
        "an engine key an older release left as EMPTY is replaced" \
        "sed -i.bak 's| \"EMPTY\"\$||' bin/ut-install"

    install_walk_discriminates "a control plane told the node's key and keeping its own" \
        "it takes the node's address and key" \
        "sed -i.bak '/env_set \"\$local_file\" VLLM_API_KEY /d' bin/ut-install"

    install_walk_discriminates "a bundle without the node's root" \
        "it trusts the node's root beside the public ones" \
        "sed -i.bak 's|cat \"\$HOST_CA_BUNDLE\" \"\$INFERENCE_CA_FILE\" >|cat \"\$HOST_CA_BUNDLE\" >|' bin/ut-install"

    install_walk_discriminates "a bundle with the node's root alone" \
        "it trusts the node's root beside the public ones" \
        "sed -i.bak 's|cat \"\$HOST_CA_BUNDLE\" \"\$INFERENCE_CA_FILE\" >|cat \"\$INFERENCE_CA_FILE\" >|' bin/ut-install"

    install_walk_discriminates "the node's key written to the install log" \
        "the node's key stays out of the install output" \
        "sed -i.bak 's|with its key, trusting its root\"|with key \$(cat \"\$INFERENCE_KEY_FILE\"), trusting its root\"|' bin/ut-install"

    install_walk_discriminates "a compute node reached over plain http" \
        "a node reached over plain http is refused before anything is written" \
        "sed -i.bak 's|\\^https://\\[\\^/\\]+|^https?://[^/]+|' bin/ut-install"

    install_walk_discriminates "a folder of another release taken for this one" \
        "a folder prepared for another release is refused, with both versions named" \
        "sed -i.bak 's|^die_on_a_folder_of_another_release() {\$|die_on_a_folder_of_another_release() { return 0;|' bin/ut-install"

    install_walk_discriminates "a folder taken without checking it holds every image" \
        "a folder that lacks an image is refused before anything is written" \
        "sed -i.bak 's|^die_on_a_folder_that_misses_an_image() {\$|die_on_a_folder_that_misses_an_image() { return 0;|' bin/ut-install"

    install_walk_discriminates "a box online again that keeps the names of a folder" \
        "an install that downloads again forgets the names a folder gave its images" \
        "sed -i.bak 's|^forget_the_images_of_a_folder() {\$|forget_the_images_of_a_folder() { return 0;|' bin/ut-install"

    install_walk_discriminates "a control plane pointed at a node only mDNS can name" \
        "a node named by mDNS is refused before anything is written" \
        "sed -i.bak '/^    elif names_an_mdns_host \"\\\$(host_of_url/d' bin/ut-install"

    install_walk_discriminates "--compute that leaves the compute overlay out" \
        "a compute node is installed with one flag, and asked for no domain" \
        "sed -i.bak '/^        \*) env_set \"\\\$local_file\" COMPOSE_FILE \"\\\${compose_files}:compose.compute.yaml\" ;;\$/d' bin/ut-install"

    install_walk_discriminates "--compute that takes a .local name" \
        "a compute node named by mDNS is refused before anything is written" \
        "sed -i.bak 's|^names_an_mdns_host() {\$|names_an_mdns_host() { return 1;|' bin/ut-install"

    install_walk_discriminates "--compute that takes --no-gpu too" \
        "a compute node without its GPU is refused before anything is written" \
        "sed -i.bak 's|^    if \$NO_GPU \|\| \[\[ -n \"\\\$INFERENCE_FROM\" \]\]; then\$|    if false; then|' bin/ut-install"

    install_walk_discriminates "a control plane with a GPU stripped of it" \
        "a control plane with a GPU keeps it for llm and starts no engine" \
        "sed -i.bak 's|\\[\\[ -n \"\\\$INFERENCE_FROM\" \\]\\] \\&\\& ! an_accelerator_answers|[[ -n \"\$INFERENCE_FROM\" ]]|' bin/ut-install"

    install_walk_discriminates "a control plane without a GPU asking for one" \
        "a control plane without a GPU is installed as with --no-gpu" \
        "sed -i.bak 's|^    \\[\\[ -n \"\\\$INFERENCE_FROM\" \\]\\] \\&\\& ! an_accelerator_answers\$|    false|' bin/ut-install"

    install_walk_discriminates "a role read from the overlay rather than from where generation comes from" \
        "the summary says where generation comes from" \
        "sed -i.bak 's|printf .control plane — generation comes from %s.|printf \"appliance — inference runs on this machine\"|' bin/ut-install"

    install_walk_discriminates "a compute node held to an authority it does not run" \
        "a compute node installs to the end, with no authority of its own" \
        "sed -i.bak '/^step_certificate_policy() {\$/,/^    fi\$/ s|this_machine_is_a_compute_node|false|' bin/ut-install"

    install_walk_discriminates "a compute node handed the summary of a platform it does not run" \
        "a compute node's summary hands the control plane what it needs" \
        "sed -i.bak '/^print_summary() {\$/,/^    fi\$/ s|this_machine_is_a_compute_node|false|' bin/ut-install"

    install_walk_discriminates "a machine without a GPU left to find out its documents get no answer" \
        "a machine without a GPU is told its documents get no answer" \
        "sed -i.bak '/chats over documents answer nothing on this machine/d' bin/ut-install"

    install_walk_discriminates "a clock nothing compares to anything" \
        "the preflight stops rather than issue certificates nothing will accept" \
        "sed -i.bak 's|^release_declares() {\$|release_declares() { return 1;|' bin/ut-install"
fi

if grep -q 'checkouts_holding_settings' "$REPO_ROOT/bin/ut-install"; then
    install_walk_discriminates "an install blind to the checkout it replaces" \
        "its settings are carried over, not regenerated" \
        "sed -i.bak 's|^checkouts_holding_settings() {\$|checkouts_holding_settings() { return 0;|' bin/ut-install"

    install_walk_discriminates "the address decided again instead of read" \
        "the address it already answers on is kept" \
        "sed -i.bak 's|^configured_domain() {\$|configured_domain() { return 0;|' bin/ut-install"

    install_walk_discriminates "an address no URL is allowed to name" \
        "an install too old to name its address has it read from its URLs" \
        "sed -i.bak 's|^domain_named_by_the_urls() {\$|domain_named_by_the_urls() { return 1;|' bin/ut-install"

    install_walk_discriminates "a migration that takes the checkout with it" \
        "the checkout itself is left untouched" \
        "sed -i.bak 's|migrate_existing_settings_into_local \"\$source_settings\" \"\$local_file\"|& \&\& rm -f \"\$source_settings\"|' bin/ut-install"

    install_walk_discriminates "a required variable nobody generates" \
        "every variable the stack requires has a value" \
        "sed -i.bak 's| GPU_VM_API_TOKEN\\([ )]\\)|\\1|' bin/ut-install"

discriminates "a model entry with no variant" \
    "model-without-variant" \
    "sed -i.bak '/^NIM_LLM_MODEL_PATH=/d' models/qwen3.8-27b-nvfp4.env"

discriminates "a model's image named by tag only" \
    "model-image-not-pinned" \
    "sed -i.bak 's|^\\(NIM_IMAGE=\"[^@]*\\)@sha256:[0-9a-f]*\"|\\1\"|' models/qwen3.8-27b-nvfp4.env"

discriminates "a proof vouching for another image" \
    "proof-of-another-image" \
    "sed -i.bak 's/sha256:20e10652/sha256:20e10653/' models/proven/qwen3.8-27b-nvfp4.nim.gb10.md"

discriminates "a proof of a model no entry has" \
    "proof-of-nothing" \
    "cp models/proven/qwen3.8-27b-nvfp4.nim.gb10.md models/proven/gone.nim.gb10.md"

discriminates "the shipped model's entry drifting from the release" \
    "shipped-model-drifted" \
    "sed -i.bak 's|^LLM_MODEL=\"Qwen/Qwen3.8-27B\"|LLM_MODEL=\"Qwen/Qwen3.8-14B\"|' models/qwen3.8-27b-nvfp4.env"

if grep -q 'check_the_package_stamps_the_commit_it_was_built_from' "$REPO_ROOT/test/invariants.sh"; then
    discriminates "a package that says nothing about the code inside it" \
        "package-version-without-commit" \
        "sed -i.bak 's|UT_RELEASE_VERSION=\\\\\"\${stamp}|UT_RELEASE_VERSION=\\\\\"\${version}|' packaging/build-deb.sh"
fi

if grep -q 'if ! terminal_is_reachable' "$REPO_ROOT/bin/ut-install"; then
    install_walk_discriminates "a terminal assumed rather than opened" \
        "it finishes, and says so" \
        "sed -i.bak 's|^terminal_is_reachable() .*$|terminal_is_reachable() { [[ -w /dev/tty ]]; }|' bin/ut-install"

    install_walk_discriminates "an install that finishes without saying where the secrets are" \
        "the secrets can be found afterwards" \
        "sed -i.bak 's|^        log_info \"No terminal here.*$|        :|' bin/ut-install"
fi

if grep -q 'looks_like_a_checkout' "$REPO_ROOT/bin/ut-install"; then
    install_walk_discriminates "an installer blind to the checkout it stands in" \
        "it takes the checkout it is standing in, and asks for no token" \
        "sed -i.bak 's|^    \[\[ -f \"\$1/compose.yaml\" && -d \"\$1/.git\" \]\]$|    false|' bin/ut-install"

    # The guard this change stands next to without touching. A neighbouring
    # correction that quietly opens the way in is exactly what it must not do.
    install_walk_discriminates "a way in that no longer needs a key" \
        "but a machine with no credentials is still asked for a key" \
        "sed -i.bak 's|^    release_is_present && registry_credentials_stored && return 1$|    release_is_present \&\& return 1|' bin/ut-install"
fi

    install_walk_discriminates "a database nobody has the password for, accepted" \
        "the install stops, and says which volume and what to do" \
        "sed -i.bak 's|^    \[\[ -n \"\$(env_get \"\$env_file\" MONGODB_PASSWORD .*$|    true|' bin/ut-install"

    install_walk_discriminates "a password refused for the way it looks" \
        "the install carries on, because that password is the right one" \
        "sed -i.bak 's#^    \[\[ -n .*MONGODB_PASSWORD.*\$#    ! is_shipped_placeholder \"\$(env_get \"\$env_file\" MONGODB_PASSWORD || true)\"#' bin/ut-install"

    install_walk_discriminates "full address pools noticed only when it is too late" \
        "the preflight stops before anything is written" \
        "sed -i.bak 's|^    elif docker_can_still_allocate_a_network; then$|    elif true; then|' bin/ut-install"

    install_walk_discriminates "two machines given the same secret" \
        "two installs do not share a secret" \
        "sed -i.bak 's|^random_alphanumeric() {$|random_alphanumeric() { printf %s the-same-everywhere; return 0;|' bin/ut-install"

    install_walk_discriminates "a token key the App Builder cannot read" \
        "the App Builder's token key is one Fernet accepts" \
        "sed -i.bak 's|^random_fernet_key() {$|random_fernet_key() { random_alphanumeric 44; return 0;|' bin/ut-install"

    install_walk_discriminates "two machines given the same token key" \
        "two installs do not share a secret" \
        "sed -i.bak 's|^random_fernet_key() {$|random_fernet_key() { printf %s the-same-everywhere; return 0;|' bin/ut-install"

    install_walk_discriminates "a carried token key replaced by a new one" \
        "the App Builder's token key comes along" \
        "sed -i.bak 's|^    local local_file=\$1 key rotated=()\$|&; env_set \"\$local_file\" APP_BUILDER_TOKEN_ENCRYPTION_KEY \"\"|' bin/ut-install"

    install_walk_discriminates "a declared machine refused anyway" \
        "the install goes on when the inference is served elsewhere" \
        "sed -i.bak 's|^the_inference_is_served_by_another_machine() {\$|the_inference_is_served_by_another_machine() { return 1;|' bin/ut-install"

    install_walk_discriminates "an accelerator waived on its absence alone" \
        "the preflight stops when nothing says the inference is elsewhere" \
        "sed -i.bak 's|^the_inference_is_served_by_another_machine() {\$|the_inference_is_served_by_another_machine() { return 0;|' bin/ut-install"

    install_walk_discriminates "a control plane asked for the storage of an appliance" \
        "the disk floor follows what the machine will actually hold" \
        "sed -i.bak 's|^MIN_DISK_BYTES_NO_INFERENCE=.*|MIN_DISK_BYTES_NO_INFERENCE=\$MIN_DISK_BYTES|' bin/ut-install"

    install_walk_discriminates "an accelerator waived without the settings that follow" \
        "the flag writes a configuration that asks docker for no GPU" \
        "sed -i.bak 's|^        write_the_settings_a_machine_without_an_accelerator_needs \"\$local_file\"\$|        :|' bin/ut-install"

    capability_discriminates "a status tool that calls an empty directory healthy" \
        "a directory with no install is refused, not called healthy" \
        "sed -i.bak 's|^    \[\[ -f \"\$INSTALL_DIR/compose.yaml\" \]\].*|    :|' bin/ut-status"

    install_walk_discriminates "an address prepared in local.env read too late to count" \
        "it stays quiet when the address already names another machine" \
        "sed -i.bak '/local.env\" VLLM_LLM_BASE_URL/d' bin/ut-install"

    install_walk_discriminates "a pull the walk no longer stops" \
        "the walk stops where the images would download" \
        "sed -i.bak 's#compose_in_dir --progress json pull 2>\\&1#compose_in_dir --progress=json pull 2>\\&1#' bin/ut-install"

    install_walk_discriminates "an inference address left pointing at a service nothing starts" \
        "it says the inference address still points at nothing" \
        "sed -i.bak 's|^    if the_inference_url_names_a_service_this_machine_will_not_run; then|    if false; then|' bin/ut-install"

    install_walk_discriminates "a backup destination on the machine's own disk taken for a mounted one" \
        "one on the machine's own disk stops the install" \
        "sed -i.bak 's|^    \[\[ \"\$filesystem\" != .*|    true|' bin/ut-install"

    install_walk_discriminates "an SFTP destination left without its way out" \
        "an S3 or SFTP destination gets its way out" \
        "sed -i.bak 's|\"\${compose_files}:compose.backup-network.yaml\"|\"\${compose_files}\"|' bin/ut-install"

    install_walk_discriminates "every repository taken for one over the network" \
        "the default destination adds no way out" \
        "sed -i.bak 's#^        s3:\*|sftp:\*|.*#        *) return 0 ;;#' bin/ut-install"

    capability_discriminates "a backup that does not work holding the install back" \
        "does not hold the install back" \
        "sed -i.bak 's/ \\&\\& \"\\\$1\" != \"backup\"//' bin/ut-install"

    install_walk_discriminates "a destination gone during an update stopping it" \
        "gone during an update" \
        "sed -i.bak 's|^                return 0 ;;\$|                : ;;|' bin/ut-install"

    install_walk_discriminates "two destinations checked only after one is written" \
        "two destinations stops the install, before" \
        "sed -i.bak '/^    die_on_two_backup_destinations \"\$local_file\"\$/d' bin/ut-install"

    install_walk_discriminates "two backup destinations let through" \
        "naming two destinations stops the install" \
        "sed -i.bak '/both say where the backup goes/,/exit 1/ s/exit 1/:/' bin/ut-install"
fi

if [[ -x "$REPO_ROOT/test/ingress.sh" ]]; then
    printf '\n%sThe front door, seen failing%s\n\n' "$BOLD" "$NC"

    ingress_discriminates "a surface whose upstream no longer exists" \
        "https://llms.box.example.test is served" \
        "sed -i.bak 's|reverse_proxy app-llms:80|reverse_proxy nowhere:80|' Caddyfile"

    ingress_discriminates "a front door that counts nothing" \
        "Caddy counts what each surface answered" \
        "sed -i.bak '/^    metrics {\$/,/^    }\$/d' caddy/ingress-internal.caddy"

    ingress_discriminates "the counters handed to any browser" \
        "the counters are not served on the front door" \
        "sed -i.bak 's|^(platform_routes) {\$|(platform_routes) {\\n    handle /metrics {\\n        metrics\\n    }|' Caddyfile"

    ingress_discriminates "every Host header counted as written" \
        "a forged host is pooled" \
        "sed -i.bak 's|^        per_host\$|        per_host\\n        observe_catchall_hosts|' caddy/ingress-internal.caddy"

    ingress_discriminates "an engine served to anyone" \
        "it refuses a request without the key" \
        "sed -i.bak '/respond @without_the_key 401/d' caddy/inference-surface.caddy"

    ingress_discriminates "a compute node that answers only to its name" \
        "it presents a certificate for that IP to a client that names none" \
        "sed -i.bak '/default_sni/d' caddy/ingress-internal.caddy"

    ingress_discriminates "a recorder that filters out the handler Caddy counts under" \
        "the recorder keeps each request to a surface" \
        "sed -i.bak 's/;metrics\"/;subroute\"/' metrics/prometheus.yml"

    ingress_discriminates "a recorder that keeps the counts but not the durations" \
        "the recorder keeps how long each request to a surface took" \
        "sed -i.bak 's#|request_duration_seconds_(bucket|sum|count))|caddy_reverse#)|caddy_reverse#' metrics/prometheus.yml"

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

printf '\n%sMigration, seen failing%s\n\n' "$BOLD" "$NC"

migration_discriminates "a volume renamed beside the one retired on purpose" \
    "every volume and network keeps its name" \
    "sed -i.bak 's|-mongodb-data$|-mongodb-data-renamed|' compose.yaml"

printf '\n%s%d discriminate%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d do not%s\n' "$RED" "$FAILED" "$NC"
    printf '\nThese checks pass whatever happens, which makes them decoration:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
