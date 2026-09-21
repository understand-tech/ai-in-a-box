#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"
DOMAIN="box.example.test"
NETWORK="ut-ingress-check"
CADDY_IMAGE="caddy:2-alpine"
PROBE_IMAGE="alpine:3"

# Every other suite stops before `docker compose up`, because the application
# images are private and weigh tens of gigabytes. The front door does not need
# them: caddy:2-alpine is public, and stubs answer for the eight upstreams. So
# the one surface a browser actually meets is the one that can be checked here.
cleanup() {
    docker rm -f ut-ingress-caddy ut-ingress-stub ut-ingress-probe >/dev/null 2>&1
    docker network rm "$NETWORK" >/dev/null 2>&1
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; NC=""
fi

PASSED=0
FAILED=0
FAILURES=()

surface() {
    local description=$1; shift
    [[ -n "${SURFACE_FILTER:-}" && "$description" != *"$SURFACE_FILTER"* ]] && return 0
    local output
    if output=$("$@" 2>&1); then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        printf '%s      %s%s\n' "$DIM" "${output//$'\n'/$'\n'      }" "$NC"
        FAILED=$((FAILED + 1))
        FAILURES+=("$description")
    fi
}

UPSTREAMS="frontend api api-customer app-llms admin-portal app-assistants app-builder app-builder-traefik"
SURFACES="${DOMAIN} llms.${DOMAIN} admin.${DOMAIN} assistants.${DOMAIN} builder.${DOMAIN} demo.apps.${DOMAIN}"

aliases_for() {
    local name
    for name in $1; do printf -- '--network-alias\n%s\n' "$name"; done
}

start_the_upstreams() {
    # One container answers for all eight names. It cannot tell them apart, and
    # that is the limit of this check: it proves every surface is served, not
    # that each reaches the service it should.
    # A site block on one line is not Caddyfile syntax: the closing brace has to
    # stand alone, and `caddy` exits 1 on the whole file rather than skip it.
    cat > "$WORK_DIR/stub.caddy" <<'STUB'
{
	admin off
	auto_https off
}
:80 {
	respond "stub 80 proto={http.request.header.X-Forwarded-Proto}" 200
}
:8501 {
	respond "stub 8501" 200
}
:8080 {
	respond "stub 8080" 200
}
:8001 {
	respond "stub 8001" 200
}
STUB
    local args=()
    while IFS= read -r line; do args+=("$line"); done < <(aliases_for "$UPSTREAMS")
    docker run -d --name ut-ingress-stub --network "$NETWORK" "${args[@]}" \
        -v "$WORK_DIR/stub.caddy":/etc/caddy/Caddyfile:ro \
        "$CADDY_IMAGE" >/dev/null
}

# An operator's certificate, made the way one is made: a private authority and
# one leaf covering the apex, the satellites and the generated applications. A
# config file rather than -addext, because LibreSSL is what answers to `openssl`
# on a developer's machine and does not know that option.
write_an_operator_certificate() {
    local dir="$WORK_DIR/certs"
    mkdir -p "$dir"
    cat > "$dir/leaf.cnf" <<EOF
[req]
distinguished_name = dn
prompt             = no
[dn]
CN = ${DOMAIN}
[leaf]
basicConstraints = critical,CA:FALSE
keyUsage         = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName   = DNS:${DOMAIN},DNS:*.${DOMAIN},DNS:*.apps.${DOMAIN}
EOF
    printf '[req]\ndistinguished_name = dn\nprompt = no\nx509_extensions = ca\n[dn]\nCN = Operator Test CA\n[ca]\nbasicConstraints = critical,CA:TRUE\nkeyUsage = critical,keyCertSign\n' > "$dir/ca.cnf"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -noenc \
        -config "$dir/ca.cnf" -keyout "$dir/ca.key" -out "$dir/ca.crt" 2>/dev/null
    openssl req -newkey rsa:2048 -noenc -config "$dir/leaf.cnf" \
        -keyout "$dir/privkey.pem" -out "$dir/leaf.csr" 2>/dev/null
    openssl x509 -req -in "$dir/leaf.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
        -CAcreateserial -days 30 -sha256 -extfile "$dir/leaf.cnf" -extensions leaf \
        -out "$dir/leaf.crt" 2>/dev/null
    cat "$dir/leaf.crt" "$dir/ca.crt" > "$dir/fullchain.pem"
    chmod 644 "$dir/fullchain.pem"; chmod 600 "$dir/privkey.pem"
}

# bash 3.2 treats "${empty[@]}" as an unbound variable under set -u, so the
# expansion has to be guarded rather than quoted.
start_the_front_door() {
    local mode=${1:-internal} args=() extra=()
    while IFS= read -r line; do args+=("$line"); done < <(aliases_for "$SURFACES")

    case "$mode" in
        custom)
            write_an_operator_certificate
            extra=(-v "$WORK_DIR/certs":/etc/caddy/certs:ro) ;;
        edge)
            # The mode's whole point: Caddy holds no certificate and serves
            # plain HTTP, so a site address left on https:// would listen on
            # 443 with nothing to present. UT_CADDY_SCHEME prefixes it.
            extra=(-e UT_CADDY_SCHEME=http -e UT_TRUSTED_PROXIES=private_ranges) ;;
    esac

    docker run -d --name ut-ingress-caddy --network "$NETWORK" "${args[@]}" \
        -e UT_DOMAIN="$DOMAIN" ${extra[@]+"${extra[@]}"} \
        -v "$REPO_ROOT/Caddyfile":/etc/caddy/Caddyfile:ro \
        -v "$REPO_ROOT/caddy/ingress-${mode}.caddy":/etc/caddy/ingress.caddy:ro \
        -v "$REPO_ROOT/caddy/no-internal-surface.caddy":/etc/caddy/surface.caddy:ro \
        "$CADDY_IMAGE" >/dev/null
}

restart_the_front_door_in() {
    docker rm -f ut-ingress-caddy >/dev/null 2>&1
    start_the_front_door "$1"
}

start_the_prober() {
    docker run -d --name ut-ingress-probe --network "$NETWORK" "$PROBE_IMAGE" \
        sh -c 'apk add --no-cache curl >/dev/null 2>&1; sleep 600' >/dev/null
    local waited=0
    until docker exec ut-ingress-probe sh -c 'command -v curl' >/dev/null 2>&1; do
        sleep 1; waited=$((waited + 1))
        (( waited < 60 )) || { echo "curl never installed in the prober" >&2; return 1; }
    done
}

SCHEME="https"

status_of() {
    local host=$1 path=${2:-/}
    docker exec ut-ingress-probe curl -sk -o /dev/null -w '%{http_code}' \
        --max-time 10 "${SCHEME}://${host}${path}" 2>/dev/null
}

body_of() {
    local host=$1 path=${2:-/}; shift 2 || true
    docker exec ut-ingress-probe curl -sk --max-time 10 "$@" \
        "${SCHEME}://${host}${path}" 2>/dev/null
}

wait_for_the_front_door() {
    local waited=0 code
    while (( waited < 90 )); do
        code=$(status_of "$DOMAIN")
        [[ "$code" =~ ^[23] ]] && return 0
        sleep 2; waited=$((waited + 2))
    done
    echo "the apex never answered over ${SCHEME} — last code ${code:-none}"
    docker logs --tail 15 ut-ingress-caddy 2>&1
    return 1
}

# A surface that answers 404 is served by Caddy and missing upstream; one that
# answers nothing at all is a site block Caddy never created, which is the
# failure this suite exists to catch.
a_surface_answers() {
    local host=$1 code
    code=$(status_of "$host")
    [[ "$code" =~ ^[23] ]] && return 0
    echo "https://${host}/ answered ${code:-nothing}"
    return 1
}

a_path_reaches_its_upstream() {
    local host=$1 path=$2 expected=$3 body
    body=$(body_of "$host" "$path")
    [[ "$body" == "$expected" ]] && return 0
    echo "https://${host}${path} returned '${body}', expected '${expected}'"
    return 1
}

# An identity provider only ever sends people back to the URI it was given, so a
# documented URI that reaches the frontend instead of the API makes sign-on fail
# for everyone who followed the documentation — with nothing in the product
# saying which URI it will really ask for.
documented_oidc_path() {
    grep -m1 'Redirect URI' "$REPO_ROOT/docs/first-run-configuration.md" 2>/dev/null \
        | grep -oE '<your-domain>[^`]*' | sed 's|<your-domain>||'
}

the_documented_callback_reaches_the_api() {
    local path body
    path=$(documented_oidc_path)
    if [[ -z "$path" ]]; then
        echo "no redirect URI found in docs/first-run-configuration.md"
        return 1
    fi
    body=$(body_of "$DOMAIN" "$path")
    [[ "$body" == "stub 8501" ]] && return 0
    echo "the documented URI ${path} is served by '${body:-nothing}', not the platform API"
    echo "an identity provider sent there would never reach the callback"
    return 1
}

# A wildcard covering the name is as good as the name: the generated
# applications are served by one certificate for *.apps.<domain>, and asking for
# the literal host would fail on a certificate that is exactly right.
the_certificate_covers_the_name() {
    local host=$1 names wildcard
    wildcard="*.${host#*.}"
    names=$(docker exec ut-ingress-probe sh -c \
        "echo | openssl s_client -connect ${host}:443 -servername ${host} 2>/dev/null \
         | openssl x509 -noout -ext subjectAltName 2>/dev/null" )
    grep -qF "DNS:${host}" <<< "$names" && return 0
    grep -qF "DNS:${wildcard}" <<< "$names" && return 0
    echo "the certificate served for ${host} names neither it nor ${wildcard}: ${names:-nothing read}"
    return 1
}

# A mode that quietly falls back to the appliance's own authority looks exactly
# like one that works: the browser is happy, and the operator's certificate —
# the whole reason their fleet needs no import — is never presented.
the_supplied_certificate_is_the_one_served() {
    local served supplied
    served=$(docker exec ut-ingress-probe sh -c \
        "echo | openssl s_client -connect ${DOMAIN}:443 -servername ${DOMAIN} 2>/dev/null \
         | openssl x509 -noout -fingerprint -sha256" 2>/dev/null | tr -d ' ')
    supplied=$(openssl x509 -in "$WORK_DIR/certs/leaf.crt" -noout -fingerprint -sha256 2>/dev/null | tr -d ' ')
    [[ -n "$served" && "$served" == "$supplied" ]] && return 0
    echo "served ${served:-nothing}"
    echo "supplied ${supplied:-nothing}"
    return 1
}

# The trap the ingress fragment warns about in prose and nothing checked: on
# https Caddy listens on 443 expecting to hold the certificate itself, and the
# plain HTTP a load balancer sends to 80 reaches nobody.
caddy_holds_no_certificate_in_edge_mode() {
    local code
    code=$(docker exec ut-ingress-probe curl -s -o /dev/null -w '%{http_code}' \
        --max-time 5 "https://${DOMAIN}/" 2>/dev/null)
    [[ -z "$code" || "$code" == "000" ]] && return 0
    echo "443 answered ${code} — Caddy is holding a certificate it should not have"
    return 1
}

# Without trusted_proxies the applications see X-Forwarded-Proto: http and build
# absolute URLs on http, which breaks the OIDC round trip — a failure that looks
# like an identity provider problem and is not one.
a_trusted_proxy_is_believed_about_the_scheme() {
    local body
    body=$(body_of "$DOMAIN" / -H 'X-Forwarded-Proto: https')
    [[ "$body" == "stub 80 proto=https" ]] && return 0
    echo "the upstream saw '${body:-nothing}' instead of a forwarded https scheme"
    return 1
}

printf '%sThe front door, actually serving%s %s(caddy on the real Caddyfile, stubs behind)%s\n\n' \
    "$BOLD" "$NC" "$DIM" "$NC"

docker network create "$NETWORK" >/dev/null 2>&1
start_the_upstreams
start_the_front_door
start_the_prober || exit 1
docker exec ut-ingress-probe sh -c 'apk add --no-cache openssl >/dev/null 2>&1' || true

if ! wait_for_the_front_door; then
    printf '\n%sThe front door never came up — nothing below could be checked.%s\n' "$RED" "$NC"
    exit 1
fi

printf '%sEvery surface UT_DOMAIN names%s\n' "$BOLD" "$NC"
for host in $SURFACES; do
    surface "https://${host} is served" a_surface_answers "$host"
done

printf '\n%sThe routes inside the platform%s\n' "$BOLD" "$NC"
surface "the apex serves the frontend" \
    a_path_reaches_its_upstream "$DOMAIN" / "stub 80 proto=https"
surface "/api goes to the platform API, not the frontend" \
    a_path_reaches_its_upstream "$DOMAIN" /api/anything "stub 8501"
surface "the administration portal is not the API" \
    a_path_reaches_its_upstream "admin.${DOMAIN}" / "stub 8080"
surface "the App Builder answers on its own port" \
    a_path_reaches_its_upstream "builder.${DOMAIN}" / "stub 8001"

printf '\n%sWhat the documentation tells a customer to register%s\n' "$BOLD" "$NC"
surface "the documented OIDC redirect URI reaches the platform API" \
    the_documented_callback_reaches_the_api

printf '\n%sWhat the certificate claims%s\n' "$BOLD" "$NC"
surface "the apex certificate names the apex" \
    the_certificate_covers_the_name "$DOMAIN"
surface "a generated application gets a certificate for its own name" \
    the_certificate_covers_the_name "demo.apps.${DOMAIN}"

printf '\n%sMode custom — the certificate comes from the operator%s\n' "$BOLD" "$NC"
restart_the_front_door_in custom
surface "custom mode comes up" wait_for_the_front_door
surface "it serves the certificate it was given, not one of its own" \
    the_supplied_certificate_is_the_one_served
surface "the apex still answers" a_surface_answers "$DOMAIN"
surface "a generated application still answers" a_surface_answers "demo.apps.${DOMAIN}"

printf '\n%sMode edge — TLS is terminated upstream%s\n' "$BOLD" "$NC"
restart_the_front_door_in edge
SCHEME="http"
surface "edge mode comes up on plain HTTP" wait_for_the_front_door
surface "it holds no certificate on 443" caddy_holds_no_certificate_in_edge_mode
surface "it believes a trusted proxy about the scheme" \
    a_trusted_proxy_is_believed_about_the_scheme

printf '\n%s%d served%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d not%s\n' "$RED" "$FAILED" "$NC"
    printf '\nNot serving:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
