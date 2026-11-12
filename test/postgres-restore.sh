#!/usr/bin/env bash
# Writes, notes the instant, writes again, restores to that instant with the
# image and the pgBackRest settings the release ships, and finds what was noted.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE=$(sed -n 's/^POSTGRES_IMAGE="\(.*\)"$/\1/p' "$REPO_ROOT/release.env" | head -1)
[[ -n "$IMAGE" ]] || { echo ">>> release.env declares no POSTGRES_IMAGE" >&2; exit 1; }
RUN=pgr-$$
DATA=$RUN-data
SOCKET=$RUN-socket
REPO=$RUN-backup

cleanup() {
    docker rm -f "$RUN" >/dev/null 2>&1
    docker volume rm "$DATA" "$SOCKET" "$REPO" >/dev/null 2>&1
}
trap cleanup EXIT

if ! docker image inspect "$IMAGE" >/dev/null 2>&1 && ! docker pull -q "$IMAGE" >/dev/null 2>&1; then
    echo ">>> FAILED: ${IMAGE} could not be pulled; it is private, and this run holds no registry access to it." >&2
    exit 1
fi

settings=(
    -e PGBACKREST_STANZA=ut
    -e PGBACKREST_PG1_PATH=/var/lib/postgresql/18/docker
    -e PGBACKREST_PG1_SOCKET_PATH=/var/run/postgresql
    -e PGBACKREST_REPO1_PATH=/var/lib/pgbackrest
    -e PGBACKREST_REPO1_CIPHER_TYPE=aes-256-cbc
    -e PGBACKREST_REPO1_CIPHER_PASS=restore-test-cipher
    -e PGBACKREST_LOG_LEVEL_CONSOLE=warn
    -e PGBACKREST_LOG_LEVEL_FILE=off
    -v "$DATA:/var/lib/postgresql" -v "$SOCKET:/var/run/postgresql" -v "$REPO:/var/lib/pgbackrest"
)
start() {
    docker run -d --name "$RUN" "${settings[@]}" -e POSTGRES_PASSWORD=restore-test "$IMAGE" \
        postgres -c archive_mode=on -c "archive_command=pgbackrest archive-push %p" -c archive_timeout=60 >/dev/null
    for _ in $(seq 60); do docker exec "$RUN" pg_isready -q 2>/dev/null && return 0; sleep 1; done
    return 1
}
sql() { docker exec "$RUN" psql -U postgres -v ON_ERROR_STOP=1 -tAc "$1"; }

failures=0
check() {
    if "${@:2}" >/dev/null 2>&1; then echo "  ✔ $1"; else echo "  ✘ $1"; failures=$((failures + 1)); fi
}

echo "image: $IMAGE"
check "PostgreSQL starts with archiving on" start
check "the stanza is created" docker exec "$RUN" pgbackrest stanza-create
check "a full backup is taken" docker exec "$RUN" pgbackrest backup --type=full --start-fast

sql "CREATE TABLE marks (label text)" >/dev/null
sql "INSERT INTO marks VALUES ('before')" >/dev/null
sleep 2
INSTANT=$(sql "SELECT now()")
sleep 2
sql "INSERT INTO marks VALUES ('after')" >/dev/null
sql "SELECT pg_switch_wal()" >/dev/null
check "the write-ahead log after the instant is archived" \
    sh -c "for _ in \$(seq 30); do docker exec $RUN psql -U postgres -tAc \"SELECT last_archived_time > '$INSTANT'::timestamptz FROM pg_stat_archiver\" | grep -qx t && exit 0; sleep 1; done; exit 1"

docker stop "$RUN" >/dev/null
docker rm "$RUN" >/dev/null
check "the restore to the instant succeeds" docker run --rm "${settings[@]}" --entrypoint pgbackrest "$IMAGE" \
    restore --delta --type=time --target="$INSTANT" --target-action=promote
check "PostgreSQL starts on the restored data" start
check "what was written before the instant is back, and nothing after it" \
    sh -c "[ \"\$(docker exec $RUN psql -U postgres -tAc \"SELECT string_agg(label, ',' ORDER BY label) FROM marks\")\" = before ]"

echo
(( failures == 0 )) && { echo "PostgreSQL comes back to an instant"; exit 0; }
echo "${failures} check(s) failed"
exit 1
