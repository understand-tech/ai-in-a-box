#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}/ut-send"
ARCHITECTURES="arm64 amd64"

usage() {
    cat <<EOF
build-ut-send.sh — compiles ut-send for every architecture the package serves.

  ./packaging/build-ut-send.sh

Writes \$OUT_DIR/ut-send/ut-send-linux-<arch> (default: dist/). Needs the Go
version go.mod names, or a container:

  docker run --rm -v "\$PWD":/src -w /src golang:<version> ./packaging/build-ut-send.sh
EOF
}

# The package is rebuilt and compared with the one that was signed: nothing
# machine- or time-dependent may reach the binary.
build_for() {
    local arch=$1
    (cd "$REPO_ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" \
            -o "$OUT_DIR/ut-send-linux-$arch" ./cmd/ut-send)
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    command -v go >/dev/null 2>&1 || { echo "go is missing — see --help for the container form" >&2; exit 1; }
    install -d "$OUT_DIR"
    local arch
    for arch in $ARCHITECTURES; do
        build_for "$arch"
        printf '%s\n' "$OUT_DIR/ut-send-linux-$arch"
    done
}

main "$@"
