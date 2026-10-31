#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

probe() {
    {
        printf '%s\n' 'set -Eeuo pipefail' 'CYAN= NC= BOLD=' 'say_message() { :; }'
        sed -n '/^log_step() /p; /^the_step_running() {$/,/^}/p' "$REPO_ROOT/bin/ut-install"
        cat <<'PROBE'
preflight() {
    log_step "Checking the synthetic system" >/dev/null
    [[ -z "$CURRENT_STEP" ]]
}
step_configure() {
    log_step "Writing the synthetic configuration" >/dev/null
    [[ "$CURRENT_STEP" == step_configure ]]
}
preflight
printf 'preflight reached configuration\n'
step_configure
printf 'named step kept its function name\n'
PROBE
    } | bash
}

if output=$(probe 2>&1); then
    [[ "$output" == $'preflight reached configuration\nnamed step kept its function name' ]]
    printf '%s\n' "$output"
else
    printf 'log_step stopped the installer before configuration under errexit\n' >&2
    exit 1
fi
