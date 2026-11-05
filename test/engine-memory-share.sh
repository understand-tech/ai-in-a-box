#!/usr/bin/env bash
# Checks, on the real ut-install functions, the share of the machine's memory the
# engines may take where the GPU has none of its own, and how it is read from the
# settings in effect.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
UT_INSTALL_DIR="$WORK" source "$REPO_ROOT/bin/ut-install" >/dev/null 2>&1
set +e
trap - ERR
trap 'rm -rf "$WORK"' EXIT

FAILED=0
expect() {
    local what=$1 expected=$2 got=$3
    if [[ "$got" == "$expected" ]]; then
        echo "ok    $what"
    else
        echo "FAIL  $what: expected '$expected', got '$got'"
        FAILED=1
    fi
}

MEMORY_OF_A_GB10_KB=127600000
SMALL_KB=$((32 * 1024 * 1024))
expect "a GB10 running the platform: 0.80" 0.80 "$(engine_share_ceiling "$MEMORY_OF_A_GB10_KB" yes)"
expect "a GB10 compute node: what the reserve leaves" 0.91 "$(engine_share_ceiling "$MEMORY_OF_A_GB10_KB" no)"
expect "a machine of 32 GiB: the reserve binds first" 0.68 "$(engine_share_ceiling "$SMALL_KB" yes)"

LOCAL="$WORK/local.env"
printf 'NIM_LLM_PASSTHROUGH_ARGS="--gpu-memory-utilization 0.75 --max-model-len 32768"\nLLM_BACKEND="nim"\n' > "$WORK/release.env"
: > "$LOCAL"
expect "the release's NIM share when nothing overrides it" 0.75 "$(engines_share "$LOCAL")"

printf 'COMPOSE_FILE=compose.yaml:compose.engine-vllm.yaml\nVLLM_ENGINE_ARGS=--gpu-memory-utilization 0.85 --trust-remote-code\n' > "$LOCAL"
expect "the vLLM entry a model wrote, unquoted" 0.85 "$(engines_share "$LOCAL")"

printf 'LLM_BACKEND="vllm"\nVLLM_LLM_GPU_MEM_UTIL="0.45"\nVLLM_VLM_GPU_MEM_UTIL="0.12"\n' >> "$LOCAL"
expect "ut-llm's own engines added when it runs them" 1.42 "$(engines_share "$LOCAL")"

printf 'COMPOSE_FILE=compose.yaml:compose.engine-vllm.yaml\nVLLM_ENGINE_ARGS=--trust-remote-code\n' > "$LOCAL"
engines_share "$LOCAL" >/dev/null
expect "an engine without a share is refused" 1 "$?"

printf 'COMPOSE_FILE=compose.yaml:compose.engine-sglang.yaml\nSGLANG_ENGINE_ARGS=--mem-fraction-static 0.7 --context-length 32768\n' > "$LOCAL"
expect "an SGLang engine's share read through its own flag" 0.7 "$(engines_share "$LOCAL")"

printf 'COMPOSE_FILE=compose.yaml:compose.engine-made-up.yaml\n' > "$LOCAL"
engines_share "$LOCAL" >/dev/null
expect "an engine family without a known share setting is refused" 2 "$?"

INSTALLER="$REPO_ROOT/bin/ut-install"
inside_the_table=$(awk '/^memory_share_setting_of\(\) \{/,/^}/' "$INSTALLER" | grep -cE -- '--gpu-memory-utilization|--mem-fraction-static')
everywhere=$(grep -cE -- '--gpu-memory-utilization|--mem-fraction-static' "$INSTALLER")
outside=$(( everywhere - inside_the_table ))
expect "no engine's memory flag named outside the family table" 0 "$outside"

exit $FAILED
