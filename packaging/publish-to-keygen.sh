#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"
RELEASE_ENV="${RELEASE_ENV:-$REPO_ROOT/release.env}"
KEYGEN_API="${KEYGEN_API:-https://api.keygen.sh/v1/accounts/cdfe8998-3b6e-4f86-8f9f-c51a7cb642e0}"
KEYGEN_PRODUCT="856fd43a-b015-4e0f-9f45-f0c4353b69a8"
PACKAGE_PREFIX="${KEYGEN_PACKAGE_PREFIX:-}"
PRIVATE_IMAGES="${PRIVATE_IMAGES:-ghcr.io/understand-tech/}"
ARTIFACT_LIMIT_BYTES=$((5 * 1000 * 1000 * 1000))
UPLOAD_WAIT_SECONDS=1800
BOX_ARCHITECTURE="arm64"

usage() {
    cat <<EOF
publish-to-keygen.sh — publishes a release to Keygen, where a box downloads it
with its license key alone.

  KEYGEN_PRODUCT_TOKEN=... ./packaging/publish-to-keygen.sh VERSION

The package and its files (\$OUT_DIR, default dist/) go to the raw package
"understandtech"; every private image release.env pins goes to an OCI package
named after its repository, under the same version. A version already
published is left as it is, so a run that stopped half way is run again.

KEYGEN_PACKAGE_PREFIX publishes under other package names, to try this without
touching the ones boxes download from.

Needs curl, jq, and skopeo logged in to the registry of the private images.
EOF
}

die() { printf 'publish-to-keygen: %s\n' "$*" >&2; exit 1; }

keygen() {
    local method=$1 path=$2 answer
    shift 2
    answer=$(curl -sS -m 60 --retry 3 -X "$method" \
        -H "Authorization: Bearer $KEYGEN_PRODUCT_TOKEN" \
        -H 'Content-Type: application/vnd.api+json' -H 'Accept: application/vnd.api+json' \
        "$KEYGEN_API$path" "$@")
    if jq -e '.errors' >/dev/null 2>&1 <<< "$answer"; then
        die "$method $path: $(jq -r '[.errors[] | .title + ": " + (.detail // "")] | join("; ")' <<< "$answer")"
    fi
    printf '%s' "$answer"
}

channel_of() {
    case "$1" in
        *-rc*) echo rc ;;
        *-*)   echo dev ;;
        *)     echo stable ;;
    esac
}

package_id() {
    local key=$1 engine=$2 found
    found=$(curl -sS -m 60 --retry 3 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $KEYGEN_PRODUCT_TOKEN" -H 'Accept: application/vnd.api+json' \
        "$KEYGEN_API/packages/$key")
    if [[ "$found" == 200 ]]; then
        keygen GET "/packages/$key" | jq -r .data.id
        return
    fi
    keygen POST /packages -d "$(jq -n --arg key "$key" --arg engine "$engine" --arg product "$KEYGEN_PRODUCT" \
        '{data: {type: "packages", attributes: {name: $key, key: $key, engine: $engine},
                 relationships: {product: {data: {type: "products", id: $product}}}}}')" | jq -r .data.id
}

release_of() {
    local package=$1 version=$2
    keygen GET "/releases?package=$package&limit=100" \
        | jq -r --arg version "$version" '.data[] | select(.attributes.version == $version) | .id + " " + .attributes.status'
}

new_draft_release() {
    local package=$1 version=$2
    keygen POST /releases -d "$(jq -n --arg version "$version" --arg channel "$(channel_of "$version")" \
        --arg product "$KEYGEN_PRODUCT" --arg package "$package" \
        '{data: {type: "releases", attributes: {version: $version, channel: $channel},
                 relationships: {product: {data: {type: "products", id: $product}},
                                  package: {data: {type: "packages", id: $package}}}}}')" | jq -r .data.id
}

wait_until_uploaded() {
    local artifact=$1 name=$2 status waited=0
    while :; do
        status=$(keygen GET "/artifacts/$artifact" | jq -r .data.attributes.status)
        case "$status" in
            UPLOADED) return 0 ;;
            FAILED)   die "Keygen could not process $name" ;;
        esac
        (( waited < UPLOAD_WAIT_SECONDS )) || die "$name still $status after ${UPLOAD_WAIT_SECONDS}s"
        sleep 10
        waited=$((waited + 10))
    done
}

upload() {
    local release=$1 file=$2 name size location artifact
    name=$(basename "$file")
    size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file")
    (( size <= ARTIFACT_LIMIT_BYTES )) \
        || die "$name weighs $((size / 1000000)) MB, above Keygen's $((ARTIFACT_LIMIT_BYTES / 1000000)) MB per file"
    location=$(curl -sS -m 60 --retry 3 -X POST -D - -o "$file.keygen" \
        -H "Authorization: Bearer $KEYGEN_PRODUCT_TOKEN" \
        -H 'Content-Type: application/vnd.api+json' -H 'Accept: application/vnd.api+json' \
        "$KEYGEN_API/artifacts" \
        -d "$(jq -n --arg name "$name" --argjson size "$size" --arg type "${name##*.}" --arg release "$release" \
            '{data: {type: "artifacts", attributes: {filename: $name, filesize: $size, filetype: $type},
                     relationships: {release: {data: {type: "releases", id: $release}}}}}')" \
        | awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r')
    [[ -n "$location" ]] || die "Keygen refused $name: $(jq -c '.errors' "$file.keygen" 2>/dev/null)"
    artifact=$(jq -r .data.id "$file.keygen")
    rm -f "$file.keygen"
    curl -sS -m 3600 --retry 3 -X PUT --upload-file "$file" -o /dev/null "$location"
    wait_until_uploaded "$artifact" "$name"
}

publish() {
    local key=$1 engine=$2 version=$3 package existing release file
    shift 3
    package=$(package_id "$key" "$engine")
    existing=$(release_of "$package" "$version")
    case "$existing" in
        *" PUBLISHED") printf '%s %s: already published\n' "$key" "$version"; return 0 ;;
        ?*)            keygen DELETE "/releases/${existing%% *}" >/dev/null ;;
    esac
    release=$(new_draft_release "$package" "$version")
    for file in "$@"; do
        upload "$release" "$file"
    done
    keygen POST "/releases/$release/actions/publish" >/dev/null
    printf '%s %s: published\n' "$key" "$version"
}

private_images() {
    grep -oE '^[A-Z_]*_IMAGE="[^"]+"' "$RELEASE_ENV" | cut -d'"' -f2 | grep -F "$PRIVATE_IMAGES" | sort -u
}

package_key_of_image() {
    local repository=${1#"$PRIVATE_IMAGES"}
    repository=${repository%%@*}
    repository=${repository%%:*}
    printf '%s%s' "$PACKAGE_PREFIX" "${repository//\//-}"
}

by_digest_alone() {
    local name=${1%@*}
    printf '%s@%s' "${name%:*}" "${1##*@}"
}

blob_in() {
    cat "$1/blobs/${2%%:*}/${2#*:}"
}

# Keygen leaves an image layout PROCESSING for good when index.json names its
# manifest without the index media type and the platform, as skopeo writes it.
with_platform_in_index() {
    local layout=$1 manifest config
    manifest=$(jq -r '.manifests[0].digest' "$layout/index.json")
    config=$(blob_in "$layout" "$manifest" | jq -r .config.digest)
    jq --argjson platform "$(blob_in "$layout" "$config" | jq -c '{architecture, os}')" \
        '.mediaType = "application/vnd.oci.image.index.v1+json" | .manifests[0].platform = $platform' \
        "$layout/index.json" > "$layout/index.json.new"
    mv "$layout/index.json.new" "$layout/index.json"
}

image_layout_of() {
    local reference=$1 version=$2 into=$3 layout
    layout=$(mktemp -d)
    skopeo copy -q --retry-times 3 --preserve-digests --override-os linux --override-arch "$BOX_ARCHITECTURE" \
        "docker://$(by_digest_alone "$reference")" "oci:$layout:$version"
    with_platform_in_index "$layout"
    tar -C "$layout" -cf "$into" oci-layout index.json blobs
    rm -rf "$layout"
}

publish_images() {
    local version=$1 work=$2 reference key
    while IFS= read -r reference; do
        [[ -n "$reference" ]] || continue
        key=$(package_key_of_image "$reference")
        if [[ "$(release_of "$(package_id "$key" oci)" "$version")" == *" PUBLISHED" ]]; then
            printf '%s %s: already published\n' "$key" "$version"
            continue
        fi
        image_layout_of "$reference" "$version" "$work/$key-$version.tar"
        publish "$key" oci "$version" "$work/$key-$version.tar"
        rm -f "$work/$key-$version.tar"
    done <<< "$(private_images)"
}

publish_package() {
    local version=$1 file files=()
    for file in "understandtech_${version}_all.deb" "understandtech_${version}_all.deb.sig" \
                "understandtech_${version}.cdx.json" ut-verify ut-get release.pub SHA256SUMS; do
        [[ -f "$OUT_DIR/$file" ]] || die "$OUT_DIR/$file is missing"
        files+=("$OUT_DIR/$file")
    done
    publish "${PACKAGE_PREFIX}understandtech" raw "$version" "${files[@]}"
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
        "") usage >&2; exit 2 ;;
    esac
    [[ -n "${KEYGEN_PRODUCT_TOKEN:-}" ]] || die "KEYGEN_PRODUCT_TOKEN is not set"
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT
    publish_images "$1" "$WORK_DIR"
    publish_package "$1"
}

main "$@"
