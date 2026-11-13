#!/usr/bin/env bash
# Every image release.env takes from the new stack's shared image workflow must
# carry the organisation's signature, its provenance and its SBOM, verified
# against images.pub. Signatures are never written to a public transparency
# log, hence --insecure-ignore-tlog.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cosign="${COSIGN:-cosign}"
key="$root/images.pub"

signed_images=(
    ARBITER_IMAGE
)

release_image() {
    sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$root/release.env"
}

failed=0
for name in "${signed_images[@]}"; do
    image=$(release_image "$name")
    if [ -z "$image" ]; then
        echo "::error file=release.env::$name is listed as signed but release.env does not set it"
        failed=1
        continue
    fi
    reference="${image%%:*}@${image##*@}"
    if "$cosign" verify --key "$key" --insecure-ignore-tlog "$reference" > /dev/null \
        && "$cosign" verify-attestation --key "$key" --insecure-ignore-tlog --type slsaprovenance1 "$reference" > /dev/null \
        && "$cosign" verify-attestation --key "$key" --insecure-ignore-tlog --type cyclonedx "$reference" > /dev/null; then
        echo "$name: signed, with provenance and SBOM"
    else
        echo "::error file=release.env::$name ($reference) is not signed by the organisation key, or lacks its provenance or SBOM"
        failed=1
    fi
done
exit "$failed"
