#!/usr/bin/env bash

# Validates the mechanism intended to replace the shared JWT_SECRET between
# services and to authenticate one appliance to another: a local certificate
# authority issuing client certificates against single-use tokens, with Caddy
# requiring them.
#
# This is not a product capability yet — nothing in this repository runs a CA.
# It belongs here because the decision to build on it rests on these properties
# holding, and because it exercises upstream images that move on their own.
#
# Everything runs on a Docker network created with --internal, so a pass also
# means the mechanism needs no outbound access — the property an isolated
# deployment depends on.

set -uo pipefail

NET=mi-net
CA_PASS=machine-identity-test
STEP_IMAGE=smallstep/step-ca:latest
CADDY_IMAGE=$(grep -m1 -oE 'caddy:[0-9a-z.-]+' "$(dirname "${BASH_SOURCE[0]}")/../compose.yaml" || echo caddy:2-alpine)
CURL_IMAGE=curlimages/curl:latest

PASSED=0
FAILED=0

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; NC=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; NC=""
fi

property() {
    local description=$1; shift
    if "$@" >/dev/null 2>&1; then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        FAILED=$((FAILED + 1))
    fi
}

cleanup() {
    docker rm -f mi-ca mi-node >/dev/null 2>&1
    docker volume rm mi-ca-data mi-certs >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -f /tmp/mi-node.caddy
}
trap cleanup EXIT
cleanup

docker network create --internal "$NET" >/dev/null
docker volume create mi-certs >/dev/null

echo "images: $STEP_IMAGE, $CADDY_IMAGE"
echo

docker run -d --name mi-ca --network "$NET" -v mi-ca-data:/home/step \
    -e DOCKER_STEPCA_INIT_NAME=identity-test \
    -e DOCKER_STEPCA_INIT_DNS_NAMES=mi-ca \
    -e DOCKER_STEPCA_INIT_PASSWORD="$CA_PASS" \
    "$STEP_IMAGE" >/dev/null
sleep 15

FINGERPRINT=$(docker logs mi-ca 2>&1 | grep -oE '[a-f0-9]{64}' | head -1)
docker exec mi-ca sh -c "echo $CA_PASS > /tmp/p" >/dev/null 2>&1

# Certificates last two minutes so a full lifecycle — issue, renew, expire,
# recover — is observable in a few minutes instead of a day. The renewal
# machinery reacts to the fraction of lifetime elapsed, not to absolute time,
# so what holds at two minutes holds at any duration.
docker exec --user root mi-ca sh -c '
    cd /home/step/config
    jq "(.authority.provisioners[]) |= (.claims = {
          minTLSCertDuration: \"20s\",
          defaultTLSCertDuration: \"2m\",
          maxTLSCertDuration: \"5m\",
          allowRenewalAfterExpiry: true })" ca.json > ca.new && mv ca.new ca.json
' >/dev/null 2>&1
docker restart mi-ca >/dev/null; sleep 12

issue_token() {
    docker exec mi-ca step ca token "$1" --provisioner admin --password-file /tmp/p 2>/dev/null | tail -1
}

step_client() {
    docker run --rm --network "$NET" -v mi-certs:/certs --user root --entrypoint sh \
        -e FP="$FINGERPRINT" "${@:2}" "$STEP_IMAGE" -c "$1"
}

ca_is_reachable_without_outbound_access() {
    step_client 'step ca bootstrap --ca-url https://mi-ca:9000 --fingerprint "$FP" \
        && cp "$(step path)/certs/root_ca.crt" /certs/root.crt && chmod -R 777 /certs'
}

a_token_issues_a_certificate() {
    local token; token=$(issue_token mi-node)
    step_client 'step ca certificate mi-node /certs/node.crt /certs/node.key --token "$TOKEN" \
        && chmod 644 /certs/node.crt /certs/node.key' -e TOKEN="$token"
}

a_token_cannot_be_reused() {
    local token; token=$(issue_token replayed)
    step_client 'step ca certificate replayed /certs/r.crt /certs/r.key --token "$TOKEN"' -e TOKEN="$token" >/dev/null 2>&1
    ! step_client 'step ca certificate replayed /certs/r2.crt /certs/r2.key --token "$TOKEN"' -e TOKEN="$token"
}

renewal_needs_no_token() {
    step_client 'step ca renew --force --ca-url https://mi-ca:9000 --root /certs/root.crt \
        /certs/node.crt /certs/node.key'
}

a_client_certificate_is_required() {
    cat > /tmp/mi-node.caddy <<'EOF'
{
    auto_https disable_redirects
}
https://mi-node {
    tls /certs/node.crt /certs/node.key {
        client_auth {
            mode require_and_verify
            trust_pool file /certs/root.crt
        }
    }
    respond "served" 200
}
EOF
    docker rm -f mi-node >/dev/null 2>&1
    docker run -d --name mi-node --network "$NET" -v mi-certs:/certs:ro \
        -v /tmp/mi-node.caddy:/etc/caddy/Caddyfile:ro "$CADDY_IMAGE" >/dev/null 2>&1
    sleep 5

    docker run --rm --network "$NET" -v mi-certs:/certs:ro "$CURL_IMAGE" \
        -sf -m 8 --cacert /certs/root.crt https://mi-node/ >/dev/null 2>&1 && return 1

    docker run --rm --network "$NET" -v mi-certs:/certs:ro "$CURL_IMAGE" \
        -sf -m 8 --cacert /certs/root.crt --cert /certs/node.crt --key /certs/node.key \
        https://mi-node/ 2>/dev/null | grep -q served
}

a_node_recovers_after_the_ca_was_unreachable() {
    docker stop mi-ca >/dev/null 2>&1
    step_client 'step ca renew --force --ca-url https://mi-ca:9000 --root /certs/root.crt \
        /certs/node.crt /certs/node.key' >/dev/null 2>&1 && return 1

    docker start mi-ca >/dev/null 2>&1
    sleep 12
    renewal_needs_no_token
}

a_node_recovers_after_its_certificate_expired() {
    docker stop mi-ca >/dev/null 2>&1
    sleep 125
    docker start mi-ca >/dev/null 2>&1
    sleep 12
    renewal_needs_no_token
}

echo "Machine identity"
property "the authority serves with no outbound access at all" \
    ca_is_reachable_without_outbound_access
property "a single-use token issues a client certificate" \
    a_token_issues_a_certificate
property "replaying that token is refused" \
    a_token_cannot_be_reused
property "renewal needs no token, only the current certificate" \
    renewal_needs_no_token
property "a node without a client certificate is turned away" \
    a_client_certificate_is_required
property "a node recovers on its own once the authority is back" \
    a_node_recovers_after_the_ca_was_unreachable

echo
echo "Resilience ${DIM}(this one waits for a certificate to expire)${NC}"
property "a node recovers even after its certificate expired" \
    a_node_recovers_after_its_certificate_expired

echo
printf '%s%d verified%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d failing%s\n' "$RED" "$FAILED" "$NC"
    exit 1
fi
printf '\n'
