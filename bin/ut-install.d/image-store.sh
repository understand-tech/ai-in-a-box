# Docker 29 keeps the images of a fresh install in containerd's store; a machine
# installed before keeps overlay2 until told otherwise. The platform's registry
# serves its images only to a Docker on containerd's store, so every box moves.
# Sourced by bin/ut-install; depends on log_*, die, log_step and DATA_DIR.

DOCKER_DAEMON_SETTINGS="${UT_DOCKER_DAEMON_SETTINGS:-/etc/docker/daemon.json}"
NVIDIA_TOOLKIT_KEEPING_DOCKER_FEATURES="1.20.1"
DAEMON_SETTINGS_BEFORE_THE_MOVE="$DATA_DIR/docker-daemon.json.before-containerd"
MOVE_TO_CONTAINERD_CAN_BE_UNDONE=false
PLATFORM_READY=false

docker_keeps_images_in_containerd() {
    docker info --format '{{json .DriverStatus}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'
}

docker_remaps_user_namespaces() {
    docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q 'name=userns'
}

# Before 1.20.1, `nvidia-ctk runtime configure` rewrote daemon.json without the
# features it held, which sends Docker back to overlay2 at its next restart.
nvidia_toolkit_drops_docker_features() {
    local version
    version=$(dpkg-query -W -f '${Version}' nvidia-container-toolkit 2>/dev/null) || return 1
    [[ -n "$version" ]] || return 1
    dpkg --compare-versions "$version" lt "$NVIDIA_TOOLKIT_KEEPING_DOCKER_FEATURES"
}

check_the_image_store() {
    docker info >/dev/null 2>&1 || return 0
    if docker_keeps_images_in_containerd; then
        log_info "Images: in containerd's store"
        return 0
    fi
    if docker_remaps_user_namespaces; then
        log_error "Images: overlay2, and Docker remaps user namespaces (userns-remap)."
        log_error "  containerd's store, which the platform's images need, does not work with it."
        log_error "  Remove userns-remap from ${DOCKER_DAEMON_SETTINGS}, restart Docker, then run this again."
        return 1
    fi
    if nvidia_toolkit_drops_docker_features; then
        log_error "Images: overlay2, and the NVIDIA Container Toolkit is older than ${NVIDIA_TOOLKIT_KEEPING_DOCKER_FEATURES}."
        log_error "  It would put Docker back on overlay2 the next time it configures Docker. Upgrade it:"
        log_error "    sudo apt-get update && sudo apt-get install --only-upgrade nvidia-container-toolkit"
        return 1
    fi
    log_warn "Images: overlay2 — this install moves them to containerd's store."
    log_warn "  The platform stops while Docker restarts, and until every image is back."
    return 0
}

daemon_settings_with_containerd() {
    local current='{}'
    [[ -s "$DOCKER_DAEMON_SETTINGS" ]] && current=$(cat "$DOCKER_DAEMON_SETTINGS")
    jq '.features["containerd-snapshotter"] = true' <<< "$current"
}

restart_docker() {
    systemctl restart docker
}

step_keep_the_images_in_containerd() {
    docker_keeps_images_in_containerd && return 0
    log_step "Moving Docker's images to containerd's store"
    log_warn "The platform stops now, and starts again once its images are back from ${IMAGES_FROM:-the registry}."
    log "     overlay2 keeps its copy until the platform is ready again."

    local settings
    settings=$(daemon_settings_with_containerd) \
        || die "${DOCKER_DAEMON_SETTINGS} is not JSON Docker could read: fix it, then run this again."
    mkdir -p "$(dirname "$DAEMON_SETTINGS_BEFORE_THE_MOVE")" "$(dirname "$DOCKER_DAEMON_SETTINGS")"
    if [[ -e "$DOCKER_DAEMON_SETTINGS" ]]; then
        cp -p "$DOCKER_DAEMON_SETTINGS" "$DAEMON_SETTINGS_BEFORE_THE_MOVE"
    else
        rm -f "$DAEMON_SETTINGS_BEFORE_THE_MOVE"
    fi
    MOVE_TO_CONTAINERD_CAN_BE_UNDONE=true
    printf '%s\n' "$settings" > "$DOCKER_DAEMON_SETTINGS"

    restart_docker || die "Docker did not restart with containerd's store."
    docker_keeps_images_in_containerd || die "Docker restarted, and still keeps its images in overlay2."
    log_info "Docker keeps its images in containerd's store"
}

# Once the platform starts on the new store, overlay2 has nothing left to bring back.
forget_how_to_undo_the_move_to_containerd() {
    MOVE_TO_CONTAINERD_CAN_BE_UNDONE=false
}

put_overlay2_back_if_the_move_failed() {
    $MOVE_TO_CONTAINERD_CAN_BE_UNDONE || return 0
    MOVE_TO_CONTAINERD_CAN_BE_UNDONE=false
    log_error "Putting Docker back on overlay2, with the platform as it ran before this install."
    if [[ -e "$DAEMON_SETTINGS_BEFORE_THE_MOVE" ]]; then
        cp -p "$DAEMON_SETTINGS_BEFORE_THE_MOVE" "$DOCKER_DAEMON_SETTINGS"
    else
        rm -f "$DOCKER_DAEMON_SETTINGS"
    fi
    if restart_docker && ! docker_keeps_images_in_containerd; then
        log_error "  Docker is on overlay2 again. Fix what stopped the install above, then run it again."
    else
        log_error "  Docker did not come back on overlay2: check 'systemctl status docker'."
    fi
}

docker_root() {
    docker info --format '{{.DockerRootDir}}' 2>/dev/null
}

step_free_what_overlay2_kept() {
    $PLATFORM_READY || return 0
    docker_keeps_images_in_containerd || return 0
    local root freed_mb
    root=$(docker_root)
    [[ "$root" == /* && -d "$root/overlay2" ]] || return 0
    log_step "Freeing what overlay2 kept"
    freed_mb=$(du -smc "$root/overlay2" "$root/image/overlay2" 2>/dev/null | tail -1 | cut -f1)
    rm -rf "${root:?}/overlay2" "${root:?}/image/overlay2"
    rm -f "$DAEMON_SETTINGS_BEFORE_THE_MOVE"
    log_info "Freed $(( ${freed_mb:-0} / 1024 )) GB that overlay2 kept, now that the platform runs on containerd's store"
}

step_settle_the_images_on_disk() {
    sync
    $DO_PULL || [[ -n "$IMAGES_FROM" ]] || return 0
    local image missing=""
    while IFS= read -r image; do
        [[ -n "$image" ]] || continue
        docker image inspect "$image" >/dev/null 2>&1 || missing+=" ${image}"
    done < <(compose_in_dir config --images 2>/dev/null | sort -u)
    [[ -z "$missing" ]] || die "These images are missing after the download:${missing}"
}
