#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ENV="${RELEASE_ENV:-$SCRIPT_DIR/../release.env}"
GITHUB_API="${UT_GITHUB_API:-https://api.github.com}"
GHCR="${UT_GHCR:-https://ghcr.io}"
REGISTRY_URL="${UT_REGISTRY_URL:-}"

usage() {
    cat <<'EOF'
issue-license.sh — issues the license key a customer types into ut-install.

  ./packaging/issue-license.sh --customer "Acme" --expires 2027-10-31 \
      --token-file acme-registry.token --signing-key license-signing.pem

  --customer NAME        who the license is issued to
  --expires YYYY-MM-DD   last day it is valid, in UTC
  --token-file PATH      the customer's own registry token
  --signing-key PATH     the private half of the license key
  --registry HOST        registry the customer pulls from (default ghcr.io)
  --registry-user NAME   registry account the token belongs to (default dgx-access)
  --rights LIST          what the license covers (default platform)
  --ledger PATH          where issued licenses are written down (default: beside
                         the signing key, licenses-issued.tsv)

Before signing, it asks GitHub about the token, and refuses one that carries more
than read:packages, never expires, ends before the license, or cannot pull every
image of release.env. For any other registry, the account has to pull every image
of release.env from it, ours and the third-party ones alike, under the names
ut-install will ask for. It then writes the license down in the ledger — customer,
dates, and the token's fingerprint, never the token — and prints the key, one
line, on stdout. The signing key never leaves the machine that issues licenses:
it is not in this repository, and not in CI.
EOF
}

fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }

customer="" expires="" token_file="" signing_key="" registry="ghcr.io" registry_user="dgx-access" rights="platform" ledger=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --customer)      customer=${2:-};      shift 2 ;;
        --expires)       expires=${2:-};       shift 2 ;;
        --token-file)    token_file=${2:-};    shift 2 ;;
        --signing-key)   signing_key=${2:-};   shift 2 ;;
        --registry)      registry=${2:-};      shift 2 ;;
        --registry-user) registry_user=${2:-}; shift 2 ;;
        --rights)        rights=${2:-};        shift 2 ;;
        --ledger)        ledger=${2:-};        shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; exit 1 ;;
    esac
done

[[ "$customer" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]] \
    || fail "--customer is required: letters, digits, spaces, dots, dashes"
[[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || fail "--expires is required, as YYYY-MM-DD: a license that never ends is not one we issue"
[[ "$expires" > "$(date -u +%F)" ]] || fail "--expires ${expires} is not in the future"
[[ "$registry" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?$ ]] || fail "--registry is not a registry host"
[[ "$registry_user" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--registry-user is not a registry account name"
[[ "$rights" =~ ^[a-z0-9,_-]+$ ]] || fail "--rights is a comma-separated list of lowercase names"
[[ -s "$token_file" ]] || fail "--token-file is required and must not be empty"
[[ -f "$signing_key" ]] || fail "--signing-key is required"

token=$(tr -d '\r\n' < "$token_file")
[[ "$token" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "the token in ${token_file} is not a single registry token"
[[ -f "$RELEASE_ENV" ]] || fail "No release.env at ${RELEASE_ENV} to check the token against"
ledger=${ledger:-"$(dirname "$signing_key")/licenses-issued.tsv"}

# curl reads its credentials from stdin, so the token never sits on a command line.
curl_with() {
    local credential=$1; shift
    printf '%s\n' "$credential" | curl -sS --max-time 15 -K - "$@"
}

header_of() {
    local headers=$1 name=$2
    grep -i "^${name}:" <<< "$headers" | head -1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//; s/ *$//'
}

token_ends=""
check_the_token_with_github() {
    local headers scopes
    headers=$(curl_with "header = \"Authorization: Bearer ${token}\"" -o /dev/null -D - \
        -w 'status=%{http_code}\n' "${GITHUB_API}/user") \
        || fail "GitHub could not be reached to check the token; nothing was issued"
    grep -q '^status=200$' <<< "$headers" || fail "GitHub refuses this token"
    scopes=$(header_of "$headers" x-oauth-scopes | tr -d ' ')
    [[ "$scopes" == "read:packages" ]] \
        || fail "the token carries '${scopes:-no scope}': issue one with read:packages and nothing else"
    token_ends=$(header_of "$headers" github-authentication-token-expiration | cut -c1-10)
    [[ "$token_ends" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
        || fail "the token never expires: give it an end no earlier than ${expires}"
    [[ "$token_ends" < "$expires" ]] \
        && fail "the token ends on ${token_ends}, before the license would (${expires})"
    return 0
}

check_the_token_pulls_the_release() {
    local reference repository object pull_token code unreadable=""
    while IFS= read -r reference; do
        repository=${reference#ghcr.io/}
        repository=${repository%@*}
        repository=${repository%:*}
        object=${reference##*@}
        [[ "$object" == "$reference" ]] && object=${reference##*:}
        pull_token=$(curl_with "user = \"${registry_user}:${token}\"" \
            "${GHCR}/token?scope=repository:${repository}:pull&service=ghcr.io" 2>/dev/null \
            | sed -n 's/.*"token" *: *"\([^"]*\)".*/\1/p')
        code=$(curl_with "header = \"Authorization: Bearer ${pull_token}\"" -o /dev/null -w '%{http_code}' -I \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
            "${GHCR}/v2/${repository}/manifests/${object}" 2>/dev/null) || code=""
        [[ "$code" == 200 ]] || unreadable="${unreadable} ${repository}"
    done < <(grep -oE '"ghcr\.io/understand-tech/[^"]+"' "$RELEASE_ENV" | tr -d '"')
    [[ -z "$unreadable" ]] || fail "the token cannot pull:${unreadable}"
}

# The same mapping as image_in_registry in ut-install: a capability holds them equal.
image_in_registry() {
    local reference=$1 first
    if [[ "$reference" == */* ]]; then
        first=${reference%%/*}
        case "$first" in
            *.*|*:*|localhost) reference=${reference#*/} ;;
        esac
    else
        reference="library/${reference}"
    fi
    printf '%s/%s' "$registry" "$reference"
}

check_the_account_pulls_the_release_from() {
    local base=$1 reference located repository object code unreadable=""
    while IFS= read -r reference; do
        located=$(image_in_registry "$reference")
        repository=${located#"$registry"/}
        repository=${repository%@*}
        repository=${repository%:*}
        object=${located##*@}
        [[ "$object" == "$located" ]] && object=${located##*:}
        code=$(curl_with "user = \"${registry_user}:${token}\"" -o /dev/null -w '%{http_code}' -I \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
            "${base}/v2/${repository}/manifests/${object}" 2>/dev/null) || code=""
        [[ "$code" == 200 ]] || unreadable="${unreadable} ${repository}"
    done < <(grep -oE '^[A-Z0-9_]+_IMAGE="[^"]+"' "$RELEASE_ENV" | cut -d'"' -f2)
    [[ -z "$unreadable" ]] || fail "the account cannot pull from ${registry}:${unreadable}"
}

write_it_down() {
    local fingerprint
    fingerprint=$(printf '%s' "$token" | openssl dgst -sha256 -r | cut -c1-16)
    [[ -s "$ledger" ]] || printf 'issued\tcustomer\texpires\trights\tregistry_user\ttoken_sha256\ttoken_ends\n' > "$ledger"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%F)" "$customer" "$expires" "$rights" \
        "$registry_user" "$fingerprint" "$token_ends" >> "$ledger"
}

if [[ "$registry" == "ghcr.io" ]]; then
    check_the_token_with_github
    check_the_token_pulls_the_release
else
    token_ends="never"
    check_the_account_pulls_the_release_from "${REGISTRY_URL:-https://${registry}}"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf 'version=1\ncustomer=%s\nissued=%s\nexpires=%s\nrights=%s\nregistry=%s\nregistry_user=%s\nregistry_token=%s\n' \
    "$customer" "$(date -u +%F)" "$expires" "$rights" "$registry" "$registry_user" "$token" > "$work/payload"
openssl dgst -sha256 -sign "$signing_key" -out "$work/signature" "$work/payload" 2>/dev/null \
    || fail "${signing_key} cannot sign: not an EC private key, or not readable"

printf 'UT1.%s.%s\n' "$(openssl base64 -A < "$work/payload")" "$(openssl base64 -A < "$work/signature")" > "$work/license"
write_it_down || fail "the ledger ${ledger} cannot be written; nothing was issued"
cat "$work/license"
