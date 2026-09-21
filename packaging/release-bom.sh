#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_ENV="${RELEASE_ENV:-$REPO_ROOT/release.env}"
VERSION="${1:-}"

usage() {
    cat <<EOF
release-bom.sh — writes what a release is made of, as CycloneDX on stdout.

  ./packaging/release-bom.sh 2026.09.1 > dist/understandtech_2026.09.1.cdx.json

One component per image, named by the digest release.env pins it to. Reads
nothing but release.env: no registry, no network, no pull.

An image that names a tag has no place here — pin it first with pin-images.sh,
or this refuses rather than describe something that can move.
EOF
}

image_lines() {
    grep -E '^[A-Z_]*_IMAGE="[^"]+@sha256:[0-9a-f]+"' "$RELEASE_ENV" || true
}

loose_image_lines() {
    grep -E '^[A-Z_]*_IMAGE="[^"]+"' "$RELEASE_ENV" | grep -v '@sha256:' || true
}

reference_in() {
    local line=${1#*=\"}
    printf '%s' "${line%\"}"
}

# ghcr.io/understand-tech/ut-api:2.0-arm64@sha256:ab… splits three ways, and the
# repository keeps its registry host because that is what identifies the image.
repository_of() { local r=$1; r=${r%@*}; printf '%s' "${r%:*}"; }
tag_of()        { local r=$1; r=${r%@*}; printf '%s' "${r##*:}"; }
digest_of()     { local r=$1; printf '%s' "${r#*@}"; }
name_of()       { local r; r=$(repository_of "$1"); printf '%s' "${r##*/}"; }

component_for_image() {
    local reference=$1 repository tag digest name
    repository=$(repository_of "$reference")
    tag=$(tag_of "$reference")
    digest=$(digest_of "$reference")
    name=$(name_of "$reference")
    printf '    {\n'
    printf '      "type": "container",\n'
    printf '      "name": "%s",\n' "$name"
    printf '      "version": "%s",\n' "$tag"
    printf '      "purl": "pkg:oci/%s@%s?repository_url=%s&tag=%s",\n' \
        "$name" "$digest" "$repository" "$tag"
    printf '      "hashes": [{ "alg": "SHA-256", "content": "%s" }]\n' "${digest#sha256:}"
    printf '    }'
}

component_for_the_package() {
    printf '    {\n'
    printf '      "type": "application",\n'
    printf '      "name": "understandtech",\n'
    printf '      "version": "%s",\n' "$VERSION"
    printf '      "purl": "pkg:deb/understandtech@%s?arch=all"\n' "$VERSION"
    printf '    }'
}

# No timestamp and no serial number: both would change between two runs of the
# same release, and a bill of materials that cannot be regenerated identically
# is one nobody can check against the release it describes.
write_bom() {
    local line
    printf '{\n'
    printf '  "bomFormat": "CycloneDX",\n'
    printf '  "specVersion": "1.6",\n'
    printf '  "version": 1,\n'
    printf '  "metadata": {\n'
    printf '    "component": {\n'
    printf '      "type": "application",\n'
    printf '      "name": "understandtech-appliance",\n'
    printf '      "version": "%s"\n' "$VERSION"
    printf '    }\n'
    printf '  },\n'
    printf '  "components": [\n'
    component_for_the_package
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf ',\n'
        component_for_image "$(reference_in "$line")"
    done <<< "$(image_lines)"
    printf '\n  ]\n'
    printf '}\n'
}

refuse_images_that_can_move() {
    local loose
    loose=$(loose_image_lines)
    [[ -z "$loose" ]] && return 0
    echo "These name a tag, which a registry can repoint:" >&2
    printf '%s\n' "$loose" >&2
    echo "" >&2
    echo "Run packaging/pin-images.sh first. A bill of materials for something" >&2
    echo "that can change describes only the minute it was written." >&2
    return 1
}

main() {
    case "$VERSION" in
        ""|-h|--help) usage; [[ -z "$VERSION" ]] && exit 1 || exit 0 ;;
    esac
    refuse_images_that_can_move
    write_bom
}

main "$@"
