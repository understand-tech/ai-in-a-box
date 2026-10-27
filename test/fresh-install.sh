#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/images.sh"
WORK_DIR="$(mktemp -d)"
VERSION="${VERSION:-0.0.0-test}"

cleanup() {
    docker run --rm -v "$WORK_DIR":/w "$ALPINE_IMAGE" sh -c 'rm -rf /w/..?* /w/.[!.]* /w/*' >/dev/null 2>&1
    [[ -n "${WITH_OPENSSL_IMAGE:-}" ]] && docker image rm "$WITH_OPENSSL_IMAGE" >/dev/null 2>&1
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    GREEN=""; RED=""; DIM=""; BOLD=""; NC=""
fi

PASSED=0
FAILED=0
FAILURES=()

property() {
    local description=$1; shift
    # PROPERTY_FILTER runs one line instead of all of them: the discrimination
    # harness breaks one thing at a time.
    [[ -n "${PROPERTY_FILTER:-}" && "$description" != *"$PROPERTY_FILTER"* ]] && return 0
    local output
    if output=$("$@" 2>&1); then
        printf '  %s✔%s %s\n' "$GREEN" "$NC" "$description"
        PASSED=$((PASSED + 1))
    else
        printf '  %s✘%s %s\n' "$RED" "$NC" "$description"
        printf '%s      %s%s\n' "$DIM" "${output//$'\n'/$'\n'      }" "$NC"
        FAILED=$((FAILED + 1))
        FAILURES+=("$description")
    fi
}

# The installer is under test here, not the compiler: stand-ins take the place
# of the Go builds and of ut-arbiter, so this suite needs neither Go nor the
# network. A package that did not build stops the suite: every property below
# would otherwise pass on an install that never ran.
build_the_package() {
    local arch tool
    for tool in ut-send ut-setup ut-pair ut-arbiter; do
        install -d "$WORK_DIR/$tool-builds"
        for arch in arm64 amd64; do
            printf '#!/bin/sh\necho stand-in\n' > "$WORK_DIR/$tool-builds/$tool-linux-$arch"
        done
    done
    docker run --rm -v "$REPO_ROOT":/src:ro -v "$WORK_DIR":/out -w /src "$DEBIAN_IMAGE" \
        sh -c "OUT_DIR=/out UT_SEND_BUILDS=/out/ut-send-builds UT_SETUP_BUILDS=/out/ut-setup-builds UT_PAIR_BUILDS=/out/ut-pair-builds UT_ARBITER_BUILDS=/out/ut-arbiter-builds ./packaging/build-deb.sh '$VERSION'" >/dev/null
    [[ -f "$WORK_DIR/understandtech_${VERSION}_all.deb" ]] || {
        echo "The package did not build — nothing below would mean anything." >&2
        exit 1
    }
}

# The installer talks to a Docker daemon, to nvidia-smi and to df. Handing it the
# real ones would have it log into a registry and create volumes on whatever
# machine runs this; stubs answer the handful of questions it asks, and are what
# lets a starting state be set up at all — "a mongo volume is already there" is a
# sentence only a stub can say.
#
# df is stubbed for a second reason: the preflight needs 250 GB and a GitHub
# runner offers 91, so left alone this suite passes or fails on the disk of
# whoever runs it rather than on the installer. It was green here on 378 GB and
# red in CI on the same commit.
write_machine_stubs() {
    cat > "$WORK_DIR/stubs.sh" <<'STUBS'
mkdir -p /stub
cat > /stub/docker <<'DOCKER'
#!/bin/sh
printf '%s\n' "$*" >> /stub/docker-calls
case "$1 $2" in
    "version --format")   echo "29.0.0" ;;
    "compose version")    echo "v5.0.0" ;;
    "info --format")      case "$*" in *Architecture*) echo aarch64 ;; *) echo '{"nvidia":{}}' ;; esac ;;
    "volume inspect")     case "$*" in *mongodb*) [ "${MONGO_VOLUME_EXISTS:-no}" = yes ] ;; *) [ "${WEIGHT_VOLUMES_EXIST:-yes}" = yes ] ;; esac ;;
    "network inspect")    exit 1 ;;
    "network create")     exit "${NETWORK_CREATE_EXIT:-0}" ;;
    "compose pull")       exit "${PULL_EXIT:-0}" ;;
    "compose --progress") case "$*" in *" pull") exit "${PULL_EXIT:-0}" ;; esac ;;
    "login "*)            cat > /stub/docker-login-stdin ;;
    *)                    exit 0 ;;
esac
DOCKER
cat > /stub/nvidia-smi <<'NVIDIA'
#!/bin/sh
case "$1" in
    -L) echo "GPU 0: NVIDIA GB10 (UUID: GPU-test)" ;;
    *)  echo "NVIDIA GB10" ;;
esac
NVIDIA
cat > /stub/df <<'DF'
#!/bin/sh
echo "Avail"
echo "${DISK_AVAIL_BYTES:-$((400 * 1000 * 1000 * 1000))}"
DF
chmod +x /stub/docker /stub/nvidia-smi /stub/df
mkdir -p /etc/cdi && : > /etc/cdi/nvidia.yaml
: > /stub/docker-calls
export PATH=/stub:$PATH
start_a_fake_keygen() {
    : > "/w/$1/keygen-requests"
    python3 /w/licenses/fake-keygen.py 8765 "/w/$1/keygen-requests" /w/licenses/certificates &
    for _ in $(seq 50); do curl -s -o /dev/null http://127.0.0.1:8765/ && return 0; sleep 0.1; done
}
STUBS
}

# Each case is a machine in a known state. The installer is run to the point
# where it would pull images, which is as far as this can go: the images are
# private and weigh tens of gigabytes. Everything that has ever broken here
# broke before that line.
run_install_from_state() {
    local state=$1 domain=${2:-box.example.test} domain_arg
    local probe="$WORK_DIR/$state"
    mkdir -p "$probe"

    # "-" leaves --domain off, which is the only way to see what the installer
    # decides on its own rather than what the caller told it.
    domain_arg="--domain $domain"
    [[ "$domain" == "-" ]] && domain_arg=""

    cat > "$WORK_DIR/walk-$state.sh" <<PROBE
set -u
. /w/stubs.sh
dpkg -i --force-depends /out/understandtech_${VERSION}_all.deb >/dev/null 2>&1
install -d /var/lib/understandtech && cat /usr/share/understandtech/models/weights/*.txt | awk '!/^#/ && NF { print \$1 }' > /var/lib/understandtech/weights-placed.txt

$(state_setup "$state")

UT_REGISTRY_TOKEN=${INSTALL_TOKEN-test-token} \\
    ${INSTALL_COMMAND:-ut-install} $domain_arg > /w/$state/output.txt 2>&1
printf 'EXIT=%s\n' "\$?" >> /w/$state/output.txt

cp /etc/understandtech/.env /w/$state/env 2>/dev/null || : > /w/$state/env
cp /etc/understandtech/local.env /w/$state/local-env 2>/dev/null || : > /w/$state/local-env
cp /var/lib/understandtech/weights-placed.txt /w/$state/weights-placed 2>/dev/null || : > /w/$state/weights-placed
ls -d /var/lib/understandtech/weights-download > /w/$state/staging-left 2>/dev/null || : > /w/$state/staging-left
cp /opt/understandtech/.env /w/$state/checkout-env 2>/dev/null || : > /w/$state/checkout-env
cp /stub/docker-calls /w/$state/docker-calls 2>/dev/null || : > /w/$state/docker-calls
cp /stub/docker-login-stdin /w/$state/login-stdin 2>/dev/null || : > /w/$state/login-stdin
cp /etc/understandtech/license /w/$state/license 2>/dev/null || : > /w/$state/license
cp /etc/understandtech/machine.lic /w/$state/machine 2>/dev/null || : > /w/$state/machine
cp /etc/understandtech/license-request.json /w/$state/license-request 2>/dev/null || : > /w/$state/license-request
ls /etc/understandtech/*.caddy /etc/understandtech/inference-ca-bundle.pem > /w/$state/link-files 2>/dev/null || :
stat -c '%a %U' /etc/understandtech/backup-ssh/id_ed25519 > /w/$state/backup-key-mode 2>/dev/null || : > /w/$state/backup-key-mode
cat /etc/understandtech/backup-ssh/id_ed25519.pub > /w/$state/backup-key-pub 2>/dev/null || : > /w/$state/backup-key-pub
sha256sum /etc/understandtech/backup-ssh/id_ed25519 2>/dev/null | cut -d' ' -f1 > /w/$state/backup-key-sum || : > /w/$state/backup-key-sum
stat -c '%a %U' /etc/understandtech/license > /w/$state/license-mode 2>/dev/null || : > /w/$state/license-mode
stat -c '%a %U' /etc/understandtech/machine.lic > /w/$state/machine-mode 2>/dev/null || : > /w/$state/machine-mode
chmod -R a+rw /w/$state
PROBE

    docker run --rm \
        -v "$WORK_DIR":/w -v "$WORK_DIR":/out \
        -e MONGO_VOLUME_EXISTS="${MONGO_VOLUME_EXISTS:-no}" \
        -e NETWORK_CREATE_EXIT="${NETWORK_CREATE_EXIT:-0}" \
        -e PULL_EXIT="${PULL_EXIT:-9}" \
        -e DISK_AVAIL_BYTES="${DISK_AVAIL_BYTES:-}" \
        "${WALK_IMAGE:-$DEBIAN_IMAGE}" bash /w/walk-$state.sh >/dev/null 2>&1
}

state_setup() {
    case "$1" in
        bare)          echo ': # nothing beyond the package' ;;
        install_runs_through) echo ': # like bare, but the pull is allowed to succeed' ;;
        # A checkout of the repository, the way an operator who cloned it has one.
        # The package is installed too, which is what makes the choice interesting.
        launched_from_a_checkout|checkout_but_no_key)
            echo 'install -d /srv/clone && cp -a /usr/share/understandtech/. /srv/clone/ && install -d /srv/clone/.git /srv/clone/bin && cp /usr/bin/ut-install /srv/clone/bin/ut-install && cp -a /usr/bin/ut-install.d /srv/clone/bin/' ;;
        empty_settings) echo 'install -m 600 /dev/null /etc/understandtech/.env' ;;
        # The packaged ut-license trusts Keygen's key and asks Keygen; these states
        # swap in one that trusts the suite's key and asks the fake Keygen, which
        # runs in every one of them so that a request nobody should make is seen.
        licensed|license_ended|license_taken|licensed_elsewhere|licensed_by_file|licensed_by_an_altered_file)
            echo "cp /w/licenses/ut-license /usr/bin/ut-license && start_a_fake_keygen $1" ;;
        # The same copy, with no Keygen behind it: the machine cannot reach it.
        license_with_no_network)
            echo "cp /w/licenses/ut-license /usr/bin/ut-license && : > /w/$1/keygen-requests" ;;
        # A license issued with no registry access, as one made by hand in Keygen is.
        licensed_without_a_token|licensed_without_a_token_pulling_nothing)
            echo "cp /w/licenses/ut-license /usr/bin/ut-license && start_a_fake_keygen $1 && install -d -m 750 /etc/understandtech && install -m 600 /w/licenses/keys/active.key /etc/understandtech/license && install -m 600 /w/licenses/files/untokened.lic /etc/understandtech/machine.lic" ;;
        license_stored|licensed_offline)
            echo "cp /w/licenses/ut-license /usr/bin/ut-license && start_a_fake_keygen $1 && install -d -m 750 /etc/understandtech && install -m 600 /w/licenses/keys/active.key /etc/understandtech/license && install -m 600 /w/licenses/files/valid.lic /etc/understandtech/machine.lic" ;;
        license_tampered)
            echo "cp /w/licenses/ut-license /usr/bin/ut-license && start_a_fake_keygen $1 && install -d -m 750 /etc/understandtech && install -m 600 /w/licenses/keys/active.key /etc/understandtech/license && install -m 600 /w/licenses/files/tampered.lic /etc/understandtech/machine.lic" ;;
        license_renewed)
            echo "cp /w/licenses/ut-license /usr/bin/ut-license && start_a_fake_keygen $1 && install -d -m 750 /etc/understandtech && install -m 600 /w/licenses/keys/active.key /etc/understandtech/license && install -m 600 /w/licenses/files/file_ended.lic /etc/understandtech/machine.lic" ;;
        license_from_another_machine)
            echo "cp /w/licenses/ut-license /usr/bin/ut-license && start_a_fake_keygen $1 && install -d -m 750 /etc/understandtech && install -m 600 /w/licenses/keys/active.key /etc/understandtech/license && install -m 600 /w/licenses/files/elsewhere.lic /etc/understandtech/machine.lic" ;;
        license_of_the_old_format)
            echo "cp /w/licenses/ut-license /usr/bin/ut-license && start_a_fake_keygen $1 && install -d -m 750 /etc/understandtech && install -m 600 /w/licenses/keys/old_format.key /etc/understandtech/license" ;;
        already_set)   echo 'install -m 600 /usr/share/understandtech/release.env /etc/understandtech/.env' ;;
        no_settings_dir) echo 'rm -rf /etc/understandtech' ;;
        pools_full)    echo ': # the daemon refuses through the stub' ;;
        disk_too_small) echo ': # the free space is answered through the stub' ;;
        # Every other state stubs nvidia-smi, so a machine with no accelerator is
        # the one where that stub is taken away. Declared, the settings file says
        # the inference is elsewhere; undeclared, nothing does.
        no_accelerator_declared|no_accelerator_on_a_smaller_disk)
            echo 'rm -f /stub/nvidia-smi && install -d -m 750 /etc/understandtech && printf '"'"'COMPOSE_FILE="compose.yaml:compose.no-gpu.yaml"\n'"'"' > /etc/understandtech/.env' ;;
        no_accelerator_undeclared|no_accelerator_by_flag)
            echo 'rm -f /stub/nvidia-smi' ;;
        # local.env written before the first install, the way the warning itself
        # tells an operator to write it.
        openai_key_given)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'OA_KEY="sk-test-kept"\n'"'"' > /etc/understandtech/local.env' ;;
        # An entry a team adds to the registry, served by vLLM.
        model_on_vllm|test_vllm_forced_on_nim)
            echo 'cp /w/models/test-vllm.env /usr/share/understandtech/models/ && cp /w/models/proven/test-vllm.vllm.gb10.md /usr/share/understandtech/models/proven/' ;;
        # A GPU no model has been proven on: the stub answers H100 rather than GB10.
        model_on_an_unproven_gpu|models_listed_on_an_unproven_gpu)
            echo 'printf "#!/bin/sh\ncase \"\$1\" in -L) echo \"GPU 0: NVIDIA H100 80GB HBM3 (UUID: GPU-test)\" ;; *) echo \"NVIDIA H100 80GB HBM3\" ;; esac\n" > /stub/nvidia-smi && chmod +x /stub/nvidia-smi' ;;
        # A box installed with --model, whose entry the release has since changed.
        model_kept_by_name)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'UT_MODEL="qwen3.8-27b-nvfp4"\nNIM_LLM_PASSTHROUGH_ARGS=--gpu-memory-utilization 0.10\n'"'"' > /etc/understandtech/local.env' ;;
        compute_node_from_a_machine_without_gpu)
            echo 'rm -f /stub/nvidia-smi' ;;
        # A platform an older release linked to its compute node by key and root.
        linked_by_key_before)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'COMPOSE_FILE="compose.yaml:compose.remote-inference.yaml"\nCOMPOSE_PROFILES=""\nVLLM_LLM_BASE_URL="https://node.example.test:9444/v1"\nVLLM_VLM_BASE_URL="https://node.example.test:9444/v1"\nUT_INFERENCE_CA_BUNDLE="/etc/understandtech/inference-ca-bundle.pem"\n'"'"' > /etc/understandtech/local.env && echo root > /etc/understandtech/inference-ca-bundle.pem' ;;
        # A second machine set up the way docs/certificates-and-dns.md says, reached by IP.
        compute_node_runs_through)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'COMPOSE_FILE="compose.yaml:compose.compute.yaml"\nCOMPOSE_PROFILES="nim"\nUT_INFERENCE_ADDRESS="192.0.2.10"\n'"'"' > /etc/understandtech/local.env' ;;
        # A folder ut-get --prepare never finished: its tools, none of the images.
        folder_without_its_images)
            echo 'install -d /w/folder_without_its_images/folder/tools && echo arm64 > /w/folder_without_its_images/folder/architecture && : > /w/folder_without_its_images/folder/understandtech_'"$VERSION"'_all.deb && : > /w/folder_without_its_images/folder/tools/distribution.tar && : > /w/folder_without_its_images/folder/tools/stable.tar && sed -i "s|^UT_RELEASE_VERSION=.*|UT_RELEASE_VERSION=\"'"$VERSION"'+0123abc\"|" /usr/share/understandtech/release.env' ;;
        # The same folder, on a box whose settings file runs its own engine image.
        folder_without_the_settings_image)
            echo 'install -d /w/folder_without_the_settings_image/folder/tools && echo arm64 > /w/folder_without_the_settings_image/folder/architecture && : > /w/folder_without_the_settings_image/folder/understandtech_'"$VERSION"'_all.deb && : > /w/folder_without_the_settings_image/folder/tools/distribution.tar && : > /w/folder_without_the_settings_image/folder/tools/stable.tar && install -d -m 750 /etc/understandtech && printf '"'"'NIM_IMAGE="ghcr.io/understand-tech/engines/nim:2.0.13@sha256:%064d"\n'"'"' 0 > /etc/understandtech/local.env' ;;
        # A settings file still naming the vision engine the release dropped.
        vision_engine_gone)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'VLLM_VLM_BASE_URL="http://nim-vlm:8000/v1"\n'"'"' > /etc/understandtech/local.env' ;;
        # A folder prepared for a compute node, carried to a box installing everything.
        folder_for_another_role)
            echo 'install -d /w/folder_for_another_role/folder && echo arm64 > /w/folder_for_another_role/folder/architecture && echo compute > /w/folder_for_another_role/folder/role && : > /w/folder_for_another_role/folder/understandtech_'"$VERSION"'_all.deb' ;;
        # A folder prepared for the release before, carried to a box installing this one.
        folder_of_another_release)
            echo 'install -d /w/folder_of_another_release/folder && echo arm64 > /w/folder_of_another_release/folder/architecture && : > /w/folder_of_another_release/folder/understandtech_0.0.1-other_all.deb' ;;
        # A folder ut-get --prepare wrote for an x86 control plane, carried to a GB10.
        folder_for_another_processor)
            echo 'install -d /w/folder_for_another_processor/folder && echo amd64 > /w/folder_for_another_processor/folder/architecture' ;;
        # A box once installed from a folder, now installed with the network again.
        installed_from_a_folder_before)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'API_IMAGE="127.0.0.1:15000/understand-tech/ut-api-customer@sha256:%064d"\nOA_KEY="kept"\n'"'"' 0 > /etc/understandtech/local.env' ;;
        # What every release before the engine had a key shipped, carried into local.env.
        engine_key_left_empty)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'VLLM_API_KEY="EMPTY"\n'"'"' > /etc/understandtech/local.env' ;;
        # A checkout that set its origins in full, on the address it had then.
        origins_on_an_old_domain)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'UT_DOMAIN="old.example"\nEXTRA_ALLOWED_ORIGINS="https://admin.old.example,https://llms.old.example,https://old.example"\n'"'"' > /etc/understandtech/local.env' ;;
        no_accelerator_pointed_at_a_real_machine)
            echo 'rm -f /stub/nvidia-smi && install -d -m 750 /etc/understandtech && printf '"'"'VLLM_LLM_BASE_URL="https://inference.example.test/v1"\n'"'"' > /etc/understandtech/local.env' ;;
        # A release dated in the future is the same arithmetic as a clock in the
        # past, and it needs no stub around date, which everything else uses.
        clock_before_the_release)
            echo "sed -i 's|^UT_RELEASE_BUILT_AT=.*|UT_RELEASE_BUILT_AT=\"4102444800\"|' /usr/share/understandtech/release.env" ;;
        # What an earlier install leaves in the settings, secrets included, looked at
        # by the check the page runs first.
        installed_and_checked)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'UT_DOMAIN="carried.example"\nUT_RELEASE_VERSION="2026.10.0-rc16"\nUT_MODEL="qwen3.8-27b-nvfp4"\nJWT_SECRET="neverinanevent0123456789abcdef0123456789abcd"\n'"'"' > /etc/understandtech/.env && printf '"'"'UT1-license-never-in-an-event\n'"'"' > /etc/understandtech/license' ;;
        # A first install online: nothing placed yet, and a stand-in for Hugging
        # Face that serves the files of two small pinned lists, one of them altered.
        weights_from_the_network)
            echo 'rm -f /var/lib/understandtech/weights-placed.txt && cp /w/weights/lists/*.txt /usr/share/understandtech/models/weights/ && cp /w/weights/curl /stub/curl' ;;
        weights_altered_on_the_way)
            echo 'rm -f /var/lib/understandtech/weights-placed.txt && cp /w/weights/lists/*.txt /usr/share/understandtech/models/weights/ && cp /w/weights/curl /stub/curl && sed -i "s/^[0-9a-f]* /0000000000000000000000000000000000000000000000000000000000000000 /" /usr/share/understandtech/models/weights/platform.txt' ;;
        orphan_volume) echo ': # the volume is asserted through the stub' ;;
        volume_with_shipped_password)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'MONGODB_USERNAME="mongoadmin"\nMONGODB_PASSWORD="12345678"\n'"'"' > /etc/understandtech/local.env' ;;
        previous_checkout)
            echo 'install -d /opt/understandtech && printf '"'"'UT_DOMAIN="carried.example"\nJWT_SECRET="keptfromthecheckout0123456789abcdef0123456789ab"\nLOG_LEVEL="WARNING"\nAPP_BUILDER_TOKEN_ENCRYPTION_KEY="a2VwdGZyb210aGVjaGVja291dDAxMjM0NTY3ODlhYmM="\n'"'"' > /opt/understandtech/.env' ;;
        checkout_without_domain)
            echo 'install -d /opt/understandtech && printf '"'"'PUBLIC_BASE_URL="https://named.by.the.urls"\nBACKEND_URL="https://named.by.the.urls/api"\nJWT_SECRET="keptfromthecheckout0123456789abcdef0123456789ab"\n'"'"' > /opt/understandtech/.env' ;;
        # /w is bind-mounted from the host, so a directory under it sits on another
        # filesystem than the container's own disk — what a mounted NAS share is.
        backup_destination_mounted)
            echo 'install -d /w/backup_destination_mounted/nas && install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_DESTINATION="/w/backup_destination_mounted/nas"\n'"'"' > /etc/understandtech/local.env' ;;
        backup_destination_not_mounted)
            echo 'install -d /mnt/nas && install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_DESTINATION="/mnt/nas"\n'"'"' > /etc/understandtech/local.env' ;;
        # What an install that already sends its backup to a share leaves behind,
        # replayed for an update while nothing is mounted at that path.
        backup_destination_gone_on_an_update)
            echo 'install -d /mnt/nas && install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_DESTINATION="/mnt/nas"\nCOMPOSE_FILE="compose.yaml:compose.backup-mount.yaml"\n'"'"' > /etc/understandtech/local.env' ;;
        backup_over_sftp)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_REPOSITORY="sftp:backup@nas.example.test:/appliance"\n'"'"' > /etc/understandtech/local.env' ;;
        # The destination already knows this key: an install must not replace it.
        backup_over_sftp_with_its_key)
            echo 'install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_REPOSITORY="sftp:backup@nas.example.test:/appliance"\n'"'"' > /etc/understandtech/local.env && install -d -m 700 /etc/understandtech/backup-ssh && echo the-key-the-nas-knows > /etc/understandtech/backup-ssh/id_ed25519 && chmod 600 /etc/understandtech/backup-ssh/id_ed25519' ;;
        backup_in_two_places)
            echo 'install -d /w/backup_in_two_places/nas && install -d -m 750 /etc/understandtech && printf '"'"'BACKUP_FILES_DESTINATION="/w/backup_in_two_places/nas"\nBACKUP_FILES_REPOSITORY="s3:https://s3.example.test/appliance"\n'"'"' > /etc/understandtech/local.env' ;;
        *)             echo ': ' ;;
    esac
}

output_of()   { cat "$WORK_DIR/$1/output.txt" 2>/dev/null; }
settings_of() { cat "$WORK_DIR/$1/env" 2>/dev/null; }

# Every state but install_runs_through stops at the pull. A pull the stub no
# longer recognises lets them all run through to the last screen, where the
# role line repeats what several properties look for.
the_walk_stops_where_the_images_would_download() {
    local output
    output=$(output_of bare)
    grep -q 'Image pull failed' <<< "$output" && ! grep -q 'Starting services' <<< "$output" && return 0
    echo "$output"
    return 1
}

reached_the_pull() {
    local state=$1
    grep -q 'Downloading images' <<< "$(output_of "$state")" && return 0
    echo "$(output_of "$state")"
    return 1
}

setting_is_filled() {
    local state=$1 key=$2 value
    value=$(grep -m1 "^${key}=" <<< "$(settings_of "$state")" | cut -d= -f2- | tr -d '"')
    [[ -n "$value" ]] && return 0
    echo "${key} is empty or absent in the settings written from state '${state}'"
    return 1
}

every_required_setting_is_filled() {
    local state=$1 key missing=()
    while read -r key; do
        [[ -n "$key" ]] || continue
        setting_is_filled "$state" "$key" >/dev/null || missing+=("$key")
    done <<< "$(grep -ohE '\$\{[A-Z_][A-Z0-9_]*:\?' "$REPO_ROOT"/compose*.yaml \
        | sed 's/^\${//; s/:?$//' | sort -u)"
    (( ${#missing[@]} == 0 )) && return 0
    echo "nothing filled these in: ${missing[*]}"
    echo "$(output_of "$state")"
    return 1
}

the_settings_render_a_stack() {
    local state=$1 render
    render="$WORK_DIR/render-$state"
    mkdir -p "$render"
    cp "$REPO_ROOT"/compose*.yaml "$render/"
    settings_of "$state" > "$render/.env"
    ( cd "$render" && docker compose config >/dev/null 2>"$WORK_DIR/render-err.txt" ) && return 0
    head -3 "$WORK_DIR/render-err.txt"
    return 1
}

checkout_of() { cat "$WORK_DIR/$1/checkout-env" 2>/dev/null; }

the_checkout_settings_are_carried_over() {
    local settings
    settings=$(settings_of previous_checkout)
    grep -q 'keptfromthecheckout' <<< "$settings" \
        || { echo "the secret was regenerated instead of carried over"; return 1; }
    grep -q '^LOG_LEVEL="WARNING"' <<< "$settings" \
        || { echo "a setting the customer had changed was lost"; return 1; }
    return 0
}

the_address_comes_from_the_checkout() {
    local settings
    settings=$(settings_of previous_checkout)
    grep -q '^UT_DOMAIN="carried.example"' <<< "$settings" && return 0
    echo "the address became $(grep -m1 '^UT_DOMAIN=' <<< "$settings")"
    return 1
}

the_address_is_read_from_the_urls() {
    local settings
    settings=$(settings_of checkout_without_domain)
    grep -q '^UT_DOMAIN="named.by.the.urls"' <<< "$settings" && return 0
    echo "the address became $(grep -m1 '^UT_DOMAIN=' <<< "$settings")"
    return 1
}

the_checkout_is_left_alone() {
    grep -q 'keptfromthecheckout' <<< "$(checkout_of previous_checkout)" && return 0
    echo "the checkout's own .env was changed or removed"
    return 1
}

the_builder_key_comes_from_the_checkout() {
    local settings
    settings=$(settings_of previous_checkout)
    grep -q '^APP_BUILDER_TOKEN_ENCRYPTION_KEY="a2VwdGZyb210aGVjaGVja291dDAxMjM0NTY3ODlhYmM="' <<< "$settings" && return 0
    echo "the key became $(grep -m1 '^APP_BUILDER_TOKEN_ENCRYPTION_KEY=' <<< "$settings") — every GitLab token the App Builder stored is now unreadable"
    return 1
}

secrets_are_not_the_shipped_ones() {
    local state=$1 mine
    if grep -q '^JWT_SECRET=' "$REPO_ROOT/release.env"; then
        echo "JWT_SECRET ships in release.env — it is meant to be generated, never shipped"
        return 1
    fi
    mine=$(grep -m1 '^JWT_SECRET=' <<< "$(settings_of "$state")" | cut -d= -f2- | tr -d '"')
    [[ ${#mine} -ge 32 ]] && return 0
    echo "JWT_SECRET is '${mine}' — too short to be a generated secret"
    return 1
}

the_builder_key_is_one_fernet_accepts() {
    local key bytes
    key=$(grep -m1 '^APP_BUILDER_TOKEN_ENCRYPTION_KEY=' <<< "$(settings_of bare)" | cut -d= -f2- | tr -d '"')
    bytes=$(printf '%s' "$key" | tr -- '-_' '+/' | base64 -d 2>/dev/null | wc -c | tr -d ' ')
    [[ ${#key} -eq 44 && "$bytes" == 32 ]] && return 0
    echo "APP_BUILDER_TOKEN_ENCRYPTION_KEY is '${key}' — Fernet wants 32 bytes in URL-safe base64"
    return 1
}

two_installs_do_not_share_a_secret() {
    local key a b
    for key in JWT_SECRET APP_BUILDER_TOKEN_ENCRYPTION_KEY; do
        a=$(grep -m1 "^${key}=" <<< "$(settings_of bare)" | cut -d= -f2-)
        b=$(grep -m1 "^${key}=" <<< "$(settings_of empty_settings)" | cut -d= -f2-)
        [[ -n "$a" && "$a" != "$b" ]] && continue
        echo "two separate installs produced the same ${key}"
        return 1
    done
    return 0
}

running_it_again_changes_nothing() {
    local before after
    before=$(settings_of already_set | grep -c .)
    run_install_from_state already_set >/dev/null 2>&1
    after=$(settings_of already_set | grep -c .)
    [[ "$before" == "$after" ]] && return 0
    echo "the settings went from ${before} lines to ${after} on a second run"
    return 1
}

# 91 GB is what a GitHub runner actually offers, and what sent this suite red
# before df was stubbed. An operator reads the two numbers or has nothing to act
# on, so the refusal has to carry both.
the_preflight_stops_on_a_disk_too_small() {
    local output
    output=$(output_of disk_too_small)
    grep -qE 'Disk: 91 GB free on .* [0-9]+ GB needed' <<< "$output" \
        && ! grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

# The name in the Python traceback is OPENAI_API_KEY, which exists nowhere in
# this appliance: an install that left OA_KEY empty came up as an API restarting
# in a loop, behind a browser page that showed only the last line.
the_install_gives_the_api_the_key_it_needs_to_start() {
    local output settings
    output=$(output_of bare)
    settings=$(settings_of bare)
    grep -q 'OA_KEY set to "not-configured"' <<< "$output" \
        && grep -qx 'OA_KEY="not-configured"' <<< "$settings" && return 0
    echo "$output"
    grep '^OA_KEY' <<< "$settings"
    return 1
}

an_openai_key_given_is_never_replaced() {
    local settings
    settings=$(settings_of openai_key_given)
    grep -qx 'OA_KEY="sk-test-kept"' <<< "$settings" && return 0
    grep '^OA_KEY' <<< "$settings"
    echo "$(output_of openai_key_given)"
    return 1
}

a_model_on_nim_is_set_with_no_vllm_overlay() {
    local settings
    settings=$(cat "$WORK_DIR/model_on_nim/local-env" 2>/dev/null)
    grep -qxF "$(grep '^NIM_LLM_PASSTHROUGH_ARGS=' "$REPO_ROOT/models/qwen3.8-27b-nvfp4.env")" <<< "$settings" \
        && ! grep -q 'compose.engine-vllm.yaml' <<< "$settings" \
        && grep -q 'Model qwen3.8-27b-nvfp4, served by NIM' <<< "$(output_of model_on_nim)" && return 0
    grep -E '^(NIM_LLM_PASSTHROUGH_ARGS|COMPOSE_FILE)=' <<< "$settings" | cut -c1-120
    output_of model_on_nim | tail -4
    return 1
}

a_model_on_vllm_brings_its_engine_and_its_arguments_whole() {
    local settings
    settings=$(cat "$WORK_DIR/model_on_vllm/local-env" 2>/dev/null)
    grep -q '^COMPOSE_FILE=.*compose.engine-vllm.yaml' <<< "$settings" \
        && grep -qxF 'VLLM_ENGINE_ARGS=--trust-remote-code --override-generation-config {"temperature":0.2,"top_p":0.9}' <<< "$settings" \
        && grep -q 'Model test-vllm, served by vLLM' <<< "$(output_of model_on_vllm)" && return 0
    grep -E '^(VLLM_ENGINE_ARGS|COMPOSE_FILE)=' <<< "$settings"
    output_of model_on_vllm | tail -4
    return 1
}

a_model_is_chosen_only_where_it_is_proven() {
    local output
    output=$(output_of model_on_an_unproven_gpu)
    grep -q 'has not been proven on h100-80gb-hbm3' <<< "$output" && ! grep -q '^EXIT=0$' <<< "$output" \
        && ! grep -q '^UT_MODEL=' "$WORK_DIR/model_on_an_unproven_gpu/local-env" 2>/dev/null && return 0
    echo "$output" | grep -E 'fail|proven|EXIT' | tail -5
    return 1
}

# The source of truth for which models are proven, on which engine, for
# which family: one file per combination under models/proven/. Reading it
# here instead of copying its contents into this test means a model freshly
# qualified and dropped into that folder is expected automatically, not
# missed until a release walk catches the mismatch by hand.
proven_model_ids() {
    local family=$1 f id
    for f in "$REPO_ROOT"/models/proven/*."$family".md; do
        [[ -e "$f" ]] || continue
        id=$(basename "$f" ".$family.md")
        id=${id%.*}
        printf '%s\n' "$id"
    done | sort
}

proven_model_engine() {
    local family=$1 id=$2 f
    for f in "$REPO_ROOT"/models/proven/"$id".*."$family".md; do
        [[ -e "$f" ]] || continue
        f=$(basename "$f" ".$family.md")
        printf '%s' "${f#"$id".}"
        return 0
    done
}

proven_model_license() {
    grep -m1 '^MODEL_LICENSE=' "$REPO_ROOT/models/$1.env" | sed -E 's/^MODEL_LICENSE="?([^"]*)"?$/\1/'
}

proven_model_runs_its_own_code() {
    grep -q -- '--trust-remote-code' "$REPO_ROOT/models/$1.env"
}

the_models_listed_are_those_proven_here() {
    local here elsewhere id engine display_engine license pattern ok=true

    here=$(output_of models_listed_on_gb10)
    elsewhere=$(output_of models_listed_on_an_unproven_gpu)

    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        engine=$(proven_model_engine gb10 "$id")
        case "$engine" in
            vllm) display_engine="vLLM" ;;
            nim)  display_engine="NIM" ;;
            *)    display_engine="$engine" ;;
        esac
        license=$(proven_model_license "$id")
        pattern="^${id//./\\.} +${display_engine} on gb10 +[0-9.]+ GB +${license//./\\.}"
        if proven_model_runs_its_own_code "$id"; then
            pattern+=" +runs code of its own\$"
        else
            pattern+=" *\$"
        fi
        grep -qE "$pattern" <<< "$here" || { echo "no row matching: $pattern"; ok=false; }
    done < <(proven_model_ids gb10)

    local expected_elsewhere="Not proven on h100-80gb-hbm3: $(proven_model_ids gb10 | tr '\n' ' ' | sed 's/ *$//')"
    grep -q '^EXIT=0$' <<< "$here" || ok=false
    ! grep -q 'Install stopped' <<< "$here" || ok=false
    ! grep -qE '^(qwen|nemotron)' <<< "$elsewhere" || ok=false
    grep -qF "$expected_elsewhere" <<< "$elsewhere" || { echo "expected: $expected_elsewhere"; ok=false; }
    grep -q '^EXIT=0$' <<< "$elsewhere" || ok=false
    ! grep -q 'Install stopped' <<< "$elsewhere" || ok=false

    $ok && return 0
    echo "on gb10:"; echo "$here" | tail -5
    echo "on h100:"; echo "$elsewhere" | tail -3
    return 1
}

the_models_also_come_as_events_with_their_columns_apart() {
    [[ "$(output_of models_as_events_on_gb10)" == "$(output_of models_listed_on_gb10)" ]] \
        || { echo "the text changed with --events"; diff <(output_of models_listed_on_gb10) <(output_of models_as_events_on_gb10); return 1; }

    local id engine display_engine license code expected=""
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        engine=$(proven_model_engine gb10 "$id")
        case "$engine" in
            vllm) display_engine="vLLM" ;;
            nim)  display_engine="NIM" ;;
            *)    display_engine="$engine" ;;
        esac
        license=$(proven_model_license "$id")
        if proven_model_runs_its_own_code "$id"; then code=true; else code=false; fi
        expected+="$id|$display_engine on gb10|$license|$code"$'\n'
    done < <(proven_model_ids gb10)

    EXPECTED="$expected" python3 - "$WORK_DIR/models_as_events_on_gb10/events.jsonl" <<'PY'
import json, os, re, sys
models = {event["id"]: event for event in map(json.loads, open(sys.argv[1])) if event["event"] == "model"}
expected = {}
for line in os.environ["EXPECTED"].splitlines():
    if not line:
        continue
    model_id, served, license, code = line.split("|")
    expected[model_id] = (served, license, code == "true")
ok = sorted(models) == sorted(expected)
for model_id, (served, license, code) in expected.items():
    m = models.get(model_id, {})
    ok = ok and m.get("served") == served and m.get("license") == license and m.get("runs_its_own_code") is code
ok = ok and all(re.fullmatch(r"[0-9.]+ GB", m.get("size", "")) for m in models.values())
if not ok:
    print(json.dumps(models, indent=1))
    print("expected:", expected)
    sys.exit(1)
PY
}

an_engine_forced_is_taken_only_if_proven() {
    local output
    output=$(output_of test_vllm_forced_on_nim)
    grep -q 'test-vllm on nim has not been proven on gb10' <<< "$output" && grep -q 'test-vllm, on vllm' <<< "$output" \
        && ! grep -q '^EXIT=0$' <<< "$output" && return 0
    echo "$output" | grep -E 'fail|proven|EXIT|on vllm' | tail -5
    return 1
}

a_model_kept_by_name_follows_its_entry() {
    local settings
    settings=$(cat "$WORK_DIR/model_kept_by_name/local-env" 2>/dev/null)
    grep -qxF "$(grep '^NIM_LLM_PASSTHROUGH_ARGS=' "$REPO_ROOT/models/qwen3.8-27b-nvfp4.env")" <<< "$settings" \
        && [[ $(grep -c '^NIM_LLM_PASSTHROUGH_ARGS=' <<< "$settings") == 1 ]] && return 0
    grep -E '^(UT_MODEL|NIM_LLM_PASSTHROUGH_ARGS)=' <<< "$settings" | cut -c1-100
    return 1
}

a_control_plane_takes_the_names_of_a_model_served_elsewhere() {
    local settings
    settings=$(cat "$WORK_DIR/model_on_a_control_plane/local-env" 2>/dev/null)
    grep -qx 'LLM_MODEL="nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB"' <<< "$settings" \
        && ! grep -q '^VLLM_ENGINE_' <<< "$settings" && ! grep -q 'compose.engine-vllm.yaml' <<< "$settings" \
        && grep -q 'its names only' <<< "$(output_of model_on_a_control_plane)" && return 0
    grep -E '^(LLM_MODEL|VLLM_ENGINE_IMAGE|COMPOSE_FILE)=' <<< "$settings" | cut -c1-100
    output_of model_on_a_control_plane | grep -E 'Model|fail' | tail -3
    return 1
}

a_model_nobody_listed_is_refused_before_anything_is_written() {
    local output
    output=$(output_of unknown_model)
    grep -q 'No model called nope' <<< "$output" && grep -q 'qwen3.8-27b-nvfp4' <<< "$output" \
        && ! grep -q '^EXIT=0$' <<< "$output" && [[ ! -s "$WORK_DIR/unknown_model/local-env" ]] && return 0
    echo "$output" | tail -5
    return 1
}

a_control_plane_calls_its_own_relay() {
    local settings
    settings=$(of_state pointed_at_a_compute_node local-env)
    grep -qx 'VLLM_LLM_BASE_URL="http://caddy:8445/v1"' <<< "$settings" \
        && grep -qx 'VLLM_VLM_BASE_URL="http://caddy:8445/v1"' <<< "$settings" \
        && grep -qx 'UT_LINKED_NODE_FILE="/etc/understandtech/linked-node.caddy"' <<< "$settings" \
        && grep -qx '/etc/understandtech/linked-node.caddy' <<< "$(of_state pointed_at_a_compute_node link-files)" \
        && grep -q '^COMPOSE_FILE=.*compose.remote-inference.yaml' <<< "$settings" && return 0
    grep -E '^(VLLM_LLM_BASE_URL|VLLM_VLM_BASE_URL|UT_LINKED_NODE_FILE|COMPOSE_FILE)=' <<< "$settings"
    of_state pointed_at_a_compute_node link-files
    output_of pointed_at_a_compute_node | tail -5
    return 1
}

a_platform_linked_by_key_moves_to_its_relay() {
    local settings output
    settings=$(of_state linked_by_key_before local-env)
    output=$(output_of linked_by_key_before)
    grep -qx 'VLLM_LLM_BASE_URL="http://caddy:8445/v1"' <<< "$settings" \
        && grep -qx 'UT_LINKED_NODE_FILE="/etc/understandtech/linked-node.caddy"' <<< "$settings" \
        && ! grep -q 'UT_INFERENCE_CA_BUNDLE' <<< "$settings" \
        && ! grep -q 'inference-ca-bundle' <<< "$(of_state linked_by_key_before link-files)" \
        && grep -qF 'sudo ut-pair join node.example.test:9444' <<< "$output" && return 0
    grep -E '^(VLLM_LLM_BASE_URL|UT_LINKED_NODE_FILE|UT_INFERENCE_CA_BUNDLE)=' <<< "$settings"
    of_state linked_by_key_before link-files
    grep -E 'ut-pair|\[fail\]|EXIT=' <<< "$output" | tail -4
    return 1
}

# llm does not start without an accelerator, so a machine that has one keeps it
# for llm: no engine of its own, and no overlay that would take the GPU away.
a_control_plane_with_a_gpu_keeps_it_for_llm() {
    local settings
    settings=$(cat "$WORK_DIR/pointed_at_a_compute_node/local-env" 2>/dev/null)
    ! grep -q '^COMPOSE_FILE=.*compose.no-gpu.yaml' <<< "$settings" \
        && grep -qx 'COMPOSE_PROFILES=""' <<< "$settings" && return 0
    grep -E '^COMPOSE_(FILE|PROFILES)=' <<< "$settings"
    return 1
}

a_control_plane_without_a_gpu_goes_without_it() {
    local settings
    settings=$(cat "$WORK_DIR/compute_node_from_a_machine_without_gpu/local-env" 2>/dev/null)
    grep -q '^COMPOSE_FILE=.*compose.no-gpu.yaml' <<< "$settings" \
        && grep -q '^COMPOSE_FILE=.*compose.remote-inference.yaml' <<< "$settings" && return 0
    grep -E '^COMPOSE_(FILE|PROFILES)=' <<< "$settings"
    output_of compute_node_from_a_machine_without_gpu | tail -5
    return 1
}

the_summary_says_where_generation_comes_from() {
    local output
    output=$(output_of pointed_at_a_compute_node)
    grep -qF 'control plane — generation will come from a compute node, once paired with it' <<< "$output" \
        && grep -qF 'sudo ut-pair join node.example.test' <<< "$output" && return 0
    grep -E 'Role|Inference|EXIT=' <<< "$output"
    return 1
}

a_compute_node_installs_to_the_end() {
    local output
    output=$(output_of compute_node_runs_through)
    grep -q 'Installation complete' <<< "$output" && grep -q '^EXIT=0$' <<< "$output" && return 0
    grep -E '^\[fail\]|^==>|^EXIT=' <<< "$output" | tail -5
    return 1
}

a_compute_node_hands_the_control_plane_what_it_needs() {
    local output
    output=$(output_of compute_node_runs_through)
    grep -qF 'compute node — serves inference at https://192.0.2.10:8444/v1' <<< "$output" \
        && grep -qF -- '--inference-from 192.0.2.10' <<< "$output" \
        && grep -qF 'sudo ut-pair offer' <<< "$output" \
        && ! grep -q -- '--inference-key-file' <<< "$output" \
        && ! grep -q 'first-run wizard' <<< "$output" && return 0
    grep -E 'Role|inference-from|ut-pair|wizard|EXIT=' <<< "$output"
    return 1
}

a_machine_without_gpu_is_told_documents_get_no_answer() {
    grep -q 'chats over documents answer nothing' <<< "$(output_of no_accelerator_by_flag)" && return 0
    output_of no_accelerator_by_flag | grep -E 'warn|Inference' | tail -4
    return 1
}

a_compute_node_keeps_the_list_of_the_platforms_it_admits() {
    local state settings
    for state in compute_by_flag compute_node_runs_through; do
        settings=$(of_state "$state" local-env)
        grep -qx 'UT_ADMITTED_BOXES_FILE="/etc/understandtech/admitted-boxes.caddy"' <<< "$settings" \
            && grep -qx '/etc/understandtech/admitted-boxes.caddy' <<< "$(of_state "$state" link-files)" && continue
        echo "${state}:"; grep '^UT_ADMITTED_BOXES_FILE=' <<< "$settings"; of_state "$state" link-files
        return 1
    done
}

tls_ends_with_the_given_certificate() {
    local settings
    settings=$(of_state certificate_given local-env)
    grep -qx 'UT_INGRESS_MODE="custom"' <<< "$settings" && grep -qx 'UT_CADDY_SCHEME="https"' <<< "$settings" \
        && grep -qx 'UT_CERT_DIR="/w/certs/good"' <<< "$settings" && return 0
    echo "$settings"
    output_of certificate_given | tail -5
    return 1
}

tls_ends_at_the_given_proxy() {
    local settings
    settings=$(of_state behind_a_proxy local-env)
    grep -qx 'UT_INGRESS_MODE="edge"' <<< "$settings" && grep -qx 'UT_CADDY_SCHEME="http"' <<< "$settings" \
        && grep -qx 'UT_TRUSTED_PROXIES="10.42.0.0/16"' <<< "$settings" && return 0
    echo "$settings"
    output_of behind_a_proxy | tail -5
    return 1
}

the_check_says_what_is_installed_and_no_secret() {
    local events
    events=$(of_state installed_and_checked events.jsonl)
    grep -q '"event":"installed","role":"appliance","address":"carried.example"' <<< "$events" \
        && grep -q '"model":"qwen3.8-27b-nvfp4"' <<< "$events" && grep -q '"licensed":true' <<< "$events" \
        && grep -q "\"installed\":\"2026.10.0-rc16\",\"release\":\"${VERSION}" <<< "$events" \
        && ! grep -qE 'neverinanevent|UT1-license' <<< "$events" && return 0
    grep '"installed"' <<< "$events" || output_of installed_and_checked | tail -5
    return 1
}

the_pinned_weights_are_downloaded_checked_and_placed() {
    local output settings
    output=$(output_of weights_from_the_network)
    settings=$(of_state weights_from_the_network local-env)
    grep -q 'Downloading nomic-ai/nomic-embed-text-v1.5-GGUF/nomic-embed-text-v1.5.f32.gguf' <<< "$output" \
        && grep -q 'Downloading Inferact/Qwen3.8-27B-NVFP4/config.json' <<< "$output" \
        && grep -qx 'HF_HUB_OFFLINE="1"' <<< "$settings" && grep -qx 'DOWNLOAD_ONNX_EMBED="false"' <<< "$settings" \
        && [[ "$(grep -c . <<< "$(of_state weights_from_the_network weights-placed)")" == 2 ]] \
        && [[ ! -s "$WORK_DIR/weights_from_the_network/staging-left" ]] && return 0
    grep -E '^\[fail\]|Downloading|^EXIT=' <<< "$output" | tail -5
    return 1
}

a_weight_that_is_not_the_listed_file_stops_the_install() {
    local output
    output=$(output_of weights_altered_on_the_way)
    grep -q 'is not the file this release lists' <<< "$output" && ! grep -q '^EXIT=0$' <<< "$output" \
        && ! grep -q 'HF_HUB_OFFLINE="1"' <<< "$(of_state weights_altered_on_the_way local-env)" && return 0
    tail -5 <<< "$output"
    return 1
}

weights_already_placed_are_not_downloaded_again() {
    ! grep -qE 'Downloading [^ ]+/[^ ]+ \(' <<< "$(output_of install_runs_through)"
}

refused_before_anything_is_written() {
    local state=$1 reason=$2 output
    output=$(output_of "$state")
    grep -qF -- "$reason" <<< "$output" && ! grep -q '^EXIT=0$' <<< "$output" \
        && [[ ! -s "$WORK_DIR/$state/local-env" ]] && return 0
    echo "$output" | tail -5
    return 1
}

a_refused_folder_names_how_to_prepare_it_again() {
    local output
    output=$(output_of folder_without_its_images)
    grep -qE -- "--version ${VERSION} --role appliance\$" <<< "$output" \
        && ! grep -q 'Install stopped at line' <<< "$output" || { grep -E 'Prepare it again|Install stopped' <<< "$output"; return 1; }
    output=$(output_of folder_without_the_settings_image)
    grep -qF -- "--image ghcr.io/understand-tech/engines/nim:2.0.13@sha256:" <<< "$output" && return 0
    grep -E 'Prepare it again|--image' <<< "$output"
    return 1
}

a_dead_vision_address_is_named() {
    grep -q 'VLLM_VLM_BASE_URL names nim-vlm, a service this stack does not run' <<< "$(output_of vision_engine_gone)" && return 0
    output_of vision_engine_gone | grep -E '\[warn\]|VLM' | tail -4
    return 1
}

a_pulling_install_forgets_the_names_of_a_folder() {
    local settings
    settings=$(cat "$WORK_DIR/installed_from_a_folder_before/local-env" 2>/dev/null)
    grep -q '^OA_KEY=' <<< "$settings" && ! grep -q '127.0.0.1:15000' <<< "$settings" && return 0
    echo "$settings" | head -5
    return 1
}

a_compute_node_is_installed_with_one_flag() {
    local output settings
    output=$(output_of compute_by_flag)
    settings=$(cat "$WORK_DIR/compute_by_flag/local-env" 2>/dev/null)
    grep -qE '^COMPOSE_FILE="?[^"]*compose\.compute\.yaml' <<< "$settings" \
        && grep -qE '^UT_INFERENCE_ADDRESS="?192\.0\.2\.10"?$' <<< "$settings" \
        && grep -qF 'compute node — serves inference at https://192.0.2.10:8444/v1' <<< "$output" \
        && grep -q '^EXIT=0$' <<< "$output" && return 0
    grep -E '^(COMPOSE_FILE|UT_INFERENCE_ADDRESS)=' <<< "$settings"
    grep -E 'Role|\[fail\]|EXIT=' <<< "$output" | tail -4
    return 1
}

a_node_given_as_a_url_is_refused() {
    local output
    output=$(output_of node_given_as_a_url)
    grep -q "takes the compute node's name or IP" <<< "$output" && ! grep -q '^EXIT=0$' <<< "$output" \
        && [[ ! -s "$WORK_DIR/node_given_as_a_url/local-env" ]] && return 0
    echo "$output" | tail -5
    return 1
}

the_allowed_origins_follow_the_domain() {
    local settings
    settings=$(cat "$WORK_DIR/origins_on_an_old_domain/local-env" 2>/dev/null)
    grep -qx 'EXTRA_ALLOWED_ORIGINS="https://admin.box.example.test,https://llms.box.example.test,https://box.example.test"' <<< "$settings" && return 0
    grep -E '^(UT_DOMAIN|EXTRA_ALLOWED_ORIGINS)=' <<< "$settings"
    return 1
}

engine_key_of() { grep -m1 '^VLLM_API_KEY=' <<< "$(settings_of "$1")" | cut -d= -f2- | tr -d '"'; }

the_engine_gets_a_key_of_its_own() {
    local key
    key=$(engine_key_of "$1")
    [[ ${#key} -ge 32 && "$key" != "EMPTY" ]] && return 0
    echo "VLLM_API_KEY is '${key}' — the relay to a compute node would let any container in"
    return 1
}

the_preflight_stops_on_a_clock_before_the_release() {
    local output
    output=$(output_of clock_before_the_release)
    grep -q 'before this release was built' <<< "$output" \
        && ! grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

a_mounted_backup_destination_is_used_and_marked() {
    local settings output
    settings=$(settings_of backup_destination_mounted)
    output=$(output_of backup_destination_mounted)
    grep -qE '^COMPOSE_FILE=.*compose\.backup-mount\.yaml' <<< "$settings" \
        && [[ -e "$WORK_DIR/backup_destination_mounted/nas/.understandtech-backup-destination" ]] \
        && grep -q 'Downloading images' <<< "$output" && return 0
    grep -E '^COMPOSE_FILE' <<< "$settings"
    echo "$output"
    return 1
}

a_destination_on_the_machine_s_own_disk_stops_the_install() {
    local output
    output=$(output_of backup_destination_not_mounted)
    grep -q "this machine's own disk" <<< "$output" \
        && grep -q 'empty BACKUP_FILES_DESTINATION' <<< "$output" \
        && ! grep -q 'Downloading images' <<< "$output" && return 0
    echo "$output"
    return 1
}

a_network_destination_gets_its_way_out_and_names_the_key_it_lacks() {
    local settings output
    settings=$(settings_of backup_over_sftp)
    output=$(output_of backup_over_sftp)
    grep -qE '^COMPOSE_FILE=.*compose\.backup-network\.yaml' <<< "$settings" \
        && grep -q 'no host key is pinned for nas.example.test' <<< "$output" \
        && grep -q 'Downloading images' <<< "$output" && return 0
    grep -E '^COMPOSE_FILE' <<< "$settings"
    echo "$output"
    return 1
}

an_sftp_destination_gets_a_key_only_root_reads() {
    local mode public output
    mode=$(of_state backup_over_sftp backup-key-mode)
    public=$(of_state backup_over_sftp backup-key-pub)
    output=$(output_of backup_over_sftp)
    [[ "$mode" == "600 root" && "$public" == ssh-ed25519\ * ]] && grep -qF "$public" <<< "$output" && return 0
    echo "key mode '${mode}', public half '${public}'"
    grep -E 'key|ssh-keygen' <<< "$output"
    return 1
}

a_key_the_destination_knows_is_never_replaced() {
    local sum
    sum=$(of_state backup_over_sftp_with_its_key backup-key-sum)
    [[ "$sum" == "$(printf 'the-key-the-nas-knows\n' | shasum -a 256 | cut -d' ' -f1)" ]] \
        && ! grep -q 'Made the key the backup logs in with' <<< "$(output_of backup_over_sftp_with_its_key)" && return 0
    echo "the key the destination knew was replaced (sum ${sum:-none})"
    return 1
}

the_default_destination_adds_no_way_out() {
    ! grep -q 'compose.backup-network.yaml' <<< "$(settings_of bare)" && return 0
    grep -E '^COMPOSE_FILE' <<< "$(settings_of bare)"
    return 1
}

two_destinations_stop_the_install() {
    local output
    output=$(output_of backup_in_two_places)
    grep -q 'both say where the backup goes' <<< "$output" \
        && ! grep -q 'Downloading images' <<< "$output" \
        && ! grep -q 'compose.backup-mount.yaml' "$WORK_DIR/backup_in_two_places/local-env" && return 0
    echo "$output"
    grep -E '^COMPOSE_FILE' "$WORK_DIR/backup_in_two_places/local-env"
    return 1
}

a_destination_gone_on_an_update_holds_nothing_back() {
    local output
    output=$(output_of backup_destination_gone_on_an_update)
    grep -q 'the backup writes nothing until it is back' <<< "$output" \
        && grep -q 'Downloading images' <<< "$output" && return 0
    echo "$output"
    return 1
}

the_install_goes_on_when_the_inference_is_elsewhere() {
    local output
    output=$(output_of no_accelerator_declared)
    grep -q 'the inference is served by another machine' <<< "$output" \
        && grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

# The other half of the pair, and the one that matters: a driver that stopped
# answering looks exactly like a machine that never had a GPU. Waiving the check
# on the absence alone would install a box that generates nothing.
the_preflight_stops_when_nothing_says_the_inference_is_elsewhere() {
    local output
    output=$(output_of no_accelerator_undeclared)
    grep -q 'No usable GPU detected' <<< "$output" \
        && ! grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

# Waiving the check and writing nothing was the first version of this, and it
# installed a machine that pulled the engines and then could not start them:
# `could not select device driver "nvidia"`, after the images were down.
the_flag_writes_a_configuration_that_asks_for_no_gpu() {
    local settings
    settings=$(settings_of no_accelerator_by_flag)
    grep -q 'compose.no-gpu.yaml' <<< "$settings" \
        && ! grep -qE '^COMPOSE_PROFILES="?nim' <<< "$settings" && return 0
    grep -E '^COMPOSE_FILE|^COMPOSE_PROFILES' <<< "$settings"
    return 1
}

# The release points VLLM_LLM_BASE_URL at nim-llm, a service a control plane
# never starts. Installing without saying so leaves a platform that comes up
# healthy and cannot answer anything a model has to write.
the_install_says_the_inference_url_points_nowhere() {
    local output
    output=$(output_of no_accelerator_by_flag)
    grep -q 'VLLM_LLM_BASE_URL still names' <<< "$output" && return 0
    echo "$output"
    return 1
}

the_install_says_nothing_when_the_address_is_already_set() {
    local output
    output=$(output_of no_accelerator_pointed_at_a_real_machine)
    grep -q 'Writing the configuration' <<< "$output" \
        && ! grep -q 'still names' <<< "$output" && return 0
    echo "$output"
    return 1
}

# The engines account for 43.1 GB of the 55.29 GB measured on a box in service.
# A machine that serves none of it should not be turned away over the storage
# they would have taken.
the_disk_floor_follows_what_the_machine_will_actually_hold() {
    local output
    output=$(output_of no_accelerator_on_a_smaller_disk)
    grep -q 'Disk: 91 GB free' <<< "$output" \
        && ! grep -q '250 GB needed' <<< "$output" \
        && grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

the_preflight_stops_on_full_pools() {
    local output
    output=$(output_of pools_full)
    grep -q 'address pools are full' <<< "$output" \
        && grep -q 'docker network prune' <<< "$output" \
        && ! grep -q 'Writing the configuration' <<< "$output" && return 0
    echo "$output"
    return 1
}

# The harness has no controlling terminal, which is the state every scripted
# install runs in — a CI job, an Ansible play, ssh without a tty.
an_install_that_worked_says_so() {
    local output
    output=$(output_of install_runs_through)
    grep -q 'Installation complete' <<< "$output" || { echo "the install did not finish"; return 1; }
    grep -q '^EXIT=0$' <<< "$output" && return 0
    echo "it finished and still reported failure:"
    grep -E '^\[fail\]|^EXIT=|/dev/tty' <<< "$output" | tail -5
    return 1
}

# Matching the path alone was not enough: any message naming local.env satisfied
# it, and the preflight gained one. What this property means is that the run with
# no terminal said where the secrets went, so it asks for that sentence.
the_secrets_are_findable_without_a_terminal() {
    local output
    output=$(output_of install_runs_through)
    grep -q 'The secrets are in' <<< "$output" && return 0
    echo "nothing told the operator where the secrets are"
    return 1
}

no_secret_reaches_the_log() {
    local output secret
    output=$(output_of install_runs_through)
    for secret in ADMIN_SETUP_PASSWORD BACKUP_FILES_PASSWORD; do
        secret=$(grep -m1 -E "^${secret}=" "$WORK_DIR/install_runs_through/env" 2>/dev/null) || continue
        secret=${secret#*=}; secret=${secret%\"}; secret=${secret#\"}
        [[ -n "$secret" ]] || continue
        grep -qF "$secret" <<< "$output" && { echo "a generated secret appears in the install output"; return 1; }
    done
    return 0
}

a_checkout_under_foot_needs_no_token() {
    local output
    output=$(output_of launched_from_a_checkout)
    if grep -qE 'Registry token for|has to be cloned' <<< "$output"; then
        echo "it set out to clone the release it was already standing in"
        grep -E 'Registry token|has to be cloned' <<< "$output" | head -2
        return 1
    fi
    grep -q '/srv/clone' <<< "$output" && return 0
    echo "it did not take the checkout it was launched from"
    grep -E 'Directory|Release|Checkout' <<< "$output" | head -3
    return 1
}

# The other half of the same change: recognising a checkout must not become a
# way in without credentials.
a_machine_with_no_credentials_is_still_asked() {
    local output
    output=$(output_of checkout_but_no_key)
    grep -qE 'License key from|license key is needed|No license key supplied' <<< "$output" && return 0
    echo "it went ahead without ever asking for a key"
    tail -6 <<< "$output"
    return 1
}

an_orphan_volume_stops_the_install() {
    local output
    output=$(output_of orphan_volume)
    grep -q 'holds no password for it' <<< "$output" \
        && grep -q 'docker volume rm' <<< "$output" && return 0
    echo "$output"
    return 1
}

# The password a machine was installed with is the password of its database,
# whatever it looks like: mongo only ever reads it when it creates the volume.
a_shipped_password_is_still_a_password() {
    local output
    output=$(output_of volume_with_shipped_password)
    if grep -q 'holds no password for it' <<< "$output"; then
        echo "the install refused a database whose password it holds"
        echo "$output"
        return 1
    fi
    grep -q 'Database already initialised' <<< "$output" && return 0
    echo "$output"
    return 1
}

the_way_back_comes_before_the_way_out() {
    local output first_rm first_put
    output=$(output_of orphan_volume)
    first_put=$(grep -n 'MONGODB_USERNAME and MONGODB_PASSWORD' <<< "$output" | head -1 | cut -d: -f1)
    first_rm=$(grep -n 'docker volume rm' <<< "$output" | head -1 | cut -d: -f1)
    [[ -n "$first_put" && -n "$first_rm" ]] || { echo "$output"; return 1; }
    (( first_put < first_rm )) && return 0
    echo "destroying the volume is offered before putting the password back"
    return 1
}

LICENSE_USER=licensed-user
LICENSE_TOKEN=license-carried-token-0001

# The walk installs the package with --force-depends, so openssl, jq and curl,
# which the package declares, are not there; a license check cannot run without
# them, nor the fake Keygen without python3.
WITH_OPENSSL_IMAGE=""

prepare_a_vllm_entry() {
    mkdir -p "$WORK_DIR/models"
    cat > "$WORK_DIR/models/test-vllm.env" <<'ENTRY'
# A model served by vLLM, for the walk.
VLLM_ENGINE_IMAGE="registry.example/vllm@sha256:0000000000000000000000000000000000000000000000000000000000000000"
VLLM_ENGINE_MODEL="org/model"
VLLM_ENGINE_ARGS=--trust-remote-code --override-generation-config {"temperature":0.2,"top_p":0.9}
LLM_MODEL="org/model"
VLLM_LLM_MODEL="org/model"
ENTRY
    mkdir -p "$WORK_DIR/models/proven"
    printf 'Image: sha256:%064d, proven on gb10 for the walk.\n' 0 > "$WORK_DIR/models/proven/test-vllm.vllm.gb10.md"
    chmod -R a+r "$WORK_DIR/models"
}

prepare_weights() {
    local work="$WORK_DIR/weights" repository revision path sha
    mkdir -p "$work/lists"
    : > "$work/lists/platform.txt"
    : > "$work/lists/qwen3.8-27b-nvfp4.txt"
    for line in "platform nomic-ai/nomic-embed-text-v1.5-GGUF 0188c9bf409793f810680a5a431e7b899c46104c nomic-embed-text-v1.5.f32.gguf" \
                "qwen3.8-27b-nvfp4 Inferact/Qwen3.8-27B-NVFP4 1111111111111111111111111111111111111111 config.json"; do
        set -- $line
        mkdir -p "$work/source/$2/resolve/$3"
        printf 'weights of %s, for the walk\n' "$4" > "$work/source/$2/resolve/$3/$4"
        sha=$(openssl dgst -sha256 -r "$work/source/$2/resolve/$3/$4" | cut -d' ' -f1)
        printf '%s %s %s@%s/%s\n' "$sha" "$(wc -c < "$work/source/$2/resolve/$3/$4" | tr -d ' ')" "$2" "$3" "$4" >> "$work/lists/$1.txt"
    done
    cat > "$work/curl" <<'CURL'
#!/bin/sh
target="" url="" previous=""
for argument; do
    [ "$previous" = --output ] && target=$argument
    case "$argument" in https://huggingface.co/*) url=$argument ;; esac
    previous=$argument
done
source="/w/weights/source/${url#https://huggingface.co/}"
[ -f "$source" ] || exit 22
cp "$source" "$target"
CURL
    chmod -R a+rx "$work"
}

prepare_certificates() {
    local work="$WORK_DIR/certs" case
    for case in good short with_another_key without_its_key; do mkdir -p "$work/$case"; done
    certificate_for() {
        openssl req -x509 -newkey rsa:2048 -sha256 -days 30 -noenc -subj "/CN=box.example.test" \
            -addext "subjectAltName=$2" -keyout "$1/privkey.pem" -out "$1/fullchain.pem" 2>/dev/null
    }
    certificate_for "$work/good" "DNS:box.example.test,DNS:*.box.example.test,DNS:*.apps.box.example.test"
    certificate_for "$work/short" "DNS:box.example.test"
    certificate_for "$work/with_another_key" "DNS:box.example.test,DNS:*.box.example.test"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$work/with_another_key/privkey.pem" 2>/dev/null
    cp "$work/good/fullchain.pem" "$work/without_its_key/fullchain.pem"
    chmod -R a+r "$work"
}

prepare_licenses() {
    local work="$WORK_DIR/licenses"
    mkdir -p "$work"
    WITH_OPENSSL_IMAGE=$(docker build -q - 2>/dev/null <<DOCKERFILE
FROM ${DEBIAN_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends openssl jq curl python3 openssh-client && rm -rf /var/lib/apt/lists/*
DOCKERFILE
) || { echo "Could not build the image the license walks run in." >&2; exit 1; }
    # Signed here rather than by Keygen: the walk is about the installer, and
    # runs with no network.
    docker run --rm -v "$REPO_ROOT":/src:ro -v "$WORK_DIR":/w -e KEYGEN_TEST_TOKEN="$LICENSE_TOKEN" \
        "$WITH_OPENSSL_IMAGE" bash -c '. /src/test/keygen.sh && prepare_license_lab /src /w/licenses' \
        || { echo "Could not sign the licenses the walks use." >&2; exit 1; }
}

of_state() { cat "$WORK_DIR/$1/$2" 2>/dev/null; }

logged_in_with_the_license() {
    local state=$1
    grep -q "^login ghcr.io -u ${LICENSE_USER} --password-stdin" <<< "$(of_state "$state" docker-calls)" \
        || { echo "no registry login as ${LICENSE_USER}:"; of_state "$state" docker-calls | grep login; output_of "$state" | tail -5; return 1; }
    [[ "$(of_state "$state" login-stdin)" == "$LICENSE_TOKEN" ]] && return 0
    echo "the registry login was not given the token the license carries"
    return 1
}

never_logged_in() {
    local state=$1
    grep -q '^login ' <<< "$(of_state "$state" docker-calls)" || return 0
    echo "it logged into the registry anyway"
    return 1
}

never_asked_keygen() {
    local state=$1
    [[ -z "$(of_state "$state" keygen-requests)" ]] && return 0
    echo "it asked Keygen anyway:"; of_state "$state" keygen-requests
    return 1
}

refused_with() {
    local state=$1 words=$2
    grep -qF "$words" <<< "$(output_of "$state")" && grep -q '^EXIT=1$' <<< "$(output_of "$state")" && return 0
    echo "${state} did not stop on '${words}':"; output_of "$state" | tail -5
    return 1
}

a_license_activates_this_machine_and_logs_in_with_its_token() {
    local asked
    asked=$(of_state licensed keygen-requests)
    grep -q 'licenses/actions/validate-key' <<< "$asked" && grep -q '^POST machines$' <<< "$asked" \
        && grep -q 'actions/check-out' <<< "$asked" \
        || { echo "the machine was not activated with Keygen:"; echo "$asked"; output_of licensed | tail -5; return 1; }
    reached_the_pull licensed && logged_in_with_the_license licensed
}

the_license_and_its_file_are_kept_for_root_alone() {
    [[ "$(of_state licensed license-mode)" == "600 root" && "$(of_state licensed machine-mode)" == "600 root" ]] \
        || { echo "the license is '$(of_state licensed license-mode)', its file '$(of_state licensed machine-mode)', not 600 root"; return 1; }
    [[ "$(of_state licensed license)" == "$(cat "$WORK_DIR/licenses/keys/fresh.key")" ]] \
        || { echo "the stored license is not the key that was given"; return 1; }
    [[ "$(of_state licensed machine)" == "$(cat "$WORK_DIR/licenses/certificates/TEST-FRESH.lic")" ]] && return 0
    echo "the stored license file is not the one Keygen handed over"
    return 1
}

an_update_takes_the_license_already_there_with_no_network() {
    reached_the_pull license_stored && logged_in_with_the_license license_stored && never_asked_keygen license_stored
}

an_altered_license_file_stops_before_any_request_or_login() {
    refused_with license_tampered 'not issued by UnderstandTech' \
        && never_asked_keygen license_tampered && never_logged_in license_tampered
}

a_license_file_that_ended_is_renewed_from_keygen() {
    grep -q 'actions/check-out' <<< "$(of_state license_renewed keygen-requests)" \
        || { echo "Keygen was never asked for a new file:"; output_of license_renewed | tail -5; return 1; }
    [[ "$(of_state license_renewed machine)" == "$(cat "$WORK_DIR/licenses/certificates/TEST-ACTIVE.lic")" ]] \
        || { echo "the file that ended was not replaced by the one Keygen handed over"; return 1; }
    reached_the_pull license_renewed && logged_in_with_the_license license_renewed
}

a_machine_with_no_network_writes_its_request_and_says_what_to_do() {
    local request
    refused_with license_with_no_network 'send /etc/understandtech/license-request.json to UnderstandTech' || return 1
    grep -q 'again with --machine-file' <<< "$(output_of license_with_no_network)" \
        || { echo "nothing said how to install with the file sent back"; return 1; }
    request=$(of_state license_with_no_network license-request)
    [[ "$(jq -r .fingerprint <<< "$request" 2>/dev/null)" == "$(cat "$WORK_DIR/licenses/fingerprint")" ]] \
        || { echo "the request does not name this machine: ${request:-nothing}"; return 1; }
    grep -qE 'TEST-' <<< "$request" && { echo "the request carries the license key"; return 1; }
    never_logged_in license_with_no_network
}

a_license_file_sent_back_installs_with_no_network() {
    grep -q 'Licensed to Test Customer' <<< "$(output_of licensed_by_file)" \
        || { echo "the license file was not checked:"; output_of licensed_by_file | tail -5; return 1; }
    [[ "$(of_state licensed_by_file machine)" == "$(cat "$WORK_DIR/licenses/files/valid.lic")" ]] \
        || { echo "the license file given is not the one kept"; return 1; }
    [[ "$(of_state licensed_by_file machine-mode)" == "600 root" ]] \
        || { echo "the license file kept is '$(of_state licensed_by_file machine-mode)', not 600 root"; return 1; }
    never_asked_keygen licensed_by_file && never_logged_in licensed_by_file
}

an_altered_license_file_sent_back_is_refused() {
    refused_with licensed_by_an_altered_file 'not issued by UnderstandTech' \
        && never_asked_keygen licensed_by_an_altered_file && never_logged_in licensed_by_an_altered_file
}

a_license_file_from_another_machine_stops_the_install() {
    refused_with license_from_another_machine 'made for another machine' \
        && never_asked_keygen license_from_another_machine && never_logged_in license_from_another_machine
}

an_ended_license_stops_the_install_and_says_when() {
    refused_with license_ended 'ended on 2020-01-01' && never_logged_in license_ended
}

a_license_activated_elsewhere_is_refused_and_says_so() {
    refused_with license_taken 'activated on another machine' && never_logged_in license_taken
}

images_already_here_need_no_registry_login() {
    grep -q 'Licensed to Test Customer' <<< "$(output_of licensed_offline)" \
        || { echo "the license was not checked:"; output_of licensed_offline | tail -5; return 1; }
    never_logged_in licensed_offline && never_asked_keygen licensed_offline
}

a_license_with_no_registry_token_is_refused_only_to_pull() {
    refused_with licensed_without_a_token 'carries no registry token to pull the images with' || return 1
    grep -q 'carries no registry token, and none is needed' <<< "$(output_of licensed_without_a_token_pulling_nothing)" \
        && ! grep -q 'carries no registry token to pull' <<< "$(output_of licensed_without_a_token_pulling_nothing)" \
        && never_logged_in licensed_without_a_token_pulling_nothing && return 0
    output_of licensed_without_a_token_pulling_nothing | grep -E 'registry token|\[fail\]|EXIT=' | tail -4
    return 1
}

a_license_of_the_old_format_says_what_to_ask_for() {
    refused_with license_of_the_old_format 'old format' && never_logged_in license_of_the_old_format
}

LICENSE_STATES="licensed_without_a_token licensed_without_a_token_pulling_nothing licensed license_stored license_renewed license_with_no_network licensed_by_file licensed_by_an_altered_file license_tampered license_from_another_machine license_ended license_taken licensed_offline licensed_elsewhere license_of_the_old_format"

the_carried_token_never_reaches_the_output() {
    local state
    for state in $LICENSE_STATES; do
        grep -qF "$LICENSE_TOKEN" <<< "$(output_of "$state")" \
            && { echo "the registry token appears in the output of ${state}"; return 1; }
        grep -qE 'TEST-(FRESH|ACTIVE|REGISTRY|ELSEWHERE|ENDED)' <<< "$(output_of "$state")" \
            && { echo "the license key appears in the output of ${state}"; return 1; }
        grep -q 'SECRET_ON_A_COMMAND_LINE' <<< "$(of_state "$state" keygen-requests)" \
            && { echo "the license key sat on a command line in ${state}"; return 1; }
    done
    return 0
}

image_lines() { grep -E '^[A-Z0-9_]+_IMAGE=' | sort; }

a_license_naming_a_registry_pulls_every_image_from_it() {
    local written release line wrong=""
    written=$(settings_of licensed_elsewhere | image_lines)
    release=$(image_lines < "$REPO_ROOT/release.env")
    [[ -n "$written" ]] || { echo "no image was written:"; output_of licensed_elsewhere | tail -5; return 1; }
    while IFS= read -r line; do
        [[ "$line" == *'="registry.example.test/'* ]] || wrong="${wrong} ${line%%=*}"
    done <<< "$written"
    [[ -z "$wrong" ]] || { echo "still pulled from elsewhere:${wrong}"; return 1; }
    [[ "$(sed 's/.*@//' <<< "$written")" == "$(sed 's/.*@//' <<< "$release")" ]] \
        || { echo "an image lost the digest release.env pins"; return 1; }
    grep -q '^CADDY_IMAGE="registry.example.test/library/caddy:' <<< "$written" \
        && grep -q '^API_IMAGE="registry.example.test/understand-tech/ut-api-customer:' <<< "$written" \
        || { echo "an image is not under its own path:"; echo "$written" | head -4; return 1; }
    grep -q '^login registry.example.test ' <<< "$(of_state licensed_elsewhere docker-calls)" && return 0
    echo "it did not sign in to the registry the license names"
    return 1
}

a_license_naming_no_registry_leaves_the_images_where_they_are() {
    [[ "$(settings_of licensed | image_lines)" == "$(image_lines < "$REPO_ROOT/release.env")" ]] && return 0
    echo "the image names changed with a license that names no registry"
    return 1
}

a_token_alone_still_installs_and_says_so() {
    reached_the_pull bare \
        && grep -q 'accepted by this version only' <<< "$(output_of bare)" && return 0
    echo "a token on its own was refused, or nothing said a license key will be needed"
    output_of bare | grep -i -E 'token|license' | head -3
    return 1
}

printf '%sWalking a fresh install%s %s(the installer, from a machine in a known state)%s\n\n' \
    "$BOLD" "$NC" "$DIM" "$NC"

build_the_package
write_machine_stubs
prepare_licenses
prepare_certificates
prepare_weights
prepare_a_vllm_entry

run_install_from_state bare
PULL_EXIT=0 run_install_from_state install_runs_through
PULL_EXIT=0 run_install_from_state compute_node_runs_through
INSTALL_TOKEN= INSTALL_COMMAND=/srv/clone/bin/ut-install \
    run_install_from_state launched_from_a_checkout
INSTALL_TOKEN= INSTALL_COMMAND=/srv/clone/bin/ut-install \
    run_install_from_state checkout_but_no_key
run_install_from_state empty_settings
run_install_from_state openai_key_given
run_install_from_state engine_key_left_empty
run_install_from_state origins_on_an_old_domain
INSTALL_COMMAND="ut-install --model qwen3.8-27b-nvfp4" run_install_from_state model_on_nim
INSTALL_COMMAND="ut-install --model test-vllm" run_install_from_state model_on_vllm
INSTALL_COMMAND="ut-install --model nope" run_install_from_state unknown_model
INSTALL_COMMAND="ut-install --model qwen3.8-27b-nvfp4" run_install_from_state model_on_an_unproven_gpu
INSTALL_COMMAND="ut-install --model test-vllm --engine nim" run_install_from_state test_vllm_forced_on_nim
INSTALL_COMMAND="ut-install --list-models" run_install_from_state models_listed_on_gb10
INSTALL_COMMAND="ut-install --list-models" run_install_from_state models_listed_on_an_unproven_gpu
INSTALL_COMMAND="ut-install --list-models --events /w/models_as_events_on_gb10/events.jsonl" run_install_from_state models_as_events_on_gb10
run_install_from_state model_kept_by_name
INSTALL_COMMAND="ut-install --no-gpu --model nemotron-3.5-bolt-74b" run_install_from_state model_on_a_control_plane
PULL_EXIT=0 INSTALL_COMMAND="ut-install --inference-from node.example.test" \
    run_install_from_state pointed_at_a_compute_node
INSTALL_COMMAND="ut-install --inference-from node.example.test" \
    run_install_from_state compute_node_from_a_machine_without_gpu
INSTALL_COMMAND="ut-install --inference-from https://node.example.test:8444" \
    run_install_from_state node_given_as_a_url
INSTALL_COMMAND="ut-install --inference-from node.local" \
    run_install_from_state pointed_at_an_mdns_node
PULL_EXIT=0 run_install_from_state linked_by_key_before
PULL_EXIT=0 INSTALL_COMMAND="ut-install --compute 192.0.2.10" \
    run_install_from_state compute_by_flag -
INSTALL_COMMAND="ut-install --compute node.local" run_install_from_state compute_named_by_mdns
PULL_EXIT=0 WALK_IMAGE=$WITH_OPENSSL_IMAGE run_install_from_state weights_from_the_network
PULL_EXIT=0 WALK_IMAGE=$WITH_OPENSSL_IMAGE run_install_from_state weights_altered_on_the_way
INSTALL_COMMAND="ut-install --check --events /w/installed_and_checked/events.jsonl" run_install_from_state installed_and_checked -
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_COMMAND="ut-install --certificate-dir /w/certs/good" run_install_from_state certificate_given
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_COMMAND="ut-install --certificate-dir /w/certs/short" run_install_from_state certificate_short
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_COMMAND="ut-install --certificate-dir /w/certs/with_another_key" run_install_from_state certificate_with_another_key
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_COMMAND="ut-install --certificate-dir /w/certs/without_its_key" run_install_from_state certificate_without_its_key
INSTALL_COMMAND="ut-install --behind-proxy 10.42.0.0/16" run_install_from_state behind_a_proxy
INSTALL_COMMAND="ut-install --behind-proxy 0.0.0.0/0" run_install_from_state behind_any_proxy
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_COMMAND="ut-install --certificate-dir /w/certs/good --behind-proxy 10.42.0.0/16" run_install_from_state certificate_and_proxy
INSTALL_COMMAND="ut-install --compute 192.0.2.10 --no-gpu" run_install_from_state compute_without_its_gpu
INSTALL_COMMAND="ut-install --images-from /w/folder_without_its_images/folder" run_install_from_state folder_without_its_images
INSTALL_COMMAND="ut-install --images-from /w/folder_for_another_processor/folder" run_install_from_state folder_for_another_processor
INSTALL_COMMAND="ut-install --images-from /w/folder_of_another_release/folder" run_install_from_state folder_of_another_release
INSTALL_COMMAND="ut-install --images-from /w/folder_without_the_settings_image/folder" run_install_from_state folder_without_the_settings_image
run_install_from_state vision_engine_gone
INSTALL_COMMAND="ut-install --images-from /w/folder_for_another_role/folder" run_install_from_state folder_for_another_role
run_install_from_state installed_from_a_folder_before
run_install_from_state already_set
run_install_from_state no_settings_dir
MONGO_VOLUME_EXISTS=yes run_install_from_state orphan_volume
MONGO_VOLUME_EXISTS=yes run_install_from_state volume_with_shipped_password -
NETWORK_CREATE_EXIT=1 run_install_from_state pools_full
DISK_AVAIL_BYTES=$((91 * 1000 * 1000 * 1000)) run_install_from_state disk_too_small
run_install_from_state clock_before_the_release
run_install_from_state previous_checkout -
run_install_from_state checkout_without_domain -
run_install_from_state no_accelerator_declared
run_install_from_state no_accelerator_undeclared
# 91 GB: under the 250 GB an appliance needs, over the 60 GB a control plane does.
DISK_AVAIL_BYTES=$((91 * 1000 * 1000 * 1000)) \
    run_install_from_state no_accelerator_on_a_smaller_disk
INSTALL_COMMAND="ut-install --no-gpu" run_install_from_state no_accelerator_by_flag
INSTALL_COMMAND="ut-install --no-gpu" run_install_from_state no_accelerator_pointed_at_a_real_machine
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/keys/fresh.key" \
    run_install_from_state licensed
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/keys/ended.key" \
    run_install_from_state license_ended
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/keys/elsewhere.key" \
    run_install_from_state license_taken
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/keys/registry.key" \
    run_install_from_state licensed_elsewhere
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= run_install_from_state license_stored
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= run_install_from_state license_tampered
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= run_install_from_state license_renewed
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/keys/fresh.key" \
    run_install_from_state license_with_no_network
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/keys/active.key --machine-file /w/licenses/files/valid.lic --skip-pull --health-timeout 5" \
    run_install_from_state licensed_by_file
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --license-file /w/licenses/keys/active.key --machine-file /w/licenses/files/tampered.lic --skip-pull" \
    run_install_from_state licensed_by_an_altered_file
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= run_install_from_state license_from_another_machine
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --skip-pull --health-timeout 5" \
    run_install_from_state licensed_offline
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= run_install_from_state license_of_the_old_format
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= run_install_from_state licensed_without_a_token
WALK_IMAGE=$WITH_OPENSSL_IMAGE INSTALL_TOKEN= INSTALL_COMMAND="ut-install --skip-pull --health-timeout 5" \
    run_install_from_state licensed_without_a_token_pulling_nothing
run_install_from_state backup_destination_mounted
run_install_from_state backup_destination_not_mounted
run_install_from_state backup_destination_gone_on_an_update
WALK_IMAGE=$WITH_OPENSSL_IMAGE run_install_from_state backup_over_sftp
WALK_IMAGE=$WITH_OPENSSL_IMAGE run_install_from_state backup_over_sftp_with_its_key
run_install_from_state backup_in_two_places

printf '%sA machine with nothing on it%s\n' "$BOLD" "$NC"
property "the install reaches the point where it pulls images" \
    reached_the_pull bare
property "the walk stops where the images would download" \
    the_walk_stops_where_the_images_would_download
property "every variable the stack requires has a value" \
    every_required_setting_is_filled bare
property "what it wrote renders a stack" \
    the_settings_render_a_stack bare
property "the secrets are not the ones the template ships" \
    secrets_are_not_the_shipped_ones bare
property "the App Builder's token key is one Fernet accepts" \
    the_builder_key_is_one_fernet_accepts

property "a machine without a GPU is told its documents get no answer" \
    a_machine_without_gpu_is_told_documents_get_no_answer
property "it gives the API the OA_KEY it needs to start" \
    the_install_gives_the_api_the_key_it_needs_to_start
property "an OpenAI key already given is never replaced" \
    an_openai_key_given_is_never_replaced

property "the engine gets a key of its own" \
    the_engine_gets_a_key_of_its_own bare
property "a model on NIM is set from its entry, with no vLLM overlay" \
    a_model_on_nim_is_set_with_no_vllm_overlay
property "a model on vLLM brings its engine, and its arguments whole" \
    a_model_on_vllm_brings_its_engine_and_its_arguments_whole
property "and what it wrote renders a stack" \
    the_settings_render_a_stack model_on_vllm
property "a model is chosen only on a GPU it is proven on" \
    a_model_is_chosen_only_where_it_is_proven
property "the models listed are those proven on this GPU, with their engine, size and license" \
    the_models_listed_are_those_proven_here
property "with --events, each model is also an event, its columns apart, and the text is unchanged" \
    the_models_also_come_as_events_with_their_columns_apart
property "an engine asked for is taken only where it is proven" \
    an_engine_forced_is_taken_only_if_proven
property "a model kept by name follows its entry on the next install" \
    a_model_kept_by_name_follows_its_entry
property "a control plane takes the names of a model served elsewhere, and no engine" \
    a_control_plane_takes_the_names_of_a_model_served_elsewhere
property "a model nobody listed is refused before anything is written" \
    a_model_nobody_listed_is_refused_before_anything_is_written
property "the allowed origins follow the address when it changes" \
    the_allowed_origins_follow_the_domain
property "an engine key an older release left as EMPTY is replaced" \
    the_engine_gets_a_key_of_its_own engine_key_left_empty

printf '\n%sA control plane pointed at a compute node%s\n' "$BOLD" "$NC"
property "it calls its own relay, which carries the link ut-pair makes" \
    a_control_plane_calls_its_own_relay
property "a platform linked by key before moves to its relay and is told how to pair" \
    a_platform_linked_by_key_moves_to_its_relay
property "a control plane with a GPU keeps it for llm and starts no engine" \
    a_control_plane_with_a_gpu_keeps_it_for_llm
property "a control plane without a GPU is installed as with --no-gpu" \
    a_control_plane_without_a_gpu_goes_without_it
property "the summary says where generation comes from" \
    the_summary_says_where_generation_comes_from
property "a compute node installs to the end" \
    a_compute_node_installs_to_the_end
property "a compute node's summary hands the control plane what it needs" \
    a_compute_node_hands_the_control_plane_what_it_needs
property "a node given as a URL is refused before anything is written" \
    a_node_given_as_a_url_is_refused
property "a node named by mDNS is refused before anything is written" \
    refused_before_anything_is_written pointed_at_an_mdns_node "names a .local host"
property "online, the weights the release pins are downloaded, checked and placed, and nothing is fetched on first start" \
    the_pinned_weights_are_downloaded_checked_and_placed
property "a weight that is not the file the release lists stops the install" \
    a_weight_that_is_not_the_listed_file_stops_the_install
property "weights already placed are not downloaded again" \
    weights_already_placed_are_not_downloaded_again
property "the check says what an installed box runs, and none of its secrets" \
    the_check_says_what_is_installed_and_no_secret
property "a certificate given to the installer is the one the front door serves" \
    tls_ends_with_the_given_certificate
property "a certificate that misses a name is refused before anything is written" \
    refused_before_anything_is_written certificate_short "does not cover llms.box.example.test assistants.box.example.test"
property "a certificate given with another key is refused before anything is written" \
    refused_before_anything_is_written certificate_with_another_key "is not the key of"
property "a certificate given without its key is refused before anything is written" \
    refused_before_anything_is_written certificate_without_its_key "holds no readable privkey.pem"
property "a load balancer given to the installer ends TLS, and is the only one believed" \
    tls_ends_at_the_given_proxy
property "a load balancer range that believes anyone is refused before anything is written" \
    refused_before_anything_is_written behind_any_proxy "would believe a forwarded address from anyone"
property "a certificate and a load balancer together are refused before anything is written" \
    refused_before_anything_is_written certificate_and_proxy "exclude each other"
property "a folder that lacks an image is refused before anything is written" \
    refused_before_anything_is_written folder_without_its_images "missing or not the one the release names"
property "a folder prepared for another role is refused, with both roles named" \
    refused_before_anything_is_written folder_for_another_role "was prepared for the compute role, and this machine is installed as appliance"
property "a folder prepared for another release is refused, with both versions named" \
    refused_before_anything_is_written folder_of_another_release "was prepared for release 0.0.1-other, and this is"
property "a folder prepared for another processor is refused before anything is written" \
    refused_before_anything_is_written folder_for_another_processor "was prepared for amd64, and this machine runs arm64"
property "a refused folder says how to prepare it again: version, role, and the images the settings run" \
    a_refused_folder_names_how_to_prepare_it_again
property "an engine address naming a service the stack does not run is named" \
    a_dead_vision_address_is_named
property "an install that downloads again forgets the names a folder gave its images" \
    a_pulling_install_forgets_the_names_of_a_folder
property "a compute node is installed with one flag, and asked for no domain" \
    a_compute_node_is_installed_with_one_flag
property "a compute node keeps the list of the platforms it admits, from its first run on" \
    a_compute_node_keeps_the_list_of_the_platforms_it_admits
property "a compute node named by mDNS is refused before anything is written" \
    refused_before_anything_is_written compute_named_by_mdns "cannot resolve a .local name"
property "a compute node without its GPU is refused before anything is written" \
    refused_before_anything_is_written compute_without_its_gpu "goes with neither --no-gpu nor --inference-from"

printf '\n%sA settings file that exists but says nothing%s\n' "$BOLD" "$NC"
property "it is filled rather than kept" \
    every_required_setting_is_filled empty_settings
property "and the result still renders" \
    the_settings_render_a_stack empty_settings

printf '\n%sA machine where the settings directory is gone%s\n' "$BOLD" "$NC"
property "it is recreated rather than reported as a broken link" \
    reached_the_pull no_settings_dir

printf '\n%sTwo machines are not the same machine%s\n' "$BOLD" "$NC"
property "two installs do not share a secret" \
    two_installs_do_not_share_a_secret

printf '\n%sA machine already configured%s\n' "$BOLD" "$NC"
property "running the installer again changes nothing" \
    running_it_again_changes_nothing

printf '\n%sA machine whose Docker address pools are full%s\n' "$BOLD" "$NC"
property "the preflight stops before anything is written" \
    the_preflight_stops_on_full_pools

printf '\n%sA machine too small to hold the models%s\n' "$BOLD" "$NC"
property "the refusal names what is free and what is needed" \
    the_preflight_stops_on_a_disk_too_small

printf '\n%sA machine whose clock is behind the release%s\n' "$BOLD" "$NC"
property "the preflight stops rather than issue certificates nothing will accept" \
    the_preflight_stops_on_a_clock_before_the_release

printf '\n%sA machine with no accelerator at all%s\n' "$BOLD" "$NC"
property "the install goes on when the inference is served elsewhere" \
    the_install_goes_on_when_the_inference_is_elsewhere
property "the preflight stops when nothing says the inference is elsewhere" \
    the_preflight_stops_when_nothing_says_the_inference_is_elsewhere
property "the disk floor follows what the machine will actually hold" \
    the_disk_floor_follows_what_the_machine_will_actually_hold
property "the flag writes a configuration that asks docker for no GPU" \
    the_flag_writes_a_configuration_that_asks_for_no_gpu
property "it says the inference address still points at nothing" \
    the_install_says_the_inference_url_points_nowhere
property "it stays quiet when the address already names another machine" \
    the_install_says_nothing_when_the_address_is_already_set

printf '\n%sAn install that still lives in a git checkout%s\n' "$BOLD" "$NC"
property "its settings are carried over, not regenerated" \
    the_checkout_settings_are_carried_over
property "the address it already answers on is kept" \
    the_address_comes_from_the_checkout
property "the checkout itself is left untouched" \
    the_checkout_is_left_alone
property "the App Builder's token key comes along, so stored GitLab tokens stay readable" \
    the_builder_key_comes_from_the_checkout
property "an install too old to name its address has it read from its URLs" \
    the_address_is_read_from_the_urls

printf '\n%sAn install with nobody watching%s\n' "$BOLD" "$NC"
property "it finishes, and says so" \
    an_install_that_worked_says_so
property "the secrets can be found afterwards" \
    the_secrets_are_findable_without_a_terminal
property "and none of them reached the log" \
    no_secret_reaches_the_log

printf '\n%sA license key%s\n' "$BOLD" "$NC"
property "a license key activates this machine with Keygen, and logs in with the token it carries" \
    a_license_activates_this_machine_and_logs_in_with_its_token
property "the license and the file Keygen signed are kept for updates, readable by root alone" \
    the_license_and_its_file_are_kept_for_root_alone
property "an update takes the license already on the machine, and asks Keygen nothing" \
    an_update_takes_the_license_already_there_with_no_network
property "a license file that has ended is renewed from Keygen, and the install goes on" \
    a_license_file_that_ended_is_renewed_from_keygen
property "a machine that cannot reach Keygen writes its request, and says what to do with it" \
    a_machine_with_no_network_writes_its_request_and_says_what_to_do
property "the license file sent back installs the machine with no network" \
    a_license_file_sent_back_installs_with_no_network
property "an altered license file sent back is refused before any request" \
    an_altered_license_file_sent_back_is_refused
property "an altered license file stops the install before any request and any login" \
    an_altered_license_file_stops_before_any_request_or_login
property "a license file made for another machine stops the install, and says so" \
    a_license_file_from_another_machine_stops_the_install
property "a license that has ended stops the install, and says when" \
    an_ended_license_stops_the_install_and_says_when
property "a license activated on another machine is refused, and says so" \
    a_license_activated_elsewhere_is_refused_and_says_so
property "with the images already here, a license needs no registry login" \
    images_already_here_need_no_registry_login
property "a license that names a registry pulls every image from it, digests kept" \
    a_license_naming_a_registry_pulls_every_image_from_it
property "a license that names no registry leaves the images where they are" \
    a_license_naming_no_registry_leaves_the_images_where_they_are
property "the token a license carries, and the license key, never reach the output" \
    the_carried_token_never_reaches_the_output
property "a license key of the old format is refused, and says what to ask for" \
    a_license_of_the_old_format_says_what_to_ask_for
property "a license with no registry token is refused to pull, and taken when nothing is pulled" \
    a_license_with_no_registry_token_is_refused_only_to_pull
property "a registry token alone still installs, and says a license will be needed" \
    a_token_alone_still_installs_and_says_so

printf '\n%sLaunched from a checkout%s\n' "$BOLD" "$NC"
property "it takes the checkout it is standing in, and asks for no token" \
    a_checkout_under_foot_needs_no_token
property "but a machine with no credentials is still asked for a key" \
    a_machine_with_no_credentials_is_still_asked

printf '\n%sA database nobody has the password for%s\n' "$BOLD" "$NC"
property "the install stops, and says which volume and what to do" \
    an_orphan_volume_stops_the_install
property "it offers the way back before the way out" \
    the_way_back_comes_before_the_way_out

printf '\n%sA backup sent to a directory the host mounts%s\n' "$BOLD" "$NC"
property "a destination on a disk of its own is used, and marked as mounted" \
    a_mounted_backup_destination_is_used_and_marked
property "one on the machine's own disk stops the install, and says how to get out" \
    a_destination_on_the_machine_s_own_disk_stops_the_install

printf '\n%sA backup sent over the network%s\n' "$BOLD" "$NC"
property "an SFTP destination gets a key made for it, read by root alone, its public half shown" \
    an_sftp_destination_gets_a_key_only_root_reads
property "a key the SFTP destination already knows is never replaced" \
    a_key_the_destination_knows_is_never_replaced
property "an S3 or SFTP destination gets its way out, and the missing host key is named" \
    a_network_destination_gets_its_way_out_and_names_the_key_it_lacks
property "the default destination adds no way out" \
    the_default_destination_adds_no_way_out
property "naming two destinations stops the install, before anything is written" \
    two_destinations_stop_the_install
property "a destination gone during an update holds the update back no more than it says so" \
    a_destination_gone_on_an_update_holds_nothing_back

printf '\n%sA database whose password happens to look shipped%s\n' "$BOLD" "$NC"
property "the install carries on, because that password is the right one" \
    a_shipped_password_is_still_a_password

printf '\n%s%d verified%s' "$GREEN" "$PASSED" "$NC"
if (( FAILED )); then
    printf ', %s%d failing%s\n' "$RED" "$FAILED" "$NC"
    printf '\nNot working:\n'
    for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
    printf '\n'
    exit 1
fi
printf '\n'
