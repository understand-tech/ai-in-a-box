# compose.arbiter-link.yaml: this machine is a box of a high-availability pair,
# and its Caddy relays ut-arbiter hold to the arbiter once ut-pair has paired
# them. Sourced by bin/ut-install; depends on env_get and env_set defined there.

# Every run: the file ut-pair writes is created empty, so that Docker never
# mounts a directory in its place.
write_the_link_a_pair_box_keeps() {
    local local_file=$1 dir
    [[ "$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)" == *compose.arbiter-link.yaml* ]] || return 0
    dir=$(dirname "$local_file")
    [[ -e "$dir/linked-arbiter.caddy" ]] || install -m 644 /dev/null "$dir/linked-arbiter.caddy"
    env_set "$local_file" UT_LINKED_ARBITER_FILE "$dir/linked-arbiter.caddy"
}
