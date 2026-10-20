#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ENV="${RELEASE_ENV:-$SCRIPT_DIR/../release.env}"
GITHUB_API="${UT_GITHUB_API:-https://api.github.com}"
GHCR="${UT_GHCR:-https://ghcr.io}"
REGISTRY_URL="${UT_REGISTRY_URL:-}"
KEYGEN_API="${UT_KEYGEN_API:-https://api.keygen.sh/v1/accounts/cdfe8998-3b6e-4f86-8f9f-c51a7cb642e0}"

usage() {
    cat <<'EOF'
issue-license.sh — issues, in Keygen, the license a customer gives ut-install.

  ./packaging/issue-license.sh --customer acme --machine acme-gb10 --expires 2027-10-31 \
      --token-file acme-registry.token --keygen-token-file keygen-issuer.token

  --customer NAME          the customer's short name in the portal, such as acme,
                           or understand-tech for our own machines
  --machine NAME           the name of the machine in the catalog
  --expires YYYY-MM-DD     last day it is valid, in UTC
  --token-file PATH        the customer's own registry token
  --keygen-token-file PATH a Keygen token that can create the product's licenses
  --policy NAME            the Keygen policy (default "AI in a Box, one machine, one year")
  --registry HOST          registry the customer pulls from (default ghcr.io)
  --registry-user NAME     registry account the token belongs to (default dgx-access)
  --ledger PATH            where issued licenses are written down (default: beside
                           the Keygen token, licenses-issued.tsv)

Before issuing, it asks GitHub about the token, and refuses one that carries more
than read:packages, never expires, ends before the license, or cannot pull every
image of release.env. For any other registry, the account has to pull every image
of release.env from it, ours and the third-party ones alike, under the names
ut-install will ask for. It then creates the license in Keygen, with the customer,
the machine and the registry access in its metadata, writes it down in the ledger
— customer, machine, dates, Keygen's id and the token's fingerprint, never the
token — and prints the license key, one line, on stdout.
EOF
}

fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }

customer="" machine="" expires="" token_file="" keygen_token_file="" policy_name="AI in a Box, one machine, one year"
registry="ghcr.io" registry_user="dgx-access" ledger=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --customer)          customer=${2:-};          shift 2 ;;
        --machine)           machine=${2:-};           shift 2 ;;
        --expires)           expires=${2:-};           shift 2 ;;
        --token-file)        token_file=${2:-};        shift 2 ;;
        --keygen-token-file) keygen_token_file=${2:-}; shift 2 ;;
        --policy)            policy_name=${2:-};       shift 2 ;;
        --registry)          registry=${2:-};          shift 2 ;;
        --registry-user)     registry_user=${2:-};     shift 2 ;;
        --ledger)            ledger=${2:-};            shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   usage >&2; exit 1 ;;
    esac
done

[[ "$customer" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "--customer is required: the customer's short name in the portal, lowercase letters, digits and dashes"
[[ "$machine" =~ ^[a-z0-9][a-z0-9-]*$ ]] \
    || fail "--machine is required: the machine's name in the catalog, lowercase letters, digits and dashes"
[[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || fail "--expires is required, as YYYY-MM-DD: a license that never ends is not one we issue"
[[ "$expires" > "$(date -u +%F)" ]] || fail "--expires ${expires} is not in the future"
[[ "$registry" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]+)?$ ]] || fail "--registry is not a registry host"
[[ "$registry_user" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--registry-user is not a registry account name"
[[ -s "$token_file" ]] || fail "--token-file is required and must not be empty"
[[ -s "$keygen_token_file" ]] || fail "--keygen-token-file is required and must not be empty"
command -v jq >/dev/null 2>&1 || fail "jq is required"

token=$(tr -d '\r\n' < "$token_file")
[[ "$token" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "the token in ${token_file} is not a single registry token"
keygen_token=$(tr -d ' \t\r\n' < "$keygen_token_file")
[[ "$keygen_token" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "${keygen_token_file} does not hold a single Keygen token"
[[ -f "$RELEASE_ENV" ]] || fail "No release.env at ${RELEASE_ENV} to check the token against"
ledger=${ledger:-"$(dirname "$keygen_token_file")/licenses-issued.tsv"}

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

# The Keygen token reaches curl through a file descriptor, leaving stdin to the body.
keygen() {
    local method=$1 path=$2
    shift 2
    curl -sS --max-time 15 -X "$method" "${KEYGEN_API}${path}" \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$keygen_token") \
        -H 'Accept: application/vnd.api+json' -H 'Content-Type: application/vnd.api+json' \
        -H 'Keygen-Version: 1.8' "$@"
}

policy_id() {
    keygen GET '/policies?limit=100' \
        | jq -r --arg name "$policy_name" '[.data[]? | select(.attributes.name == $name) | .id][0] // empty'
}

# Keygen writes metadata keys in lower camel case, and ut-license reads them so.
license_request() {
    local policy=$1
    printf '%s' "$token" | jq -Rc --arg customer "$customer" --arg machine "$machine" --arg expires "$expires" \
        --arg registry "$registry" --arg user "$registry_user" --arg policy "$policy" '
        {data: {type: "licenses",
          attributes: {name: "\($customer) \($machine)", expiry: "\($expires)T23:59:59.000Z",
            metadata: {customer: $customer, machine: $machine, registry: $registry,
                       registryUser: $user, registryToken: .}},
          relationships: {policy: {data: {type: "policies", id: $policy}}}}}'
}

issued=""
create_the_license() {
    local policy answer
    policy=$(policy_id) || fail "Keygen could not be reached to find the policy; nothing was issued"
    [[ -n "$policy" ]] || fail "Keygen has no policy named '${policy_name}'; nothing was issued"
    answer=$(license_request "$policy" | keygen POST /licenses --data-binary @-) \
        || fail "Keygen could not be reached to create the license; nothing was issued"
    issued=$(jq -c '{id: .data.id, key: .data.attributes.key} | select(.id and .key)' <<< "$answer" 2>/dev/null) \
        || issued=""
    [[ -n "$issued" ]] \
        || fail "Keygen refused the license: $(jq -r '[.errors[]? | .detail // .title] | join("; ")' <<< "$answer" 2>/dev/null)"
}

write_it_down() {
    local fingerprint
    fingerprint=$(printf '%s' "$token" | openssl dgst -sha256 -r | cut -c1-16)
    [[ -s "$ledger" ]] \
        || printf 'issued\tcustomer\tmachine\texpires\tkeygen_license\tregistry_user\ttoken_sha256\ttoken_ends\n' > "$ledger"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%F)" "$customer" "$machine" "$expires" \
        "$(jq -r .id <<< "$issued")" "$registry_user" "$fingerprint" "$token_ends" >> "$ledger"
}

if [[ "$registry" == "ghcr.io" ]]; then
    check_the_token_with_github
    check_the_token_pulls_the_release
else
    token_ends="never"
    check_the_account_pulls_the_release_from "${REGISTRY_URL:-https://${registry}}"
fi

create_the_license
write_it_down || fail "the ledger ${ledger} cannot be written; the license $(jq -r .id <<< "$issued") is in Keygen, write it down by hand"
jq -r .key <<< "$issued"
