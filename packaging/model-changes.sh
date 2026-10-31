#!/usr/bin/env bash
# The release notes' paragraph on models: whether the settings that decide which
# model a box serves, on which engine and with which arguments, changed since
# the previous release. A customer's agreement is asked for on that paragraph.
#   model-changes.sh PREVIOUS_RELEASE_ENV CURRENT_RELEASE_ENV PREVIOUS_VERSION
set -euo pipefail

previous_env=$1
current_env=$2
previous_version=$3

MODEL_SETTINGS=(NIM_IMAGE NIM_LLM_MODEL_PATH NIM_LLM_PASSTHROUGH_ARGS LLM_MODEL
    VLLM_ENGINE_IMAGE VLLM_ENGINE_MODEL VLLM_ENGINE_ARGS EMBED_MODEL_NAME RERANKER_HF_PATH)

value_in() {
    sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$2" | tail -1
}

changed=()
for key in "${MODEL_SETTINGS[@]}"; do
    before=$(value_in "$key" "$previous_env")
    after=$(value_in "$key" "$current_env")
    [[ "$before" == "$after" ]] || changed+=("- \`${key}\`: \`${before:-unset}\` → \`${after:-unset}\`")
done

if (( ${#changed[@]} == 0 )); then
    printf '**Models: unchanged since %s.** The model, its engine and their arguments are those of the previous release.\n\n' "$previous_version"
    exit 0
fi

printf '**Models: changed since %s.** Updating changes what a box serves:\n\n' "$previous_version"
printf '%s\n' "${changed[@]}"
printf '\nA customer who has not agreed to the change keeps the model they have with `sudo ut-install --model <id>` before updating, while this release proves it on their GPU — see [updating](https://github.com/understand-tech/ai-in-a-box/blob/%s/docs/update.md).\n\n' "${GITHUB_REF_NAME:-2026-Q4}"
