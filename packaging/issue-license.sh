#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    cat <<'EOF'
issue-license.sh — issues the license key a customer types into ut-install.

  ./packaging/issue-license.sh --customer "Acme" --expires 2027-10-31 \
      --token-file acme-registry.token --signing-key license-signing.pem

  --customer NAME        who the license is issued to
  --expires YYYY-MM-DD   last day it is valid, in UTC
  --token-file PATH      the customer's own registry token
  --signing-key PATH     the private half of the license key
  --registry-user NAME   registry account the token belongs to (default dgx-access)
  --rights LIST          what the license covers (default platform)

Prints the key, one line, on stdout. The signing key never leaves the machine
that issues licenses: it is not in this repository, and not in CI.
EOF
}

fail() { printf '[fail] %s\n' "$*" >&2; exit 1; }

customer="" expires="" token_file="" signing_key="" registry_user="dgx-access" rights="platform"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --customer)      customer=${2:-};      shift 2 ;;
        --expires)       expires=${2:-};       shift 2 ;;
        --token-file)    token_file=${2:-};    shift 2 ;;
        --signing-key)   signing_key=${2:-};   shift 2 ;;
        --registry-user) registry_user=${2:-}; shift 2 ;;
        --rights)        rights=${2:-};        shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; exit 1 ;;
    esac
done

[[ "$customer" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]] \
    || fail "--customer is required: letters, digits, spaces, dots, dashes"
[[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || fail "--expires is required, as YYYY-MM-DD: a license that never ends is not one we issue"
[[ "$expires" > "$(date -u +%F)" ]] || fail "--expires ${expires} is not in the future"
[[ "$registry_user" =~ ^[A-Za-z0-9._-]+$ ]] || fail "--registry-user is not a registry account name"
[[ "$rights" =~ ^[a-z0-9,_-]+$ ]] || fail "--rights is a comma-separated list of lowercase names"
[[ -s "$token_file" ]] || fail "--token-file is required and must not be empty"
[[ -f "$signing_key" ]] || fail "--signing-key is required"

token=$(tr -d '\r\n' < "$token_file")
[[ "$token" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "the token in ${token_file} is not a single registry token"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

printf 'version=1\ncustomer=%s\nissued=%s\nexpires=%s\nrights=%s\nregistry_user=%s\nregistry_token=%s\n' \
    "$customer" "$(date -u +%F)" "$expires" "$rights" "$registry_user" "$token" > "$work/payload"
openssl dgst -sha256 -sign "$signing_key" -out "$work/signature" "$work/payload" 2>/dev/null \
    || fail "${signing_key} cannot sign: not an EC private key, or not readable"

printf 'UT1.%s.%s\n' "$(openssl base64 -A < "$work/payload")" "$(openssl base64 -A < "$work/signature")"
