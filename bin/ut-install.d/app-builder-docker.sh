# The App Builder's apps run in a rootless Docker of their own
# (compose.appbuilder-nested.yaml), or, while that move proves itself, on this
# machine's Docker (APP_BUILDER_DOCKER="host", compose.appbuilder-on-host.yaml).
# Sourced by bin/ut-install; depends on env_get, env_set, env_drop,
# release_declares, settings_directory, render_settings, compose_in_dir, log_*,
# die, DATA_DIR and INSTALL_DIR defined there.

APP_BUILDER_DOCKER_UID=2375
APP_BUILDER_DOCKER_SUBIDS_START=237500000
APP_BUILDER_DOCKER_SUBIDS_COUNT=65536
APP_BUILDER_TRAEFIK_IMAGE="ut-app-builder-traefik:local"
MONGO_UID_IN_AN_APP=999

app_builder_data() {
    local data_root
    data_root=$(env_get "$INSTALL_DIR/.env" DATA_ROOT 2>/dev/null || true)
    printf '%s/appbuilder' "${data_root:-$DATA_DIR}"
}

# 0 inside the daemon is its own user; n > 0 is the n-th id of its range.
id_this_machine_sees_for() {
    printf '%s' $(( APP_BUILDER_DOCKER_SUBIDS_START + $1 - 1 ))
}

the_docker_the_app_builder_uses() {
    local local_file=$1
    env_get "$local_file" APP_BUILDER_DOCKER 2>/dev/null \
        || release_declares APP_BUILDER_DOCKER \
        || printf 'nested'
}

die_on_ids_the_app_builder_docker_would_share() {
    local account overlaps file
    account=$(getent passwd "$APP_BUILDER_DOCKER_UID" 2>/dev/null | cut -d: -f1 || true)
    if [[ -n "$account" ]]; then
        die "The account ${account} has the uid ${APP_BUILDER_DOCKER_UID}, which the App Builder's Docker runs as: its apps would own ${account}'s files. Nothing was changed; APP_BUILDER_DOCKER=\"host\" in local.env keeps the App Builder as it was."
    fi
    for file in /etc/subuid /etc/subgid; do
        [[ -r "$file" ]] || continue
        overlaps=$(awk -F: -v start="$APP_BUILDER_DOCKER_SUBIDS_START" -v count="$APP_BUILDER_DOCKER_SUBIDS_COUNT" \
            'NF >= 3 && $2 < start + count && $2 + $3 > start { print $1 ":" $2 ":" $3 }' "$file")
        [[ -z "$overlaps" ]] && continue
        die "${file} gives ${overlaps//$'\n'/, } ids that the App Builder's Docker maps its apps to (${APP_BUILDER_DOCKER_SUBIDS_START} to $(( APP_BUILDER_DOCKER_SUBIDS_START + APP_BUILDER_DOCKER_SUBIDS_COUNT - 1 ))): their containers would share files. Nothing was changed; APP_BUILDER_DOCKER=\"host\" in local.env keeps the App Builder as it was."
    done
}

write_the_identities_of_the_app_builder_docker() {
    local dir=$1
    install -d -m 755 "$dir"
    printf 'root:x:0:0:root:/root:/bin/sh\nabuilder:x:%s:%s::/home/abuilder:/bin/sh\n' \
        "$APP_BUILDER_DOCKER_UID" "$APP_BUILDER_DOCKER_UID" > "$dir/passwd"
    printf 'root:x:0:\nabuilder:x:%s:\n' "$APP_BUILDER_DOCKER_UID" > "$dir/group"
    printf 'abuilder:%s:%s\n' "$APP_BUILDER_DOCKER_SUBIDS_START" "$APP_BUILDER_DOCKER_SUBIDS_COUNT" > "$dir/subuid"
    cp "$dir/subuid" "$dir/subgid"
    chmod 644 "$dir/passwd" "$dir/group" "$dir/subuid" "$dir/subgid"
}

forget_the_app_builder_docker() {
    local local_file=$1 key
    for key in APP_BUILDER_DOCKER_IDS APPS_MONGO_UID APPS_MONGO_GID; do
        env_drop "$local_file" "$key"
    done
}

write_the_settings_the_app_builder_s_docker_needs() {
    local local_file=$1 compose_files others overlay mode dir mongo
    compose_files=$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || true)
    [[ -n "$compose_files" ]] || compose_files=$(release_declares COMPOSE_FILE || echo "compose.yaml")
    others=${compose_files//:compose.appbuilder-nested.yaml/}
    others=${others//:compose.appbuilder-on-host.yaml/}

    case ":${others}:" in
        *:compose.appbuilder.yaml:*) ;;
        *)
            [[ "$others" == "$compose_files" ]] || env_set "$local_file" COMPOSE_FILE "$others"
            forget_the_app_builder_docker "$local_file"
            return 0 ;;
    esac

    mode=$(the_docker_the_app_builder_uses "$local_file")
    case "$mode" in
        nested)
            overlay=compose.appbuilder-nested.yaml
            die_on_ids_the_app_builder_docker_would_share
            dir="$(dirname "$local_file")/app-builder-docker"
            write_the_identities_of_the_app_builder_docker "$dir"
            mongo=$(id_this_machine_sees_for "$MONGO_UID_IN_AN_APP")
            env_set "$local_file" APP_BUILDER_DOCKER_IDS "$dir"
            env_set "$local_file" APPS_MONGO_UID "$mongo"
            env_set "$local_file" APPS_MONGO_GID "$mongo"
            ;;
        host)
            overlay=compose.appbuilder-on-host.yaml
            forget_the_app_builder_docker "$local_file"
            log_warn "The App Builder drives this machine's own Docker (APP_BUILDER_DOCKER=\"host\"): whoever reaches it is root here."
            log_warn "  Remove that line from ${local_file} to give its apps a Docker of their own."
            ;;
        *)
            die "APP_BUILDER_DOCKER is \"${mode}\" in ${local_file}: it takes nested or host."
            ;;
    esac
    [[ "${others}:${overlay}" == "$compose_files" ]] || env_set "$local_file" COMPOSE_FILE "${others}:${overlay}"
}

in_the_app_builder_docker() { compose_in_dir exec -T app-builder-docker docker "$@"; }

load_the_profile_the_app_builder_docker_runs_under() {
    local profile="$INSTALL_DIR/appbuilder/apparmor/ut-app-builder-docker" said
    if ! docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q apparmor; then
        log_info "Docker confines nothing with AppArmor here: the App Builder's Docker needs no profile"
        return 0
    fi
    if ! command -v apparmor_parser >/dev/null 2>&1; then
        log_error "Docker confines containers with AppArmor here, and apparmor_parser is missing: the App Builder's Docker cannot get its profile."
        return 1
    fi
    if ! said=$(install -m 644 "$profile" /etc/apparmor.d/ut-app-builder-docker 2>&1 \
            && apparmor_parser -r /etc/apparmor.d/ut-app-builder-docker 2>&1); then
        log_error "AppArmor refused the profile of the App Builder's Docker: ${said}"
        return 1
    fi
    log_info "AppArmor profile ut-app-builder-docker loaded, kept in /etc/apparmor.d for the next boot"
}

start_the_app_builder_docker() {
    local attempt
    if ! compose_in_dir up -d app-builder-docker >/dev/null 2>&1; then
        log_error "The App Builder's Docker did not start: $(compose_in_dir logs --tail 3 app-builder-docker 2>&1 | tail -1)"
        return 1
    fi
    for attempt in $(seq 60); do
        in_the_app_builder_docker version >/dev/null 2>&1 && { log_info "The App Builder's Docker answers, rootless, on its socket alone"; return 0; }
        sleep 2
    done
    log_error "The App Builder's Docker did not answer in two minutes: $(compose_in_dir logs --tail 3 app-builder-docker 2>&1 | tail -1)"
    return 1
}

# Its routes are the files the App Builder and ut-import-app write: the release's
# own route goes beside them, a file whose name the App Builder leaves alone.
give_the_app_builder_docker_its_traefik() {
    local image wanted have routes config args
    image=$(env_get "$INSTALL_DIR/.env" TRAEFIK_IMAGE 2>/dev/null || true)
    routes="$(app_builder_data)/traefik-dynamic"
    install -d "$routes"
    install -m 644 "$INSTALL_DIR/appbuilder/traefik/_orchestrator.yml" "$routes/_orchestrator.yml"

    if ! wanted=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null); then
        log_error "Traefik's image ${image} is not on this machine, so the App Builder's Docker cannot be given it."
        return 1
    fi
    have=$(in_the_app_builder_docker image inspect --format '{{.Id}}' "$APP_BUILDER_TRAEFIK_IMAGE" 2>/dev/null || true)
    if [[ "$have" != "$wanted" ]]; then
        if ! { docker tag "$image" "$APP_BUILDER_TRAEFIK_IMAGE" \
                && docker save "$APP_BUILDER_TRAEFIK_IMAGE" | in_the_app_builder_docker load -q >/dev/null; }; then
            docker rmi "$APP_BUILDER_TRAEFIK_IMAGE" >/dev/null 2>&1 || true
            log_error "Traefik's image could not be handed to the App Builder's Docker."
            return 1
        fi
        docker rmi "$APP_BUILDER_TRAEFIK_IMAGE" >/dev/null 2>&1 || true
    fi

    if ! in_the_app_builder_docker network inspect proxy >/dev/null 2>&1 \
            && ! in_the_app_builder_docker network create proxy >/dev/null 2>&1; then
        log_error "The App Builder's Docker has no proxy network for its apps, and could not create one."
        return 1
    fi

    args=(--global.checknewversion=false --global.sendanonymoususage=false
        --providers.file.directory=/etc/traefik/dynamic --providers.file.watch=true
        --entrypoints.web.address=:80 --ping=true --ping.entrypoint=web)
    config=$(printf '%s\n' "$wanted" "$routes" "${args[@]}" | sha256sum | cut -c1-16)
    if [[ "$(in_the_app_builder_docker inspect --format '{{index .Config.Labels "ut.config"}} {{.State.Running}}' traefik 2>/dev/null || true)" == "$config true" ]]; then
        log_info "Traefik already serves the generated apps from inside their Docker"
        return 0
    fi
    in_the_app_builder_docker rm -f traefik >/dev/null 2>&1 || true
    if ! in_the_app_builder_docker run -d --name traefik --restart unless-stopped --label "ut.config=${config}" \
            --network proxy --network-alias ut-api-v3 -p 8090:80 -v "${routes}:/etc/traefik/dynamic:ro" \
            "$APP_BUILDER_TRAEFIK_IMAGE" "${args[@]}" >/dev/null 2>&1; then
        log_error "Traefik did not start inside the App Builder's Docker."
        return 1
    fi
    log_info "Traefik serves the generated apps from inside their Docker"
}

# Every compose project the App Builder runs or ran: a workspace's own, its
# published stack (<id>--prod), and whatever a container under its data says.
projects_of_the_app_builder() {
    local data root dir name
    data=$(app_builder_data)
    for root in "$data/workspaces" "$data/prod-workspaces"; do
        for dir in "$root"/*/; do
            [[ -d "$dir" ]] || continue
            name=$(basename "$dir")
            printf '%s\n%s--prod\n' "$name" "$name"
        done
    done
    docker ps -a --filter label=com.docker.compose.project \
        --format '{{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null \
        | awk -v root="$data/" 'index($2, root) == 1 { print $1 }'
}

images_the_apps_name() {
    local data file
    data=$(app_builder_data)
    for file in "$data"/workspaces/*/docker-compose.yml "$data"/prod-workspaces/*/docker-compose.yml; do
        [[ -f "$file" ]] || continue
        sed -n 's/^[[:space:]]*image:[[:space:]]*["'\'']\{0,1\}\([^"'\''[:space:]]*\).*/\1/p' "$file"
    done | { grep -v '\$' || true; } | sort -u
}

databases_of_the_apps() {
    local data dir
    data=$(app_builder_data)
    for dir in "$data"/workspaces/*/mongo-data "$data"/prod-workspaces/*/mongo-data; do
        [[ -d "$dir" && "$(stat -c %u "$dir")" == "$MONGO_UID_IN_AN_APP" ]] && printf '%s\n' "$dir"
    done
    return 0
}

put_the_apps_back_on_this_machine_s_docker() {
    local databases=$1 running=$2 dir
    while IFS= read -r dir; do
        [[ -n "$dir" ]] && chown -R "${MONGO_UID_IN_AN_APP}:${MONGO_UID_IN_AN_APP}" "$dir"
    done <<< "$databases"
    [[ -z "$running" ]] || docker start $running >/dev/null 2>&1 || true
    compose_in_dir start app-builder >/dev/null 2>&1 || true
}

# Every app moves, those the App Builder archived too: their images are what
# restores them without npm, which a box with no network does not have.
move_the_apps_off_this_machine_s_docker() {
    local projects containers running images app_images base_images refs needed free disk_target
    local databases="" moved_databases="" dir mongo ref missing=""

    projects=$(projects_of_the_app_builder | sort -u || true)
    [[ -n "$projects" ]] || { log_info "No app built here yet: nothing to move"; return 0; }

    containers=$(docker ps -a --filter label=com.docker.compose.project \
        --format '{{.ID}} {{.State}} {{.Label "com.docker.compose.project"}}' 2>/dev/null \
        | awk 'NR == FNR { wanted[$1] = 1; next } wanted[$3]' <(printf '%s\n' "$projects") - || true)
    running=$(awk '$2 == "running" { print $1 }' <<< "$containers")
    images=$(docker image ls -q --filter label=com.docker.compose.project 2>/dev/null | sort -u \
        | xargs -r docker image inspect --format '{{index .Config.Labels "com.docker.compose.project"}} {{.Size}} {{join .RepoTags " "}}' 2>/dev/null \
        | awk 'NR == FNR { wanted[$1] = 1; next } wanted[$1] && NF > 2' <(printf '%s\n' "$projects") - || true)
    if [[ -z "$containers" && -z "$images" ]]; then
        log_info "No app left on this machine's Docker: nothing to move"
        return 0
    fi
    app_images=$(awk '{ for (i = 3; i <= NF; i++) print $i }' <<< "$images")
    base_images=$(images_the_apps_name | while IFS= read -r ref; do
        docker image inspect --format '{{.Size}} '"$ref" "$ref" 2>/dev/null || true
    done || true)

    needed=$(printf '%s\n%s\n' "$(awk '{ print $2 }' <<< "$images")" "$(awk '{ print $1 }' <<< "$base_images")" \
        | awk '{ total += $1 } END { printf "%.0f", total * 1.1 + 1000000000 }')
    disk_target=$([[ -d /var/lib/docker ]] && echo /var/lib/docker || echo /var/lib)
    free=$(df -B1 --output=avail "$disk_target" 2>/dev/null | tail -1 | tr -d ' ' || true)
    if [[ -z "$free" ]] || (( free < needed )); then
        log_error "Moving the apps needs $(( needed / 1000000000 )) GB free on ${disk_target}, which has $(( ${free:-0} / 1000000000 )): nothing was moved."
        return 1
    fi

    log_info "Moving $(wc -l <<< "$app_images" | tr -d ' ') app image(s) to the apps' own Docker, archived apps included"
    compose_in_dir stop app-builder >/dev/null 2>&1 || true
    [[ -z "$running" ]] || docker stop $running >/dev/null 2>&1 || true

    refs=$(printf '%s\n%s\n' "$app_images" "$(awk '{ print $2 }' <<< "$base_images")" | { grep -v '^$' || true; } | sort -u)
    if [[ -n "$refs" ]] && ! docker save $refs | in_the_app_builder_docker load -q >/dev/null; then
        put_the_apps_back_on_this_machine_s_docker "" "$running"
        log_error "The apps' images did not reach their Docker: they stay on this machine's."
        return 1
    fi

    databases=$(databases_of_the_apps)
    mongo=$(id_this_machine_sees_for "$MONGO_UID_IN_AN_APP")
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if ! chown -R "${mongo}:${mongo}" "$dir"; then
            put_the_apps_back_on_this_machine_s_docker "${moved_databases}${dir}"$'\n' "$running"
            log_error "The database in ${dir} could not be handed to the apps' Docker: the apps stay on this machine's."
            return 1
        fi
        moved_databases+="${dir}"$'\n'
    done <<< "$databases"

    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        in_the_app_builder_docker image inspect "$ref" >/dev/null 2>&1 || missing+=" ${ref}"
    done <<< "$refs"
    if [[ -n "$missing" ]]; then
        put_the_apps_back_on_this_machine_s_docker "$moved_databases" "$running"
        log_error "The apps' Docker lacks${missing} after the move: the apps stay on this machine's."
        return 1
    fi

    [[ -z "$containers" ]] || docker rm $(awk '{ print $1 }' <<< "$containers") >/dev/null 2>&1 || true
    [[ -z "$app_images" ]] || docker image rm $app_images >/dev/null 2>&1 || true
    log_info "The apps run in their own Docker now; their images left this machine's, their volumes stayed"
}

fall_back_to_this_machine_s_docker() {
    local env_file="$INSTALL_DIR/.env" local_file
    local_file="$(settings_directory "$env_file")/local.env"
    compose_in_dir rm -sf app-builder-docker app-builder-docker-home >/dev/null 2>&1 || true
    env_set "$local_file" APP_BUILDER_DOCKER host
    write_the_settings_the_app_builder_s_docker_needs "$local_file"
    render_settings "$env_file" "$local_file"
    log_error "The App Builder keeps this machine's Docker: APP_BUILDER_DOCKER=\"host\" is now in ${local_file}."
    log_error "  Once the cause above is fixed, remove that line and run ut-install again."
}

step_give_the_app_builder_its_docker() {
    case "$(env_get "$INSTALL_DIR/.env" COMPOSE_FILE 2>/dev/null || true)" in
        *compose.appbuilder-nested.yaml*) ;;
        *) return 0 ;;
    esac
    log_step "Giving the App Builder's apps a Docker of their own"
    load_the_profile_the_app_builder_docker_runs_under \
        && start_the_app_builder_docker \
        && give_the_app_builder_docker_its_traefik \
        && move_the_apps_off_this_machine_s_docker \
        && return 0
    fall_back_to_this_machine_s_docker
}
