#!/bin/sh

set -eu

SOURCE_DIR="${BACKUP_SOURCE:-/data}"
DUMP_DIR="${BACKUP_DUMPS:-/backup}"
KEEP_DAILY="${BACKUP_FILES_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_FILES_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${BACKUP_FILES_KEEP_MONTHLY:-6}"

log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S') [files-backup] $*"; }

restic snapshots >/dev/null 2>&1 || {
    log "initialising repository at ${RESTIC_REPOSITORY}"
    restic init
}

# A running database's files copied while it writes restore into a corrupt
# state. The App Builder starts one MongoDB per generated app under
# workspaces/*/mongo-data, so those are left out rather than backed up
# unreliably — they need a dump each, which belongs with the decision on
# whether the builder keeps generating containerised apps at all.
set -- "$SOURCE_DIR"
if [ -d "$DUMP_DIR" ]; then
    set -- "$@" "$DUMP_DIR"
fi

# The repository usually lives inside DUMP_DIR, so without this exclusion restic
# would take a snapshot of itself, growing on every run.
log "backing up $*"
restic backup "$@" \
    --exclude "$RESTIC_REPOSITORY" \
    --exclude '*/mongo-data' \
    --exclude '*/node_modules' \
    --tag files

log "applying retention"
restic forget --tag files --prune \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY"

log "verifying repository"
restic check

log "done"
