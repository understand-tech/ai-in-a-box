# --inference-from: this machine is a control plane, generation comes from a
# compute node elsewhere (--compute, on that node's own install) instead of a
# local GPU. Sourced by bin/ut-install; depends on names_an_mdns_host,
# the_key_file_holds_one_key, host_of_url, inference_base_url, log_error,
# env_set, release_declares, HOST_CA_BUNDLE defined there.

INFERENCE_FROM=""
INFERENCE_KEY_FILE=""
INFERENCE_CA_FILE=""

problem_with_the_compute_node_given() {
    if [[ -z "$INFERENCE_FROM" ]]; then
        [[ -z "$INFERENCE_KEY_FILE$INFERENCE_CA_FILE" ]] && return 1
        echo "--inference-key-file and --inference-ca-file only go with --inference-from"
    elif [[ ! "$INFERENCE_FROM" =~ ^https://[^/]+ ]]; then
        echo "--inference-from must be an https address, got ${INFERENCE_FROM}"
    elif names_an_mdns_host "$(host_of_url "$INFERENCE_FROM")"; then
        echo "--inference-from names a .local host, which this machine's containers cannot resolve: give the node's IP or a DNS name"
    elif ! the_key_file_holds_one_key "$INFERENCE_KEY_FILE"; then
        echo "--inference-key-file must hold the node's VLLM_API_KEY, one line, nothing else"
    elif ! openssl x509 -in "$INFERENCE_CA_FILE" -noout 2>/dev/null; then
        echo "--inference-ca-file must be the node's root certificate, in PEM"
    elif [[ ! -r "$HOST_CA_BUNDLE" ]]; then
        echo "no public roots at ${HOST_CA_BUNDLE} to keep beside the node's (apt install ca-certificates)"
    else
        return 1
    fi
}

die_on_a_compute_node_given_wrong() {
    local problem
    problem=$(problem_with_the_compute_node_given) || return 0
    log_error "$problem"
    log_error "  Give all three, as the compute node's install printed them:"
    log_error "    --inference-from https://<node>:8444 --inference-key-file <key> --inference-ca-file <root.crt>"
    log_error "  or none, and point VLLM_LLM_BASE_URL at the inference yourself."
    exit 1
}

write_the_settings_a_compute_node_needs() {
    local local_file=$1 bundle compose_files
    [[ -n "$INFERENCE_FROM" ]] || return 0

    bundle="$(dirname "$local_file")/inference-ca-bundle.pem"
    cat "$HOST_CA_BUNDLE" "$INFERENCE_CA_FILE" > "$bundle"
    chmod 644 "$bundle"

    env_set "$local_file" VLLM_LLM_BASE_URL "$(inference_base_url "$INFERENCE_FROM")"
    env_set "$local_file" VLLM_VLM_BASE_URL "$(inference_base_url "$INFERENCE_FROM")"
    env_set "$local_file" VLLM_API_KEY "$(tr -d '\r\n' < "$INFERENCE_KEY_FILE")"
    env_set "$local_file" UT_INFERENCE_CA_BUNDLE "$bundle"

    compose_files=$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)
    [[ -n "$compose_files" ]] || compose_files=$(release_declares COMPOSE_FILE || echo "compose.yaml")
    case "$compose_files" in
        *compose.remote-inference.yaml*) ;;
        *) env_set "$local_file" COMPOSE_FILE "${compose_files}:compose.remote-inference.yaml" ;;
    esac
    log_info "Inference from ${INFERENCE_FROM}, with its key, trusting its root"
}
