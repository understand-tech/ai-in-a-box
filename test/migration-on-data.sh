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
        [[ -n "${MIGRATION_API_IMAGE:-}" ]] && echo "API_IMAGE=$MIGRATION_API_IMAGE"
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
    rewrite_fixed_names "$WORK_DIR/$stage/compose.yaml"
    cp "$WORK_DIR/env" "$WORK_DIR/$stage/.env"
}

rewrite_fixed_names() {
    sed -i.bak \
        -e "s/^\( *container_name: \)ut-/\1$RUN-/" \
        -e "s/^\( *container_name: \)nim-/\1$RUN-nim-/" \
        -e "s/^\( *name: \)ut-/\1$RUN-/" \
        -e "s/^\( *- \"\)27018:27017\"/\1127.0.0.1:$HOST_PORT:27017\"/" \
        -e "s/^\( *- \"\)8001:8000\"/\1127.0.0.1:$((HOST_PORT + 1)):8000\"/" \
        -e "s/^\( *- \"\)8002:8000\"/\1127.0.0.1:$((HOST_PORT + 2)):8000\"/" \
        "$1"
    rm -f "$1.bak"
}

names_not_isolated_in() {
    compose_in "$1" config 2>/dev/null \
        | grep -oE '^ *(container_name|name): [a-z][a-z0-9_-]*' \
        | awk '{print $2}' | grep -vE "^$RUN" | sort -u
}

refuse_to_run_beside_production() {
    local stray
    stray=$(names_not_isolated_in "$1")
    [[ -z "$stray" ]] && return 0
    printf '%s\n' "$stray" | sed 's/^/     /'
    fail "these names are not isolated and belong to whatever else runs here"
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

database_shape() {
    mongo_eval '
        db.adminCommand("listDatabases").databases
          .filter(d => !["admin","local","config"].includes(d.name))
          .map(d => {
              const target = db.getSiblingDB(d.name);
              return d.name + "[" + target.getCollectionNames().sort()
                  .map(c => {
                      const collection = target.getCollection(c);
                      return c + ":" + collection.countDocuments()
                           + "/" + collection.getIndexes().map(i => i.name).sort().join("+");
                  }).join(",") + "]";
          }).sort().join(" ")'
}

database_contents() {
    mongo_eval '
        db.adminCommand("listDatabases").databases
          .filter(d => !["admin","local","config"].includes(d.name))
          .map(d => {
              const target = db.getSiblingDB(d.name);
              return target.getCollectionNames().sort().map(c =>
                  EJSON.stringify(target.getCollection(c).find().sort({_id: 1}).toArray())
              ).join("");
          }).join("")' | cksum | cut -d' ' -f1
}

documents_fingerprint() {
    ( cd "$DATA_ROOT" && find . -type f | sort | while read -r file; do
        printf '%s %s\n' "$file" "$(cksum < "$file" | cut -d' ' -f1)"
      done | cksum | cut -d' ' -f1 )
}

document_count() {
    find "$DATA_ROOT" -type f | wc -l | tr -d ' '
}

application_image_is_available() {
    docker image inspect "$(env_value API_IMAGE)" >/dev/null 2>&1
}

open_database_connections() {
    mongo_eval 'db.serverStatus().connections.current'
}

application_answers() {
    local attempt code
    for attempt in $(seq 1 45); do
        code=$(docker run --rm --network "${RUN}_${RUN}-backend-network" curlimages/curl:latest \
            -s -o /dev/null -w '%{http_code}' -m 5 "http://$RUN-api:8501/api/" 2>/dev/null)
        [[ "$code" == "200" ]] && return 0
        sleep 4
    done
    return 1
}

supply_missing_variables() {
    set +u
    INSTALL_DIR="$WORK_DIR/after" source "$REPO_ROOT/ut-install" >/dev/null 2>&1
    set -u +eE
    trap - ERR
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

echo "1. checking nothing here belongs to another deployment"
refuse_to_run_beside_production before
refuse_to_run_beside_production after

echo "2. starting the version the customer runs"
compose_in before up -d mongodb >/dev/null 2>&1 || fail "the starting version does not come up"
wait_for_database || fail "the database never answered"

echo "3. filling it"
if [[ -n "$ARCHIVE" ]]; then
    fill_from_archive || fail "could not restore $ARCHIVE"
    printf '   %srestored from %s%s\n' "$DIM" "$(basename "$ARCHIVE")" "$NC"
else
    fill_with_generated_data >/dev/null
    printf '   %sgenerated%s\n' "$DIM" "$NC"
fi
write_documents

BEFORE_SHAPE=$(database_shape)
BEFORE_CONTENTS=$(database_contents)
BEFORE_DOCS=$(documents_fingerprint)
BEFORE_COUNT=$(document_count)
[[ -n "$BEFORE_SHAPE" ]] || fail "the database is empty before the migration, so nothing would be proven"
(( BEFORE_COUNT > 0 )) || fail "no documents on disk before the migration"
printf '   %s%s%s\n' "$DIM" "${BEFORE_SHAPE:0:120}" "$NC"

echo "4. applying the new version"
supply_missing_variables
compose_in before down >/dev/null 2>&1
compose_in after up -d mongodb >/dev/null 2>&1 || fail "the new version does not come up on the existing volume"
wait_for_database || fail "the database never answered after the migration"

echo "5. comparing"
AFTER_SHAPE=$(database_shape)
AFTER_CONTENTS=$(database_contents)
AFTER_DOCS=$(documents_fingerprint)
AFTER_COUNT=$(document_count)

echo
if [[ "$BEFORE_SHAPE" != "$AFTER_SHAPE" ]]; then
    printf '%sthe databases, collections, counts or indexes changed%s\n  before: %s\n  after:  %s\n' \
        "$RED" "$NC" "$BEFORE_SHAPE" "$AFTER_SHAPE"
    exit 1
fi
if [[ "$BEFORE_CONTENTS" != "$AFTER_CONTENTS" ]]; then
    printf '%sthe documents inside the database changed%s — %s became %s\n' \
        "$RED" "$NC" "$BEFORE_CONTENTS" "$AFTER_CONTENTS"
    exit 1
fi
if [[ "$BEFORE_COUNT" != "$AFTER_COUNT" || "$BEFORE_DOCS" != "$AFTER_DOCS" ]]; then
    printf '%sthe files on disk changed%s — %s files / %s became %s files / %s\n' \
        "$RED" "$NC" "$BEFORE_COUNT" "$BEFORE_DOCS" "$AFTER_COUNT" "$AFTER_DOCS"
    exit 1
fi

printf '%s✔ the database keeps its shape%s — every database, collection, document count and index\n' "$GREEN" "$NC"
printf '%s✔ the database keeps its contents%s — every document, field by field, checksum %s\n' \
    "$GREEN" "$NC" "$AFTER_CONTENTS"
printf '%s✔ the files keep their names and contents%s — %s files, checksum %s\n' \
    "$GREEN" "$NC" "$AFTER_COUNT" "$AFTER_DOCS"

if ! application_image_is_available; then
    printf '\n%sthe application was not started: %s is not on this machine%s\n' \
        "$DIM" "$(env_value API_IMAGE)" "$NC"
    exit 0
fi

echo
echo "6. starting the application on the migrated database"
IDLE_CONNECTIONS=$(open_database_connections)
compose_in after up -d redis api >/dev/null 2>&1 || fail "the application does not come up after the migration"
application_answers || fail "the application never answered on /api/"

BUSY_CONNECTIONS=$(open_database_connections)
SERVED_SHAPE=$(database_shape)
SERVED_CONTENTS=$(database_contents)

echo
(( BUSY_CONNECTIONS > IDLE_CONNECTIONS )) \
    || fail "the application answers but opened no database connection — $IDLE_CONNECTIONS before, $BUSY_CONNECTIONS after"
printf '%s✔ the application serves%s — /api/ answers 200\n' "$GREEN" "$NC"
printf '%s✔ it reaches the database across the new network%s — connections went from %s to %s\n' \
    "$GREEN" "$NC" "$IDLE_CONNECTIONS" "$BUSY_CONNECTIONS"

if [[ "$SERVED_SHAPE" != "$AFTER_SHAPE" || "$SERVED_CONTENTS" != "$AFTER_CONTENTS" ]]; then
    printf '%s✘ starting the application changed the data%s — the comparison above was taken too early\n' "$RED" "$NC"
    exit 1
fi
printf '%s✔ starting it changed nothing%s — no schema migration ran behind the comparison\n' "$GREEN" "$NC"
