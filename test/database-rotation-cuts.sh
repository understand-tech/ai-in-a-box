#!/usr/bin/env bash
# Replays every cut of the database password rotation on the real ut-install
# functions, then the next run's recovery, and compares what they leave with
# the formal model. Expected cases on stdin, as printed by
# `lake exe rotation_cases` in formal/: "<path> <cut> <outcome> <db> <local.env> <record>".

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

with_fakes() {
    local path=$1 cut=$2 work=$3
    UT_INSTALL_DIR="$work" source "$REPO_ROOT/bin/ut-install" >/dev/null 2>&1
    set +e
    trap - ERR
    EVENTS=0
    CUT=$cut
    REPLAYED_PATH=$path
    WORK=$work
    LOCAL_FILE="$work/local.env"
    ENV_FILE="$work/.env"
    RECORD="$work/database-password-change"
    COMPOSE_UPS=0

    event() { (( EVENTS == CUT )) && exit 99; EVENTS=$((EVENTS + 1)); }
    writing_to() { [[ "$(readlink "/proc/$1/fd/1")" == "$2" ]]; }

    cat() {
        local me=$BASHPID
        if writing_to "$me" "$LOCAL_FILE" || writing_to "$me" "$ENV_FILE"; then event; fi
        command cat "$@"
    }
    printf() {
        local me=$BASHPID
        if writing_to "$me" "$LOCAL_FILE"; then event; fi
        builtin printf "$@"
    }
    install() { event; : > "${*: -1}"; }
    sync() { event; }
    rm() {
        local arg
        for arg in "$@"; do [[ "$arg" == "$RECORD" ]] && event; done
        command rm "$@"
    }

    the_database_runs_here() { return 0; }
    the_services_that_read_it_are_ready_now() { return 0; }
    the_database_answers() { return 0; }
    take_a_verified_database_backup() { echo before.archive; }
    a_verified_database_backup_within_two_minutes() { echo after.archive; }
    every_waited_for_service_is_ready() { return 0; }
    random_alphanumeric() { echo new; }
    database_opens_with() { [[ "$1" == ut && "$2" == "$(<"$WORK/db")" ]]; }
    change_database_password() {
        event
        [[ "$REPLAYED_PATH" == change_is_refused ]] && return 1
        echo "$3" > "$WORK/db"
    }
    compose_in_dir() {
        COMPOSE_UPS=$((COMPOSE_UPS + 1))
        [[ "$REPLAYED_PATH" == services_do_not_come_back && $COMPOSE_UPS == 1 ]] && return 1
        return 0
    }
}

replay() {
    local path=$1 cut=$2 work outcome db local_password record
    work=$(mktemp -d)
    echo 'UT_RELEASE_VERSION="test"' > "$work/release.env"
    builtin printf '%s\n' 'MONGODB_USERNAME="ut"' 'MONGODB_PASSWORD="old"' 'JWT_SECRET="kept"' > "$work/local.env"
    echo old > "$work/db"

    ( with_fakes "$path" "$cut" "$work"; ROTATE_DATABASE_PASSWORD=true; step_rotate_a_published_database_password ) >/dev/null 2>&1
    if ( with_fakes "$path" -1 "$work"; step_finish_an_interrupted_database_password_change ) >/dev/null 2>&1; then
        outcome=settled
    else
        outcome=stopped
    fi

    db=$(<"$work/db")
    local_password=$(sed -n 's/^MONGODB_PASSWORD="\(.*\)"$/\1/p' "$work/local.env")
    [[ -f "$work/database-password-change" ]] && record=true || record=false
    command rm -rf "$work"
    echo "$path $cut $outcome $db ${local_password:-empty} $record"
}

differences=0
while read -r path cut expected; do
    actual=$(replay "$path" "$cut")
    if [[ "$actual" == "$path $cut $expected" ]]; then
        echo "same  $actual"
    else
        echo "DIFF  model: $path $cut $expected | ut-install: $actual"
        differences=$((differences + 1))
    fi
done

(( differences == 0 ))
