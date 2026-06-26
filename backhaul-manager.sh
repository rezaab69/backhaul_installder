#!/usr/bin/env bash
# ============================================================================
#  Backhaul Manager & Installer
#  ----------------------------------------------------------------------------
#  A powerful, full-featured menu-driven installer/manager for the
#  Musixal/Backhaul reverse-tunneling tool on systemd-based Linux systems
#  (Debian, Ubuntu and derivatives).
#
#  * Installs the official `backhaul` binary for amd64 / arm64
#  * Lets you create any number of server- or client-side tunnels, each as
#    its own systemd service and TOML config
#  * Supports every transport: tcp, tcpmux, ws, wss, wsmux, wssmux, udp
#  * Generates self-signed TLS certificates for WSS / WSSMUX
#  * Provides bulk start/stop/restart, live status table, live log tail,
#    config edit, import / export, backup, update, uninstall, and more.
#  ----------------------------------------------------------------------------
#  Usage :  sudo bash backhaul-manager.sh
#  Author:  Reza (opencode) — built around github.com/Musixal/Backhaul
#  Version: 1.0.0
# ============================================================================

set -Eeuo pipefail
shopt -s nocasematch

# ----------------------------------------------------------------------------
#  Globals
# ----------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly GITHUB_REPO="Musixal/Backhaul"
readonly DEFAULT_API="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
readonly INSTALL_DIR="/opt/backhaul"
readonly CONF_DIR="/etc/backhaul"
readonly BIN_PATH="/usr/local/bin/backhaul"
readonly SVC_DIR="/etc/systemd/system"
readonly BACKUP_DIR="/var/backhaul-backups"

# Colors / styling (auto-disabled when not a TTY or NO_COLOR is set)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
    C_GREY=$'\033[90m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""
    C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_GREY=""
fi

# ----------------------------------------------------------------------------
#  Utility helpers
# ----------------------------------------------------------------------------
log_info()  { printf '%s[i]%s %s\n' "$C_CYAN"   "$C_RESET" "$*"; }
log_ok()    { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
log_err()   { printf '%s[x]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
log_step()  { printf '%s==>%s %s\n' "$C_BLUE"   "$C_BOLD"  "$*"; }

die()       { log_err "$*"; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Please run this script as root (sudo bash $0)"
    fi
}

have() { command -v "$1" >/dev/null 2>&1; }

clear_screen() {
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    fi
}

press_enter() {
    printf '\n%sPress ENTER to continue...%s' "$C_DIM" "$C_RESET"
    read -r _
}

banner() {
    cat <<EOF
${C_CYAN}${C_BOLD}
  ____             _                                  _    _
 | __ )  __ _  ___| | _____  _ __ ___  __ _ _   _ _ __| | _(_)_ __
 |  _ \ / _\` |/ __| |/ _ \\ \\/ / '__/ _ \\/ _\` | | | | '__| |/ / | '_ \\
 | |_) | (_| | (__| |  __/ >  <| | |  __/ (_| | |_| | |  |   <| | | | |
 |____/ \\__,_|\\___|_|\\___|/_/\\_\\_|  \\___|\\__,_|\\__,_|_|  |_|\\_\\_|_| |_|
${C_RESET}${C_GREY}   Reverse-tunnel manager for ${GITHUB_REPO}   |   v${SCRIPT_VERSION}${C_RESET}
EOF
}

# Pretty-print a horizontal line of width N (default terminal width - 0)
hr() {
    local char="${1:--}"
    local cols
    cols="$(tput cols 2>/dev/null || printf 70)"
    printf '%*s\n' "$cols" "" | tr ' ' "$char"
}

confirm() {
    local prompt="${1:-Are you sure?}"
    local reply
    while true; do
        printf '%s%s [y/N]: %s' "$C_YELLOW" "$prompt" "$C_RESET"
        read -r reply
        case "$reply" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]|"") return 1 ;;
            *) printf 'Please answer y or n.\n' ;;
        esac
    done
}

read_input() {
    local prompt="$1"
    local default="${2:-}"
    local value
    if [[ -n "$default" ]]; then
        printf '%s%s [%s]: %s' "$C_BOLD" "$prompt" "$default" "$C_RESET"
    else
        printf '%s%s: %s' "$C_BOLD" "$prompt" "$C_RESET"
    fi
    read -r value
    printf '%s' "${value:-$default}"
}

read_input_required() {
    local prompt="$1"
    local value
    while true; do
        value="$(read_input "$prompt")"
        [[ -n "$value" ]] && printf '%s' "$value" && return 0
        log_warn "This field is required."
    done
}

read_int() {
    local prompt="$1" default="$2" min="$3" max="$4"
    local value
    while true; do
        value="$(read_input "$prompt" "$default")"
        [[ -z "$value" ]] && value="$default"
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
            printf '%s' "$value"; return 0
        fi
        log_warn "Please enter a number between $min and $max."
    done
}

read_yesno_default_no() {
    local prompt="$1" default="${2:-N}" value
    while true; do
        printf '%s%s [y/N]: %s' "$C_YELLOW" "$prompt" "$C_RESET"
        read -r value
        value="${value:-$default}"
        case "$value" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) printf 'Please answer y or n.\n' ;;
        esac
    done
}

# ----------------------------------------------------------------------------
#  Environment setup / dependency installer
# ----------------------------------------------------------------------------
detect_arch() {
    local m
    m="$(uname -m)"
    case "$m" in
        x86_64|amd64)   printf 'amd64' ;;
        aarch64|arm64)  printf 'arm64' ;;
        armv7l|armv7)   printf 'armv7'  ;;
        *) die "Unsupported architecture: $m  (only amd64 and arm64 are shipped in official releases)" ;;
    esac
}

ensure_deps() {
    log_step "Verifying required tools..."
    local missing=()
    for cmd in curl wget tar systemctl awk grep sed systemctl-journald openssl; do
        if ! have "$cmd"; then missing+=("$cmd"); fi
    done
    if (( ${#missing[@]} > 0 )); then
        log_warn "Missing tools: ${missing[*]}"
        if have apt-get; then
            log_step "Installing missing tools via apt..."
            apt-get update -y >/dev/null
            apt-get install -y curl wget tar openssl systemd-journald ca-certificates >/dev/null
        elif have dnf; then
            dnf install -y curl wget tar openssl systemd-journald ca-certificates >/dev/null
        elif have yum; then
            yum install -y curl wget tar openssl systemd-journald ca-certificates >/dev/null
        else
            die "Cannot auto-install missing tools. Please install: ${missing[*]}"
        fi
    fi
    log_ok "All dependencies satisfied."
}

init_dirs() {
    install -d -m 755 "$INSTALL_DIR"
    install -d -m 755 "$CONF_DIR"
    install -d -m 755 "$BACKUP_DIR"
}

# ----------------------------------------------------------------------------
#  Binary download / update
# ----------------------------------------------------------------------------
fetch_latest_release_json() {
    if have curl; then
        curl -fsSL "$DEFAULT_API"
    elif have wget; then
        wget -qO- "$DEFAULT_API"
    else
        die "Neither curl nor wget is available."
    fi
}

# Extracts a value for the given asset name from the release JSON
# $1 = JSON, $2 = asset name
extract_browser_url() {
    local json="$1" name="$2"
    printf '%s' "$json" \
        | awk -v RS='},{' -v ORS='} {' -v n="$name" '
            $0 ~ "\"name\":\""n"\"" {
                match($0, /"browser_download_url":"[^"]+"/);
                if (RSTART) {
                    s = substr($0, RSTART, RLENGTH);
                    gsub(/"browser_download_url":"|"$/, "", s);
                    print s;
                    exit
                }
            }
        '
}

# $1 = JSON, $2 = asset name
extract_asset_sha256() {
    local json="$1" name="$2"
    printf '%s' "$json" \
        | awk -v RS='},{' -v ORS='} {' -v n="$name" '
            $0 ~ "\"name\":\""n"\"" {
                match($0, /"digest":"sha256:[a-f0-9]+"/);
                if (RSTART) {
                    s = substr($0, RSTART, RLENGTH);
                    gsub(/"digest":"sha256:|"$/, "", s);
                    print s;
                    exit
                }
            }
        '
}

download_backhaul_binary() {
    local arch="$1"
    local asset="backhaul_linux_${arch}.tar.gz"
    local url="https://github.com/${GITHUB_REPO}/releases/download/__VERSION__/${asset}"
    local tag version tmpdir

    log_step "Fetching latest release metadata..."
    local json
    if ! json="$(fetch_latest_release_json 2>/dev/null)"; then
        log_warn "Cannot reach GitHub API. Falling back to hardcoded v0.7.2"
        tag="v0.7.2"
    else
        tag="$(printf '%s' "$json" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
        [[ -z "$tag" ]] && tag="v0.7.2"
    fi
    version="${tag#v}"
    url="${url/__VERSION__/${tag}}"
    log_info "Latest version: $tag"

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    log_step "Downloading $asset ..."
    if have curl; then
        curl -fL --retry 3 --connect-timeout 15 -o "$tmpdir/$asset" "$url" || die "Download failed: $url"
    else
        wget -O "$tmpdir/$asset" "$url" || die "Download failed: $url"
    fi

    # Verify SHA256 if checksum file is available
    local checksum_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/checksums.txt"
    if have curl && curl -fsSL -o "$tmpdir/checksums.txt" "$checksum_url" 2>/dev/null \
       && [[ -s "$tmpdir/checksums.txt" ]]; then
        local expected
        expected="$(grep -i "$asset" "$tmpdir/checksums.txt" | awk '{print $1}' || true)"
        if [[ -n "$expected" ]]; then
            local actual
            actual="$(sha256sum "$tmpdir/$asset" | awk '{print $1}')"
            if [[ "${expected,,}" != "$actual" ]]; then
                die "SHA256 mismatch for $asset. Aborting."
            fi
            log_ok "SHA256 verified."
        fi
    fi

    log_step "Extracting binary..."
    tar -xzf "$tmpdir/$asset" -C "$tmpdir"
    local extracted
    extracted="$(find "$tmpdir" -maxdepth 2 -type f -name 'backhaul' | head -1)"
    [[ -z "$extracted" ]] && die "Could not locate extracted backhaul binary."

    install -m 755 "$extracted" "$BIN_PATH"
    log_ok "Installed $BIN_PATH ($tag)"
    "$BIN_PATH" --version 2>/dev/null || true
}

ensure_binary() {
    if [[ -x "$BIN_PATH" ]]; then
        log_info "Existing binary: $("$BIN_PATH" --version 2>&1 | head -1 || echo unknown)"
        if confirm "Re-download / update Backhaul to the latest version?"; then
            local arch; arch="$(detect_arch)"
            download_backhaul_binary "$arch"
        fi
    else
        local arch; arch="$(detect_arch)"
        download_backhaul_binary "$arch"
    fi
}

# ----------------------------------------------------------------------------
#  Service / instance helpers
# ----------------------------------------------------------------------------
service_name() {
    printf 'backhaul-%s' "$1"
}

service_path() {
    printf '%s/%s.service' "$SVC_DIR" "$1"
}

conf_path() {
    printf '%s/%s.toml' "$CONF_DIR" "$1"
}

# Build a sanitized instance name from a user-supplied label
sanitize_instance_name() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+|-+$//g'
}

list_instances() {
    local f
    for f in "$CONF_DIR"/*.toml; do
        [[ -f "$f" ]] || continue
        basename "$f" .toml
    done
    # Also pick up service files that exist but have no config (orphan services)
    local s
    for s in "$SVC_DIR"/backhaul-*.service; do
        [[ -f "$s" ]] || continue
        basename "$s" .service
    done | sort -u
}

instance_exists() {
    [[ -f "$(conf_path "$1")" ]] || [[ -f "$(service_path "$1")" ]]
}

# ----------------------------------------------------------------------------
#  systemd unit template
# ----------------------------------------------------------------------------
write_systemd_unit() {
    local name="$1"
    local svc; svc="$(service_path "$name")"
    local cfg; cfg="$(conf_path "$name")"

    cat > "$svc" <<EOF
[Unit]
Description=Backhaul Reverse Tunnel - ${name}
Documentation=https://github.com/${GITHUB_REPO}
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} -c ${cfg}
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=false
KillMode=process
TimeoutStopSec=20

# Sandboxing (light)
ProtectSystem=full
ProtectHome=false
PrivateTmp=false

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# ----------------------------------------------------------------------------
#  TOML config writer
# ----------------------------------------------------------------------------
# $1=mode ("server"|"client") $2=instance_name $3=...
# The full args list is parsed via globals / arrays passed to the function.
write_toml_config() {
    local mode="$1"; shift
    local name="$1"; shift
    local cfg; cfg="$(conf_path "$name")"
    : > "$cfg"

    {
        printf '# Backhaul %s config — instance: %s\n' "$mode" "$name"
        printf '# Generated on %s by backhaul-manager.sh\n' "$(date '+%F %T')"
        printf '# DO NOT edit this comment block manually if you want to keep it.\n\n'

        if [[ "$mode" == "server" ]]; then
            printf '[server]\n'
            printf 'bind_addr = "%s"\n'        "$BIND_ADDR"
            printf 'transport = "%s"\n'        "$TRANSPORT"
            printf 'token = "%s"\n'            "$TOKEN"
            printf 'accept_udp = %s\n'         "$ACCEPT_UDP"
            printf 'keepalive_period = %s\n'   "$KEEPALIVE_PERIOD"
            printf 'nodelay = %s\n'            "$NODELAY"
            printf 'channel_size = %s\n'       "$CHANNEL_SIZE"
            printf 'heartbeat = %s\n'          "$HEARTBEAT"
            printf 'sniffer = %s\n'            "$SNIFFER"
            printf 'web_port = %s\n'           "$WEB_PORT"
            printf 'log_level = "%s"\n'        "$LOG_LEVEL"
            printf 'skip_optz = %s\n'          "$SKIP_OPTZ"
            if [[ "$TRANSPORT" == "tcpmux" || "$TRANSPORT" == "wsmux" || "$TRANSPORT" == "wssmux" ]]; then
                printf 'mux_con = %s\n'             "$MUX_CON"
                printf 'mux_version = %s\n'         "$MUX_VERSION"
                printf 'mux_framesize = %s\n'       "$MUX_FRAMESIZE"
                printf 'mux_recievebuffer = %s\n'   "$MUX_RECVBUF"
                printf 'mux_streambuffer = %s\n'    "$MUX_STRBUF"
            fi
            if [[ "$TRANSPORT" == "tcp" || "$TRANSPORT" == "tcpmux" ]]; then
                printf 'mss = %s\n'           "$MSS"
                printf 'so_rcvbuf = %s\n'     "$SO_RCVBUF"
                printf 'so_sndbuf = %s\n'     "$SO_SNDBUF"
            fi
            if [[ "$TRANSPORT" == "wss" || "$TRANSPORT" == "wssmux" ]]; then
                printf 'tls_cert = "%s"\n'    "$TLS_CERT"
                printf 'tls_key  = "%s"\n'    "$TLS_KEY"
            fi
            printf '\nports = [\n'
            local IFS=','
            local first=1
            for p in $PORTS; do
                [[ -z "$p" ]] && continue
                if (( first )); then first=0; else printf ',\n'; fi
                printf '  "%s"' "$p"
            done
            printf '\n]\n'
        else
            printf '[client]\n'
            printf 'remote_addr = "%s"\n'      "$REMOTE_ADDR"
            printf 'transport = "%s"\n'        "$TRANSPORT"
            printf 'token = "%s"\n'            "$TOKEN"
            printf 'edge_ip = "%s"\n'          "$EDGE_IP"
            printf 'connection_pool = %s\n'    "$CONNECTION_POOL"
            printf 'aggressive_pool = %s\n'    "$AGGRESSIVE_POOL"
            printf 'keepalive_period = %s\n'   "$KEEPALIVE_PERIOD"
            printf 'nodelay = %s\n'            "$NODELAY"
            printf 'retry_interval = %s\n'     "$RETRY_INTERVAL"
            printf 'dial_timeout = %s\n'       "$DIAL_TIMEOUT"
            printf 'sniffer = %s\n'            "$SNIFFER"
            printf 'web_port = %s\n'           "$WEB_PORT"
            printf 'log_level = "%s"\n'        "$LOG_LEVEL"
            printf 'skip_optz = %s\n'          "$SKIP_OPTZ"
            if [[ "$TRANSPORT" == "tcpmux" || "$TRANSPORT" == "wsmux" || "$TRANSPORT" == "wssmux" ]]; then
                printf 'mux_version = %s\n'         "$MUX_VERSION"
                printf 'mux_framesize = %s\n'       "$MUX_FRAMESIZE"
                printf 'mux_recievebuffer = %s\n'   "$MUX_RECVBUF"
                printf 'mux_streambuffer = %s\n'    "$MUX_STRBUF"
            fi
            if [[ "$TRANSPORT" == "tcp" || "$TRANSPORT" == "tcpmux" ]]; then
                printf 'mss = %s\n'           "$MSS"
                printf 'so_rcvbuf = %s\n'     "$SO_RCVBUF"
                printf 'so_sndbuf = %s\n'     "$SO_SNDBUF"
            fi
        fi
    } >> "$cfg"

    chown root:root "$cfg" 2>/dev/null || true
    chmod 600 "$cfg"
}

# ----------------------------------------------------------------------------
#  Input wizards
# ----------------------------------------------------------------------------
# Choose mode (server/client)
choose_mode() {
    printf '\n%sSelect tunnel mode:%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s1)%s %sServer%s  — runs on the public-facing side (e.g. abroad)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %s2)%s %sClient%s  — runs on the local/private side  (e.g. Iran)\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$C_RESET"
    while true; do
        printf '%sChoice [1/2]: %s' "$C_BOLD" "$C_RESET"
        read -r c
        case "$c" in
            1) MODE="server"; return 0 ;;
            2) MODE="client"; return 0 ;;
            *) printf 'Please enter 1 or 2.\n' ;;
        esac
    done
}

# Choose transport
choose_transport() {
    printf '\n%sSelect transport protocol:%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s1)%s tcp       — plain TCP (lowest overhead)\n' "$C_CYAN" "$C_RESET"
    printf '  %s2)%s tcpmux    — TCP + SMUX multiplexing\n' "$C_CYAN" "$C_RESET"
    printf '  %s3)%s ws        — WebSocket (CDN-friendly)\n' "$C_CYAN" "$C_RESET"
    printf '  %s4)%s wss       — secure WebSocket (TLS)\n' "$C_CYAN" "$C_RESET"
    printf '  %s5)%s wsmux     — WS + SMUX multiplexing\n' "$C_CYAN" "$C_RESET"
    printf '  %s6)%s wssmux    — WSS + SMUX multiplexing\n' "$C_CYAN" "$C_RESET"
    printf '  %s7)%s udp       — UDP over TCP (server only)\n' "$C_CYAN" "$C_RESET"
    while true; do
        printf '%sChoice [1-7]: %s' "$C_BOLD" "$C_RESET"
        read -r c
        case "$c" in
            1) TRANSPORT="tcp" ;;
            2) TRANSPORT="tcpmux" ;;
            3) TRANSPORT="ws" ;;
            4) TRANSPORT="wss" ;;
            5) TRANSPORT="wsmux" ;;
            6) TRANSPORT="wssmux" ;;
            7) TRANSPORT="udp" ;;
            *) printf 'Please enter a number between 1 and 7.\n'; continue ;;
        esac
        return 0
    done
}

# Ask for ports — works for both server and client depending on MODE
ask_ports() {
    if [[ "$MODE" == "server" ]]; then
        printf '\n%sPort forwarding rules (server side):%s\n' "$C_BOLD" "$C_RESET"
        printf '  Format examples:\n'
        printf '    443                    — listen 443, forward to same port on client\n'
        printf '    443=5201               — listen 443, forward to 5201 on client\n'
        printf '    443=1.1.1.1:5201       — listen 443, forward to 1.1.1.1:5201\n'
        printf '    2000-2010              — listen on range 2000-2010, forward same range\n'
        printf '    2000-2010=5201         — listen on range, all to port 5201\n'
        printf '    2000-2010=1.1.1.1:5201 — listen on range, all to 1.1.1.1:5201\n'
        printf '  You may enter multiple comma-separated rules. Empty = no forwarding.\n'
        PORTS="$(read_input 'Ports' '')"
    else
        # clients do not expose ports — leave PORTS blank
        PORTS=""
    fi
}

# Generate self-signed cert
generate_self_signed_cert() {
    local name="$1"
    local certdir="/etc/backhaul/certs/${name}"
    install -d -m 700 "$certdir"
    local cn
    cn="$(read_input 'Common Name (domain or IP, blank=auto)' "$(hostname -I 2>/dev/null | awk '{print $1}')")"
    [[ -z "$cn" ]] && cn="backhaul"

    log_step "Generating RSA 2048-bit key..."
    openssl genpkey -algorithm RSA -out "${certdir}/server.key" -pkeyopt rsa_keygen_bits:2048 2>/dev/null
    chmod 600 "${certdir}/server.key"

    log_step "Generating CSR..."
    openssl req -new -key "${certdir}/server.key" \
        -subj "/C=US/ST=NA/L=NA/O=Backhaul/OU=Tunnel/CN=${cn}" \
        -out "${certdir}/server.csr" >/dev/null 2>&1

    log_step "Generating self-signed certificate (valid 365 days)..."
    openssl x509 -req -days 365 -in "${certdir}/server.csr" \
        -signkey "${certdir}/server.key" \
        -out "${certdir}/server.crt" >/dev/null 2>&1
    chmod 644 "${certdir}/server.crt"
    rm -f "${certdir}/server.csr"

    TLS_CERT="${certdir}/server.crt"
    TLS_KEY="${certdir}/server.key"
    log_ok "TLS files created."
}

# ----------------------------------------------------------------------------
#  Interactive config wizard
# ----------------------------------------------------------------------------
build_server_config() {
    local name="$1"
    printf '\n%s=== Server configuration: %s ===%s\n' "$C_BOLD" "$name" "$C_RESET"

    BIND_ADDR="$(read_input 'Bind address (host:port)' '0.0.0.0:3080')"
    if [[ ! "$BIND_ADDR" =~ ^[^:]+:[0-9]+$ ]]; then
        log_warn "Bind address should look like 0.0.0.0:3080"
    fi

    choose_transport
    TOKEN="$(read_input 'Token (any secret string)' "$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24)")"
    ACCEPT_UDP="false"
    if [[ "$TRANSPORT" == "tcp" || "$TRANSPORT" == "tcpmux" ]]; then
        if confirm "Enable accept_udp (encapsulate UDP over TCP)?"; then
            ACCEPT_UDP="true"
        fi
    fi

    KEEPALIVE_PERIOD="$(read_int 'keepalive_period (seconds)' 75 1 86400)"
    NODELAY="true"; confirm 'Enable TCP_NODELAY (recommended)?' || NODELAY="false"
    CHANNEL_SIZE="$(read_int 'channel_size' 2048 64 65536)"
    HEARTBEAT="$(read_int 'heartbeat (seconds)' 40 1 86400)"
    WEB_PORT="$(read_int 'web_port (0=disable)' 2060 0 65535)"
    LOG_LEVEL="$(read_input 'log_level (info/debug/warn/error)' 'info')"
    if confirm "Enable skip_optz (recommended on modern kernels)?"; then
        SKIP_OPTZ="true"
    else
        SKIP_OPTZ="false"
    fi
    if confirm "Enable sniffer (records traffic)?"; then
        SNIFFER="true"
    else
        SNIFFER="false"
    fi

    if [[ "$TRANSPORT" == "tcpmux" || "$TRANSPORT" == "wsmux" || "$TRANSPORT" == "wssmux" ]]; then
        MUX_CON="$(read_int 'mux_con' 8 1 4096)"
        MUX_VERSION="$(read_int 'mux_version (1 or 2)' 1 1 2)"
        MUX_FRAMESIZE="$(read_int 'mux_framesize' 32768 1024 16777216)"
        MUX_RECVBUF="$(read_int 'mux_recievebuffer' 4194304 65536 268435456)"
        MUX_STRBUF="$(read_int 'mux_streambuffer' 65536 4096 16777216)"
    fi

    if [[ "$TRANSPORT" == "tcp" || "$TRANSPORT" == "tcpmux" ]]; then
        MSS="$(read_int 'mss (0=system default)' 1360 0 65535)"
        SO_RCVBUF="$(read_int 'so_rcvbuf (0=default)' 4194304 0 268435456)"
        SO_SNDBUF="$(read_int 'so_sndbuf (0=default)' 1048576 0 268435456)"
    fi

    if [[ "$TRANSPORT" == "wss" || "$TRANSPORT" == "wssmux" ]]; then
        if confirm "Generate a fresh self-signed TLS cert now?"; then
            generate_self_signed_cert "$name"
        else
            TLS_CERT="$(read_input 'tls_cert path' "/etc/backhaul/certs/${name}/server.crt")"
            TLS_KEY="$(read_input 'tls_key path'  "/etc/backhaul/certs/${name}/server.key")"
        fi
    fi

    ask_ports
}

build_client_config() {
    local name="$1"
    printf '\n%s=== Client configuration: %s ===%s\n' "$C_BOLD" "$name" "$C_RESET"

    REMOTE_ADDR="$(read_input 'Remote address (server host:port)' '1.2.3.4:3080')"
    choose_transport
    TOKEN="$(read_input 'Token (must match server)' '')"
    [[ -z "$TOKEN" ]] && log_warn "Empty token — server must also have empty token."
    EDGE_IP="$(read_input 'edge_ip (CDN only, blank=ignore)' '')"

    CONNECTION_POOL="$(read_int 'connection_pool' 8 1 4096)"
    AGGRESSIVE_POOL="false"
    if confirm "Enable aggressive_pool (faster reconnect, higher CPU)?"; then
        AGGRESSIVE_POOL="true"
    fi
    KEEPALIVE_PERIOD="$(read_int 'keepalive_period (seconds)' 75 1 86400)"
    NODELAY="true"; confirm 'Enable TCP_NODELAY (recommended)?' || NODELAY="false"
    RETRY_INTERVAL="$(read_int 'retry_interval (seconds)' 3 1 3600)"
    DIAL_TIMEOUT="$(read_int 'dial_timeout (seconds)' 10 1 600)"
    WEB_PORT="$(read_int 'web_port (0=disable)' 2060 0 65535)"
    LOG_LEVEL="$(read_input 'log_level (info/debug/warn/error)' 'info')"
    if confirm "Enable skip_optz (recommended on modern kernels)?"; then
        SKIP_OPTZ="true"
    else
        SKIP_OPTZ="false"
    fi
    if confirm "Enable sniffer (records traffic)?"; then
        SNIFFER="true"
    else
        SNIFFER="false"
    fi

    if [[ "$TRANSPORT" == "tcpmux" || "$TRANSPORT" == "wsmux" || "$TRANSPORT" == "wssmux" ]]; then
        MUX_VERSION="$(read_int 'mux_version (1 or 2)' 1 1 2)"
        MUX_FRAMESIZE="$(read_int 'mux_framesize' 32768 1024 16777216)"
        MUX_RECVBUF="$(read_int 'mux_recievebuffer' 4194304 65536 268435456)"
        MUX_STRBUF="$(read_int 'mux_streambuffer' 65536 4096 16777216)"
    fi
    if [[ "$TRANSPORT" == "tcp" || "$TRANSPORT" == "tcpmux" ]]; then
        MSS="$(read_int 'mss (0=system default)' 1360 0 65535)"
        SO_RCVBUF="$(read_int 'so_rcvbuf (0=default)' 1048576 0 268435456)"
        SO_SNDBUF="$(read_int 'so_sndbuf (0=default)' 4194304 0 268435456)"
    fi

    PORTS=""
}

# ----------------------------------------------------------------------------
#  Instance creation flow
# ----------------------------------------------------------------------------
create_instance() {
    local name mode transport

    printf '\n%s=== Create new tunnel ===%s\n' "$C_BOLD" "$C_RESET"
    while true; do
        local raw
        raw="$(read_input 'Instance name (a-z, 0-9, . _ -)')"
        name="$(sanitize_instance_name "$raw")"
        if [[ -z "$name" ]]; then
            log_warn "Invalid name."; continue
        fi
        if instance_exists "$name"; then
            log_warn "An instance called '$name' already exists."
            continue
        fi
        break
    done

    choose_mode
    if [[ "$MODE" == "server" ]]; then
        build_server_config "$name"
    else
        build_client_config "$name"
    fi

    write_toml_config "$MODE" "$name"
    write_systemd_unit "$name"

    log_ok "Instance '$name' created."
    if confirm "Enable and start it now?"; then
        systemctl enable "$(service_name "$name")" >/dev/null
        systemctl start  "$(service_name "$name")"
        sleep 1
        systemctl --no-pager --no-legend status "$(service_name "$name")" || true
    fi
}

# ----------------------------------------------------------------------------
#  Instance listing & status
# ----------------------------------------------------------------------------
print_status_table() {
    printf '\n%s%-22s %-7s %-8s %-9s %-9s %-22s%s\n' \
        "$C_BOLD" "INSTANCE" "MODE" "TRANSPORT" "STATUS" "ENABLED" "LISTEN / REMOTE" "$C_RESET"
    hr -

    local name mode transport status enabled addr
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        local cfg; cfg="$(conf_path "$name")"
        if [[ -f "$cfg" ]]; then
            mode="$(grep -m1 -oE '\[(server|client)\]' "$cfg" | tr -d '[]')"
            transport="$(grep -m1 '^transport' "$cfg" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')"
            if [[ "$mode" == "server" ]]; then
                addr="$(grep -m1 '^bind_addr' "$cfg" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')"
            else
                addr="$(grep -m1 '^remote_addr' "$cfg" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/')"
            fi
        else
            mode="?"; transport="?"; addr="(no config)"
        fi

        local svc; svc="$(service_name "$name")"
        if systemctl is-active --quiet "$svc"; then
            status="${C_GREEN}active${C_RESET}"
        elif systemctl is-failed --quiet "$svc" 2>/dev/null; then
            status="${C_RED}failed${C_RESET}"
        else
            status="${C_YELLOW}inactive${C_RESET}"
        fi

        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            enabled="${C_GREEN}enabled${C_RESET}"
        else
            enabled="${C_GREY}disabled${C_RESET}"
        fi

        printf '%-22s %-7s %-8s %b %b %-22s\n' \
            "$name" "${mode:-?}" "${transport:-?}" "$status" "$enabled" "${addr:-}"
    done < <(list_instances)

    if [[ -z "$(list_instances)" ]]; then
        printf '%s(no instances yet — create one from the menu)%s\n' "$C_DIM" "$C_RESET"
    fi
}

# ----------------------------------------------------------------------------
#  Pick an existing instance
# ----------------------------------------------------------------------------
pick_instance() {
    local prompt="$1"
    local instances
    mapfile -t instances < <(list_instances)
    if (( ${#instances[@]} == 0 )); then
        log_warn "No instances configured yet."
        return 1
    fi
    printf '\n%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET"
    local i
    for i in "${!instances[@]}"; do
        printf '  %s%d)%s %s\n' "$C_CYAN" "$((i+1))" "$C_RESET" "${instances[$i]}"
    done
    printf '  %s0)%s Cancel\n' "$C_GREY" "$C_RESET"
    local choice
    while true; do
        printf '%sChoice: %s' "$C_BOLD" "$C_RESET"
        read -r choice
        [[ "$choice" == "0" ]] && return 1
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#instances[@]} )); then
            INSTANCE="${instances[$((choice-1))]}"
            return 0
        fi
        printf 'Invalid choice.\n'
    done
}

# ----------------------------------------------------------------------------
#  Service operations
# ----------------------------------------------------------------------------
op_start()    { systemctl start    "$(service_name "$INSTANCE")"; log_ok "Started $INSTANCE"; }
op_stop()     { systemctl stop     "$(service_name "$INSTANCE")"; log_ok "Stopped $INSTANCE"; }
op_restart()  { systemctl restart  "$(service_name "$INSTANCE")"; log_ok "Restarted $INSTANCE"; }
op_reload()   { systemctl reload   "$(service_name "$INSTANCE")" 2>/dev/null || op_restart; log_ok "Reloaded $INSTANCE"; }
op_enable()   { systemctl enable   "$(service_name "$INSTANCE")"; log_ok "Enabled $INSTANCE"; }
op_disable()  { systemctl disable  "$(service_name "$INSTANCE")"; log_ok "Disabled $INSTANCE"; }
op_status()   { systemctl --no-pager --no-legend status "$(service_name "$INSTANCE")"; }

op_logs() {
    local lines; lines="$(read_input 'Lines to show (Enter = 200)' '200')"
    lines="${lines:-200}"
    journalctl -u "$(service_name "$INSTANCE")" -n "$lines" --no-pager
    if confirm "Follow logs live (Ctrl+C to exit)?"; then
        journalctl -u "$(service_name "$INSTANCE")" -f --no-pager
    fi
}

op_show_config() {
    if [[ ! -f "$(conf_path "$INSTANCE")" ]]; then
        log_warn "No config file found for $INSTANCE."
        return
    fi
    printf '\n%s--- %s ---%s\n' "$C_BOLD" "$(conf_path "$INSTANCE")" "$C_RESET"
    cat "$(conf_path "$INSTANCE")"
}

op_edit_config() {
    local cfg; cfg="$(conf_path "$INSTANCE")"
    [[ -f "$cfg" ]] || { log_warn "No config file."; return; }
    local editor="${EDITOR:-}"
    if [[ -z "$editor" ]]; then
        for e in nano vi vim; do
            if have "$e"; then editor="$e"; break; fi
        done
    fi
    if [[ -z "$editor" ]]; then
        log_warn "No editor found. Please install 'nano' or set EDITOR."
        return
    fi
    "$editor" "$cfg"
    if confirm "Reload service to apply new config?"; then
        op_reload
    fi
}

op_remove() {
    local svc; svc="$(service_name "$INSTANCE")"
    local cfg; cfg="$(conf_path "$INSTANCE")"
    if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    fi
    rm -f "$(service_path "$INSTANCE")"
    systemctl daemon-reload
    if [[ -f "$cfg" ]]; then
        if confirm "Also delete config file $cfg?"; then
            # keep last backup
            cp -a "$cfg" "$BACKUP_DIR/${INSTANCE}.$(date +%s).toml" 2>/dev/null || true
            rm -f "$cfg"
            log_ok "Removed service + config (backup in $BACKUP_DIR)."
        else
            log_ok "Removed service (config kept)."
        fi
    else
        log_ok "Removed service."
    fi
}

op_backup() {
    local cfg; cfg="$(conf_path "$INSTANCE")"
    [[ -f "$cfg" ]] || { log_warn "No config to back up."; return; }
    local dest="$BACKUP_DIR/${INSTANCE}.$(date +%s).toml"
    install -d "$BACKUP_DIR"
    cp -a "$cfg" "$dest"
    chmod 600 "$dest"
    log_ok "Backed up to $dest"
}

op_clone() {
    local src_name="$INSTANCE"
    local dst_raw
    dst_raw="$(read_input 'Name for cloned instance')"
    local dst; dst="$(sanitize_instance_name "$dst_raw")"
    [[ -z "$dst" ]] && { log_warn "Invalid name."; return; }
    instance_exists "$dst" && { log_warn "'$dst' already exists."; return; }
    local src_cfg; src_cfg="$(conf_path "$src_name")"
    local dst_cfg; dst_cfg="$(conf_path "$dst")"
    cp -a "$src_cfg" "$dst_cfg"
    # rewrite the header comment
    sed -i "1s|.*|# Backhaul config (cloned from ${src_name}) — instance: ${dst}|" "$dst_cfg" 2>/dev/null || true
    write_systemd_unit "$dst"
    log_ok "Cloned '$src_name' → '$dst'."
}

op_export() {
    local cfg; cfg="$(conf_path "$INSTANCE")"
    [[ -f "$cfg" ]] || { log_warn "No config."; return; }
    local dest; dest="$(read_input 'Export path' "/tmp/${INSTANCE}.toml")"
    cp -a "$cfg" "$dest"
    log_ok "Exported to $dest"
}

op_import() {
    local src; src="$(read_input 'Path to .toml file to import')"
    [[ -f "$src" ]] || { log_warn "File not found."; return; }
    local raw; raw="$(basename "$src" .toml)"
    local name; name="$(sanitize_instance_name "$(read_input 'Instance name' "$raw")")"
    instance_exists "$name" && { log_warn "'$name' already exists."; return; }
    install -m 600 "$src" "$(conf_path "$name")"
    # Try to detect mode from the file
    if grep -q '\[server\]' "$(conf_path "$name")"; then MODE="server"; else MODE="client"; fi
    write_systemd_unit "$name"
    log_ok "Imported as '$name' ($MODE)."
}

# ----------------------------------------------------------------------------
#  Bulk operations
# ----------------------------------------------------------------------------
bulk_start_all() {
    local i
    while IFS= read -r i; do
        [[ -z "$i" ]] && continue
        systemctl enable "$(service_name "$i")" 2>/dev/null || true
        systemctl start  "$(service_name "$i")" 2>/dev/null || log_warn "Failed to start $i"
    done < <(list_instances)
    log_ok "All instances started."
}
bulk_stop_all() {
    local i
    while IFS= read -r i; do
        [[ -z "$i" ]] && continue
        systemctl stop "$(service_name "$i")" 2>/dev/null || log_warn "Failed to stop $i"
    done < <(list_instances)
    log_ok "All instances stopped."
}
bulk_restart_all() {
    local i
    while IFS= read -r i; do
        [[ -z "$i" ]] && continue
        systemctl restart "$(service_name "$i")" 2>/dev/null || log_warn "Failed to restart $i"
    done < <(list_instances)
    log_ok "All instances restarted."
}

# ----------------------------------------------------------------------------
#  Uninstall whole manager / binary
# ----------------------------------------------------------------------------
uninstall_all() {
    confirm "This will REMOVE all Backhaul services, configs and the binary. Continue?" || return
    local i svc
    while IFS= read -r i; do
        [[ -z "$i" ]] && continue
        svc="$(service_name "$i")"
        systemctl stop    "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "$(service_path "$i")"
    done < <(list_instances)
    systemctl daemon-reload
    rm -f "$BIN_PATH"
    if confirm "Also remove ALL configs and backups ($CONF_DIR, $BACKUP_DIR)?"; then
        rm -rf "$CONF_DIR" "$BACKUP_DIR"
    fi
    log_ok "Uninstall completed."
}

# ----------------------------------------------------------------------------
#  Menus
# ----------------------------------------------------------------------------
instance_menu() {
    pick_instance "Select instance" || return
    while true; do
        clear_screen; banner
        printf '\n%sManaging instance:%s %s%s%s\n\n' "$C_BOLD" "$C_RESET" "$C_CYAN" "$INSTANCE" "$C_RESET"
        printf '  %s1)%s Start\n'            "$C_CYAN" "$C_RESET"
        printf '  %s2)%s Stop\n'             "$C_CYAN" "$C_RESET"
        printf '  %s3)%s Restart\n'          "$C_CYAN" "$C_RESET"
        printf '  %s4)%s Reload (SIGHUP)\n'  "$C_CYAN" "$C_RESET"
        printf '  %s5)%s Enable at boot\n'   "$C_CYAN" "$C_RESET"
        printf '  %s6)%s Disable at boot\n'  "$C_CYAN" "$C_RESET"
        printf '  %s7)%s View status\n'      "$C_CYAN" "$C_RESET"
        printf '  %s8)%s View logs\n'        "$C_CYAN" "$C_RESET"
        printf '  %s9)%s Show config\n'      "$C_CYAN" "$C_RESET"
        printf '  %s10)%s Edit config\n'     "$C_CYAN" "$C_RESET"
        printf '  %s11)%s Backup config\n'   "$C_CYAN" "$C_RESET"
        printf '  %s12)%s Clone to new name\n'"$C_CYAN" "$C_RESET"
        printf '  %s13)%s Export config\n'   "$C_CYAN" "$C_RESET"
        printf '  %s14)%s Remove\n'          "$C_CYAN" "$C_RESET"
        printf '  %s0)%s Back to main menu\n' "$C_GREY" "$C_RESET"
        local ch; printf '%sChoice: %s' "$C_BOLD" "$C_RESET"; read -r ch
        case "$ch" in
            1)  op_start   ; press_enter ;;
            2)  op_stop    ; press_enter ;;
            3)  op_restart ; press_enter ;;
            4)  op_reload  ; press_enter ;;
            5)  op_enable  ; press_enter ;;
            6)  op_disable ; press_enter ;;
            7)  op_status  ; press_enter ;;
            8)  op_logs    ; press_enter ;;
            9)  op_show_config ; press_enter ;;
            10) op_edit_config ; press_enter ;;
            11) op_backup  ; press_enter ;;
            12) op_clone   ; press_enter ;;
            13) op_export  ; press_enter ;;
            14) op_remove  ; press_enter ;;
            0) return 0 ;;
            *) printf 'Invalid.\n' ;;
        esac
    done
}

import_menu() {
    while true; do
        clear_screen; banner
        printf '\n%sImport / Export%s\n\n' "$C_BOLD" "$C_RESET"
        printf '  %s1)%s Import a .toml config\n' "$C_CYAN" "$C_RESET"
        printf '  %s0)%s Back\n'                  "$C_GREY" "$C_RESET"
        local ch; printf '%sChoice: %s' "$C_BOLD" "$C_RESET"; read -r ch
        case "$ch" in
            1) op_import; press_enter ;;
            0) return 0 ;;
        esac
    done
}

main_menu() {
    while true; do
        clear_screen; banner
        print_status_table
        printf '\n%sMain Menu%s\n\n' "$C_BOLD" "$C_RESET"
        printf '  %s1)%s Create new tunnel (server/client)\n' "$C_CYAN" "$C_RESET"
        printf '  %s2)%s Manage an existing instance\n'       "$C_CYAN" "$C_RESET"
        printf '  %s3)%s Start ALL instances\n'                "$C_CYAN" "$C_RESET"
        printf '  %s4)%s Stop  ALL instances\n'                "$C_CYAN" "$C_RESET"
        printf '  %s5)%s Restart ALL instances\n'              "$C_CYAN" "$C_RESET"
        printf '  %s6)%s Import / export configs\n'            "$C_CYAN" "$C_RESET"
        printf '  %s7)%s Update / re-download Backhaul binary\n'"$C_CYAN" "$C_RESET"
        printf '  %s8)%s Show paths & system info\n'           "$C_CYAN" "$C_RESET"
        printf '  %s9)%s Uninstall Backhaul (full cleanup)\n'  "$C_CYAN" "$C_RESET"
        printf '  %s0)%s Exit\n'                               "$C_GREY" "$C_RESET"
        local ch; printf '%sChoice: %s' "$C_BOLD" "$C_RESET"; read -r ch
        case "$ch" in
            1) create_instance; press_enter ;;
            2) instance_menu ;;
            3) bulk_start_all; press_enter ;;
            4) bulk_stop_all; press_enter ;;
            5) bulk_restart_all; press_enter ;;
            6) import_menu ;;
            7) ensure_binary; press_enter ;;
            8) show_info ;;
            9) uninstall_all; press_enter ;;
            0) printf '%sGoodbye!%s\n' "$C_CYAN" "$C_RESET"; exit 0 ;;
            *) printf 'Invalid choice.\n' ;;
        esac
    done
}

show_info() {
    clear_screen; banner
    printf '\n%sSystem & installation info%s\n\n' "$C_BOLD" "$C_RESET"
    printf '  Script version : %s\n'  "$SCRIPT_VERSION"
    printf '  OS / kernel    : %s  (%s)\n' "$(uname -srm)" "$(uname -m)"
    printf '  Architecture   : %s\n' "$(detect_arch 2>/dev/null || echo '?')"
    printf '  systemd        : %s\n' "$(systemctl --version | head -1 || echo 'not available')"
    printf '  Install dir    : %s\n' "$INSTALL_DIR"
    printf '  Configs dir    : %s\n' "$CONF_DIR"
    printf '  Services dir   : %s\n' "$SVC_DIR"
    printf '  Binary path    : %s\n' "$BIN_PATH"
    printf '  Backups dir    : %s\n' "$BACKUP_DIR"
    if [[ -x "$BIN_PATH" ]]; then
        printf '  Backhaul ver   : %s\n' "$("$BIN_PATH" --version 2>&1 | head -1 || echo 'unknown')"
    else
        printf '  Backhaul ver   : %snot installed%s\n' "$C_RED" "$C_RESET"
    fi
    printf '  Instances      : %d\n' "$(list_instances | wc -l)"
    press_enter
}

# ----------------------------------------------------------------------------
#  Entrypoint
# ----------------------------------------------------------------------------
main() {
    require_root
    ensure_deps
    init_dirs
    ensure_binary
    main_menu
}

main "$@"
