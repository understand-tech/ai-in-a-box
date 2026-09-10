#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_FILE="$SCRIPT_DIR/known-issues.txt"
ALLOWED_PORTS_FILE="$SCRIPT_DIR/allowed-ports.txt"

ENV_EXAMPLE="$REPO_ROOT/.env.example"
COMPOSE_FILES=("$REPO_ROOT/compose.yaml" "$REPO_ROOT/compose.appbuilder.yaml")

if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BOLD=""; NC=""
fi

FINDING_IDS=()
FINDING_MESSAGES=()

report() {
    FINDING_IDS+=("$1")
    FINDING_MESSAGES+=("$2")
}

env_keys() {
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_EXAMPLE" | tr -d '='
}

env_raw_value() {
    local key=$1 line
    line=$(grep -m1 -E "^${key}=" "$ENV_EXAMPLE" 2>/dev/null) || return 1
    line=${line#*=}
    line=${line%\"}; line=${line#\"}
    line=${line%\'}; line=${line#\'}
    printf '%s' "$line"
}

read_baseline() {
    [[ -f "$BASELINE_FILE" ]] || return 0
    grep -vE '^\s*(#|$)' "$BASELINE_FILE" || true
}

compare_with_baseline() {
    local baseline found new=() stale=() id
    baseline=$(read_baseline)
    found=$(printf '%s\n' "${FINDING_IDS[@]+"${FINDING_IDS[@]}"}" | grep -v '^$' | sort -u || true)

    while read -r id; do
        [[ -n "$id" ]] || continue
        grep -qxF "$id" <<< "$baseline" || new+=("$id")
    done <<< "$found"

    while read -r id; do
        [[ -n "$id" ]] || continue
        grep -qxF "$id" <<< "$found" || stale+=("$id")
    done <<< "$baseline"

    local i
    if (( ${#new[@]} )); then
        printf '%s%sNew problems%s — not in test/known-issues.txt:\n\n' "$RED" "$BOLD" "$NC"
        for id in "${new[@]}"; do
            for i in "${!FINDING_IDS[@]}"; do
                [[ "${FINDING_IDS[$i]}" == "$id" ]] || continue
                printf '  %s%s%s\n    %s\n' "$BOLD" "$id" "$NC" "${FINDING_MESSAGES[$i]}"
                break
            done
        done
        printf '\nFix them, or add the identifier to test/known-issues.txt with a reason.\n\n'
    fi

    if (( ${#stale[@]} )); then
        printf '%s%sFixed problems still listed%s in test/known-issues.txt:\n\n' "$YELLOW" "$BOLD" "$NC"
        for id in "${stale[@]}"; do
            printf '  %s\n' "$id"
        done
        printf '\nRemove those lines. A baseline nobody prunes stops protecting anything.\n\n'
    fi

    if (( ${#new[@]} || ${#stale[@]} )); then
        return 1
    fi

    printf '%s%s invariant(s) hold%s' "$GREEN" "$(printf '%s\n' "$found" | grep -c . || true)" "$NC"
    printf ' — %s known issue(s) accepted in the baseline\n' "$(printf '%s\n' "$baseline" | grep -c . || true)"
}

main() {
    compare_with_baseline
}

main "$@"
