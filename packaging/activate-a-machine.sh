#!/usr/bin/env bash

set -Eeuo pipefail

KEYGEN_API="${UT_KEYGEN_API:-https://api.keygen.sh/v1/accounts/cdfe8998-3b6e-4f86-8f9f-c51a7cb642e0}"
MACHINE_FILE_SECONDS=31556952

usage() {
    cat <<'EOF'
activate-a-machine.sh — activates, in Keygen, a machine that cannot reach it, from
the request its ut-install wrote, and writes the license file to send back.

  ./packaging/activate-a-machine.sh --customer acme --machine acme-gb10 \
      --request license-request.json --keygen-token-file keygen-issuer.token

  --customer NAME          the customer's short name, as the license names it
  --machine NAME           the machine's name, as the license names it
  --request PATH           /etc/understandtech/license-request.json, from the box
  --keygen-token-file PATH a Keygen token that can activate the product's machines
  --out PATH               where the license file goes (default: <machine>.lic)

The request holds the machine's fingerprint and name, never the license key: the
license is found by its customer and machine. The license file is valid for a
year, on that machine only. On the box:

  sudo ut-install --machine-file <machine>.lic --skip-pull
EOF
}

fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }

customer="" machine="" request="" keygen_token_file="" out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --customer)          customer=${2:-};          shift 2 ;;
        --machine)           machine=${2:-};           shift 2 ;;
        --request)           request=${2:-};           shift 2 ;;
        --keygen-token-file) keygen_token_file=${2:-}; shift 2 ;;
        --out)               out=${2:-};               shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   usage >&2; exit 1 ;;
    esac
done

[[ "$customer" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "--customer is required: the customer's short name"
[[ "$machine" =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "--machine is required: the machine's name in the catalog"
[[ -r "$request" ]] || fail "--request is required: the license-request.json the box wrote"
[[ -s "$keygen_token_file" ]] || fail "--keygen-token-file is required and must not be empty"
command -v jq >/dev/null 2>&1 || fail "jq is required"
out=${out:-"${machine}.lic"}

fingerprint=$(jq -r 'select(.v == 1) | .fingerprint // empty' "$request" 2>/dev/null) || fingerprint=""
[[ "$fingerprint" =~ ^[0-9a-f]{64}$ ]] || fail "${request} is not a license request ut-install wrote"
name=$(jq -r '.name // "" | .[0:255]' "$request")
keygen_token=$(tr -d ' \t\r\n' < "$keygen_token_file")
[[ "$keygen_token" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "${keygen_token_file} does not hold a single Keygen token"

# The Keygen token reaches curl through a file descriptor, leaving stdin to the body.
keygen() {
    local method=$1 path=$2
    shift 2
    curl -sS --max-time 20 -X "$method" "${KEYGEN_API}${path}" \
        -K <(printf 'header = "Authorization: Bearer %s"\n' "$keygen_token") \
        -H 'Accept: application/vnd.api+json' -H 'Content-Type: application/vnd.api+json' \
        -H 'Keygen-Version: 1.8' "$@"
}

errors_of() { jq -r '[.errors[]? | .detail // .title // .code] | join("; ")' <<< "$1" 2>/dev/null; }

licenses=$(keygen GET "/licenses?metadata%5Bcustomer%5D=${customer}&metadata%5Bmachine%5D=${machine}&limit=2") \
    || fail "Keygen could not be reached; nothing was activated"
license=$(jq -r 'if (.data | length) == 1 then .data[0].id else empty end' <<< "$licenses" 2>/dev/null) || license=""
[[ -n "$license" ]] \
    || fail "Keygen holds $(jq -r '.data | length' <<< "$licenses" 2>/dev/null || echo no) license for ${customer} ${machine}, not one: $(errors_of "$licenses")"

activation=$(jq -nc --arg fingerprint "$fingerprint" --arg name "$name" --arg license "$license" \
    '{data: {type: "machines", attributes: {fingerprint: $fingerprint, name: $name, platform: "linux"},
      relationships: {license: {data: {type: "licenses", id: $license}}}}}' \
    | keygen POST /machines --data-binary @-) || fail "Keygen could not be reached; nothing was activated"
case "$(jq -r '.errors[0].code // empty' <<< "$activation" 2>/dev/null)" in
    "")
        machine_id=$(jq -r '.data.id // empty' <<< "$activation") ;;
    FINGERPRINT_TAKEN)
        machine_id=$(keygen GET "/machines?license=${license}&fingerprint=${fingerprint}&limit=1" \
            | jq -r '.data[0].id // empty' 2>/dev/null) || machine_id="" ;;
    MACHINE_LIMIT_EXCEEDED)
        fail "This license is already activated on another machine; release that one in Keygen first" ;;
    *)
        fail "Keygen refused to activate the machine: $(errors_of "$activation")" ;;
esac
[[ -n "$machine_id" ]] || fail "Keygen did not say which machine it activated"

certificate=$(keygen POST "/machines/${machine_id}/actions/check-out?include=license&ttl=${MACHINE_FILE_SECONDS}" \
    | jq -r '.data.attributes.certificate // empty' 2>/dev/null) || certificate=""
[[ -n "$certificate" ]] || fail "Keygen did not hand over the license file of ${machine}"
(umask 077 && printf '%s\n' "$certificate" > "$out")
printf 'License file of %s %s written to %s. Send it to the customer; on the box:\n' "$customer" "$machine" "$out"
printf '  sudo ut-install --machine-file %s --skip-pull\n' "$(basename "$out")"
