# --arbiter: this machine judges a pair of boxes (no GPU, no control-plane
# state of its own). Sourced by bin/ut-install; depends on names_an_mdns_host,
# log_error, env_set, release_declares defined there.

ARBITER_ADDRESS=""

problem_with_the_arbiter_role_given() {
    [[ -n "$ARBITER_ADDRESS" ]] || return 1
    if [[ -n "$COMPUTE_ADDRESS" ]]; then
        echo "--arbiter judges a pair of boxes; it goes with neither --compute nor a model"
    elif [[ -n "$INFERENCE_FROM" ]]; then
        echo "--arbiter judges a pair of boxes; it goes with neither --inference-from nor a model"
    elif [[ -n "$MODEL_ID" || -n "$ENGINE_CHOICE" ]]; then
        echo "--arbiter serves no model; it goes with neither --model nor --engine"
    elif [[ "$ARBITER_ADDRESS" == */* || "$ARBITER_ADDRESS" == *:* ]]; then
        echo "--arbiter takes a name or an IP, such as 10.42.0.9, not ${ARBITER_ADDRESS}"
    elif names_an_mdns_host "$ARBITER_ADDRESS"; then
        echo "--arbiter ${ARBITER_ADDRESS}: the two boxes' containers cannot resolve a .local name; give this machine's IP or a DNS name"
    else
        return 1
    fi
}

die_on_an_arbiter_role_given_wrong() {
    local problem
    problem=$(problem_with_the_arbiter_role_given) || return 0
    log_error "$problem"
    exit 1
}

write_the_settings_an_arbiter_role_needs() {
    local local_file=$1 compose_files
    [[ -n "$ARBITER_ADDRESS" ]] || return 0
    env_set "$local_file" UT_ARBITER_ADDRESS "$ARBITER_ADDRESS"
    compose_files=$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)
    [[ -n "$compose_files" ]] || compose_files=$(release_declares COMPOSE_FILE || echo "compose.yaml")
    case "$compose_files" in
        *compose.arbiter.yaml*) ;;
        *) env_set "$local_file" COMPOSE_FILE "${compose_files}:compose.arbiter.yaml" ;;
    esac
    log_info "Arbiter, reached at https://${ARBITER_ADDRESS}:8446 by the two boxes it judges: no GPU, no control-plane state"
}
