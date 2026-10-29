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

# What the generated apps may take of this machine, together: a share of its
# memory per mille, by what else that memory serves, and a share of its cores.
APPS_MEMORY_PER_MILLE_BESIDE_A_GPU_SHARING_IT=125
APPS_MEMORY_PER_MILLE_BESIDE_A_GPU_OF_ITS_OWN=250
APPS_MEMORY_PER_MILLE_WITHOUT_A_MODEL_HERE=500
APPS_CORES_PERCENT=20
APPS_MEMORY_FLOOR_MB=8192
APPS_CORES_FLOOR=2
APPS_PROCESSES=4096

kind_of_machine_the_apps_share() {
    local gpu=$1 serves_a_model=$2
    if [[ "$serves_a_model" != yes ]]; then
        echo without-a-model-here
    elif [[ "$gpu" =~ GB10|GB200|GB300|GH200 ]]; then
        echo beside-a-gpu-sharing-it
    else
        echo beside-a-gpu-of-its-own
    fi
}

# "<memory> <cpus> <processes>" for a machine of this kind, memory and cores.
ceiling_of_the_apps_docker() {
    local kind=$1 memory_kb=$2 cores=$3 per_mille memory cpus
    case "$kind" in
        beside-a-gpu-sharing-it) per_mille=$APPS_MEMORY_PER_MILLE_BESIDE_A_GPU_SHARING_IT ;;
        beside-a-gpu-of-its-own) per_mille=$APPS_MEMORY_PER_MILLE_BESIDE_A_GPU_OF_ITS_OWN ;;
        *) per_mille=$APPS_MEMORY_PER_MILLE_WITHOUT_A_MODEL_HERE ;;
    esac
    memory=$(( memory_kb / 1024 * per_mille / 1000 ))
    (( memory >= APPS_MEMORY_FLOOR_MB )) || memory=$APPS_MEMORY_FLOOR_MB
    cpus=$(( cores * APPS_CORES_PERCENT / 100 ))
    (( cpus >= APPS_CORES_FLOOR )) || cpus=$APPS_CORES_FLOOR
    printf '%sM %s %s\n' "$memory" "$cpus" "$APPS_PROCESSES"
}

this_machine_serves_a_model() {
    local local_file=$1 compose_files
    the_inference_is_served_by_another_machine && return 1
    compose_files=$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || release_declares COMPOSE_FILE || true)
    [[ "$compose_files" != *compose.no-gpu.yaml* && "$compose_files" != *compose.remote-inference.yaml* ]]
}

kind_of_this_machine() {
    kind_of_machine_the_apps_share "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)" \
        "$(this_machine_serves_a_model "$1" && echo yes || echo no)"
}

# Computed at every install rather than kept in local.env, where a value nobody
# chose would outlive the hardware it was computed for.
settings_computed_for_this_machine() {
    local local_file=$1 compose_files memory_kb ceiling
    compose_files=$(env_get "$local_file" COMPOSE_FILE 2>/dev/null || release_declares COMPOSE_FILE || true)
    [[ "$compose_files" == *compose.appbuilder.yaml* ]] || return 0
    memory_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
    [[ -n "$memory_kb" ]] || return 0
    ceiling=$(ceiling_of_the_apps_docker "$(kind_of_this_machine "$local_file")" "$memory_kb" "$(nproc)")
    set -- $ceiling
    printf 'APP_BUILDER_DOCKER_MEMORY="%s"\nAPP_BUILDER_DOCKER_CPUS="%s"\nAPP_BUILDER_DOCKER_PIDS="%s"\n' "$1" "$2" "$3"
}

described() {
    case "$1" in
        beside-a-gpu-sharing-it) echo "a machine whose GPU shares its memory" ;;
        beside-a-gpu-of-its-own) echo "a machine whose GPU has memory of its own" ;;
        *) echo "a machine that serves no model" ;;
    esac
}

say_what_the_apps_may_take() {
    local local_file=$1 env_file="$INSTALL_DIR/.env" key chosen=""
    for key in APP_BUILDER_DOCKER_MEMORY APP_BUILDER_DOCKER_CPUS APP_BUILDER_DOCKER_PIDS; do
        env_get "$local_file" "$key" >/dev/null 2>&1 && chosen+=" ${key}"
    done
    log_info "The generated apps may take $(env_get "$env_file" APP_BUILDER_DOCKER_MEMORY) of memory, $(env_get "$env_file" APP_BUILDER_DOCKER_CPUS) CPUs and $(env_get "$env_file" APP_BUILDER_DOCKER_PIDS) processes between them, as computed for $(described "$(kind_of_this_machine "$local_file")")${chosen:+; set in local.env:${chosen}}"
}

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

# compose exec forwards its standard input: called inside a `while read` loop,
# it would take the lines the loop has yet to read.
in_the_app_builder_docker() { compose_in_dir exec -T app-builder-docker docker "$@" < /dev/null; }

load_into() {
    if [[ "$1" == docker ]]; then docker load -q; else compose_in_dir exec -T app-builder-docker docker load -q; fi
}

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
    local attempt said
    if ! said=$(compose_in_dir up -d app-builder-docker 2>&1); then
        log_error "The App Builder's Docker did not start: $(tail -1 <<< "$said")"
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
                && docker save "$APP_BUILDER_TRAEFIK_IMAGE" | load_into in_the_app_builder_docker >/dev/null; }; then
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

# The apps live on one Docker at a time. This file says it is their own, from
# the install that moved them there until the one that brings them back.
apps_home_marker() { printf '%s/app-builder-docker/holds-the-apps' "$(settings_directory "$INSTALL_DIR/.env")"; }
the_apps_live_in_their_docker() { [[ -f "$(apps_home_marker)" ]]; }

name_of() {
    if [[ "$1" == docker ]]; then printf "this machine's Docker"; else printf "the apps' Docker"; fi
}

# Every compose project the App Builder runs or ran: a workspace's own, its
# published stack (<id>--prod), and whatever a container under its data says.
# Compose takes a project's name in lower case, as the App Builder names its folders.
projects_of_the_app_builder() {
    local side=$1 data root dir name
    data=$(app_builder_data)
    for root in "$data/workspaces" "$data/prod-workspaces"; do
        for dir in "$root"/*/; do
            [[ -d "$dir" ]] || continue
            name=$(basename "$dir" | tr '[:upper:]' '[:lower:]')
            printf '%s\n%s--prod\n' "$name" "$name"
        done
    done
    "$side" ps -a --filter label=com.docker.compose.project \
        --format '{{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null \
        | awk -v root="$data/" 'index($2, root) == 1 { print $1 }' || true
}

images_the_apps_name() {
    local data file
    data=$(app_builder_data)
    for file in "$data"/workspaces/*/docker-compose.yml "$data"/prod-workspaces/*/docker-compose.yml; do
        [[ -f "$file" ]] || continue
        sed -n 's/^[[:space:]]*image:[[:space:]]*["'\'']\{0,1\}\([^"'\''[:space:]]*\).*/\1/p' "$file"
    done | { grep -v '\$' || true; } | sort -u
}

containers_of_the_apps() {
    local side=$1 projects=$2
    "$side" ps -a --filter label=com.docker.compose.project \
        --format '{{.ID}} {{.State}} {{.Label "com.docker.compose.project"}}' 2>/dev/null \
        | awk 'NR == FNR { wanted[$1] = 1; next } wanted[$3]' <(printf '%s\n' "$projects") - || true
}

# "<reference> <id> <size>", for each image compose built for these projects.
images_built_for_the_apps() {
    local side=$1 projects=$2 built
    built=$("$side" image ls -q --filter label=com.docker.compose.project 2>/dev/null | sort -u || true)
    [[ -n "$built" ]] || return 0
    "$side" image inspect --format '{{index .Config.Labels "com.docker.compose.project"}} {{.Id}} {{.Size}} {{join .RepoTags " "}}' $built 2>/dev/null \
        | awk 'NR == FNR { wanted[$1] = 1; next } wanted[$1] { for (i = 4; i <= NF; i++) print $i, $2, $3 }' <(printf '%s\n' "$projects") - || true
}

images_of_the_apps() {
    local side=$1 projects=$2 reference
    images_built_for_the_apps "$side" "$projects"
    images_the_apps_name | while IFS= read -r reference; do
        "$side" image inspect --format "${reference} {{.Id}} {{.Size}}" "$reference" 2>/dev/null || true
    done
}

images_the_other_side_lacks() {
    local side=$1 images=$2 reference id size
    while read -r reference id size; do
        [[ -n "$reference" ]] || continue
        [[ "$("$side" image inspect --format '{{.Id}}' "$reference" 2>/dev/null || true)" == "$id" ]] \
            || printf '%s %s %s\n' "$reference" "$id" "$size"
    done <<< "$images"
}

volumes_of_the_apps() {
    local side=$1 projects=$2
    "$side" volume ls --filter label=com.docker.compose.project \
        --format '{{.Name}} {{.Label "com.docker.compose.project"}}' 2>/dev/null \
        | awk 'NR == FNR { wanted[$1] = 1; next } wanted[$2]' <(printf '%s\n' "$projects") - || true
}

databases_of_the_apps() {
    local owner=$1 data dir
    data=$(app_builder_data)
    for dir in "$data"/workspaces/*/mongo-data "$data"/prod-workspaces/*/mongo-data; do
        [[ -d "$dir" && "$(stat -c %u "$dir")" == "$owner" ]] && printf '%s\n' "$dir"
    done
    return 0
}

# Runs a command in a volume as the root of its Docker, so that the files keep
# the owners their app sees: on this machine's through a throwaway container, in
# the apps' inside the user namespace their containers run in.
in_a_volume() {
    local side=$1 volume=$2 dir
    shift 2
    if [[ "$side" == docker ]]; then
        docker run --rm -i --user 0 --network none -v "${volume}:/volume" -w /volume \
            --entrypoint "$1" "$(env_get "$INSTALL_DIR/.env" APP_BUILDER_DOCKER_IMAGE)" "${@:2}"
        return
    fi
    dir=$(in_the_app_builder_docker volume inspect --format '{{.Mountpoint}}' "$volume") || return 1
    compose_in_dir exec -T -w "$dir" app-builder-docker \
        sh -c 'exec nsenter -U --preserve-credentials -t "$(cat "$XDG_RUNTIME_DIR/docker.pid")" "$@"' sh "$@"
}

entries_in_a_volume() { in_a_volume "$1" "$2" sh -c 'find . | wc -l' < /dev/null | tr -d ' '; }
bytes_in_a_volume() { in_a_volume "$1" "$2" du -sk . < /dev/null | awk '{ printf "%.0f\n", $1 * 1024 }'; }

volumes_the_other_side_holds_already() {
    local side=$1 volumes=$2 volume project
    while read -r volume project; do
        [[ -n "$volume" ]] && "$side" volume inspect "$volume" >/dev/null 2>&1 || continue
        [[ "$(entries_in_a_volume "$side" "$volume")" == 1 ]] || printf '%s %s\n' "$volume" "$project"
    done <<< "$volumes"
}

move_a_volume() {
    local from=$1 to=$2 volume=$3 line labels=()
    while IFS= read -r line; do
        [[ -z "$line" ]] || labels+=("$line")
    done < <("$from" volume inspect --format '{{range $k, $v := .Labels}}{{printf "--label=%s=%s\n" $k $v}}{{end}}' "$volume" 2>/dev/null)
    "$to" volume create ${labels[@]+"${labels[@]}"} "$volume" >/dev/null || return 1
    in_a_volume "$from" "$volume" tar -cf - --numeric-owner . < /dev/null \
        | in_a_volume "$to" "$volume" tar -xf - --numeric-owner || return 1
    [[ "$(entries_in_a_volume "$from" "$volume")" == "$(entries_in_a_volume "$to" "$volume")" ]]
}

put_the_apps_back() {
    local from=$1 to=$2 owner=$3 databases=$4 volumes=$5 running=$6 dir volume
    while IFS= read -r dir; do
        [[ -z "$dir" ]] || chown -R "${owner}:${owner}" "$dir" \
            || log_error "The database in ${dir} could not be given back to ${owner}: its app will not open it."
    done <<< "$databases"
    while IFS= read -r volume; do
        [[ -z "$volume" ]] || "$to" volume rm "$volume" >/dev/null 2>&1 || true
    done <<< "$volumes"
    [[ -z "$running" ]] || "$from" start $running >/dev/null 2>&1 || true
    compose_in_dir start app-builder >/dev/null 2>&1 || true
}

APPS_MOVED=""
APPS_STOPPED_BY_THE_MOVE=""

# Moves every app the App Builder built from one Docker to the other, archived
# ones included: their images are what restores them without npm, which a box
# with no network does not have. The Docker they leave keeps its copies.
move_the_apps() {
    local from=$1 to=$2 owner=$3 new_owner=$4
    local projects containers running images volumes databases taken needed free disk references
    local reference id size volume project dir filled="" moved_databases="" missing=""

    projects=$(projects_of_the_app_builder "$from" | sort -u)
    containers=$(containers_of_the_apps "$from" "$projects")
    running=$(awk '$2 == "running" { print $1 }' <<< "$containers")
    images=$(images_the_other_side_lacks "$to" "$(images_of_the_apps "$from" "$projects")")
    volumes=$(volumes_of_the_apps "$from" "$projects")
    databases=$(databases_of_the_apps "$owner")
    if [[ -z "${images}${volumes}${databases}" ]]; then
        log_info "No app on $(name_of "$from"): nothing to move"
        return 0
    fi

    taken=$(volumes_the_other_side_holds_already "$to" "$volumes")
    if [[ -n "$taken" ]]; then
        while read -r volume project; do
            log_error "${project}'s volume ${volume} has files in $(name_of "$to") already: nothing was moved, so that neither copy overwrites the other."
        done <<< "$taken"
        log_error "  Remove the copy that is out of date, then run ut-install again."
        return 1
    fi

    needed=$( { awk '{ print $3 }' <<< "$images"
                while read -r volume project; do
                    [[ -z "$volume" ]] || bytes_in_a_volume "$from" "$volume"
                done <<< "$volumes"; } | awk '{ total += $1 } END { printf "%.0f", total * 1.1 + 1000000000 }')
    disk=$([[ -d /var/lib/docker ]] && echo /var/lib/docker || echo /var/lib)
    free=$(df -B1 --output=avail "$disk" 2>/dev/null | tail -1 | tr -d ' ' || true)
    if [[ -z "$free" ]] || (( free < needed )); then
        log_error "Moving the apps needs $(( needed / 1000000000 )) GB free on ${disk}, which has $(( ${free:-0} / 1000000000 )): nothing was moved."
        return 1
    fi

    log_info "Moving the apps to $(name_of "$to"), archived ones included: $(grep -c . <<< "$images" || true) image(s), $(grep -c . <<< "$volumes" || true) volume(s), $(grep -c . <<< "$databases" || true) database(s)"
    compose_in_dir stop app-builder >/dev/null 2>&1 || true
    [[ -z "$running" ]] || "$from" stop $running >/dev/null 2>&1 || true

    references=$(awk '{ print $1 }' <<< "$images" | { grep -v '^$' || true; })
    if [[ -n "$references" ]] && ! "$from" save $references | load_into "$to" >/dev/null; then
        put_the_apps_back "$from" "$to" "$owner" "" "" "$running"
        log_error "The apps' images did not reach $(name_of "$to"): the apps stay on $(name_of "$from")."
        return 1
    fi
    while read -r reference id size; do
        [[ -z "$reference" || "$("$to" image inspect --format '{{.Id}}' "$reference" 2>/dev/null || true)" == "$id" ]] \
            || missing+=" ${reference}"
    done <<< "$images"
    if [[ -n "$missing" ]]; then
        put_the_apps_back "$from" "$to" "$owner" "" "" "$running"
        log_error "After the move, $(name_of "$to") lacks${missing}: the apps stay on $(name_of "$from")."
        return 1
    fi

    while read -r volume project; do
        [[ -n "$volume" ]] || continue
        filled+="${volume}"$'\n'
        if ! move_a_volume "$from" "$to" "$volume"; then
            put_the_apps_back "$from" "$to" "$owner" "" "$filled" "$running"
            log_error "${project}'s volume ${volume} could not be copied to $(name_of "$to"): the apps stay on $(name_of "$from")."
            return 1
        fi
    done <<< "$volumes"

    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        if ! chown -R "${new_owner}:${new_owner}" "$dir"; then
            put_the_apps_back "$from" "$to" "$owner" "${moved_databases}${dir}"$'\n' "$filled" "$running"
            log_error "The database in ${dir} could not be handed to $(name_of "$to"): the apps stay on $(name_of "$from")."
            return 1
        fi
        moved_databases+="${dir}"$'\n'
    done <<< "$databases"

    APPS_MOVED=yes
    APPS_STOPPED_BY_THE_MOVE=$running
    log_info "The apps' images, volumes and databases are in $(name_of "$to") now"
}

# What the apps left on the Docker they moved out of: their containers, the
# images built for them and their volumes. The images they only name stay.
let_go_of_the_apps_on() {
    local side=$1 projects containers images volumes
    projects=$(projects_of_the_app_builder "$side" | sort -u)
    containers=$(containers_of_the_apps "$side" "$projects" | awk '{ print $1 }')
    images=$(images_built_for_the_apps "$side" "$projects" | awk '{ print $1 }')
    volumes=$(volumes_of_the_apps "$side" "$projects" | awk '{ print $1 }')
    [[ -z "$containers" ]] || "$side" rm -f $containers >/dev/null 2>&1 || true
    [[ -z "$images" ]] || "$side" image rm $images >/dev/null 2>&1 || true
    [[ -z "$volumes" ]] || "$side" volume rm $volumes >/dev/null 2>&1 || true
    log_info "Removed from $(name_of "$side") what the apps left there: $(grep -c . <<< "$containers" || true) container(s), $(grep -c . <<< "$images" || true) image(s), $(grep -c . <<< "$volumes" || true) volume(s)"
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

fall_forward_to_the_apps_docker() {
    local env_file="$INSTALL_DIR/.env" local_file
    local_file="$(settings_directory "$env_file")/local.env"
    env_set "$local_file" APP_BUILDER_DOCKER nested
    write_the_settings_the_app_builder_s_docker_needs "$local_file"
    render_settings "$env_file" "$local_file"
    give_the_app_builder_docker_its_traefik || true
    log_error "The apps stay in their own Docker: APP_BUILDER_DOCKER=\"nested\" is now in ${local_file}."
    log_error "  Once the cause above is fixed, write \"host\" there again and run ut-install."
}

APPS_MOVED_INTO_THEIR_DOCKER=""

give_the_apps_their_docker() {
    log_step "Giving the App Builder's apps a Docker of their own"
    say_what_the_apps_may_take "$(settings_directory "$INSTALL_DIR/.env")/local.env"
    if ! { load_the_profile_the_app_builder_docker_runs_under \
            && start_the_app_builder_docker \
            && give_the_app_builder_docker_its_traefik; }; then
        if the_apps_live_in_their_docker; then
            die "The generated apps live in the App Builder's Docker, which did not start: they are out of reach until it does. Fix the cause above and run ut-install again."
        fi
        fall_back_to_this_machine_s_docker
        return 0
    fi
    the_apps_live_in_their_docker && return 0
    APPS_MOVED=""
    if ! move_the_apps docker in_the_app_builder_docker "$MONGO_UID_IN_AN_APP" "$(id_this_machine_sees_for "$MONGO_UID_IN_AN_APP")"; then
        fall_back_to_this_machine_s_docker
        return 0
    fi
    date -u +%Y-%m-%dT%H:%M:%SZ > "$(apps_home_marker)"
    APPS_MOVED_INTO_THEIR_DOCKER=$APPS_MOVED
}

# The way back starts the apps' Docker once more, to bring them out of it.
bring_the_apps_back_to_this_machine_s_docker() {
    local -x COMPOSE_FILE APP_BUILDER_DOCKER_IDS
    log_step "Bringing the App Builder's apps back to this machine's Docker"
    COMPOSE_FILE=$(env_get "$INSTALL_DIR/.env" COMPOSE_FILE)
    COMPOSE_FILE=${COMPOSE_FILE/compose.appbuilder-on-host.yaml/compose.appbuilder-nested.yaml}
    APP_BUILDER_DOCKER_IDS=$(dirname "$(apps_home_marker)")
    write_the_identities_of_the_app_builder_docker "$APP_BUILDER_DOCKER_IDS"
    load_the_profile_the_app_builder_docker_runs_under && start_the_app_builder_docker \
        || die "The generated apps live in the App Builder's Docker, which did not start, so they cannot come back to this machine's. Fix the cause above and run ut-install again, or remove APP_BUILDER_DOCKER=\"host\" from local.env to leave them there."
    if ! move_the_apps in_the_app_builder_docker docker "$(id_this_machine_sees_for "$MONGO_UID_IN_AN_APP")" "$MONGO_UID_IN_AN_APP"; then
        fall_forward_to_the_apps_docker
        return 0
    fi
    let_go_of_the_apps_on in_the_app_builder_docker
    rm -f "$(apps_home_marker)"
    log_info "The apps run on this machine's Docker again"
}

step_give_the_app_builder_its_docker() {
    case "$(env_get "$INSTALL_DIR/.env" COMPOSE_FILE 2>/dev/null || true)" in
        *compose.appbuilder-nested.yaml*) give_the_apps_their_docker ;;
        *compose.appbuilder-on-host.yaml*) the_apps_live_in_their_docker && bring_the_apps_back_to_this_machine_s_docker ;;
    esac
    return 0
}

the_app_builder_drives_its_docker() {
    local attempt
    for attempt in $(seq 30); do
        compose_in_dir exec -T app-builder docker version < /dev/null >/dev/null 2>&1 && return 0
        sleep 2
    done
    log_error "The App Builder did not reach the apps' Docker within a minute."
    return 1
}

# This machine's Docker keeps the apps' copies until the platform runs with
# them in their own: a start that fails puts them back as they were.
step_start_with_the_apps_where_they_went() {
    if step_start && { [[ -z "$APPS_MOVED_INTO_THEIR_DOCKER" ]] || the_app_builder_drives_its_docker; }; then
        [[ -z "$APPS_MOVED_INTO_THEIR_DOCKER" ]] || let_go_of_the_apps_on docker
        return 0
    fi
    [[ -n "$APPS_MOVED_INTO_THEIR_DOCKER" ]] || return 1
    log_error "The platform did not start with the apps in their own Docker: they go back to this machine's."
    compose_in_dir stop app-builder >/dev/null 2>&1 || true
    let_go_of_the_apps_on in_the_app_builder_docker
    put_the_apps_back docker in_the_app_builder_docker "$MONGO_UID_IN_AN_APP" \
        "$(databases_of_the_apps "$(id_this_machine_sees_for "$MONGO_UID_IN_AN_APP")")" "" "$APPS_STOPPED_BY_THE_MOVE"
    rm -f "$(apps_home_marker)"
    APPS_MOVED_INTO_THEIR_DOCKER=""
    fall_back_to_this_machine_s_docker
    step_start
}
