#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PACKAGE="understandtech"
VERSION="${1:-}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/dist}"

SHARE_DIR="usr/share/$PACKAGE"
DOC_DIR="usr/share/doc/$PACKAGE"
LIB_DIR="usr/lib/$PACKAGE"
UT_SEND_BUILDS="${UT_SEND_BUILDS:-$REPO_ROOT/dist/ut-send}"
UT_SETUP_BUILDS="${UT_SETUP_BUILDS:-$REPO_ROOT/dist/ut-setup}"
CONFIG_DIR="etc/$PACKAGE"

usage() {
    cat <<EOF
build-deb.sh — builds the ${PACKAGE} Debian package.

  ./packaging/build-deb.sh 2026.09.1

The version is the only argument. It has to be orderable by dpkg, so
YYYY.MM.N reads the way it sorts.

Writes to \$OUT_DIR (default: dist/). Needs ut-send and ut-setup compiled first
(packaging/build-ut-send.sh), and dpkg-deb, so run it on Debian or in a
container:

  docker run --rm -v "\$PWD":/src -w /src debian:12-slim ./packaging/build-deb.sh 2026.09.1
EOF
}

version_is_orderable() {
    [[ "$1" =~ ^[0-9][0-9a-zA-Z.+~-]*$ ]]
}

stage_release_files() {
    local root=$1
    install -d "$root/$SHARE_DIR"
    install -m 644 "$REPO_ROOT"/compose*.yaml "$root/$SHARE_DIR/"
    install -m 644 "$REPO_ROOT/Caddyfile" "$root/$SHARE_DIR/"
    install -m 644 "$REPO_ROOT/packaging/release.pub" "$root/$SHARE_DIR/"
    cp -r "$REPO_ROOT/caddy" "$root/$SHARE_DIR/"
    cp -r "$REPO_ROOT/appbuilder" "$root/$SHARE_DIR/"
    cp -r "$REPO_ROOT/metrics" "$root/$SHARE_DIR/"
    cp -r "$REPO_ROOT/models" "$root/$SHARE_DIR/"
    install -m 755 "$REPO_ROOT/setup-autostart.sh" "$root/$SHARE_DIR/"
    install -m 755 "$REPO_ROOT/backup-files.sh" "$root/$SHARE_DIR/"
    find "$root/$SHARE_DIR/caddy" "$root/$SHARE_DIR/appbuilder" "$root/$SHARE_DIR/metrics" "$root/$SHARE_DIR/models" -type f -exec chmod 644 {} +
}

# dpkg compares numbers, not contents: 2026.09.3 built from an older commit
# installed over 2026.09.2 and put a fixed defect back, in silence.
release_commit() {
    local commit
    commit=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null) \
        || { printf '%s' "${UT_RELEASE_COMMIT:-}"; return 0; }
    git -C "$REPO_ROOT" diff --quiet HEAD 2>/dev/null || commit="${commit}-dirty"
    printf '%s' "$commit"
}

warn_about_a_tree_nobody_can_match() {
    local commit=$1
    case "$commit" in
        "")       echo "[warn] No commit could be read: this package says nothing about its source." >&2 ;;
        *-dirty)  echo "[warn] The tree has uncommitted changes: '${commit}' matches no published commit." >&2 ;;
    esac
    git -C "$REPO_ROOT" rev-list --count '@{upstream}..HEAD' 2>/dev/null | grep -qvx 0 \
        && echo "[warn] This branch is ahead of its upstream: the commit is not pushed anywhere." >&2
    return 0
}

stamp_the_release_version() {
    local root=$1 version=$2 commit stamp built_at
    commit=$(release_commit)
    warn_about_a_tree_nobody_can_match "$commit"
    stamp="$version"
    [[ -n "$commit" ]] && stamp="${version}+${commit}"
    # The same value the archive's timestamps are clamped to, so the stamp is
    # the commit's date and not the hour this ran at: a build date that moved
    # between two builds would make the package unreproducible again.
    built_at="${SOURCE_DATE_EPOCH:-}"
    sed -e "s|^UT_RELEASE_VERSION=.*|UT_RELEASE_VERSION=\"${stamp}\"|" \
        -e "s|^UT_RELEASE_BUILT_AT=.*|UT_RELEASE_BUILT_AT=\"${built_at}\"|" \
        "$REPO_ROOT/release.env" > "$root/$SHARE_DIR/release.env"
    chmod 644 "$root/$SHARE_DIR/release.env"
}

stage_commands() {
    local root=$1
    install -d "$root/usr/bin"
    install -m 755 "$REPO_ROOT/bin/ut-install" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-certificate" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-logs-archive" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-verify" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-get" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-import-app" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-license" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-status" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-report" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-send" "$root/usr/bin/"
    install -m 755 "$REPO_ROOT/bin/ut-setup" "$root/usr/bin/"
}

stage_builds_of() {
    local root=$1 tool=$2 builds=$3 arch
    install -d "$root/$LIB_DIR"
    for arch in arm64 amd64; do
        [[ -f "$builds/$tool-linux-$arch" ]] || {
            echo "$tool-linux-$arch is missing from $builds — run packaging/build-ut-send.sh first" >&2
            exit 1
        }
        install -m 755 "$builds/$tool-linux-$arch" "$root/$LIB_DIR/"
    done
}

stage_documentation() {
    local root=$1
    install -d "$root/$DOC_DIR"
    install -m 644 "$REPO_ROOT/README.md" "$root/$DOC_DIR/"
    install -m 644 "$REPO_ROOT"/docs/*.md "$root/$DOC_DIR/"
}

# .env lives in /etc because it is the customer's, and is reached through a link
# because compose reads .env from the project directory and nowhere else.
# Measured: compose follows the link, and a broken one reads as no file at all —
# which the required ${VAR:?} entries then refuse to start on.
link_configuration_into_project_directory() {
    local root=$1
    install -d -m 750 "$root/$CONFIG_DIR"
    ln -s "/$CONFIG_DIR/.env" "$root/$SHARE_DIR/.env"
}

# du reports blocks, and the filesystem decides how many: the same tree measured
# 396 KiB on a runner and 348 here, which is enough to make a rebuilt package
# differ from the one that was signed. Apparent size rounded per file is the
# same number everywhere.
installed_size_in_kib() {
    find "$1" -type f -exec du -k --apparent-size {} + \
        | awk '{ total += $1 } END { print total + 0 }'
}

write_control() {
    local root=$1 version=$2 size
    size=$(installed_size_in_kib "$root")
    install -d "$root/DEBIAN"
    cat > "$root/DEBIAN/control" <<EOF
Package: $PACKAGE
Version: $version
Section: utils
Priority: optional
Architecture: all
Maintainer: UnderstandTech <contact@understand.tech>
Installed-Size: $size
Depends: openssl (>= 3.0), jq, curl
Recommends: docker-ce | docker.io
Homepage: https://github.com/understand-tech/ai-in-a-box
Description: On-premise AI appliance
 Compose stack, reverse proxy configuration and operating tools for the
 UnderstandTech appliance.
 .
 The release lives in /usr/share/understandtech and is replaced on upgrade.
 Settings live in /etc/understandtech and are never overwritten. Data lives
 in /var/lib/understandtech.
 .
 Run "sudo ut-install" after installing to generate the secrets and start
 the stack.
EOF
}

write_maintainer_scripts() {
    local root=$1
    cat > "$root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = configure ]; then
    install -d -m 750 /etc/understandtech
    install -d -m 755 /var/lib/understandtech

    if [ ! -e /etc/understandtech/.env ]; then
        echo ""
        echo "understandtech installed. Nothing is configured yet:"
        echo ""
        echo "  sudo ut-install"
        echo ""
        echo "It generates every secret, writes /etc/understandtech/.env,"
        echo "and starts the stack."
        echo ""
    fi
fi
EOF
    cat > "$root/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

# /etc/understandtech and /var/lib/understandtech are deliberately left behind:
# they hold the customer's settings and data, which removing a package must not
# take with it.

# The timer ut-send configure set up would go on calling a program that is gone.
# An upgrade keeps it: the new ut-send sits at the same path.
if [ "$1" = remove ] && [ -e /etc/systemd/system/ut-send.timer ]; then
    systemctl disable --now ut-send.timer >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/ut-send.timer /etc/systemd/system/ut-send.service
    systemctl daemon-reload >/dev/null 2>&1 || true
fi
EOF
    chmod 755 "$root/DEBIAN/postinst" "$root/DEBIAN/prerm"
}

write_md5sums() {
    local root=$1
    # find walks in directory order, which the filesystem decides too. Sorting
    # is what makes two machines write this file the same way — under LC_ALL=C,
    # because a UTF-8 collation orders ut-helper and ut_helper the other way
    # round and the locale belongs to the machine as much as the block size does.
    ( cd "$root" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' \
        | LC_ALL=C sort -z | xargs -0 md5sum > DEBIAN/md5sums )
}

main() {
    case "${VERSION}" in
        ""|-h|--help) usage; [[ -z "$VERSION" ]] && exit 1 || exit 0 ;;
    esac
    version_is_orderable "$VERSION" \
        || { echo "Version '$VERSION' is not orderable by dpkg" >&2; exit 1; }
    command -v dpkg-deb >/dev/null 2>&1 \
        || { echo "dpkg-deb is missing — see --help for the container form" >&2; exit 1; }

    # Not a local: the EXIT trap runs after main returns, where a local is gone.
    root=$(mktemp -d)
    trap 'rm -rf "$root"' EXIT
    chmod 755 "$root"

    stage_release_files "$root"
    stamp_the_release_version "$root" "$VERSION"
    stage_commands "$root"
    stage_builds_of "$root" ut-send "$UT_SEND_BUILDS"
    stage_builds_of "$root" ut-setup "$UT_SETUP_BUILDS"
    stage_documentation "$root"
    link_configuration_into_project_directory "$root"
    write_control "$root" "$VERSION"
    write_maintainer_scripts "$root"
    write_md5sums "$root"

    install -d "$OUT_DIR"
    local deb="$OUT_DIR/${PACKAGE}_${VERSION}_all.deb"
    dpkg-deb --root-owner-group --build "$root" "$deb" >/dev/null
    printf '%s\n' "$deb"
}

main "$@"
