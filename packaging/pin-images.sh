#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_ENV="${RELEASE_ENV:-$REPO_ROOT/release.env}"

usage() {
    cat <<EOF
pin-images.sh — rewrites every image in release.env as name:tag@sha256:...

  ./packaging/pin-images.sh          resolve and rewrite
  ./packaging/pin-images.sh --check  report what is not pinned, change nothing

A tag is a name the registry can repoint; a digest is the content. Keeping both
means the line still says which version it is, and still pulls one exact image.

Needs a registry login: these images are private.
EOF
}

digest_of() {
    docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null
}

image_lines() {
    grep -nE '^[A-Z_]*_IMAGE="[^"]+"' "$RELEASE_ENV" || true
}

reference_in() {
    local line=$1
    line=${line#*=\"}
    printf '%s' "${line%\"}"
}

key_in() {
    local line=$1
    line=${line#*:}
    printf '%s' "${line%%=*}"
}

already_pinned() {
    case "$1" in
        *@sha256:*) return 0 ;;
    esac
    return 1
}

report_what_is_not_pinned() {
    local line reference loose=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        reference=$(reference_in "$line")
        already_pinned "$reference" && continue
        printf '%s is a tag: %s\n' "$(key_in "$line")" "$reference"
        loose=$((loose + 1))
    done <<< "$(image_lines)"
    (( loose == 0 )) && return 0
    printf '\n%d image(s) name something the registry can repoint.\n' "$loose"
    return 1
}

pin_one_reference() {
    local key=$1 reference=$2 digest
    if already_pinned "$reference"; then
        printf '  = %s already pinned\n' "$key" >&2
        return 0
    fi
    digest=$(digest_of "$reference")
    if [[ -z "$digest" ]]; then
        printf '  ! %s could not be resolved: %s\n' "$key" "$reference" >&2
        return 1
    fi
    printf '  + %s %s\n' "$key" "$digest" >&2
    # The separator is a literal @, so a reference already carrying one would
    # take a second: already_pinned is what keeps that from happening.
    sed -i.bak "s|^${key}=\"${reference}\"|${key}=\"${reference}@${digest}\"|" "$RELEASE_ENV"
    rm -f "${RELEASE_ENV}.bak"
}

pin_every_image() {
    local line failed=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        pin_one_reference "$(key_in "$line")" "$(reference_in "$line")" || failed=$((failed + 1))
    done <<< "$(image_lines)"
    (( failed == 0 )) && return 0
    printf '\n%d image(s) were left as they were. A registry login is what this usually wants.\n' "$failed" >&2
    return 1
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        --check)   report_what_is_not_pinned; exit $? ;;
        "")        ;;
        *)         usage >&2; exit 1 ;;
    esac
    command -v docker >/dev/null 2>&1 \
        || { echo "docker is missing — it is what talks to the registry" >&2; exit 1; }
    pin_every_image
}

main "$@"
