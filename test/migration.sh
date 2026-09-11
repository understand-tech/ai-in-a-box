#!/usr/bin/env bash

# Answers one question: what happens to a customer who already runs this
# appliance when the next version lands on their machine.
#
# The comparison is made with the environment file the earlier version shipped,
# because that is literally what a customer copied to .env and has been running
# since. It is never printed: it carries the secrets that shipped with it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FROM_REF=${MIGRATION_FROM:-origin/main}

WORK_DIR="$(mktemp -d)"
BEFORE="$WORK_DIR/before"
AFTER="$WORK_DIR/after"
trap 'rm -rf "$WORK_DIR"' EXIT

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
    local output
    if output=$("$@" 2>&1); then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        [[ -n "$output" ]] && printf '%s      %s%s\n' "$DIM" "${output//$'\n'/$'\n'      }" "$NC"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        [[ -n "$output" ]] && printf '%s      %s%s\n' "$DIM" "${output//$'\n'/$'\n'      }" "$NC"
        FAILED=$((FAILED + 1))
        FAILURES+=("$description")
    fi
}

resolve_starting_point() {
    git -C "$REPO_ROOT" rev-parse --verify --quiet "$FROM_REF" >/dev/null && return 0
    git -C "$REPO_ROOT" fetch --quiet --depth=1 origin "${FROM_REF#origin/}" 2>/dev/null \
        && git -C "$REPO_ROOT" rev-parse --verify --quiet FETCH_HEAD >/dev/null \
        && FROM_REF=FETCH_HEAD
}

lay_out_both_versions() {
    mkdir -p "$BEFORE" "$AFTER"
    local file
    for file in compose.yaml compose.appbuilder.yaml .env.example; do
        git -C "$REPO_ROOT" show "$FROM_REF:$file" > "$BEFORE/$file" 2>/dev/null
    done
    cp "$REPO_ROOT"/compose*.yaml "$AFTER/"

    # The environment file of the earlier version becomes the .env of both, which
    # is the whole point: the same file that runs today is asked to run the new
    # stack unchanged.
    cp "$BEFORE/.env.example" "$BEFORE/.env"
    cp "$BEFORE/.env.example" "$AFTER/.env"
    chmod 600 "$BEFORE/.env" "$AFTER/.env"
}

required_variables_in() {
    grep -ohE '\$\{[A-Z_][A-Z_0-9]*:\?' "$1"/compose.yaml "$1"/compose.appbuilder.yaml 2>/dev/null \
        | sed 's/^\${//; s/:?$//' | sort -u
}

declared_variables_in() {
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$1/.env" | tr -d '=' | sort -u
}

variables_the_install_must_gain() {
    comm -23 <(required_variables_in "$AFTER") <(declared_variables_in "$BEFORE")
}

rendered() {
    ( cd "$1" && shift && docker compose "$@" config 2>&1 )
}

names_the_install_would_lose() {
    comm -23 \
        <(rendered "$BEFORE" -f compose.yaml | grep -oE 'container_name: [a-z0-9_-]+' | sort -u) \
        <(rendered "$AFTER" -f compose.yaml | grep -oE 'container_name: [a-z0-9_-]+' | sort -u)
}

the_new_stack_refuses_an_untouched_env() {
    local missing
    missing=$(variables_the_install_must_gain | tr '\n' ' ')
    [[ -n "${missing// /}" ]] || { echo "nothing is missing, so nothing would refuse"; return 1; }
    rendered "$AFTER" -f compose.yaml >/dev/null 2>&1 && return 1
    echo "compose stops on: ${missing% }"
}

the_installer_supplies_what_is_missing() {
    local key
    set +u
    # Sourcing rather than reimplementing: the answer has to come from the code
    # a customer actually runs, not from a copy of its logic that can drift.
    INSTALL_DIR="$BEFORE" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
    set -u
    generate_application_secrets "$BEFORE/.env" >/dev/null 2>&1
    generate_database_credentials "$BEFORE/.env" >/dev/null 2>&1

    while read -r key; do
        [[ -n "$key" ]] || continue
        grep -qE "^${key}=\"?.+\"?$" "$BEFORE/.env" || { echo "$key is still unset"; return 1; }
    done <<< "$(required_variables_in "$AFTER")"
    cp "$BEFORE/.env" "$AFTER/.env"
}

the_new_stack_then_renders() {
    rendered "$AFTER" -f compose.yaml >/dev/null
}

# A name that appears is harmless — the internal data network is one. A name
# that disappears is a volume the new stack no longer mounts, so only the
# one-way comparison says anything.
the_state_keeps_its_names() {
    local before lost
    before=$(rendered "$BEFORE" -f compose.yaml | grep -oE 'name: ut-[a-z-]+(-data|-network)' | sort -u)
    [[ -n "$before" ]] || { echo "no named volume or network found before the change"; return 1; }
    lost=$(comm -23 <(printf '%s\n' "$before") \
        <(rendered "$AFTER" -f compose.yaml | grep -oE 'name: ut-[a-z-]+(-data|-network)' | sort -u))
    [[ -z "$lost" ]] || { echo "no longer mounted: $(echo "$lost" | sed 's/name: //' | tr '\n' ' ')"; return 1; }
}

the_data_directory_is_unchanged() {
    rendered "$AFTER" -f compose.yaml | grep -q '/var/lib/understandtech'
}

the_database_keeps_its_credentials() {
    local before after
    before=$(rendered "$BEFORE" -f compose.yaml | grep -c 'MONGO_INITDB_ROOT_USERNAME')
    after=$(rendered "$AFTER" -f compose.yaml | grep -c 'MONGO_INITDB_ROOT_USERNAME')
    [[ "$before" == "$after" ]]
}

service_names_in() {
    awk '/^  [a-z0-9_-]+:$/ { gsub(/[ :]/, ""); print }' "$1/compose.yaml" | sort -u
}

# Losing a fixed name is the price of --scale, and Compose recognises the old
# container by its labels, so nothing is orphaned. What breaks is every command
# and document that still spells the old name out.
#
# A container named after its own service is not affected: the service name
# stays a network alias, so http://nim-llm:8000 keeps resolving. Only a name
# that differs from the service disappears for good.
renamed_containers_are_not_named_elsewhere() {
    local name services renamed=() still_cited=()
    services=$(service_names_in "$AFTER")

    while read -r name; do
        [[ -n "$name" ]] || continue
        grep -qxF "$name" <<< "$services" && continue
        renamed+=("$name")
        grep -rqE "(^|[^a-z0-9-])${name}([^a-z0-9-]|$)" \
            "$REPO_ROOT/README.md" "$REPO_ROOT"/*.sh 2>/dev/null \
            && still_cited+=("$name")
    done <<< "$(names_the_install_would_lose | sed 's/container_name: //')"

    (( ${#renamed[@]} )) && echo "no longer reachable by name: ${renamed[*]}"
    (( ${#still_cited[@]} == 0 )) && return 0
    echo "still spelled out in the repository: ${still_cited[*]}"
    return 1
}

# The reason a rename is safe at all, and not a property of this configuration:
# a volume is attached by its own name. If Compose ever stopped carrying it
# over, every customer would re-download the model weights on migration.
a_renamed_container_keeps_its_volumes() {
    local project=migration-rename-$$ dir="$WORK_DIR/rename"
    mkdir -p "$dir"
    cat > "$dir/before.yaml" <<EOF
name: $project
services:
  engine:
    image: alpine:3
    container_name: ${project}-fixed
    command: sleep 120
    volumes:
      - cache:/cache
volumes:
  cache:
    name: ${project}-cache
EOF
    grep -v 'container_name:' "$dir/before.yaml" > "$dir/after.yaml"

    docker compose -f "$dir/before.yaml" up -d >/dev/null 2>&1 || return 1
    docker exec "${project}-fixed" sh -c 'echo model-weights > /cache/w' >/dev/null 2>&1
    docker compose -f "$dir/after.yaml" up -d >/dev/null 2>&1

    local survived=1
    docker compose -f "$dir/after.yaml" exec -T engine cat /cache/w 2>/dev/null | grep -q model-weights \
        && survived=0
    docker compose -f "$dir/after.yaml" down -v >/dev/null 2>&1
    return "$survived"
}

resolve_starting_point || { echo "cannot resolve $FROM_REF"; exit 1; }
lay_out_both_versions

printf '%sMigrating an existing install%s %sfrom %s%s\n' \
    "$BOLD" "$NC" "$DIM" "$(git -C "$REPO_ROOT" rev-parse --short "$FROM_REF")" "$NC"
echo

property "an untouched environment file is refused, and says which variable" \
    the_new_stack_refuses_an_untouched_env
property "the installer supplies every variable the new version requires" \
    the_installer_supplies_what_is_missing
property "the stack then renders" \
    the_new_stack_then_renders

echo
printf '%sWhat the customer keeps%s\n' "$BOLD" "$NC"
property "every volume and network keeps its name" \
    the_state_keeps_its_names
property "the documents stay at the same path" \
    the_data_directory_is_unchanged
property "the database keeps its credentials" \
    the_database_keeps_its_credentials
property "the containers that lose a fixed name are named nowhere else" \
    renamed_containers_are_not_named_elsewhere
property "a renamed container keeps its volumes" \
    a_renamed_container_keeps_its_volumes

echo
printf '%s%d verified%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d failing%s\n' "$RED" "$FAILED" "$NC"
    printf '\nNot working:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
