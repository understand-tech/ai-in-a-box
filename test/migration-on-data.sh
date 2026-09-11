#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FROM_REF=${MIGRATION_FROM:-origin/main}
ARCHIVE=${MIGRATION_ARCHIVE:-}

RUN=mig$$
WORK_DIR="$(mktemp -d)"
DATA_ROOT="$WORK_DIR/data"
HOST_PORT=${MIGRATION_HOST_PORT:-27119}

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; NC=""
fi

compose_in() {
    local stage=$1; shift
    ( cd "$WORK_DIR/$stage" && docker compose -f compose.yaml "$@" )
}

cleanup() {
    compose_in after down >/dev/null 2>&1
    compose_in before down >/dev/null 2>&1
    docker volume rm "$RUN-mongodb-data" "$RUN-redis-data" >/dev/null 2>&1
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() { printf '\n%s>>> %s%s\n' "$RED" "$1" "$NC"; exit 1; }

write_isolated_env() {
    git -C "$REPO_ROOT" show "$FROM_REF:.env.example" > "$WORK_DIR/env"
    {
        echo "COMPOSE_PROJECT_NAME=$RUN"
        echo "RESOURCE_PREFIX=$RUN"
        echo "CONTAINER_PREFIX=$RUN"
        echo "DATA_ROOT=$DATA_ROOT"
        echo "MONGODB_HOST_PORT=$HOST_PORT"
    } >> "$WORK_DIR/env"
    chmod 600 "$WORK_DIR/env"
    mkdir -p "$DATA_ROOT"
}

stage_version() {
    local stage=$1 ref=$2
    mkdir -p "$WORK_DIR/$stage"
    if ! git -C "$REPO_ROOT" show "$ref:compose.yaml" > "$WORK_DIR/$stage/compose.yaml" 2>/dev/null; then
        cp "$REPO_ROOT/compose.yaml" "$WORK_DIR/$stage/compose.yaml"
    fi
    cp "$WORK_DIR/env" "$WORK_DIR/$stage/.env"
}

env_value() {
    grep -m1 -E "^${1}=" "$WORK_DIR/env" | cut -d= -f2- | tr -d '"'
}

mongo_eval() {
    docker exec "$RUN-mongodb" mongosh --quiet \
        -u "$(env_value MONGODB_USERNAME)" -p "$(env_value MONGODB_PASSWORD)" \
        --authenticationDatabase admin --eval "$1" 2>/dev/null | tail -1
}

wait_for_database() {
    local attempt
    for attempt in $(seq 1 30); do
        [[ "$(mongo_eval 'db.adminCommand("ping").ok')" == "1" ]] && return 0
        sleep 2
    done
    return 1
}

fill_with_generated_data() {
    mongo_eval '
        for (const name of ["ut-db", "ut-app-llms", "app-builder"]) {
            const target = db.getSiblingDB(name);
            for (let c = 0; c < 4; c++) {
                const docs = [];
                for (let i = 0; i < 250; i++) docs.push({ n: i, payload: "x".repeat(400) });
                target.getCollection("collection_" + c).insertMany(docs);
            }
        }
        "filled"'
}

fill_from_archive() {
    docker cp "$ARCHIVE" "$RUN-mongodb":/tmp/seed.gz >/dev/null || return 1
    docker exec "$RUN-mongodb" mongorestore --gzip --archive=/tmp/seed.gz --quiet \
        -u "$(env_value MONGODB_USERNAME)" -p "$(env_value MONGODB_PASSWORD)" \
        --authenticationDatabase admin >/dev/null 2>&1
}

write_documents() {
    local index
    mkdir -p "$DATA_ROOT/documents"
    for index in $(seq 1 200); do
        head -c 20000 /dev/urandom > "$DATA_ROOT/documents/document-$index.bin"
    done
}

database_fingerprint() {
    mongo_eval '
        db.adminCommand("listDatabases").databases
          .filter(d => !["admin","local","config"].includes(d.name))
          .map(d => {
              const target = db.getSiblingDB(d.name);
              return d.name + "[" + target.getCollectionNames().sort()
                  .map(c => c + ":" + target.getCollection(c).countDocuments()).join(",") + "]";
          }).sort().join(" ")'
}

documents_fingerprint() {
    find "$DATA_ROOT" -type f -exec cat {} + 2>/dev/null | cksum | cut -d' ' -f1
}

supply_missing_variables() {
    set +u
    INSTALL_DIR="$WORK_DIR/after" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
    set -u
    generate_application_secrets "$WORK_DIR/after/.env" >/dev/null 2>&1
    generate_database_credentials "$WORK_DIR/after/.env" >/dev/null 2>&1
}

printf '%sMigrating real data%s %sfrom %s, isolated as %s%s\n\n' \
    "$BOLD" "$NC" "$DIM" \
    "$(git -C "$REPO_ROOT" rev-parse --short "$FROM_REF" 2>/dev/null || echo "$FROM_REF")" \
    "$RUN" "$NC"

write_isolated_env
stage_version before "$FROM_REF"
stage_version after HEAD

echo "1. starting the version the customer runs"
compose_in before up -d mongodb >/dev/null 2>&1 || fail "the starting version does not come up"
wait_for_database || fail "the database never answered"

echo "2. filling it"
if [[ -n "$ARCHIVE" ]]; then
    fill_from_archive || fail "could not restore $ARCHIVE"
    printf '   %srestored from %s%s\n' "$DIM" "$(basename "$ARCHIVE")" "$NC"
else
    fill_with_generated_data >/dev/null
    printf '   %sgenerated%s\n' "$DIM" "$NC"
fi
write_documents

BEFORE_DB=$(database_fingerprint)
BEFORE_DOCS=$(documents_fingerprint)
[[ -n "$BEFORE_DB" ]] || fail "the database is empty before the migration, so nothing would be proven"
printf '   %s%s%s\n' "$DIM" "${BEFORE_DB:0:120}" "$NC"

echo "3. applying the new version"
supply_missing_variables
compose_in before down >/dev/null 2>&1
compose_in after up -d mongodb >/dev/null 2>&1 || fail "the new version does not come up on the existing volume"
wait_for_database || fail "the database never answered after the migration"

echo "4. comparing"
AFTER_DB=$(database_fingerprint)
AFTER_DOCS=$(documents_fingerprint)

echo
if [[ "$BEFORE_DB" != "$AFTER_DB" ]]; then
    printf '%sthe database changed%s\n  before: %s\n  after:  %s\n' "$RED" "$NC" "$BEFORE_DB" "$AFTER_DB"
    exit 1
fi
if [[ "$BEFORE_DOCS" != "$AFTER_DOCS" ]]; then
    printf '%sthe documents changed%s\n  before: %s\n  after:  %s\n' "$RED" "$NC" "$BEFORE_DOCS" "$AFTER_DOCS"
    exit 1
fi

printf '%s✔ the database is identical%s — every database, collection and document count\n' "$GREEN" "$NC"
printf '%s✔ the documents are identical%s — %s files, checksum %s\n' \
    "$GREEN" "$NC" "$(find "$DATA_ROOT" -type f | wc -l | tr -d ' ')" "$AFTER_DOCS"
