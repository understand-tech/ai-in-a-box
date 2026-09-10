#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_FILE="$SCRIPT_DIR/known-issues.txt"
ALLOWED_PORTS_FILE="$SCRIPT_DIR/allowed-ports.txt"

ENV_EXAMPLE="$REPO_ROOT/.env.example"
COMPOSE_FILES=("$REPO_ROOT/compose.yaml" "$REPO_ROOT/compose.appbuilder.yaml")

SENSITIVE_KEYS=(
    MONGODB_PASSWORD JWT_SECRET ADMIN_SETUP_PASSWORD STATE_SECRET
    OPENID_SECRET_KEY OA_KEY SENDGRID_API_KEY GROQ_API_KEY HF_TOKEN
    VLLM_API_KEY GPU_VM_API_TOKEN APP_BUILDER_ANTHROPIC_API_KEY
    APP_BUILDER_GATEWAY_API_KEY NGC_API_KEY CLAUDE_API_KEY
)

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

check_plaintext_secrets() {
    local key value
    for key in "${SENSITIVE_KEYS[@]}"; do
        value=$(env_raw_value "$key" 2>/dev/null) || continue
        [[ -z "$value" ]] && continue
        report "plaintext-secret:${key}" \
            "${key} ships a value in .env.example — every deployment that follows the guide reuses it"
    done
}

check_variables_without_default_are_declared() {
    local declared required var
    declared=$(env_keys | sort -u)
    required=$(grep -ohE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${COMPOSE_FILES[@]}" \
        | tr -d '${}' | sort -u)

    while read -r var; do
        [[ -n "$var" ]] || continue
        grep -qxF "$var" <<< "$declared" && continue
        report "undeclared-variable:${var}" \
            "\${${var}} has no default in the compose files and no value in .env.example — the stack starts with it empty"
    done <<< "$required"
}

published_port_entries() {
    awk '
        /^  [a-z0-9_-]+:/ { service = $1; sub(":", "", service) }
        /^    ports:/     { in_ports = 1; next }
        in_ports && /^      - / {
            entry = $2
            gsub(/"/, "", entry)
            print service "|" entry
            next
        }
        in_ports && !/^      / { in_ports = 0 }
    ' "$@"
}

check_published_ports_are_allowed() {
    local service port_spec allowed
    allowed=$(grep -vE '^\s*(#|$)' "$ALLOWED_PORTS_FILE" 2>/dev/null || true)

    while IFS='|' read -r service port_spec; do
        [[ -n "$service" && -n "$port_spec" ]] || continue
        [[ "$port_spec" == 127.0.0.1:* || "$port_spec" == localhost:* ]] && continue
        grep -qxF "${service}:${port_spec}" <<< "$allowed" && continue
        report "unlisted-port:${service}:${port_spec}" \
            "${service} publishes ${port_spec} on every interface, and it is not in test/allowed-ports.txt"
    done <<< "$(published_port_entries "${COMPOSE_FILES[@]}")"
}

check_images_are_pinned() {
    local key value
    while read -r key; do
        [[ "$key" == *_IMAGE ]] || continue
        value=$(env_raw_value "$key") || continue
        [[ -z "$value" ]] && continue
        [[ "$value" == *@sha256:* ]] && continue
        report "unpinned-image:${key}" \
            "${key}=${value} is a mutable reference — two boxes on the same version can differ"
    done <<< "$(env_keys)"
}

check_production_defaults() {
    local log_level
    log_level=$(env_raw_value LOG_LEVEL 2>/dev/null || true)
    if [[ "$log_level" == "DEBUG" || "$log_level" == "TRACE" ]]; then
        report "verbose-log-level:LOG_LEVEL" \
            "LOG_LEVEL=${log_level} in .env.example — verbose logs on a customer's appliance"
    fi

    if grep -q 'maxmemory-policy allkeys-lru' "$REPO_ROOT/compose.yaml"; then
        report "queue-eviction:redis" \
            "redis runs allkeys-lru while holding the RQ queues — tasks can be evicted under memory pressure"
    fi
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
    check_plaintext_secrets
    check_variables_without_default_are_declared
    check_published_ports_are_allowed
    check_images_are_pinned
    check_production_defaults
    compare_with_baseline
}

main "$@"
