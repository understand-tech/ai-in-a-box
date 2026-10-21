#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
    cat <<EOF
pin-weights.sh — prints the weights of a Hugging Face repository at one revision,
one line per file: <sha256> <size> <repository>@<revision>/<path>

  ./packaging/pin-weights.sh <repository> <revision> [path...]

Without paths, every file but .gitattributes. Run it when a model enters the
registry or changes revision, and keep its output in models/weights/: the box
that installs from a folder takes a weight only if it is listed there, and the
signed package is what lists it.

Hugging Face gives the sha256 of a large file; a small one it names by its git
blob, so the file is downloaded, hashed, and checked against that blob.
EOF
}

fail() { printf '%s\n' "$*" >&2; exit 1; }

sha256_of() { openssl dgst -sha256 -r "$1" | cut -d' ' -f1; }

git_blob_of() {
    { printf 'blob %s\0' "$(wc -c < "$1" | tr -d ' ')"; cat "$1"; } | openssl dgst -sha1 -r | cut -d' ' -f1
}

main() {
    [[ $# -ge 2 ]] || { usage >&2; exit 1; }
    [[ "$1" == -h || "$1" == --help ]] && { usage; exit 0; }
    local repository=$1 revision=$2 tree tmp path size kind oid sha
    shift 2
    command -v jq >/dev/null || fail "jq is required"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || fail "give the revision as its 40-character commit, not ${revision}"

    tree=$(curl -fsS --max-time 60 "https://huggingface.co/api/models/${repository}/tree/${revision}?recursive=true") \
        || fail "Hugging Face did not list ${repository} at ${revision}"
    tmp=$(mktemp)
    while IFS=$'\t' read -r path size kind oid; do
        [[ "$path" == .gitattributes ]] && continue
        if (( $# )); then
            printf '%s\n' "$@" | grep -qxF "$path" || continue
        fi
        if [[ "$kind" == lfs ]]; then
            sha=$oid
        else
            curl -fsSL --max-time 300 -o "$tmp" "https://huggingface.co/${repository}/resolve/${revision}/${path}" \
                || fail "Could not download ${path}"
            [[ "$(git_blob_of "$tmp")" == "$oid" ]] || fail "${path} is not the blob Hugging Face lists for it"
            sha=$(sha256_of "$tmp")
        fi
        printf '%s %s %s@%s/%s\n' "$sha" "$size" "$repository" "$revision" "$path"
    done < <(jq -r '.[] | select(.type=="file") | [.path, (.size|tostring), (if .lfs then "lfs" else "git" end), (if .lfs then .lfs.oid else .oid end)] | @tsv' <<< "$tree")
    rm -f "$tmp"
}

main "$@"
