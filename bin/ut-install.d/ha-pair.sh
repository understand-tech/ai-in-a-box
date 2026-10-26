# --ha-arbiter: this machine is one of the two boxes an arbiter judges. Sourced
# by bin/ut-install; depends on names_an_mdns_host, the_key_file_holds_one_key,
# host_of_url, log_error, log_info, env_set defined there.

HA_ID=""
HA_ARBITER=""
HA_KEY_FILE=""
HA_CA_FILE=""

# A cgo-free static binary (ut-arbiter's build, like ut-send's) never resolves
# .local: Go's pure resolver only hands mDNS names to the cgo resolver, which
# this binary does not carry — unlike a container reaching the same name
# through Caddy, no host-side avahi fixes this one.
problem_with_the_ha_pair_given() {
    if [[ -z "$HA_ARBITER" ]]; then
        [[ -z "$HA_ID$HA_KEY_FILE$HA_CA_FILE" ]] && return 1
        echo "--ha-id, --ha-key-file and --ha-ca-file only go with --ha-arbiter"
    elif [[ -n "$ARBITER_ADDRESS" ]]; then
        echo "--ha-arbiter pairs this box with an arbiter; this machine cannot be the arbiter and one of the pair at once"
    elif [[ -z "$HA_ID" ]]; then
        echo "--ha-arbiter needs --ha-id: this fleet already has two boxes sharing a hostname, so the hostname is not a safe default"
    elif [[ ! "$HA_ARBITER" =~ ^https://[^/]+ ]]; then
        echo "--ha-arbiter must be an https address, got ${HA_ARBITER}"
    elif names_an_mdns_host "$(host_of_url "$HA_ARBITER")"; then
        echo "--ha-arbiter names a .local host: ut-arbiter hold is a static binary and cannot resolve mDNS names at all; give the arbiter's IP or a DNS name"
    elif ! the_key_file_holds_one_key "$HA_KEY_FILE"; then
        echo "--ha-key-file must hold the arbiter's UT_ARBITER_API_KEY, one line, nothing else"
    elif ! openssl x509 -in "$HA_CA_FILE" -noout 2>/dev/null; then
        echo "--ha-ca-file must be the arbiter's root certificate, in PEM"
    else
        return 1
    fi
}

die_on_an_ha_pair_given_wrong() {
    local problem
    problem=$(problem_with_the_ha_pair_given) || return 0
    log_error "$problem"
    log_error "  Give all four, as the arbiter's install printed them:"
    log_error "    --ha-id <this-box> --ha-arbiter https://<arbiter>:8446 \\"
    log_error "    --ha-key-file <key> --ha-ca-file <root.crt>"
    exit 1
}

# ut-arbiter hold reads its key and its root from files, not from the
# environment: it is a host binary with no .env to source. Copied beside
# local.env, next to inference-ca-bundle.pem, rather than left at the path the
# operator typed them at — that path is often a throwaway copy in a home
# directory, and the systemd unit setup-autostart.sh installs needs one that
# survives it being deleted.
write_the_settings_an_ha_pair_needs() {
    local local_file=$1 dir key_file ca_file
    [[ -n "$HA_ARBITER" ]] || return 0

    dir="$(dirname "$local_file")"
    key_file="$dir/ha-arbiter.key"
    ca_file="$dir/ha-arbiter-root.crt"
    install -m 600 "$HA_KEY_FILE" "$key_file"
    install -m 644 "$HA_CA_FILE" "$ca_file"

    env_set "$local_file" UT_HA_ID "$HA_ID"
    env_set "$local_file" UT_HA_ARBITER "$HA_ARBITER"
    env_set "$local_file" UT_HA_ARBITER_KEY_FILE "$key_file"
    env_set "$local_file" UT_HA_ARBITER_CA_FILE "$ca_file"
    log_info "Paired with the arbiter at ${HA_ARBITER} as '${HA_ID}'"
}
