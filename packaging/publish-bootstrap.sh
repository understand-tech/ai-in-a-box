#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://get.understand.tech}"
BOOTSTRAP_FILES=(ut-get release.pub)
KEPT_BY_CACHES="public, max-age=31536000, immutable"

usage() {
    cat <<EOF
publish-bootstrap.sh — publishes what a machine downloads before it has shown a license.

  BOOTSTRAP_BUCKET=... ./packaging/publish-bootstrap.sh VERSION

Puts ut-get and release.pub from \$OUT_DIR (default: dist/) under VERSION/ in the
bucket that ${BOOTSTRAP_URL} serves. A published file is never replaced: the
same file is left as it is, another one stops the publication.

Needs the aws CLI, signed in, and curl.
EOF
}

die() { printf 'publish-bootstrap: %s\n' "$*" >&2; exit 1; }

is_a_release_version() { [[ "$1" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]+(-rc[0-9]+)?$ ]]; }

is_published_as() {
    local file=$1 url=$2 published same=0
    published=$(mktemp "${TMPDIR:-/tmp}/publish-bootstrap.XXXXXX")
    if ! curl --fail --silent --show-error --max-time 60 --retry 3 --output "$published" "$url"; then
        rm -f "$published"
        die "$url is already published but could not be read back to compare it with $file"
    fi
    cmp -s "$file" "$published" || same=1
    rm -f "$published"
    return "$same"
}

publish_one() {
    local version=$1 name=$2
    local file="$OUT_DIR/$name" key="$version/$name" refusal
    [[ -f "$file" ]] || die "$file is missing — build the release first"

    if refusal=$(aws s3api put-object --bucket "$BOOTSTRAP_BUCKET" --key "$key" --body "$file" \
            --if-none-match '*' --content-type text/plain --cache-control "$KEPT_BY_CACHES" 2>&1 >/dev/null); then
        printf 'published %s/%s\n' "$BOOTSTRAP_URL" "$key"
        return 0
    fi

    [[ "$refusal" == *PreconditionFailed* ]] || die "could not publish $key: $refusal"
    is_published_as "$file" "$BOOTSTRAP_URL/$key" \
        || die "$key is already published and differs from $file. A published file is never replaced: publish under the next version"
    printf 'already published %s/%s\n' "$BOOTSTRAP_URL" "$key"
}

main() {
    local version=${1:-} name
    case "$version" in
        -h|--help) usage; exit 0 ;;
        "") usage >&2; exit 2 ;;
    esac
    is_a_release_version "$version" || die "$version is not a release version"
    [[ -n "${BOOTSTRAP_BUCKET:-}" ]] || die "BOOTSTRAP_BUCKET is not set"

    for name in "${BOOTSTRAP_FILES[@]}"; do
        publish_one "$version" "$name"
    done
}

main "$@"
