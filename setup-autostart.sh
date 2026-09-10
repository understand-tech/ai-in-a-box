#!/bin/bash
# UnderstandTech Auto-Start Setup Script
#
# Installs two systemd units:
#   understandtech.service  - brings the compose stack up on boot
#   ut-mdns-alias.service   - publishes the .local names over mDNS, all of them
#                             derived from UT_DOMAIN in .env
#
# It does not pull images, create stack resources, or start anything. Deploy
# the stack the normal way (docker compose pull && docker compose up -d); this
# script only makes it survive a reboot.
#
# Usage: sudo ./setup-autostart.sh [OPTIONS]
#   --install     Install and enable both units (default)
#   --mdns        Install only the mDNS aliases (satellite + generated apps)
#   --check       Check the domain / TLS / proxy settings, changing nothing
#   --uninstall   Remove the units
#   --status      Show unit status
#   --dir PATH    Install directory (default: the directory holding this script)

set -euo pipefail

SERVICE_NAME="understandtech"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
MDNS_SERVICE_NAME="ut-mdns-alias"
MDNS_SERVICE_FILE="/etc/systemd/system/${MDNS_SERVICE_NAME}.service"
MDNS_HELPER="/usr/local/bin/ut-mdns-alias"
MDNS_DEFAULTS="/etc/default/ut-mdns-alias"
DOCKER_BIN=""

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; NC=''
fi

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} $1"; }

banner() {
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# The install directory is wherever the repository was cloned. The documented
# path is ~/understand-tech, but nothing here depends on that — deriving it
# from this script's own location means the installed unit always points at
# the checkout the installer was run from.
resolve_script_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" == /* ]] || src="$dir/$src"
    done
    ( cd -P "$(dirname "$src")" && pwd )
}

INSTALL_DIR="${UT_INSTALL_DIR:-$(resolve_script_dir)}"

# Write via a temp file in the same directory and rename into place. The mDNS
# helper is a running process's script file: truncating it in place makes the
# live /bin/sh read the rest of its program from the wrong offset.
#
# Returns 0 if the file changed, 1 if the content was already identical, so
# callers can skip the work that only a change makes necessary.
write_file_atomic() {
    local path="$1" mode="$2" tmp
    mkdir -p "$(dirname "$path")"
    tmp="$(mktemp "${path}.XXXXXX")"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$path"
    return 0
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_docker() {
    DOCKER_BIN="$(command -v docker || true)"
    if [[ -z "$DOCKER_BIN" ]]; then
        log_error "Docker is not installed"
        exit 1
    fi
    if ! "$DOCKER_BIN" compose version &>/dev/null; then
        log_error "Docker Compose V2 is not available"
        exit 1
    fi
}

# Always run compose from the install directory: that is where it picks up
# .env, and .env is where COMPOSE_FILE and COMPOSE_PROFILES live.
compose() {
    ( cd "$INSTALL_DIR" && "$DOCKER_BIN" compose "$@" )
}

# Read one variable out of the install directory's .env. Deliberately not
# `source`: compose keeps quoting that a shell strips, and .env holds a JSON
# GATEWAY_MODELS value whose braces and quotes a shell would glob or execute.
# Prints nothing when the file or the variable is absent, so callers apply
# their own default.
env_value() {
    local var="$1" file="${2:-$INSTALL_DIR/.env}" raw
    [[ -r "$file" ]] || return 0
    raw="$(sed -n "s/^[[:space:]]*${var}[[:space:]]*=[[:space:]]*//p" "$file" | tail -n1)"
    [[ -n "$raw" ]] || return 0
    case "$raw" in
        \"*) raw="${raw#\"}"; raw="${raw%%\"*}" ;;
        \'*) raw="${raw#\'}"; raw="${raw%%\'*}" ;;
        *)   raw="${raw%%[[:space:]#]*}" ;;
    esac
    printf '%s' "$raw"
}

check_prerequisites() {
    log_step "Checking prerequisites..."

    detect_docker

    if [[ ! -d "$INSTALL_DIR" ]]; then
        log_error "Install directory not found: $INSTALL_DIR"
        echo ""
        echo "Pass the checkout location explicitly:"
        echo "  sudo ./setup-autostart.sh --dir /path/to/understand-tech"
        exit 1
    fi

    if [[ ! -f "$INSTALL_DIR/compose.yaml" ]]; then
        log_error "compose.yaml not found in $INSTALL_DIR"
        exit 1
    fi

    if [[ ! -f "$INSTALL_DIR/Caddyfile" ]]; then
        log_warn "Caddyfile not found in $INSTALL_DIR — the proxy will not start"
    fi

    # .env is not required to install the units — it is only read when the
    # stack is started, which this script never does. Installing auto-start
    # before configuring the environment is a legitimate order, so this is a
    # warning, not an error. When .env is there, validate it: a broken one
    # should surface now rather than on the next reboot.
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        if ! compose config -q; then
            log_error "'docker compose config' failed in $INSTALL_DIR — fix the errors above first"
            exit 1
        fi
        log_info "Prerequisites satisfied (install directory: $INSTALL_DIR)"

        # Reported, not fatal: installing the units is still the right thing to
        # do on a box whose ingress settings are not finished yet.
        echo ""
        if ! check_ingress; then
            log_warn "Ingress configuration has errors — see above. The units install anyway;"
            log_warn "fix them before 'docker compose up -d' or Caddy will not start."
        fi
    else
        log_warn "No .env in $INSTALL_DIR yet — units installed anyway."
        log_warn "The stack will boot once you create it: cp .env.example .env"
    fi
}

# The ingress settings interact in ways that neither `docker compose config`
# nor `caddy validate` catches on its own:
#   - a typo in UT_INGRESS_MODE leaves the bind-mount source missing, and
#     docker silently creates a directory there instead of failing;
#   - UT_INGRESS_MODE=edge with UT_CADDY_SCHEME=https adapts cleanly, then
#     listens on :443 holding no certificate, so the load balancer's requests
#     to :80 reach nothing at all;
#   - a missing certificate file in custom mode stops Caddy from starting,
#     because validating the config provisions the TLS app for real.
# Catching these here means the operator finds out before the first `up`
# rather than from a restart loop. Returns non-zero when something is wrong.
check_ingress() {
    local errors=0
    local domain mode caddy_scheme public_scheme cert_dir

    domain="$(env_value UT_DOMAIN)";               domain="${domain:-understand.local}"
    mode="$(env_value UT_INGRESS_MODE)";           mode="${mode:-internal}"
    caddy_scheme="$(env_value UT_CADDY_SCHEME)";   caddy_scheme="${caddy_scheme:-https}"
    public_scheme="$(env_value UT_PUBLIC_SCHEME)"; public_scheme="${public_scheme:-https}"
    cert_dir="$(env_value UT_CERT_DIR)";           cert_dir="${cert_dir:-$INSTALL_DIR/caddy/certs}"

    log_step "Checking ingress configuration..."
    echo "  UT_DOMAIN          $domain"
    echo "  UT_INGRESS_MODE    $mode"
    echo "  UT_CADDY_SCHEME    $caddy_scheme  (the scheme Caddy listens on)"
    echo "  UT_PUBLIC_SCHEME   $public_scheme  (the scheme the apps advertise)"
    echo ""

    local fragment="$INSTALL_DIR/caddy/ingress-${mode}.caddy"
    if [[ ! -f "$fragment" ]]; then
        local available
        available="$(cd "$INSTALL_DIR/caddy" 2>/dev/null && ls ingress-*.caddy 2>/dev/null \
            | sed -e 's/^ingress-//' -e 's/\.caddy$//' | tr '\n' ' ')"
        log_error "UT_INGRESS_MODE=\"$mode\" has no fragment at $fragment"
        log_error "Available modes: ${available:-none found}"
        errors=$((errors + 1))
    fi

    case "$mode" in
        edge)
            if [[ "$caddy_scheme" != http ]]; then
                log_error "UT_INGRESS_MODE=\"edge\" requires UT_CADDY_SCHEME=\"http\" (it is \"$caddy_scheme\")."
                log_error "On https Caddy listens on :443 expecting to hold the certificate itself,"
                log_error "and the plain HTTP your proxy sends to :80 reaches nothing."
                errors=$((errors + 1))
            fi
            if [[ -z "$(env_value UT_TRUSTED_PROXIES)" ]]; then
                log_warn "UT_TRUSTED_PROXIES is unset, so every private range is trusted to set"
                log_warn "X-Forwarded-*. Narrow it to the network your proxy speaks from."
            fi
            ;;
        internal|custom)
            if [[ "$caddy_scheme" != https ]]; then
                log_error "UT_CADDY_SCHEME=\"$caddy_scheme\" only makes sense with UT_INGRESS_MODE=\"edge\"."
                errors=$((errors + 1))
            fi
            ;;
    esac

    if [[ "$mode" == custom ]]; then
        local cfile kfile cert key f
        cfile="$(env_value UT_CERT_FILE)"; cfile="${cfile:-/etc/caddy/certs/fullchain.pem}"
        kfile="$(env_value UT_KEY_FILE)";  kfile="${kfile:-/etc/caddy/certs/privkey.pem}"
        # Those are paths inside the container, and UT_CERT_DIR is what gets
        # mounted there — translate before looking for them on the host.
        cert="${cfile/#\/etc\/caddy\/certs/$cert_dir}"
        key="${kfile/#\/etc\/caddy\/certs/$cert_dir}"

        for f in "$cert" "$key"; do
            if [[ ! -r "$f" ]]; then
                log_error "custom mode, but $f is missing or unreadable."
                errors=$((errors + 1))
            fi
        done

        # A certificate covering only the apex leaves the four satellite names
        # on a mismatch every browser refuses, and that is easier to diagnose
        # now than from a TLS error later.
        if [[ -r "$cert" ]] && command -v openssl &>/dev/null; then
            local sans h missing=()
            sans="$(openssl x509 -noout -ext subjectAltName -in "$cert" 2>/dev/null | tr -d ' ')"
            for h in "$domain" "llms.$domain" "assistants.$domain" "admin.$domain" "builder.$domain"; do
                [[ "$sans" == *"DNS:$h"* || "$sans" == *"DNS:*.${h#*.}"* ]] || missing+=("$h")
            done
            (( ${#missing[@]} )) && log_warn "Certificate SANs do not cover: ${missing[*]}"
            if [[ "$sans" != *"DNS:*.apps.$domain"* ]]; then
                log_warn "No *.apps.$domain SAN — App Builder generated apps will fail TLS."
                log_warn "Supply a second wildcard via UT_APPS_CERT_FILE / UT_APPS_KEY_FILE."
            fi
        fi
    fi

    if [[ "$domain" != *.local ]]; then
        log_info "Outside .local: mDNS does not apply, so create these records in your own DNS,"
        log_info "pointing at this box (or at the proxy in front of it):"
        echo "    $domain  llms.$domain  assistants.$domain  admin.$domain  builder.$domain  *.apps.$domain"
    fi

    # The decisive check: adapt and provision the config with the very image
    # the stack runs. Skipped rather than pulled when that image is not local,
    # so an air-gapped box never stalls here.
    local caddy_image
    caddy_image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\(caddy:[^[:space:]]*\).*/\1/p' \
        "$INSTALL_DIR/compose.yaml" 2>/dev/null | head -n1)"
    if [[ -f "$fragment" && -n "$caddy_image" ]] && "$DOCKER_BIN" image inspect "$caddy_image" &>/dev/null; then
        local -a args=(--rm
            -v "$INSTALL_DIR/Caddyfile:/etc/caddy/Caddyfile:ro"
            -v "$fragment:/etc/caddy/ingress.caddy:ro"
            -e "UT_DOMAIN=$domain" -e "UT_CADDY_SCHEME=$caddy_scheme")
        [[ -d "$cert_dir" ]] && args+=(-v "$cert_dir:/etc/caddy/certs:ro")
        # Passed only when non-empty on purpose: Caddy applies a placeholder's
        # default when the variable is absent, but a variable that is present
        # and empty expands to nothing and breaks the directive.
        local v
        for v in UT_TRUSTED_PROXIES UT_CERT_FILE UT_KEY_FILE UT_APPS_CERT_FILE UT_APPS_KEY_FILE; do
            local val; val="$(env_value "$v")"
            [[ -n "$val" ]] && args+=(-e "$v=$val")
        done

        local out
        if out="$("$DOCKER_BIN" run "${args[@]}" "$caddy_image" \
                  caddy validate --config /etc/caddy/Caddyfile 2>&1)"; then
            log_info "Caddy accepts the resulting configuration"
        else
            log_error "'caddy validate' rejects the resulting configuration:"
            printf '%s\n' "$out" | grep -E '^Error|error' | head -3 | sed 's/^/    /'
            errors=$((errors + 1))
        fi
    fi

    (( errors == 0 ))
}

do_check() {
    banner "UnderstandTech Ingress Check"

    detect_docker

    if [[ ! -f "$INSTALL_DIR/.env" ]]; then
        log_error "No .env in $INSTALL_DIR — nothing to check yet."
        echo "  cp .env.example .env"
        exit 1
    fi

    if ! compose config -q; then
        log_error "'docker compose config' failed — fix the errors above first"
        exit 1
    fi

    echo ""
    if check_ingress; then
        echo ""
        log_info "Ingress configuration looks consistent."
    else
        echo ""
        log_error "Ingress configuration has errors — fix them before 'docker compose up -d'."
        exit 1
    fi
}

install_mdns_defaults() {
    # Created once and never overwritten, so an operator's added names survive
    # the next --mdns run. The helper itself is regenerated every time.
    if [[ -f "$MDNS_DEFAULTS" ]]; then
        log_info "Keeping existing $MDNS_DEFAULTS"

        # A literal UT_MDNS_ALIASES predates domain derivation and wins over
        # it, so it keeps publishing the names it was written with. Harmless
        # until the operator moves the box to another domain, at which point
        # the published names and UT_DOMAIN silently disagree.
        local literal domain
        literal="$(sed -n 's/^[[:space:]]*UT_MDNS_ALIASES[[:space:]]*=[[:space:]]*//p' "$MDNS_DEFAULTS" | tail -n1)"
        domain="$(env_value UT_DOMAIN)"
        if [[ -n "$literal" && -n "$domain" && "$literal" != *"$domain"* ]]; then
            log_warn "$MDNS_DEFAULTS pins a literal UT_MDNS_ALIASES that does not mention"
            log_warn "UT_DOMAIN=\"$domain\" — those names take precedence over derivation."
            log_warn "Comment the UT_MDNS_ALIASES line out to publish names derived from UT_DOMAIN."
        fi
        return 0
    fi

    if {
        cat << 'DEFAULTS_EOF'
# mDNS publishing for this appliance.
#
# setup-autostart.sh creates this file once and never overwrites it, so edits
# made here survive re-running the installer. Apply changes with:
#   sudo systemctl restart ut-mdns-alias

# Install directory, which is where UT_DOMAIN is read from .env. That variable
# is the appliance's single source of truth for its name: every published
# record below is derived from it.
UT_INSTALL_DIR="@INSTALL_DIR@"

# By default the names come from UT_DOMAIN: the apex, then llms. assistants.
# admin. builder., plus one name per App Builder generated app. Uncomment to
# pin a literal list instead — it will then stop following UT_DOMAIN.
#UT_MDNS_ALIASES="llms.understand.local assistants.understand.local admin.understand.local builder.understand.local"

# Hostname suffix for App Builder generated apps. Derived from UT_DOMAIN when
# unset. One name is published per app; mDNS has no wildcards.
#UT_MDNS_APPS_SUFFIX="apps.understand.local"

# How often the generated-app list is rescanned, in seconds.
UT_MDNS_SCAN_INTERVAL="10"
DEFAULTS_EOF
    } | sed -e "s|@INSTALL_DIR@|${INSTALL_DIR}|g" | write_file_atomic "$MDNS_DEFAULTS" 644
    then
        log_info "Defaults written: $MDNS_DEFAULTS"
    fi
}

install_mdns_alias() {
    log_step "Installing mDNS alias publisher..."

    install_mdns_defaults

    local mdns_changed=false

    if write_file_atomic "$MDNS_HELPER" 755 << 'HELPER_EOF'
#!/bin/sh
# Publish the mDNS names of this appliance and its satellite apps behind Caddy.
#
# Every name is derived from UT_DOMAIN in the install directory's .env, so a
# second box on the same network only needs its own UT_DOMAIN. Avahi answers
# for this machine's own host name only, so both the apex and a name one level
# down like llms.<UT_DOMAIN> need a record of their own. Each is published as
# an A record pointing at this host's primary address; the reverse (PTR) entry
# is skipped so the host's own reverse lookup is untouched.
#
# The address is re-derived on every start, so when it changes we exit and let
# systemd restart us — the restart is the republish.
#
# App Builder installs get one extra name per generated app. mDNS has no
# wildcards, so *.apps.<UT_DOMAIN> cannot resolve on its own — every app
# hostname has to be announced individually. The App Builder writes one
# traefik file per app, which makes that directory the list of names to
# publish: it is rescanned every SCAN_INTERVAL seconds, so a new app becomes
# resolvable within that window and a deleted one stops resolving.
set -eu

# Configuration lives in /etc/default/ut-mdns-alias, which setup-autostart.sh
# creates once and never overwrites — edits to it survive a reinstall. This
# helper script is the part that gets regenerated.
UT_INSTALL_DIR="/opt/understand-tech"
SCAN_INTERVAL=10

if [ -r /etc/default/ut-mdns-alias ]; then
    . /etc/default/ut-mdns-alias
    SCAN_INTERVAL="${UT_MDNS_SCAN_INTERVAL:-$SCAN_INTERVAL}"
fi

# The appliance's name comes from UT_DOMAIN in the install directory's .env,
# read rather than sourced: compose keeps quoting that a shell would strip,
# and that file holds JSON a shell would try to glob or execute.
env_value() {
    [ -r "$UT_INSTALL_DIR/.env" ] || return 0
    _raw="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$UT_INSTALL_DIR/.env" | tail -n1)"
    case "$_raw" in
        '"'*) _raw="${_raw#\"}"; _raw="${_raw%%\"*}" ;;
        "'"*) _raw="${_raw#\'}"; _raw="${_raw%%\'*}" ;;
        *)    _raw="${_raw%%[[:space:]#]*}" ;;
    esac
    printf '%s' "$_raw"
}

DOMAIN="$(env_value UT_DOMAIN)"
[ -n "$DOMAIN" ] || DOMAIN="understand.local"

# mDNS answers for .local and nothing else (RFC 6762). On any other domain the
# names come from the operator's own DNS and there is nothing to publish here.
# Exit 10, which the unit treats as a definitive stop rather than a failure to
# retry every five seconds forever.
case "$DOMAIN" in
    *.local) ;;
    *)
        echo "UT_DOMAIN=$DOMAIN is outside .local — mDNS does not apply, nothing to publish"
        exit 10
        ;;
esac

# A literal list in /etc/default/ut-mdns-alias wins, so a box that had one
# before the domain became configurable keeps publishing exactly what it did.
if [ -n "${UT_MDNS_ALIASES:-}" ]; then
    ALIASES="$UT_MDNS_ALIASES"
else
    ALIASES="llms.$DOMAIN assistants.$DOMAIN admin.$DOMAIN builder.$DOMAIN"
    # The apex used to resolve only because the box's host name happened to be
    # the domain's first label: avahi publishes <hostname>.local by itself.
    # Publishing it here is what makes UT_DOMAIN sufficient on its own — except
    # when avahi already answers for that name, since two records for one name
    # collide.
    _host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo '')"
    [ "$_host.local" = "$DOMAIN" ] || ALIASES="$DOMAIN $ALIASES"
fi
APPS_SUFFIX="${UT_MDNS_APPS_SUFFIX:-apps.$DOMAIN}"

# Generated apps (App Builder add-on). A missing directory just means the
# add-on is not installed, and the scan is a no-op.
APPS_DIR="/var/lib/understandtech/appbuilder/traefik-dynamic"
APPS_PID_DIR="/run/ut-mdns-apps"

primary_ip() {
    # The address behind the default route, when there is one.
    _addr="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)"

    # An air-gapped box has no default route at all. Fall back to the first
    # global IPv4 that is not a container or virtualisation bridge —
    # publishing docker0's 172.17.0.1 would point every client at an address
    # they cannot reach.
    if [ -z "$_addr" ]; then
        _addr="$(ip -4 -o addr show scope global 2>/dev/null \
            | awk '$2 !~ /^(docker|br-|veth|virbr|cni|flannel)/ { print $4 }' \
            | cut -d/ -f1 | head -n1)"
    fi

    printf '%s' "$_addr"
}

ip_addr="$(primary_ip)"
if [ -z "$ip_addr" ]; then
    echo "no usable IPv4 address yet — will retry" >&2
    exit 1
fi

# --no-reverse keeps the host's own PTR record intact, but it is not in every
# avahi-utils build — only pass it when this one advertises it. --no-fail waits
# for the daemon instead of giving up when we start before it does.
no_reverse=""
if avahi-publish --help 2>&1 | grep -q -- "--no-reverse"; then
    no_reverse="-R"
fi

pids=""
for alias in $ALIASES; do
    echo "publishing $alias -> $ip_addr"
    avahi-publish -a -f $no_reverse "$alias" "$ip_addr" &
    pids="$pids $!"
done

# Pidfiles live in /run (cleared on reboot), but a crash can leave entries
# behind pointing at dead processes. Drop them so this run republishes.
mkdir -p "$APPS_PID_DIR"
rm -f "$APPS_PID_DIR"/*.pid

# Dots are regex wildcards, so escape them before matching hostnames.
apps_suffix_re="$(printf '%s' "$APPS_SUFFIX" | sed 's/\./\\./g')"

scan_apps() {
    [ -d "$APPS_DIR" ] || return 0

    # The traefik router rules are the source of truth: one Host(`...`) per
    # surface, so an app's preview, --staging and --prod names all appear.
    # Underscores are legal in a compose project name, so they are legal here.
    names="$(grep -rhoE "Host\(\`[A-Za-z0-9_-]+\.${apps_suffix_re}\`\)" "$APPS_DIR" 2>/dev/null \
        | sed -e 's/^Host(`//' -e 's/`)$//' | sort -u || true)"

    for name in $names; do
        pidfile="$APPS_PID_DIR/$name.pid"
        if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            continue
        fi
        echo "publishing $name -> $ip_addr"
        avahi-publish -a -f $no_reverse "$name" "$ip_addr" &
        echo "$!" > "$pidfile"
    done

    # An alias only exists while its publisher runs, so killing the process
    # is how a deleted app's name leaves the network.
    for pidfile in "$APPS_PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        name="$(basename "$pidfile" .pid)"
        if ! printf '%s\n' "$names" | grep -qxF "$name"; then
            echo "withdrawing $name"
            kill "$(cat "$pidfile")" 2>/dev/null || true
            rm -f "$pidfile"
        fi
    done
}

terminate() {
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    for pidfile in "$APPS_PID_DIR"/*.pid; do
        [ -f "$pidfile" ] || continue
        kill "$(cat "$pidfile")" 2>/dev/null || true
        rm -f "$pidfile"
    done
    exit 0
}
trap terminate TERM INT

# Watch for an address change or a dead publisher; either way, exit and let
# systemd start us again. Generated-app names are reconciled on the same pass.
while :; do
    scan_apps
    sleep "$SCAN_INTERVAL"
    if [ "$(primary_ip)" != "$ip_addr" ]; then
        echo "primary address changed — republishing"
        terminate
    fi
    for pid in $pids; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "publisher $pid exited — republishing" >&2
            terminate
        fi
    done
done
HELPER_EOF
    then
        mdns_changed=true
        log_info "Helper installed: $MDNS_HELPER"
    else
        log_info "Helper already up to date: $MDNS_HELPER"
    fi

    if write_file_atomic "$MDNS_SERVICE_FILE" 644 << 'SYSTEMD_EOF'
[Unit]
Description=UnderstandTech mDNS aliases for satellite and generated apps
Documentation=https://docs.understand.tech
After=avahi-daemon.service network-online.target
Wants=avahi-daemon.service network-online.target
# Never give up: a slow boot must not leave the aliases permanently unpublished.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/ut-mdns-alias
Restart=always
RestartSec=5
# The publisher exits 0 on purpose when an address change means it must
# republish, so Restart=always is what re-registers the names. Exit 10 is the
# other deliberate exit: UT_DOMAIN is outside .local, mDNS does not apply, and
# restarting would just loop on the same verdict every five seconds. Pairing
# it with SuccessExitStatus keeps that case reported as inactive, not failed.
RestartPreventExitStatus=10
SuccessExitStatus=10

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
    then
        mdns_changed=true
        log_info "Service file created: $MDNS_SERVICE_FILE"
        systemctl daemon-reload
    else
        log_info "Service file already up to date: $MDNS_SERVICE_FILE"
    fi

    if ! systemctl enable "$MDNS_SERVICE_NAME" >/dev/null 2>&1; then
        log_warn "Could not enable $MDNS_SERVICE_NAME — it will not start on boot"
    fi

    if ! command -v avahi-publish &>/dev/null; then
        log_warn "avahi-publish not found — the aliases cannot be published yet."
        log_warn "Install it, then start the service:"
        echo "  sudo apt-get install -y avahi-daemon avahi-utils"
        echo "  sudo systemctl start $MDNS_SERVICE_NAME"
        return 0
    fi

    # A restart withdraws every .local name for a moment while the old
    # publishers are reaped and the new ones re-register. Re-running the
    # installer should not disturb names that are already correct, so only
    # bounce it when something changed or it is not running.
    if [[ "$mdns_changed" != true ]] && systemctl is-active --quiet "$MDNS_SERVICE_NAME"; then
        log_info "mDNS publisher already running with this config — left alone"
        return 0
    fi

    if systemctl restart "$MDNS_SERVICE_NAME"; then
        log_info "mDNS aliases published (edit $MDNS_DEFAULTS to change them)"
    else
        log_warn "$MDNS_SERVICE_NAME failed to start"
        log_warn "Check: journalctl -u $MDNS_SERVICE_NAME -n 50"
        return 0
    fi

    local domain scheme
    domain="$(env_value UT_DOMAIN)"; domain="${domain:-understand.local}"
    scheme="$(env_value UT_PUBLIC_SCHEME)"; scheme="${scheme:-https}"

    echo ""
    if [[ "$domain" != *.local ]]; then
        # The publisher stops itself with exit 10 in this case; say so here
        # rather than leaving the operator to read journalctl to find out why
        # nothing was published.
        log_info "UT_DOMAIN=\"$domain\" is outside .local — mDNS does not apply and nothing was published."
        echo ""
        echo -e "${GREEN}Create these records in your own DNS, pointing at this box (or at the"
        echo -e "load balancer in front of it):${NC}"
        echo "  $domain"
        echo "  llms.$domain"
        echo "  assistants.$domain"
        echo "  admin.$domain"
        echo "  builder.$domain          (App Builder, if installed)"
        echo "  *.apps.$domain           (one per generated app)"
        return 0
    fi

    echo -e "${GREEN}Published names:${NC}"
    echo "  $scheme://$domain"
    echo "  $scheme://llms.$domain"
    echo "  $scheme://assistants.$domain"
    echo "  $scheme://admin.$domain"
    echo "  $scheme://builder.$domain          (App Builder, if installed)"
    echo "  $scheme://<app>.apps.$domain       (one per generated app, rescanned every 10s)"
}

install_service() {
    log_step "Creating systemd service file..."

    # The unit is templated rather than hardcoded so WorkingDirectory and the
    # docker binary always match what was checked at install time.
    if {
        cat << 'UNIT_EOF'
[Unit]
Description=UnderstandTech Docker Compose Stack
Documentation=https://docs.understand.tech
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
# An appliance must keep trying: never latch off after a few failed boots.
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=@INSTALL_DIR@

# Deliberately no EnvironmentFile. Compose reads @INSTALL_DIR@/.env itself,
# and systemd's parser is not compose's: systemd strips single and double
# quotes, so values holding JSON or quoted arguments come out different.
# Anything systemd exported would land in the process environment, which
# *outranks* .env in compose's precedence order — the stack would boot with
# different values than a manual `docker compose up -d` produces.

# Wait for the daemon to accept connections rather than guessing with a sleep.
# TimeoutStartSec below bounds the wait.
ExecStartPre=/bin/sh -c 'until @DOCKER@ info >/dev/null 2>&1; do sleep 2; done'

# --pull never: boot from local images only. `up` would otherwise pull anything
# missing, which on an air-gapped box stalls on registry timeouts, and as root
# hits a different credential store than the operator's `docker login` — the
# guide runs that without sudo. Images are installed with `docker compose pull`
# before this unit ever runs.

ExecStart=@DOCKER@ compose up -d --pull never --remove-orphans
ExecStop=@DOCKER@ compose down

Restart=on-failure
RestartSec=30

# A cold NIM model cache makes the first start slow.
TimeoutStartSec=900
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
UNIT_EOF
    } | sed -e "s|@INSTALL_DIR@|${INSTALL_DIR}|g" -e "s|@DOCKER@|${DOCKER_BIN}|g" \
      | write_file_atomic "$SERVICE_FILE" 644
    then
        log_info "Service file created: $SERVICE_FILE"
        log_step "Reloading systemd daemon..."
        systemctl daemon-reload
    else
        log_info "Service file already up to date: $SERVICE_FILE"
    fi

    log_step "Enabling service for boot..."
    systemctl enable "$SERVICE_NAME"
}

do_install() {
    banner "UnderstandTech Auto-Start Installation"

    check_root
    check_prerequisites
    install_service
    install_mdns_alias

    echo ""
    log_info "Installation complete!"
    echo ""
    echo -e "${GREEN}The stack will start automatically on every boot.${NC}"
    echo "Nothing was started just now — deploy the stack the usual way:"
    echo ""
    echo "  cd $INSTALL_DIR"
    echo "  docker compose pull      # as the user that ran 'docker login ghcr.io', not with sudo"
    echo "  docker compose up -d"
    echo ""
    echo -e "${GREEN}Service Commands:${NC}"
    echo "  Start now:     sudo systemctl start $SERVICE_NAME"
    echo "  Stop:          sudo systemctl stop $SERVICE_NAME"
    echo "  Restart:       sudo systemctl restart $SERVICE_NAME"
    echo "  Status:        sudo systemctl status $SERVICE_NAME"
    echo "  View logs:     sudo journalctl -u $SERVICE_NAME -f"
    echo ""
}

do_uninstall() {
    banner "UnderstandTech Auto-Start Removal"

    check_root

    if [[ ! -f "$SERVICE_FILE" && ! -f "$MDNS_SERVICE_FILE" ]]; then
        log_warn "Service file not found - nothing to remove"
        exit 0
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        log_step "Stopping service..."
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true

        log_step "Disabling service..."
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true

        log_step "Removing service file..."
        rm -f "$SERVICE_FILE"
    fi

    if [[ -f "$MDNS_SERVICE_FILE" ]]; then
        log_step "Removing mDNS alias service..."
        systemctl stop "$MDNS_SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$MDNS_SERVICE_NAME" 2>/dev/null || true
        rm -f "$MDNS_SERVICE_FILE" "$MDNS_HELPER"
    fi

    log_step "Reloading systemd daemon..."
    systemctl daemon-reload

    echo ""
    log_info "Service removed successfully"
    echo ""
    echo "Kept: $MDNS_DEFAULTS (your alias list)"
    echo "Note: Your containers may still be running."
    echo "To stop them: cd $INSTALL_DIR && docker compose down"
}

do_status() {
    banner "UnderstandTech Service Status"

    echo "Install directory: $INSTALL_DIR"
    echo ""

    if [[ ! -f "$SERVICE_FILE" ]]; then
        log_warn "Service is not installed"
        echo ""
        echo "Run: sudo $0 --install"
        exit 0
    fi

    echo -e "${GREEN}Systemd Service:${NC}"
    systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || true
    echo ""

    if [[ -f "$MDNS_SERVICE_FILE" ]]; then
        echo -e "${GREEN}mDNS Alias Service:${NC}"
        systemctl status "$MDNS_SERVICE_NAME" --no-pager 2>/dev/null || true
        echo ""
    fi

    echo -e "${GREEN}Compose Services:${NC}"
    DOCKER_BIN="$(command -v docker || true)"
    if [[ -n "$DOCKER_BIN" && -f "$INSTALL_DIR/compose.yaml" ]]; then
        # `docker compose ps` covers the scaled workers and the profile-gated
        # NIM containers, which a `name=ut-` filter silently misses.
        compose ps 2>/dev/null || echo "  Unable to query compose in $INSTALL_DIR"
    else
        echo "  Docker or compose.yaml not available"
    fi
    echo ""

    echo -e "${GREEN}Recent Service Logs:${NC}"
    journalctl -u "$SERVICE_NAME" -n 10 --no-pager 2>/dev/null || echo "  No logs available"
}

show_help() {
    echo "UnderstandTech Auto-Start Setup"
    echo ""
    echo "Usage: sudo $0 [OPTION]"
    echo ""
    echo "Installs the boot service and the mDNS alias publisher. It does not"
    echo "pull images or start the stack."
    echo ""
    echo "Options:"
    echo "  --install     Install and enable both units (default)"
    echo "  --mdns        Install only the mDNS aliases (satellite apps + generated apps)"
    echo "  --check       Check the domain / TLS / proxy settings without changing anything"
    echo "  --uninstall   Remove both units"
    echo "  --status      Show unit and container status"
    echo "  --dir PATH    Install directory (default: the directory holding this script)"
    echo "  --help        Show this help message"
    echo ""
}

# Main
ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install|-i)            ACTION="install" ;;
        --mdns|-m)               ACTION="mdns" ;;
        --check|-c)              ACTION="check" ;;
        --uninstall|-u|--remove) ACTION="uninstall" ;;
        --status|-s)             ACTION="status" ;;
        --dir)
            shift
            if [[ $# -eq 0 || -z "$1" ]]; then
                log_error "--dir requires a path"
                exit 1
            fi
            INSTALL_DIR="$1"
            ;;
        --dir=*)                 INSTALL_DIR="${1#*=}" ;;
        --help|-h)               show_help; exit 0 ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

INSTALL_DIR="$( cd -P "$INSTALL_DIR" 2>/dev/null && pwd || echo "$INSTALL_DIR" )"

case "${ACTION:-install}" in
    install)   do_install ;;
    mdns)      check_root; install_mdns_alias ;;
    check)     do_check ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
esac
