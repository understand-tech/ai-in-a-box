#!/usr/bin/env bash
# The images the suites run, each named by digest. A suite that pulls a tag
# tests whatever the registry serves that day: quay.io/minio/minio:latest
# stopped answering on 2026-10-06 and two capabilities failed with it.
# Images the release ships are read from release.env, so a suite runs exactly
# what an install pulls.

release_image() {
    sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$(dirname "${BASH_SOURCE[0]}")/../release.env"
}

CADDY_IMAGE=$(release_image CADDY_IMAGE)
MONGODB_IMAGE=$(release_image MONGODB_IMAGE)
RESTIC_IMAGE=$(release_image FILES_BACKUP_IMAGE)
RELAY_IMAGE=$(release_image BACKUP_RELAY_IMAGE)
PROMETHEUS_IMAGE=$(release_image PROMETHEUS_IMAGE)

ALPINE_IMAGE="alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6"
DEBIAN_IMAGE="debian:12.15-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587"
BASH_IMAGE="bash:5.3.20@sha256:61962062d969cb46dfc2bad061d36342406fa485f64f246aa7e95693ca07df1f"
BASH_3_IMAGE="bash:3.2.57@sha256:0fd7cb8499c63a3c9345e7088a9cd83bb69f6e895e83833859aff838a0312091"
PYTHON_IMAGE="python:3.12-alpine@sha256:1b668429b3511ab407d8e00648891631b0b1a4d7e15e3ca70f38ab5b91ad4ab4"
# A versioned tag on a registry that never deletes an image: quay.io dropped the
# manifest of busybox:latest the night after it was pinned here.
BUSYBOX_IMAGE="registry.k8s.io/e2e-test-images/busybox:1.36.1-1@sha256:a9155b13325b2abef48e71de77bb8ac015412a566829f621d06bfae5c699b1b9"
ALPINE_INDEX_IMAGE="ghcr.io/linuxcontainers/alpine:3.20@sha256:28a33e0390da2b341d05e53803c6766977039baedfc8a82a4910d5acc4755b66"
CURL_IMAGE="curlimages/curl:8.22.0@sha256:58adaa4e8dca9c988bae2aba4ab3434a0bb2da16bbe3f92dec39ec7785166777"
YQ_IMAGE="mikefarah/yq:4.53.6@sha256:cfc4eee658595834ef304eadb0c3ea721f3b7cb6404ad8b7cb909cc5b5145b23"
OBJECT_STORE_IMAGE="rclone/rclone:1.75.1@sha256:45401ad7410db1d67ffdb58e19059ad20b0d8e0285a60e38bbec55cc1019c7a5"
SFTP_SERVER_IMAGE="lscr.io/linuxserver/openssh-server:10.3_p1-r1-ls239@sha256:0f535b0faa7448511b23528165e9fbd4f1fe563b861b3dcaa5ddb0ddbfe2254c"
