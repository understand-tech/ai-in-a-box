#!/usr/bin/env bash

set -uo pipefail

MONGO_IMAGE=$(grep -m1 -oE 'mongo:[0-9.]+' "$(dirname "${BASH_SOURCE[0]}")/../compose.yaml" || echo mongo:8.2)
BACKUP_IMAGE=$(grep -m1 -oE 'tiredofit/db-backup:[0-9.]+' "$(dirname "${BASH_SOURCE[0]}")/../compose.yaml" || echo tiredofit/db-backup:4.1.100)
RUN=dbr-$$
NET=$RUN-net
SOURCE_NODE=$RUN-source
TARGET_NODE=$RUN-target
BACKUP_NODE=$RUN-backup
ARCHIVE_VOLUME=$RUN-archives
PASSWORD=restore-test

cleanup() {
    docker rm -f "$SOURCE_NODE" "$TARGET_NODE" "$BACKUP_NODE" >/dev/null 2>&1
    docker volume rm "$ARCHIVE_VOLUME" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT

echo "images: $MONGO_IMAGE, $BACKUP_IMAGE"
docker network create "$NET" >/dev/null
docker volume create "$ARCHIVE_VOLUME" >/dev/null

echo
echo "=== a database with known content ==="
docker run -d --name "$SOURCE_NODE" --network "$NET" \
    -e MONGO_INITDB_ROOT_USERNAME=admin -e MONGO_INITDB_ROOT_PASSWORD="$PASSWORD" \
    "$MONGO_IMAGE" >/dev/null
sleep 15

docker exec "$SOURCE_NODE" mongosh --quiet -u admin -p "$PASSWORD" --authenticationDatabase admin --eval '
    for (const dbName of ["ut-db", "ut-app-llms", "app-builder"]) {
        const target = db.getSiblingDB(dbName);
        for (let c = 0; c < 3; c++) {
            const docs = [];
            for (let i = 0; i < 50; i++) docs.push({ n: i, payload: "x".repeat(200) });
            target.getCollection("collection_" + c).insertMany(docs);
        }
    }
' >/dev/null 2>&1

fingerprint() {
    docker exec "$1" mongosh --quiet ${2:+-u admin -p "$PASSWORD" --authenticationDatabase admin} --eval '
        db.adminCommand("listDatabases").databases
          .filter(d => !["admin","local","config"].includes(d.name))
          .map(d => {
              const target = db.getSiblingDB(d.name);
              return d.name + "[" + target.getCollectionNames().sort()
                  .map(c => c + ":" + target.getCollection(c).countDocuments()).join(",") + "]";
          }).sort().join(" ")' 2>/dev/null | tail -1
}

SOURCE=$(fingerprint "$SOURCE_NODE" auth)
echo "$SOURCE"

echo
echo "=== the backup container produces an archive ==="
docker run -d --name "$BACKUP_NODE" --network "$NET" -v "$ARCHIVE_VOLUME":/backup \
    -e DB01_TYPE=mongo -e DB01_HOST="$SOURCE_NODE" -e DB01_PORT=27017 \
    -e DB01_USER=admin -e DB01_PASS="$PASSWORD" -e DB01_AUTH=admin \
    -e DB01_BACKUP_INTERVAL=1440 -e DEFAULT_LOG_LEVEL=INFO \
    "$BACKUP_IMAGE" >/dev/null
sleep 25
docker exec "$BACKUP_NODE" sh -c 'backup-now >/dev/null 2>&1 || true'
sleep 15

ARCHIVE=$(docker exec "$BACKUP_NODE" sh -c 'ls -t /backup/*.archive.gz 2>/dev/null | head -1')
if [[ -z "$ARCHIVE" ]]; then
    echo ">>> FAILED: the backup container produced no archive"
    docker logs "$BACKUP_NODE" 2>&1 | tail -8
    exit 1
fi
echo "archive: $(basename "$ARCHIVE")"
docker exec "$BACKUP_NODE" sh -c "cd /backup && md5sum -c '$(basename "$ARCHIVE").md5'" 2>&1 | tail -1

echo
echo "=== it restores into an empty database ==="
docker run -d --name "$TARGET_NODE" --network "$NET" "$MONGO_IMAGE" >/dev/null
sleep 15
LOCAL_ARCHIVE=$(mktemp)
docker exec "$BACKUP_NODE" sh -c "cat '$ARCHIVE'" > "$LOCAL_ARCHIVE"
docker cp "$LOCAL_ARCHIVE" "$TARGET_NODE":/tmp/a.gz >/dev/null
rm -f "$LOCAL_ARCHIVE"
docker exec "$TARGET_NODE" mongorestore --gzip --archive=/tmp/a.gz --quiet 2>&1 | tail -2

RESTORED=$(fingerprint "$TARGET_NODE")
echo "$RESTORED"

echo
if [[ "$SOURCE" == "$RESTORED" ]]; then
    echo ">>> identical: every database, collection and document count"
    exit 0
fi
echo ">>> DIFFERENT"
echo "    source:   $SOURCE"
echo "    restored: $RESTORED"
exit 1
