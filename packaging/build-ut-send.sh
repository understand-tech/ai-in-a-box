#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
ARCHITECTURES="arm64 amd64"
TOOLS="ut-send ut-setup"

usage() {
    cat <<EOF
build-ut-send.sh — compiles the Go tools, ut-send and ut-setup, for every
architecture the package serves.

  ./packaging/build-ut-send.sh

Writes \$OUT_DIR/<tool>/<tool>-linux-<arch> (default: dist/). Needs the Go
version go.mod names, or a container:

  docker run --rm -v "\$PWD":/src -w /src golang:<version> ./packaging/build-ut-send.sh
EOF
}

# The package is rebuilt and compared with the one that was signed: nothing
# machine- or time-dependent may reach the binary.
build_for() {
    local tool=$1 arch=$2
    (cd "$REPO_ROOT" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
        go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" \
            -o "$OUT_DIR/$tool/$tool-linux-$arch" "./cmd/$tool")
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    command -v go >/dev/null 2>&1 || { echo "go is missing — see --help for the container form" >&2; exit 1; }
    local tool arch
    for tool in $TOOLS; do
        install -d "$OUT_DIR/$tool"
        for arch in $ARCHITECTURES; do
            build_for "$tool" "$arch"
            printf '%s\n' "$OUT_DIR/$tool/$tool-linux-$arch"
        done
    done
}

main "$@"
