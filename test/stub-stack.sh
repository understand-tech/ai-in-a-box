#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"
PROJECT="ut-stub-$$"
WAIT_SECONDS="${STUB_WAIT_SECONDS:-180}"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; BOLD=$'\033[1m'; NC=$'\033[0m'
PASSED=0; FAILED=0

# Every other suite stops before `docker compose up`, because the application
# images are private. This one goes past that line on public stand-ins, so the
# four services the lifecycle actually leans on — mongodb, redis, step-ca and
# caddy — are exercised for real, up to healthy, with no registry token.
#
# What it does NOT prove: that the application images behave. The stubs answer
# the same routes on the same ports, nothing more. Their healthchecks are the
# ones compose.yaml declares, unmodified, which is the whole point.
cleanup() {
    [[ -f "$WORK_DIR/env" ]] && compose_here down -v --remove-orphans >/dev/null 2>&1
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

COMPOSE_ARGS="-f compose.yaml -f compose.no-gpu.yaml -f test/compose.stub.yaml"

check() {
    local description=$1; shift
    if "$@" >/dev/null 2>&1; then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        FAILED=$((FAILED + 1))
    fi
}

# DATA_ROOT is redirected into the work directory: the real one is /var/lib,
# and a suite that writes there would need root and would outlive itself.
write_settings() {
    install -d "$WORK_DIR/data/ca/certs" "$WORK_DIR/data/app-data"
    cat > "$WORK_DIR/env" <<SETTINGS
COMPOSE_PROJECT_NAME="$PROJECT"
RESOURCE_PREFIX="$PROJECT"
CONTAINER_PREFIX="$PROJECT"
DATA_ROOT="$WORK_DIR/data"
UT_DOMAIN="stub.example.test"
UT_INGRESS_MODE="internal"
UT_HTTP_PORT="18080"
UT_HTTPS_PORT="18443"
MONGODB_HOST_PORT="27219"
MONGODB_USERNAME="stubadmin"
MONGODB_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')"
MONGODB_DATABASE="stub"
MONGODB_HOST="mongodb"
MONGODB_PORT="27017"
REDIS_HOST="redis"
REDIS_PORT="6379"
JWT_SECRET="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')"
STATE_SECRET="$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')"
CA_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')"
GPU_VM_API_TOKEN="unused-by-the-stubs"
BACKUP_FILES_PASSWORD="unused-by-the-stubs"
WORKER_REPLICAS="1"
WORKER_CUSTOMER_REPLICAS="1"
SETTINGS
}

# Every compose invocation goes through here. Splitting them meant the settings
# reached `up` and not `ps`, which reported a healthy service as missing — the
# check failed while the stack was fine.
compose_here() {
    ( cd "$REPO_ROOT" \
        && env $(grep -v '^#' "$WORK_DIR/env" | tr -d '"' | xargs) \
           docker compose -p "$PROJECT" $COMPOSE_ARGS "$@" )
}

service_is_healthy() {
    local service=$1 id state
    id=$(compose_here ps -q "$service" 2>/dev/null | head -1)
    [[ -n "$id" ]] || return 1
    state=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null)
    [[ "$state" == "healthy" || "$state" == "running" ]]
}

the_stack_reaches_healthy() {
    compose_here up -d --wait --wait-timeout "$WAIT_SECONDS"
}

a_real_service_answers() {
    local service=$1; shift
    compose_here exec -T "$service" "$@"
}

printf '%sThe stack, brought up on public stand-ins%s %s(mongodb, redis, step-ca and caddy are real)%s\n\n' \
    "$BOLD" "$NC" "$BOLD" "$NC"

write_settings

if ! the_stack_reaches_healthy; then
    printf '  %s✘%s the stack reaches healthy\n' "$RED" "$NC"
    compose_here ps
    printf '\n%s1 check failed%s\n' "$RED" "$NC"
    exit 1
fi
printf '  %s✔%s the stack reaches healthy without a registry token\n' "$GREEN" "$NC"
PASSED=$((PASSED + 1))

check "the database answers its own healthcheck, not a stub's" \
    a_real_service_answers mongodb mongosh --quiet --eval 'db.adminCommand("ping").ok'
check "redis answers" \
    a_real_service_answers redis redis-cli ping
check "the certificate authority is up" \
    service_is_healthy step-ca
check "the front door validates the real Caddyfile" \
    a_real_service_answers caddy caddy validate --config /etc/caddy/Caddyfile
check "a stubbed upstream answers the route its healthcheck asks for" \
    a_real_service_answers api curl -fsS http://localhost:8501/api/docs

printf '\n'
if (( FAILED )); then
    printf '%s%d verified, %d failed%s\n' "$RED" "$PASSED" "$FAILED" "$NC"
    exit 1
fi
printf '%s%d verified%s\n' "$GREEN" "$PASSED" "$NC"
