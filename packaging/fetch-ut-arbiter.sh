#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
RELEASE_ENV="${RELEASE_ENV:-$REPO_ROOT/release.env}"
ARCHITECTURES="arm64 amd64"
GH_REPO="understand-tech/ut-arbiter"

usage() {
    cat <<EOF
fetch-ut-arbiter.sh — downloads the ut-arbiter hold binary for every
architecture the package serves, and refuses one that does not match the
checksum release.env pins.

  ./packaging/fetch-ut-arbiter.sh

Writes \$OUT_DIR/ut-arbiter/ut-arbiter-linux-<arch> (default: dist/). This
binary is not built here: ai-in-a-box never builds an image or a binary it
does not own the source of — it pins what ut-arbiter's own pipeline
publishes, by checksum, the same way it pins an image by digest.

Needs the gh CLI, authenticated against a token that can read ut-arbiter
(a private repository).
EOF
}

pinned_value() {
    local key=$1 line
    # Not found is routine here (the key is not pinned yet) — pipefail would
    # otherwise turn grep's no-match into a pipeline failure, and set -e
    # would kill the script right here, before the caller's own "is this
    # empty" check ever ran.
    line=$(grep -m1 -E "^${key}=" "$RELEASE_ENV") || return 0
    line=${line#*=}
    printf '%s' "${line//\"/}"
}

fetch_one() {
    local arch=$1 tag=$2 want=$3 dir got
    dir="$OUT_DIR/ut-arbiter"
    install -d "$dir"
    gh release download "$tag" --repo "$GH_REPO" \
        --pattern "ut-arbiter-linux-${arch}" --clobber --dir "$dir" \
        || { echo "fetch-ut-arbiter.sh: could not download ut-arbiter-linux-${arch} from ${tag}" >&2; exit 1; }
    got=$(openssl dgst -sha256 -r "$dir/ut-arbiter-linux-${arch}" | cut -d' ' -f1)
    if [[ "$got" != "$want" ]]; then
        rm -f "$dir/ut-arbiter-linux-${arch}"
        echo "fetch-ut-arbiter.sh: ut-arbiter-linux-${arch} is ${got}, release.env pins ${want} — refusing it" >&2
        exit 1
    fi
    chmod 755 "$dir/ut-arbiter-linux-${arch}"
    printf '%s\n' "$dir/ut-arbiter-linux-${arch}"
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    command -v gh >/dev/null 2>&1 || { echo "gh is missing — it is what authenticates against the private repository" >&2; exit 1; }
    local tag arch want
    tag=$(pinned_value ARBITER_HOLD_RELEASE)
    [[ -n "$tag" ]] || { echo "fetch-ut-arbiter.sh: ARBITER_HOLD_RELEASE is not set in ${RELEASE_ENV}" >&2; exit 1; }
    for arch in $ARCHITECTURES; do
        want=$(pinned_value "ARBITER_HOLD_SHA256_$(printf '%s' "$arch" | tr '[:lower:]' '[:upper:]')")
        [[ -n "$want" ]] || { echo "fetch-ut-arbiter.sh: no pinned checksum for ${arch} in ${RELEASE_ENV}" >&2; exit 1; }
        fetch_one "$arch" "$tag" "$want"
    done
}

main "$@"
