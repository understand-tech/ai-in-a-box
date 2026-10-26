# --compute: this machine serves inference on its own GPU, to a control plane
# reached through --inference-from. Sourced by bin/ut-install; depends on
# names_an_mdns_host, log_error, env_set, env_get, release_declares defined there.

COMPUTE_ADDRESS=""

problem_with_the_compute_role_given() {
    [[ -n "$COMPUTE_ADDRESS" ]] || return 1
    if $NO_GPU || [[ -n "$INFERENCE_FROM" ]]; then
        echo "--compute serves the inference on this machine's GPU; it goes with neither --no-gpu nor --inference-from"
    elif [[ "$COMPUTE_ADDRESS" == */* || "$COMPUTE_ADDRESS" == *:* ]]; then
        echo "--compute takes a name or an IP, such as 10.42.0.7, not ${COMPUTE_ADDRESS}"
    elif names_an_mdns_host "$COMPUTE_ADDRESS"; then
        echo "--compute ${COMPUTE_ADDRESS}: a control plane's containers cannot resolve a .local name; give this machine's IP or a DNS name"
    else
        return 1
    fi
}

die_on_a_compute_role_given_wrong() {
    local problem
    problem=$(problem_with_the_compute_role_given) || return 0
    log_error "$problem"
    exit 1
}

write_the_settings_a_compute_role_needs() {
    local local_file=$1 compose_files
    [[ -n "$COMPUTE_ADDRESS" ]] || return 0
    env_set "$local_file" UT_INFERENCE_ADDRESS "$COMPUTE_ADDRESS"
    compose_files=$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)
    [[ -n "$compose_files" ]] || compose_files=$(release_declares COMPOSE_FILE || echo "compose.yaml")
    case "$compose_files" in
        *compose.compute.yaml*) ;;
        *) env_set "$local_file" COMPOSE_FILE "${compose_files}:compose.compute.yaml" ;;
    esac
    log_info "Compute node, reached at https://${COMPUTE_ADDRESS}:8444 by the platforms paired with it"
}

# Every run, not only the one given --compute: a node that had the role before
# gets the list ut-pair keeps, created empty so that Docker never mounts a
# directory in its place.
write_the_list_a_compute_node_keeps() {
    local local_file=$1 dir
    [[ "$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)" == *compose.compute.yaml* ]] || return 0
    dir=$(dirname "$local_file")
    [[ -e "$dir/admitted-boxes.caddy" ]] || install -m 644 /dev/null "$dir/admitted-boxes.caddy"
    env_set "$local_file" UT_ADMITTED_BOXES_FILE "$dir/admitted-boxes.caddy"
}
