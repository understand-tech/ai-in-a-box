#!/bin/sh

# Each step checks its own result: set -e is ignored inside a function called
# from an || list, which is how each run is called.
set -u

LOCAL_REPOSITORY="${RESTIC_REPOSITORY:-/backup/restic}"
DESTINATION="${BACKUP_DESTINATION_REPOSITORY:-}"
SOURCE_DIR="${BACKUP_SOURCE:-/data}"
DUMP_DIR="${BACKUP_DUMPS:-/backup}"
HTTPS_AUTHORITY="${BACKUP_HTTPS_AUTHORITY:-/caddy/caddy/pki/authorities/local}"
STATUS_FILE="${DUMP_DIR}/.understandtech-backup-status.json"
KEEP_DAILY="${BACKUP_FILES_KEEP_DAILY:-7}"
KEEP_WEEKLY="${BACKUP_FILES_KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${BACKUP_FILES_KEEP_MONTHLY:-6}"
HEALTHY_FOR_MINUTES=$(( 26 * 60 ))

log() { echo "$(date -u '+%Y-%m-%d %H:%M:%S') [files-backup] $*"; }

on() {
    local repository=$1
    shift
    RESTIC_REPOSITORY="$repository" restic --retry-lock 30m "$@"
}

the_destination_is_mounted() {
    [ -z "${BACKUP_DESTINATION_MARKER:-}" ] || [ -e "$BACKUP_DESTINATION_MARKER" ]
}

# restic 0.18 exits 10 when there is no repository and 12 when the password does
# not open it; anything else non-zero is a destination it cannot reach.
open() {
    local repository=$1 template=${2:-} status=0 reason
    reason=$(on "$repository" cat config 2>&1 >/dev/null) || status=$?
    case "$status" in
        0) return 0 ;;
        10)
            if [ -n "$template" ] && on "$template" cat config >/dev/null 2>&1; then
                log "initialising repository at ${repository}, chunked as ${template} so that copies between them deduplicate"
                RESTIC_FROM_REPOSITORY="$template" RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" \
                    on "$repository" init --copy-chunker-params
            else
                log "initialising repository at ${repository}"
                on "$repository" init
            fi ;;
        12)
            log "BACKUP_FILES_PASSWORD does not open the repository at ${repository}, nothing written"
            return 1 ;;
        *)
            log "cannot reach the repository at ${repository}, nothing written"
            printf '%s\n' "$reason"
            return 1 ;;
    esac
}

back_up() {
    set -- "$SOURCE_DIR"
    if [ -d "$DUMP_DIR" ]; then
        set -- "$@" "$DUMP_DIR"
    fi
    # Caddy's own authority signs the HTTPS certificate browsers see; one recreated
    # on a restored machine sends every client back to importing a root.
    if [ -d "$HTTPS_AUTHORITY" ]; then
        set -- "$@" "$HTTPS_AUTHORITY"
    fi
    # A running database's files copied while it writes restore into a corrupt
    # state. The App Builder starts one MongoDB per generated app under
    # workspaces/*/mongo-data, so those are left out rather than backed up
    # unreliably. The repository lives inside DUMP_DIR, so without its exclusion
    # restic would take a snapshot of itself, growing on every run.
    log "backing up $*"
    on "$LOCAL_REPOSITORY" backup "$@" \
        --exclude "$LOCAL_REPOSITORY" \
        --exclude "$STATUS_FILE" \
        --exclude '*/mongo-data' \
        --exclude '*/node_modules' \
        --tag files
}

apply_retention() {
    on "$1" forget --tag files --prune \
        --keep-within-hourly 1d \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY"
}

copy_to_the_destination() {
    if ! the_destination_is_mounted; then
        log "the destination is not mounted: ${BACKUP_DESTINATION_MARKER} is missing, nothing copied"
        DESTINATION_STATE=not-mounted
        return 1
    fi
    open "$DESTINATION" "$LOCAL_REPOSITORY" || return 1
    log "copying to ${DESTINATION}"
    RESTIC_FROM_REPOSITORY="$LOCAL_REPOSITORY" RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD" \
        on "$DESTINATION" copy || return 1
    if [ "${BACKUP_DESTINATION_RETENTION:-appliance}" = owner ]; then
        log "retention at ${DESTINATION} is left to its owner"
    else
        log "applying retention at ${DESTINATION}"
        apply_retention "$DESTINATION" || return 1
    fi
    DESTINATION_STATE=copied
}

json_or_null() {
    if [ -z "$1" ]; then printf 'null'; else printf '"%s"' "$1"; fi
}

write_the_status() {
    local result=$1
    {
        printf '{"started_at":"%s","finished_at":"%s","result":"%s",' \
            "$RUN_STARTED_AT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$result"
        printf '"failed_step":%s,"destination":"%s"}\n' "$(json_or_null "$FAILED_STEP")" "$DESTINATION_STATE"
    } > "${STATUS_FILE}.new" && mv "${STATUS_FILE}.new" "$STATUS_FILE"
}

step() {
    FAILED_STEP=$1
    shift
    "$@" || return 1
    FAILED_STEP=""
}

run_the_steps() {
    # A destination that already holds snapshots lends the local repository its
    # chunking, so that the copies between them deduplicate.
    local template=""
    if [ -n "$DESTINATION" ] && the_destination_is_mounted; then
        template=$DESTINATION
    fi
    step open-local-repository open "$LOCAL_REPOSITORY" "$template" || return 1
    step back-up back_up || return 1
    log "applying retention"
    step apply-retention apply_retention "$LOCAL_REPOSITORY" || return 1
    log "verifying repository"
    step check-local-repository on "$LOCAL_REPOSITORY" check || return 1
    if [ -n "$DESTINATION" ]; then
        DESTINATION_STATE=failed
        step copy-to-destination copy_to_the_destination || return 1
    fi
}

run() {
    RUN_STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    FAILED_STEP=""
    DESTINATION_STATE=none
    if run_the_steps; then
        write_the_status ok
        log "done"
        return 0
    fi
    write_the_status failed
    log "failed at ${FAILED_STEP}"
    return 1
}

# A run killed with its container leaves its lock behind, and the next would
# wait on it. When the service starts nothing else writes to the local
# repository, so every lock there is stale; at the destination, only the ones
# restic can tell are.
clear_stale_locks() {
    on "$LOCAL_REPOSITORY" unlock --remove-all >/dev/null 2>&1 || true
    if [ -n "$DESTINATION" ] && the_destination_is_mounted; then
        on "$DESTINATION" unlock >/dev/null 2>&1 || true
    fi
}

# Healthy while the last run went through to the end, the copy to the
# destination included, and was less than a day and two hours ago.
healthy() {
    grep -q '"result":"ok"' "$STATUS_FILE" 2>/dev/null \
        && [ -n "$(find "$STATUS_FILE" -mmin -"$HEALTHY_FOR_MINUTES")" ]
}

case "${1:-run}" in
    run) run ;;
    start) clear_stale_locks; run ;;
    healthy) healthy ;;
    *) echo "usage: backup-files [run|start|healthy]" >&2; exit 2 ;;
esac
