#!/usr/bin/env bash

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

    cp "$BEFORE/.env.example" "$BEFORE/.env"
    cp "$BEFORE/.env.example" "$AFTER/.env"
    chmod 600 "$BEFORE/.env" "$AFTER/.env"
}

load_installer() {
    set +u
    INSTALL_DIR="$BEFORE" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
    set -u
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

rendered_as_json() {
    ( cd "$1" && docker compose -f compose.yaml config --format json 2>/dev/null )
}

service_names_in() {
    awk '/^  [a-z0-9_-]+:$/ { gsub(/[ :]/, ""); print }' "$1/compose.yaml" | sort -u
}

state_names_in() {
    rendered_as_json "$1" \
        | jq -r '((.volumes // {}) + (.networks // {})) | to_entries[] | .value.name // .key' \
        | sort -u
}

container_names_in() {
    rendered "$1" -f compose.yaml | grep -oE 'container_name: [a-z0-9_-]+' | sort -u
}

names_the_install_would_lose() {
    comm -23 <(container_names_in "$BEFORE") <(container_names_in "$AFTER")
}

networks_of() {
    jq -r --arg s "$2" '.services[$s].networks // {} | keys[]' <<< "$1" | sort
}

services_holding_a_database_connection() {
    jq -r '.services | to_entries[]
           | select(.key != "mongodb")
           | select([.value.environment // {} | to_entries[]
                     | select((.value | tostring | test("mongodb://"))
                              or ((.key | test("_HOST$")) and (.value | tostring) == "mongodb"))]
                    | length > 0)
           | .key' <<< "$1"
}

spelled_out_in_the_repository() {
    grep -rqE "(^|[^a-z0-9-])${1}([^a-z0-9-]|$)" \
        "$REPO_ROOT/README.md" "$REPO_ROOT"/*.sh 2>/dev/null
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

the_installer_recognises_an_existing_database() {
    local present=migration-probe-$$ absent=migration-absent-$$ verdict=1
    docker volume create "$present-mongodb-data" >/dev/null 2>&1 || return 1
    printf 'RESOURCE_PREFIX="%s"\n' "$present" > "$WORK_DIR/present.env"
    printf 'RESOURCE_PREFIX="%s"\n' "$absent" > "$WORK_DIR/absent.env"

    if database_already_initialised "$WORK_DIR/present.env" \
        && ! database_already_initialised "$WORK_DIR/absent.env"; then
        verdict=0
    fi
    docker volume rm "$present-mongodb-data" >/dev/null 2>&1
    return "$verdict"
}

the_state_keeps_its_names() {
    local before lost
    before=$(state_names_in "$BEFORE")
    (( $(grep -c . <<< "$before") >= 10 )) \
        || { echo "only $(grep -c . <<< "$before") names found before the change, too few to be reading them all"; return 1; }
    lost=$(comm -23 <(printf '%s\n' "$before") <(state_names_in "$AFTER"))
    [[ -z "$lost" ]] || { echo "no longer mounted: $(tr '\n' ' ' <<< "$lost")"; return 1; }
}

the_data_directory_is_unchanged() {
    rendered "$AFTER" -f compose.yaml | grep -q '/var/lib/understandtech'
}

database_credentials_in() {
    rendered "$1" -f compose.yaml | grep -E 'MONGO_INITDB_ROOT_(USERNAME|PASSWORD):' | sort | cksum
}

the_database_keeps_its_credentials() {
    local before
    before=$(database_credentials_in "$BEFORE")
    [[ "$before" != "$(printf '' | cksum)" ]] || { echo "no credentials rendered before the change"; return 1; }
    [[ "$before" == "$(database_credentials_in "$AFTER")" ]] \
        || { echo "the rendered credentials differ"; return 1; }
}

every_service_that_uses_the_database_can_reach_it() {
    command -v jq >/dev/null || { echo "jq absent"; return 1; }
    local config db_networks service stranded=()
    config=$(rendered_as_json "$AFTER")
    db_networks=$(networks_of "$config" mongodb)
    [[ -n "$db_networks" ]] || { echo "the database is on no network at all"; return 1; }

    while read -r service; do
        [[ -n "$service" ]] || continue
        [[ -n "$(comm -12 <(printf '%s\n' "$db_networks") <(networks_of "$config" "$service"))" ]] && continue
        stranded+=("$service")
    done <<< "$(services_holding_a_database_connection "$config")"

    (( ${#stranded[@]} == 0 )) && return 0
    echo "would lose the database: ${stranded[*]}"
    return 1
}

renamed_containers_are_not_named_elsewhere() {
    local name services renamed=() still_cited=()
    services=$(service_names_in "$AFTER")

    while read -r name; do
        [[ -n "$name" ]] || continue
        grep -qxF "$name" <<< "$services" && continue
        renamed+=("$name")
        spelled_out_in_the_repository "$name" && still_cited+=("$name")
    done <<< "$(names_the_install_would_lose | sed 's/container_name: //')"

    (( ${#renamed[@]} )) && echo "no longer reachable by name: ${renamed[*]}"
    (( ${#still_cited[@]} == 0 )) && return 0
    echo "still spelled out in the repository: ${still_cited[*]}"
    return 1
}

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
load_installer

printf '%sMigrating an existing install%s %sfrom %s%s\n' \
    "$BOLD" "$NC" "$DIM" "$(git -C "$REPO_ROOT" rev-parse --short "$FROM_REF")" "$NC"
echo

property "an untouched environment file is refused, and says which variable" \
    the_new_stack_refuses_an_untouched_env
property "the installer supplies every variable the new version requires" \
    the_installer_supplies_what_is_missing
property "the stack then renders" \
    the_new_stack_then_renders
property "the installer recognises a database that is already there" \
    the_installer_recognises_an_existing_database

echo
printf '%sWhat the customer keeps%s\n' "$BOLD" "$NC"
property "every volume and network keeps its name" \
    the_state_keeps_its_names
property "the documents stay at the same path" \
    the_data_directory_is_unchanged
property "the database keeps its credentials" \
    the_database_keeps_its_credentials
property "every service that uses the database can still reach it" \
    every_service_that_uses_the_database_can_reach_it
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
