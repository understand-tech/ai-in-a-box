#!/usr/bin/env bash
# Replays every cut of the split of main's .env into local.env on the real
# ut-install functions, then the next run, and compares the settings compose
# reads with the formal model. Expected cases on stdin, as printed by
# `lake exe settings_cases` in formal/: "<cut> <value of each key>".

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYS=(OPERATOR_ONLY OPERATOR_CHANGED SAME_AS_RELEASE API_IMAGE LOG_LEVEL)

with_fakes() {
    local cut=$1 work=$2
    UT_INSTALL_DIR="$work" source "$REPO_ROOT/bin/ut-install" >/dev/null 2>&1
    set +e
    trap - ERR
    ROOT=$BASHPID
    CUT=$cut
    CUTS_COUNTER="$work/cuts-counter"
    echo 0 > "$CUTS_COUNTER"
    LOCAL_FILE="$work/local.env"
    ENV_FILE="$work/.env"

    event() {
        local events
        events=$(<"$CUTS_COUNTER")
        (( events == CUT )) && { kill -KILL "$ROOT"; exit 99; }
        echo $((events + 1)) > "$CUTS_COUNTER"
    }
    writing_to() { [[ "$(readlink "/proc/$1/fd/1")" == "$2" ]]; }

    printf() {
        local me=$BASHPID
        if writing_to "$me" "$LOCAL_FILE"; then event; fi
        builtin printf "$@"
    }
    mv() {
        local destination="${*: -1}"
        if [[ "$destination" == "$LOCAL_FILE" || "$destination" == "$ENV_FILE" ]]; then event; fi
        command mv "$@"
    }
    install() { event; command install "$@"; }
}

split_and_render() {
    migrate_existing_settings_into_local "$WORK/.env" "$WORK/local.env"
    render_settings "$WORK/.env" "$WORK/local.env"
}

replay() {
    local cut=$1 key values=()
    WORK=$(mktemp -d)
    builtin printf '%s\n' 'OPERATOR_CHANGED="release"' 'SAME_AS_RELEASE="release"' \
        'API_IMAGE="release"' 'LOG_LEVEL="INFO"' > "$WORK/release.env"
    builtin printf '%s\n' 'OPERATOR_ONLY="mine"' 'OPERATOR_CHANGED="mine"' 'SAME_AS_RELEASE="release"' \
        "API_IMAGE=\"main's\"" 'LOG_LEVEL="DEBUG"' > "$WORK/.env"

    ( with_fakes "$cut" "$WORK"; split_and_render ) >/dev/null 2>&1
    ( with_fakes -1 "$WORK"; split_and_render ) >/dev/null 2>&1

    UT_INSTALL_DIR="$WORK" source "$REPO_ROOT/bin/ut-install" >/dev/null 2>&1
    set +e
    for key in "${KEYS[@]}"; do
        values+=("$(setting_as_compose_reads_it "$WORK/.env" "$key" || echo unset)")
    done
    command rm -rf "$WORK"
    echo "$cut ${values[*]}"
}

differences=0
while read -r cut expected; do
    actual=$(replay "$cut")
    if [[ "$actual" == "$cut $expected" ]]; then
        echo "same  $actual"
    else
        echo "DIFF  model: $cut $expected | ut-install: $actual"
        differences=$((differences + 1))
    fi
done

(( differences == 0 ))
