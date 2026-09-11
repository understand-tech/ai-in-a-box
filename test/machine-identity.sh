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

RUN=mi-$$
NET=$RUN-net
CA_NODE=$RUN-ca
NODE=$RUN-node
REVOKED=$RUN-revoked
CA_VOLUME=$RUN-ca-data
CERT_VOLUME=$RUN-certs
CA_URL=https://$CA_NODE:9000
CADDYFILE=$(mktemp)
CA_PASS=machine-identity-test
STEP_IMAGE=smallstep/step-ca:latest
CADDY_IMAGE=$(grep -m1 -oE 'caddy:[0-9a-z.-]+' "$(dirname "${BASH_SOURCE[0]}")/../compose.yaml" || echo caddy:2-alpine)
CURL_IMAGE=curlimages/curl:latest
RESTIC_IMAGE=$(grep -m1 -oE 'restic/restic:[0-9.]+' "$(dirname "${BASH_SOURCE[0]}")/../compose.yaml" || echo restic/restic:latest)
SPARE_CA=$RUN-spare-ca
SPARE_CERTS=$RUN-spare-certs
SPARE_WORK=$(mktemp -d)
SPARE_ROOT=$SPARE_WORK/ca

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
    docker rm -f "$CA_NODE" "$NODE" "$SPARE_CA" >/dev/null 2>&1
    docker volume rm "$CA_VOLUME" "$CERT_VOLUME" "$SPARE_CERTS" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    docker run --rm -v "$SPARE_WORK":/w alpine:3 sh -c 'rm -rf /w/..?* /w/.[!.]* /w/*' >/dev/null 2>&1
    rm -rf "$SPARE_WORK"
    rm -f "$CADDYFILE"
}
trap cleanup EXIT

docker network create --internal "$NET" >/dev/null
docker volume create "$CERT_VOLUME" >/dev/null

echo "images: $STEP_IMAGE, $CADDY_IMAGE"
echo

docker run -d --name "$CA_NODE" --network "$NET" -v "$CA_VOLUME":/home/step \
    -e DOCKER_STEPCA_INIT_NAME=identity-test \
    -e DOCKER_STEPCA_INIT_DNS_NAMES="$CA_NODE" \
    -e DOCKER_STEPCA_INIT_PASSWORD="$CA_PASS" \
    "$STEP_IMAGE" >/dev/null
sleep 15

FINGERPRINT=$(docker logs "$CA_NODE" 2>&1 | grep -oE '[a-f0-9]{64}' | head -1)
docker exec "$CA_NODE" sh -c "echo $CA_PASS > /tmp/p" >/dev/null 2>&1

# Certificates last two minutes so a full lifecycle — issue, renew, expire,
# recover — is observable in a few minutes instead of a day. The renewal
# machinery reacts to the fraction of lifetime elapsed, not to absolute time,
# so what holds at two minutes holds at any duration.
docker exec --user root "$CA_NODE" sh -c '
    cd /home/step/config
    jq "(.authority.provisioners[]) |= (.claims = {
          minTLSCertDuration: \"20s\",
          defaultTLSCertDuration: \"2m\",
          maxTLSCertDuration: \"5m\",
          allowRenewalAfterExpiry: true })" ca.json > ca.new && mv ca.new ca.json
' >/dev/null 2>&1
docker restart "$CA_NODE" >/dev/null; sleep 12

issue_token() {
    docker exec "$CA_NODE" step ca token "$1" --provisioner admin --password-file /tmp/p 2>/dev/null | tail -1
}

step_client() {
    docker run --rm --network "$NET" -v "$CERT_VOLUME":/certs --user root --entrypoint sh \
        -e FP="$FINGERPRINT" -e CA_URL="$CA_URL" -e NODE="$NODE" -e REVOKED="$REVOKED" "${@:2}" "$STEP_IMAGE" -c "$1"
}

ca_is_reachable_without_outbound_access() {
    step_client 'step ca bootstrap --ca-url "$CA_URL" --fingerprint "$FP" \
        && cp "$(step path)/certs/root_ca.crt" /certs/root.crt && chmod -R 777 /certs'
}

a_token_issues_a_certificate() {
    local token; token=$(issue_token "$NODE")
    step_client 'step ca certificate "$NODE" /certs/node.crt /certs/node.key --token "$TOKEN" \
        && chmod 644 /certs/node.crt /certs/node.key' -e TOKEN="$token"
}

a_token_cannot_be_reused() {
    local token; token=$(issue_token replayed)
    step_client 'step ca certificate replayed /certs/r.crt /certs/r.key --token "$TOKEN"' -e TOKEN="$token" >/dev/null 2>&1
    ! step_client 'step ca certificate replayed /certs/r2.crt /certs/r2.key --token "$TOKEN"' -e TOKEN="$token"
}

renewal_needs_no_token() {
    step_client 'step ca renew --force --ca-url "$CA_URL" --root /certs/root.crt \
        /certs/node.crt /certs/node.key'
}

a_client_certificate_is_required() {
    cat > "$CADDYFILE" <<EOF
{
    auto_https disable_redirects
}
https://$NODE {
    tls /certs/node.crt /certs/node.key {
        client_auth {
            mode require_and_verify
            trust_pool file /certs/root.crt
        }
    }
    respond "served" 200
}
EOF
    chmod 644 "$CADDYFILE"
    docker rm -f "$NODE" >/dev/null 2>&1
    docker run -d --name "$NODE" --network "$NET" -v "$CERT_VOLUME":/certs:ro \
        -v "$CADDYFILE":/etc/caddy/Caddyfile:ro "$CADDY_IMAGE" >/dev/null 2>&1
    sleep 5

    docker run --rm --network "$NET" -v "$CERT_VOLUME":/certs:ro "$CURL_IMAGE" \
        -sf -m 8 --cacert /certs/root.crt "https://$NODE/" >/dev/null 2>&1 && return 1

    docker run --rm --network "$NET" -v "$CERT_VOLUME":/certs:ro "$CURL_IMAGE" \
        -sf -m 8 --cacert /certs/root.crt --cert /certs/node.crt --key /certs/node.key \
        "https://$NODE/" 2>/dev/null | grep -q served
}

a_node_recovers_after_the_ca_was_unreachable() {
    docker stop "$CA_NODE" >/dev/null 2>&1
    step_client 'step ca renew --force --ca-url "$CA_URL" --root /certs/root.crt \
        /certs/node.crt /certs/node.key' >/dev/null 2>&1 && return 1

    docker start "$CA_NODE" >/dev/null 2>&1
    sleep 12
    renewal_needs_no_token
}

a_node_recovers_after_its_certificate_expired() {
    docker stop "$CA_NODE" >/dev/null 2>&1
    sleep 125
    docker start "$CA_NODE" >/dev/null 2>&1
    sleep 12
    renewal_needs_no_token
}

enrol_second_node() {
    local token; token=$(issue_token "$REVOKED")
    step_client 'step ca certificate "$REVOKED" /certs/revoked.crt /certs/revoked.key --token "$TOKEN" \
        && chmod 644 /certs/revoked.crt /certs/revoked.key' -e TOKEN="$token"
}

revoked_node_renews() {
    step_client 'step ca renew --force --ca-url "$CA_URL" --root /certs/root.crt \
        /certs/revoked.crt /certs/revoked.key'
}

a_revoked_node_cannot_renew() {
    enrol_second_node >/dev/null 2>&1 || return 1
    revoked_node_renews >/dev/null 2>&1 || return 1
    step_client 'step ca revoke --cert /certs/revoked.crt --key /certs/revoked.key \
        --ca-url "$CA_URL" --root /certs/root.crt' >/dev/null 2>&1 || return 1
    ! revoked_node_renews
}

a_revoked_node_cannot_renew_once_expired() {
    sleep 125
    ! revoked_node_renews
}

spare_authority_starts() {
    docker run -d --name "$SPARE_CA" --network "$NET" -v "$SPARE_ROOT":/home/step \
        -e DOCKER_STEPCA_INIT_NAME=restore-test \
        -e DOCKER_STEPCA_INIT_DNS_NAMES="$SPARE_CA" \
        -e DOCKER_STEPCA_INIT_PASSWORD="$CA_PASS" \
        "$STEP_IMAGE" >/dev/null 2>&1
    sleep 15
}

spare_client() {
    docker run --rm --network "$NET" -v "$SPARE_CERTS":/certs --user root --entrypoint sh \
        -e FP="$SPARE_FINGERPRINT" -e CA_URL="https://$SPARE_CA:9000" "${@:2}" "$STEP_IMAGE" -c "$1"
}

spare_node_renews() {
    spare_client 'step ca renew --force --ca-url "$CA_URL" --root /certs/root.crt \
        /certs/node.crt /certs/node.key'
}

restic_on_spare() {
    docker run --rm -v "$SPARE_WORK":/work \
        -e RESTIC_REPOSITORY=/work/backup -e RESTIC_PASSWORD="$CA_PASS" \
        "$RESTIC_IMAGE" "$@"
}

a_backed_up_root_survives_the_machine() {
    local token before after
    mkdir -p "$SPARE_ROOT" && chmod 777 "$SPARE_ROOT"
    docker volume create "$SPARE_CERTS" >/dev/null
    spare_authority_starts

    SPARE_FINGERPRINT=$(docker logs "$SPARE_CA" 2>&1 | grep -oE '[a-f0-9]{64}' | head -1)
    docker exec "$SPARE_CA" sh -c "echo $CA_PASS > /tmp/p" >/dev/null 2>&1
    spare_client 'step ca bootstrap --force --ca-url "$CA_URL" --fingerprint "$FP" \
        && cp "$(step path)/certs/root_ca.crt" /certs/root.crt && chmod -R 777 /certs' >/dev/null 2>&1
    token=$(docker exec "$SPARE_CA" step ca token node --provisioner admin --password-file /tmp/p 2>/dev/null | tail -1)
    spare_client 'step ca certificate node /certs/node.crt /certs/node.key --token "$TOKEN" \
        && chmod 644 /certs/node.crt /certs/node.key' -e TOKEN="$token" >/dev/null 2>&1
    spare_node_renews >/dev/null 2>&1 || return 1

    before=$(docker run --rm -v "$SPARE_ROOT":/ca:ro alpine:3 cksum /ca/certs/root_ca.crt | cut -d' ' -f1)

    restic_on_spare init >/dev/null 2>&1
    restic_on_spare backup /work/ca --quiet >/dev/null 2>&1 || return 1

    docker rm -f "$SPARE_CA" >/dev/null 2>&1
    docker run --rm -v "$SPARE_WORK":/w alpine:3 sh -c 'rm -rf /w/ca' >/dev/null 2>&1
    [[ -e "$SPARE_ROOT/config/ca.json" ]] && return 1

    restic_on_spare restore latest --target / --quiet >/dev/null 2>&1
    [[ -e "$SPARE_ROOT/config/ca.json" ]] || return 1

    spare_authority_starts
    after=$(docker run --rm -v "$SPARE_ROOT":/ca:ro alpine:3 cksum /ca/certs/root_ca.crt | cut -d' ' -f1)
    [[ "$before" == "$after" ]] || return 1

    spare_node_renews
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
echo "Revocation ${DIM}(what makes recovery-after-expiry safe to allow)${NC}"
property "a revoked node cannot renew" \
    a_revoked_node_cannot_renew
property "it still cannot once its certificate has expired" \
    a_revoked_node_cannot_renew_once_expired

echo
echo "Recovery ${DIM}(the only irreversible part of running an authority)${NC}"
property "a backed-up root survives losing the machine" \
    a_backed_up_root_survives_the_machine

echo
printf '%s%d verified%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d failing%s\n' "$RED" "$FAILED" "$NC"
    exit 1
fi
printf '\n'
