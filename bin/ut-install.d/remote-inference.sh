# --inference-from: this machine is a control plane, generation comes from a
# compute node elsewhere (--compute, on that node's own install) instead of a
# local GPU, through this box's Caddy once ut-pair has paired the two.
# --inference-here undoes it. Sourced by bin/ut-install; depends on
# names_an_mdns_host, an_accelerator_answers, linked_node_address, log_error,
# log_warn, log_info, env_set, env_get, env_drop, release_declares and
# LINK_RELAY_URL defined there.

INFERENCE_FROM=""
INFERENCE_HERE=false

# A name or an IP, with :port when it is not 8444: ut-pair writes it into
# Caddy's settings and dials it, nothing else.
problem_with_the_compute_node_given() {
    [[ -n "$INFERENCE_FROM" ]] || return 1
    if [[ ! "$INFERENCE_FROM" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?)(:[0-9]{1,5})?$ ]]; then
        echo "--inference-from takes the compute node's name or IP, with :port when it is not 8444, not ${INFERENCE_FROM}"
    elif names_an_mdns_host "${INFERENCE_FROM%:*}"; then
        echo "--inference-from names a .local host, which this machine's containers cannot resolve: give the node's IP or a DNS name"
    else
        return 1
    fi
}

problem_with_the_inference_taken_back() {
    $INFERENCE_HERE || return 1
    if [[ -n "$INFERENCE_FROM" ]] || $NO_GPU || [[ -n "${COMPUTE_ADDRESS:-}" || -n "${ARBITER_ADDRESS:-}" ]]; then
        echo "--inference-here serves the inference on this machine's GPU; it goes with none of --inference-from, --no-gpu, --compute, --arbiter"
    elif ! an_accelerator_answers; then
        echo "--inference-here starts the engine on this machine's GPU, and no GPU answers here (nvidia-smi): install its driver, or keep taking the inference from a compute node"
    else
        return 1
    fi
}

die_on_a_compute_node_given_wrong() {
    local problem
    problem=$(problem_with_the_compute_node_given || problem_with_the_inference_taken_back) || return 0
    log_error "$problem"
    log_error "  Give the address the compute node's install printed: --inference-from <node>"
    exit 1
}

write_the_settings_a_compute_node_needs() {
    local local_file=$1 compose_files
    [[ -n "$INFERENCE_FROM" ]] || return 0
    compose_files=$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)
    [[ -n "$compose_files" ]] || compose_files=$(release_declares COMPOSE_FILE || echo "compose.yaml")
    case "$compose_files" in
        *compose.remote-inference.yaml*) ;;
        *) env_set "$local_file" COMPOSE_FILE "${compose_files}:compose.remote-inference.yaml" ;;
    esac
    log_info "Inference from the compute node at ${INFERENCE_FROM}, once the two are paired"
}

# Every run, not only the one given --inference-from: the file ut-pair writes is
# created empty, so that Docker never mounts a directory in its place. A
# platform linked by key, before ut-pair, moves to its relay and is told how to
# pair; the key and the root it was given no longer open anything.
write_the_link_a_platform_keeps() {
    local local_file=$1 dir previous node
    [[ "$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)" == *compose.remote-inference.yaml* ]] || return 0
    dir=$(dirname "$local_file")
    [[ -e "$dir/linked-node.caddy" ]] || install -m 644 /dev/null "$dir/linked-node.caddy"
    env_set "$local_file" UT_LINKED_NODE_FILE "$dir/linked-node.caddy"
    previous=$(env_get "$local_file" VLLM_LLM_BASE_URL 2>/dev/null || true)
    if [[ "$previous" == https://* ]]; then
        node=${previous#https://}; node=${node%%/*}; node=${node%:8444}
        log_warn "This platform reached its compute node with a key; it now goes through ut-pair."
        log_warn "  On the node: sudo ut-pair offer — then here: sudo ut-pair join ${node}"
    fi
    env_set "$local_file" VLLM_LLM_BASE_URL "$LINK_RELAY_URL"
    env_set "$local_file" VLLM_VLM_BASE_URL "$LINK_RELAY_URL"
    env_drop "$local_file" UT_INFERENCE_CA_BUNDLE
    rm -f "$dir/inference-ca-bundle.pem"
}

# The release's own COMPOSE_PROFILES and engine addresses take over again once
# the platform's are gone. What ut-pair recorded is left: forgetting it is the
# operator's to do, on both machines.
write_the_settings_a_platform_taking_its_inference_back_needs() {
    local local_file=$1 compose_files key node
    $INFERENCE_HERE || return 0
    compose_files=$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)
    if [[ -n "$compose_files" ]]; then
        compose_files=${compose_files//:compose.remote-inference.yaml/}
        env_set "$local_file" COMPOSE_FILE "${compose_files//:compose.no-gpu.yaml/}"
    fi
    for key in COMPOSE_PROFILES VLLM_LLM_BASE_URL VLLM_VLM_BASE_URL UT_LINKED_NODE_FILE UT_INFERENCE_CA_BUNDLE; do
        env_drop "$local_file" "$key"
    done
    log_info "Inference back on this machine: its engine starts here, on its GPU"
    node=$(linked_node_address)
    if [[ -n "$node" ]]; then
        log_warn "ut-pair still records the link to the compute node at ${node}; nothing uses it now."
        log_warn "  Forget it here: sudo ut-pair list, then sudo ut-pair forget <its prefix>; and on the node, this platform."
    fi
}
