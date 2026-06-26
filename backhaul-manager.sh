#!/usr/bin/env bash
# ============================================================
#  Backhaul Reverse Tunnel Manager
#  Supports: Debian / Ubuntu (systemd-based)
#  GitHub  : https://github.com/Musixal/Backhaul
# ============================================================

set -euo pipefail

# ─── Constants ───────────────────────────────────────────────
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/backhaul"
SERVICE_PREFIX="backhaul"
LOG_DIR="/var/log/backhaul"
BINARY_NAME="backhaul"
BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
GITHUB_API="https://api.github.com/repos/Musixal/Backhaul/releases/latest"
GITHUB_RELEASES="https://github.com/Musixal/Backhaul/releases"

# ─── Colors ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# ─── Helpers ─────────────────────────────────────────────────
err()  { echo -e "${RED}[✗] $*${NC}" >&2; }
ok()   { echo -e "${GREEN}[✓] $*${NC}"; }
info() { echo -e "${CYAN}[i] $*${NC}"; }
warn() { echo -e "${YELLOW}[!] $*${NC}"; }
step() { echo -e "${BLUE}[→] $*${NC}"; }
bold() { echo -e "${BOLD}$*${NC}"; }

pause() {
    echo ""
    read -rp "$(echo -e "${DIM}  Press Enter to continue...${NC}")" _
}

confirm() {
    local prompt="${1:-Are you sure?}"
    local answer
    read -rp "$(echo -e "${YELLOW}  ${prompt} [y/N]: ${NC}")" answer
    [[ "${answer,,}" == "y" ]]
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This action requires root privileges."
        err "Please run: sudo $0"
        exit 1
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        i386|i686) echo "386" ;;
        *)       echo "$arch" ;;
    esac
}

detect_os() {
    local os
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    echo "$os"
}

is_installed() {
    [[ -x "${BINARY_PATH}" ]]
}

installed_version() {
    if is_installed; then
        "${BINARY_PATH}" --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
    else
        echo "not installed"
    fi
}

list_tunnel_services() {
    systemctl list-units --type=service --all --no-legend 2>/dev/null \
        | awk '{print $1}' \
        | grep "^${SERVICE_PREFIX}-" \
        | sed 's/\.service$//' || true
}

list_config_files() {
    find "${CONFIG_DIR}" -maxdepth 1 -name "*.toml" 2>/dev/null | sort || true
}

service_name_from_config() {
    local config="$1"
    local base
    base=$(basename "$config" .toml)
    echo "${SERVICE_PREFIX}-${base}"
}

config_from_service() {
    local svc="$1"
    local base="${svc#${SERVICE_PREFIX}-}"
    echo "${CONFIG_DIR}/${base}.toml"
}

service_status_icon() {
    local svc="$1"
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        echo -e "${GREEN}●${NC}"
    elif systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
        echo -e "${YELLOW}○${NC}"
    else
        echo -e "${RED}✗${NC}"
    fi
}

service_status_text() {
    local svc="$1"
    if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
        echo -e "${GREEN}running${NC}"
    elif systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
        echo -e "${YELLOW}stopped${NC}"
    else
        echo -e "${RED}disabled${NC}"
    fi
}

get_tunnel_role() {
    local config="$1"
    if grep -q '^\[server\]' "$config" 2>/dev/null; then
        echo "server"
    elif grep -q '^\[client\]' "$config" 2>/dev/null; then
        echo "client"
    else
        echo "unknown"
    fi
}

get_tunnel_transport() {
    local config="$1"
    grep -oP '(?<=^transport = ").*(?=")' "$config" 2>/dev/null || echo "?"
}

get_tunnel_bind_or_remote() {
    local config="$1"
    local role
    role=$(get_tunnel_role "$config")
    if [[ "$role" == "server" ]]; then
        grep -oP '(?<=^bind_addr = ").*(?=")' "$config" 2>/dev/null || echo "?"
    else
        grep -oP '(?<=^remote_addr = ").*(?=")' "$config" 2>/dev/null || echo "?"
    fi
}

draw_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${WHITE}${BOLD}        Backhaul Reverse Tunnel Manager v2.0              ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}║${DIM}        github.com/Musixal/Backhaul                        ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"

    local ver
    ver=$(installed_version)
    local status_str
    if is_installed; then
        status_str="${GREEN}Installed${NC} (${ver})"
    else
        status_str="${RED}Not Installed${NC}"
    fi

    local tunnel_count
    tunnel_count=$(list_tunnel_services | wc -l)

    printf "${CYAN}║${NC}  Binary : %-47b${CYAN}║${NC}\n" "$status_str"
    printf "${CYAN}║${NC}  Tunnels: ${WHITE}%d${NC} configured%-37s${CYAN}║${NC}\n" "$tunnel_count" ""
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ─── Installation ────────────────────────────────────────────
install_backhaul() {
    require_root
    draw_header
    bold "  ╔═ Install / Update Backhaul ═══════════════════════════╗"

    echo ""
    info "Detecting system architecture..."
    local arch os
    arch=$(detect_arch)
    os=$(detect_os)
    info "Detected: ${os}/${arch}"
    echo ""

    # Fetch latest release info
    step "Fetching latest release from GitHub..."
    local release_info download_url version
    release_info=$(curl -fsSL --retry 3 "$GITHUB_API" 2>/dev/null) || {
        warn "Could not reach GitHub API. Attempting manual version entry."
        release_info=""
    }

    if [[ -n "$release_info" ]]; then
        version=$(echo "$release_info" | grep '"tag_name"' | head -1 | grep -oP '(?<=")[^"]*(?=")' | tail -1)
        download_url=$(echo "$release_info" | grep '"browser_download_url"' | grep "${os}_${arch}" | head -1 | grep -oP '(?<=")[^"]+\.tar\.gz(?=")')
    fi

    if [[ -z "${version:-}" ]]; then
        echo ""
        read -rp "$(echo -e "${YELLOW}  Enter version tag (e.g. v0.7.2): ${NC}")" version
        version="${version#v}"
        download_url="https://github.com/Musixal/Backhaul/releases/download/v${version}/backhaul_${os}_${arch}.tar.gz"
    fi

    if [[ -z "${download_url:-}" ]]; then
        local ver_clean="${version#v}"
        download_url="https://github.com/Musixal/Backhaul/releases/download/v${ver_clean}/backhaul_${os}_${arch}.tar.gz"
    fi

    info "Version  : ${version}"
    info "Download : ${download_url}"
    echo ""

    if is_installed && ! confirm "Backhaul is already installed. Overwrite?"; then
        return
    fi

    # Create dirs
    mkdir -p "${CONFIG_DIR}" "${LOG_DIR}"

    # Download
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf ${tmpdir}" EXIT

    step "Downloading binary..."
    if ! curl -fsSL --retry 3 -o "${tmpdir}/backhaul.tar.gz" "${download_url}"; then
        err "Download failed. Check the URL or your internet connection."
        info "Releases: ${GITHUB_RELEASES}"
        pause; return 1
    fi

    step "Extracting archive..."
    tar -xzf "${tmpdir}/backhaul.tar.gz" -C "${tmpdir}"

    local extracted_bin
    extracted_bin=$(find "${tmpdir}" -name "backhaul" -type f | head -1)
    if [[ -z "$extracted_bin" ]]; then
        err "Binary not found in archive."
        pause; return 1
    fi

    chmod +x "$extracted_bin"
    cp "$extracted_bin" "${BINARY_PATH}"

    trap - EXIT
    rm -rf "${tmpdir}"

    ok "Backhaul installed at ${BINARY_PATH}"
    ok "Version: $(installed_version)"
    pause
}

uninstall_backhaul() {
    require_root
    draw_header
    bold "  ╔═ Uninstall Backhaul ═══════════════════════════════════╗"
    echo ""

    if ! is_installed; then
        warn "Backhaul binary is not installed."
        pause; return
    fi

    local services
    services=$(list_tunnel_services)
    if [[ -n "$services" ]]; then
        warn "The following tunnel services will also be removed:"
        while IFS= read -r svc; do
            echo -e "  ${RED}▸${NC} ${svc}"
        done <<< "$services"
        echo ""
    fi

    if ! confirm "Uninstall Backhaul and remove ALL services & configs?"; then
        return
    fi

    # Stop and remove all services
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        step "Removing service: ${svc}"
        systemctl stop "${svc}.service" 2>/dev/null || true
        systemctl disable "${svc}.service" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
    done <<< "$(list_tunnel_services)"

    systemctl daemon-reload 2>/dev/null || true

    rm -f "${BINARY_PATH}"
    ok "Binary removed."

    if confirm "Also remove all config files in ${CONFIG_DIR}?"; then
        rm -rf "${CONFIG_DIR}"
        ok "Config directory removed."
    fi

    if confirm "Also remove log directory ${LOG_DIR}?"; then
        rm -rf "${LOG_DIR}"
        ok "Log directory removed."
    fi

    ok "Backhaul uninstalled."
    pause
}

# ─── Tunnel Creation ─────────────────────────────────────────
pick_transport() {
    echo "" >&2
    echo -e "  ${BOLD}Select Transport Protocol:${NC}" >&2
    echo "" >&2
    echo -e "  ${CYAN}1)${NC} tcp      - Standard TCP (fastest, simple)" >&2
    echo -e "  ${CYAN}2)${NC} tcpmux   - TCP with multiplexing (efficient, multi-session)" >&2
    echo -e "  ${CYAN}3)${NC} udp      - UDP tunneling" >&2
    echo -e "  ${CYAN}4)${NC} ws       - WebSocket (bypasses HTTP proxies/firewalls)" >&2
    echo -e "  ${CYAN}5)${NC} wss      - Secure WebSocket with TLS" >&2
    echo -e "  ${CYAN}6)${NC} wsmux    - WebSocket with multiplexing" >&2
    echo -e "  ${CYAN}7)${NC} wssmux   - Secure WebSocket with TLS + multiplexing" >&2
    echo "" >&2
    local choice
    read -rp "$(echo -e "${YELLOW}  Choice [1-7]: ${NC}")" choice
    case "$choice" in
        1) echo "tcp" ;;
        2) echo "tcpmux" ;;
        3) echo "udp" ;;
        4) echo "ws" ;;
        5) echo "wss" ;;
        6) echo "wsmux" ;;
        7) echo "wssmux" ;;
        *) echo "tcp" ;;
    esac
}

input_ports_interactive() {
    echo ""
    echo -e "  ${BOLD}Port Forwarding Rules:${NC}"
    echo -e "  ${DIM}Formats supported:${NC}"
    echo -e "  ${DIM}  443          → forward port 443 to remote 443${NC}"
    echo -e "  ${DIM}  4000=5000    → local 4000 → remote 5000${NC}"
    echo -e "  ${DIM}  443=1.1.1.1:5201 → local 443 → 1.1.1.1:5201${NC}"
    echo -e "  ${DIM}  443-600      → port range 443 to 600${NC}"
    echo ""
    echo -e "  ${DIM}Enter ports one per line. Empty line when done.${NC}"
    echo ""

    local ports=()
    local i=1
    while true; do
        read -rp "$(echo -e "${YELLOW}  Port rule #${i} (or Enter to finish): ${NC}")" rule
        [[ -z "$rule" ]] && break
        ports+=("\"${rule}\"")
        ((i++))
    done

    if [[ ${#ports[@]} -eq 0 ]]; then
        echo '[]'
    else
        local joined
        joined=$(IFS=', '; echo "${ports[*]}")
        echo "[${joined}]"
    fi
}

generate_token() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || openssl rand -hex 16 2>/dev/null \
        || echo "$(date +%s%N | sha256sum | head -c 32)"
}

create_server_config() {
    local name="$1"
    local transport="$2"
    local config_file="${CONFIG_DIR}/${name}.toml"

    echo ""
    echo -e "  ${BOLD}═══ Server Configuration ═══════════════════════════${NC}"
    echo ""

    # Bind address
    local bind_addr
    read -rp "$(echo -e "${YELLOW}  Bind address (default 0.0.0.0:3080): ${NC}")" bind_addr
    bind_addr="${bind_addr:-0.0.0.0:3080}"

    # Token
    local token
    local auto_token
    auto_token=$(generate_token)
    read -rp "$(echo -e "${YELLOW}  Auth token [Enter for random: ${auto_token:0:8}...]: ${NC}")" token
    token="${token:-$auto_token}"

    # Advanced options?
    local nodelay="false" channel_size="2048" heartbeat="40" keepalive="75"
    local web_port="0" log_level="info"

    if confirm "Configure advanced options?"; then
        read -rp "$(echo -e "${YELLOW}  Enable nodelay? [y/N]: ${NC}")" nd
        [[ "${nd,,}" == "y" ]] && nodelay="true"

        read -rp "$(echo -e "${YELLOW}  Channel size [2048]: ${NC}")" cs
        channel_size="${cs:-2048}"

        read -rp "$(echo -e "${YELLOW}  Heartbeat interval in seconds [40]: ${NC}")" hb
        heartbeat="${hb:-40}"

        read -rp "$(echo -e "${YELLOW}  Keepalive period in seconds [75]: ${NC}")" kp
        keepalive="${kp:-75}"

        read -rp "$(echo -e "${YELLOW}  Web monitoring port (0=disabled) [0]: ${NC}")" wp
        web_port="${wp:-0}"

        echo -e "${YELLOW}  Log level [info/debug/warn/error]: ${NC}"
        read -rp "  " ll
        log_level="${ll:-info}"
    fi

    # TLS for wss/wssmux
    local tls_cert="" tls_key=""
    if [[ "$transport" == "wss" || "$transport" == "wssmux" ]]; then
        echo ""
        warn "TLS certificate and key are required for ${transport}."
        echo -e "  ${DIM}Options:${NC}"
        echo -e "  ${CYAN}1)${NC} Generate self-signed certificate"
        echo -e "  ${CYAN}2)${NC} Provide existing paths"
        read -rp "$(echo -e "${YELLOW}  Choice [1/2]: ${NC}")" tls_choice

        if [[ "$tls_choice" == "1" ]]; then
            tls_cert="${CONFIG_DIR}/${name}-server.crt"
            tls_key="${CONFIG_DIR}/${name}-server.key"
            step "Generating self-signed TLS certificate..."
            openssl req -x509 -newkey rsa:2048 -keyout "${tls_key}" \
                -out "${tls_cert}" -days 3650 -nodes \
                -subj "/CN=backhaul-${name}" 2>/dev/null
            ok "Certificate: ${tls_cert}"
            ok "Key        : ${tls_key}"
        else
            read -rp "$(echo -e "${YELLOW}  TLS cert path: ${NC}")" tls_cert
            read -rp "$(echo -e "${YELLOW}  TLS key path:  ${NC}")" tls_key
        fi
    fi

    # Ports
    local ports_toml
    ports_toml=$(input_ports_interactive)

    # Mux options
    local mux_block=""
    if [[ "$transport" == "tcpmux" || "$transport" == "wsmux" || "$transport" == "wssmux" ]]; then
        echo ""
        local mux_con="8"
        read -rp "$(echo -e "${YELLOW}  Mux connections per stream [8]: ${NC}")" mc
        mux_con="${mc:-8}"
        mux_block="mux_con = ${mux_con}
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536"
    fi

    # Write config
    {
        echo "[server]"
        echo "bind_addr = \"${bind_addr}\""
        echo "transport = \"${transport}\""
        echo "token = \"${token}\""
        echo "keepalive_period = ${keepalive}"
        echo "nodelay = ${nodelay}"
        echo "channel_size = ${channel_size}"
        echo "heartbeat = ${heartbeat}"
        [[ -n "$mux_block" ]] && echo "$mux_block"
        [[ -n "$tls_cert" ]] && echo "tls_cert = \"${tls_cert}\""
        [[ -n "$tls_key"  ]] && echo "tls_key = \"${tls_key}\""
        echo "web_port = ${web_port}"
        echo "log_level = \"${log_level}\""
        echo "sniffer = false"
        echo "sniffer_log = \"${LOG_DIR}/${name}.json\""
        echo "ports = ${ports_toml}"
    } > "$config_file"

    echo ""
    ok "Server config saved: ${config_file}"
    echo ""
    info "Share these details with the client:"
    echo -e "  ${CYAN}Remote addr : ${WHITE}${bind_addr}${NC}"
    echo -e "  ${CYAN}Transport   : ${WHITE}${transport}${NC}"
    echo -e "  ${CYAN}Token       : ${WHITE}${token}${NC}"

    echo "$config_file"
}

create_client_config() {
    local name="$1"
    local transport="$2"
    local config_file="${CONFIG_DIR}/${name}.toml"

    echo ""
    echo -e "  ${BOLD}═══ Client Configuration ═══════════════════════════${NC}"
    echo ""

    # Remote address (the server's bind address)
    local remote_addr
    read -rp "$(echo -e "${YELLOW}  Server address:port (e.g. 1.2.3.4:3080): ${NC}")" remote_addr
    while [[ -z "$remote_addr" ]]; do
        warn "Remote address is required."
        read -rp "$(echo -e "${YELLOW}  Server address:port: ${NC}")" remote_addr
    done

    # Token
    local token
    read -rp "$(echo -e "${YELLOW}  Auth token (must match server): ${NC}")" token
    while [[ -z "$token" ]]; do
        warn "Token is required."
        read -rp "$(echo -e "${YELLOW}  Auth token: ${NC}")" token
    done

    # Advanced
    local nodelay="false" pool="8" retry="3" keepalive="75"
    local web_port="0" log_level="info" aggressive_pool="false"

    if confirm "Configure advanced options?"; then
        read -rp "$(echo -e "${YELLOW}  Enable nodelay? [y/N]: ${NC}")" nd
        [[ "${nd,,}" == "y" ]] && nodelay="true"

        read -rp "$(echo -e "${YELLOW}  Connection pool size [8]: ${NC}")" cp_size
        pool="${cp_size:-8}"

        read -rp "$(echo -e "${YELLOW}  Enable aggressive pool? [y/N]: ${NC}")" ap
        [[ "${ap,,}" == "y" ]] && aggressive_pool="true"

        read -rp "$(echo -e "${YELLOW}  Retry interval in seconds [3]: ${NC}")" ri
        retry="${ri:-3}"

        read -rp "$(echo -e "${YELLOW}  Keepalive period in seconds [75]: ${NC}")" kp
        keepalive="${kp:-75}"

        read -rp "$(echo -e "${YELLOW}  Web monitoring port (0=disabled) [0]: ${NC}")" wp
        web_port="${wp:-0}"

        read -rp "$(echo -e "${YELLOW}  Log level [info]: ${NC}")" ll
        log_level="${ll:-info}"
    fi

    # Edge IP (CDN/WebSocket)
    local edge_ip=""
    if [[ "$transport" == "ws" || "$transport" == "wss" || "$transport" == "wsmux" || "$transport" == "wssmux" ]]; then
        read -rp "$(echo -e "${YELLOW}  Edge/CDN IP (optional, press Enter to skip): ${NC}")" edge_ip
    fi

    # Mux options
    local mux_block=""
    if [[ "$transport" == "tcpmux" || "$transport" == "wsmux" || "$transport" == "wssmux" ]]; then
        mux_block="mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536"
    fi

    # Write config
    {
        echo "[client]"
        echo "remote_addr = \"${remote_addr}\""
        [[ -n "$edge_ip" ]] && echo "edge_ip = \"${edge_ip}\""
        echo "transport = \"${transport}\""
        echo "token = \"${token}\""
        echo "connection_pool = ${pool}"
        echo "aggressive_pool = ${aggressive_pool}"
        echo "keepalive_period = ${keepalive}"
        echo "nodelay = ${nodelay}"
        echo "retry_interval = ${retry}"
        echo "dial_timeout = 10"
        [[ -n "$mux_block" ]] && echo "$mux_block"
        echo "web_port = ${web_port}"
        echo "log_level = \"${log_level}\""
        echo "sniffer = false"
        echo "sniffer_log = \"${LOG_DIR}/${name}.json\""
    } > "$config_file"

    echo ""
    ok "Client config saved: ${config_file}"

    echo "$config_file"
}

create_systemd_service() {
    local name="$1"
    local config_file="$2"
    local svc_name="${SERVICE_PREFIX}-${name}"
    local svc_file="/etc/systemd/system/${svc_name}.service"

    cat > "$svc_file" <<EOF
[Unit]
Description=Backhaul Tunnel - ${name}
Documentation=https://github.com/Musixal/Backhaul
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BINARY_PATH} -c ${config_file}
Restart=always
RestartSec=5
StartLimitInterval=0
LimitNOFILE=1048576
LimitNPROC=65536
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${svc_name}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    ok "Service created: ${svc_file}"
    echo "$svc_name"
}

create_tunnel() {
    require_root
    draw_header
    bold "  ╔═ Create New Tunnel ════════════════════════════════════╗"
    echo ""

    if ! is_installed; then
        err "Backhaul is not installed. Please install it first."
        pause; return 1
    fi

    mkdir -p "${CONFIG_DIR}" "${LOG_DIR}"

    # Tunnel name
    echo -e "  ${DIM}Tunnel name is used for the config file and service name.${NC}"
    local name
    read -rp "$(echo -e "${YELLOW}  Tunnel name (e.g. ir-tunnel): ${NC}")" name
    name="${name//[^a-zA-Z0-9_-]/}"
    while [[ -z "$name" ]]; do
        warn "Name cannot be empty or contain special characters."
        read -rp "$(echo -e "${YELLOW}  Tunnel name: ${NC}")" name
        name="${name//[^a-zA-Z0-9_-]/}"
    done

    if [[ -f "${CONFIG_DIR}/${name}.toml" ]]; then
        warn "A tunnel named '${name}' already exists."
        if ! confirm "Overwrite it?"; then return; fi
    fi

    # Role
    echo ""
    echo -e "  ${BOLD}Select Role:${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Server  ${DIM}(Iran / restricted-side — waits for client connections)${NC}"
    echo -e "  ${CYAN}2)${NC} Client  ${DIM}(Abroad / free-side — initiates the tunnel outbound)${NC}"
    echo ""
    read -rp "$(echo -e "${YELLOW}  Role [1/2]: ${NC}")" role_choice

    local transport
    transport=$(pick_transport)

    local config_file
    case "$role_choice" in
        1) config_file=$(create_server_config "$name" "$transport") ;;
        2) config_file=$(create_client_config "$name" "$transport") ;;
        *)
            err "Invalid choice."
            pause; return 1
            ;;
    esac

    echo ""
    local svc_name
    svc_name=$(create_systemd_service "$name" "$config_file")

    # Enable & start?
    echo ""
    if confirm "Enable and start the tunnel service now?"; then
        systemctl enable "${svc_name}.service" 2>/dev/null
        systemctl start "${svc_name}.service"
        sleep 1
        if systemctl is-active --quiet "${svc_name}.service"; then
            ok "Tunnel '${name}' is running!"
        else
            warn "Service started but may have issues. Check logs:"
            echo -e "  ${CYAN}journalctl -u ${svc_name}.service -f${NC}"
        fi
    else
        info "To start later: ${CYAN}systemctl start ${svc_name}.service${NC}"
    fi

    pause
}

# ─── Service Management ───────────────────────────────────────
select_tunnel() {
    local prompt="${1:-Select a tunnel:}"
    local services
    services=$(list_tunnel_services)

    if [[ -z "$services" ]]; then
        warn "No tunnels found."
        return 1
    fi

    echo ""
    echo -e "  ${BOLD}${prompt}${NC}"
    echo ""

    local i=1
    local -a svc_array=()
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        local icon status config role transport addr
        icon=$(service_status_icon "$svc")
        status=$(service_status_text "$svc")
        config=$(config_from_service "$svc")
        role=$(get_tunnel_role "$config")
        transport=$(get_tunnel_transport "$config")
        addr=$(get_tunnel_bind_or_remote "$config")

        printf "  ${CYAN}%d)${NC} %b %-25s %b  ${DIM}[%s/%s → %s]${NC}\n" \
            "$i" "$icon" "${svc#${SERVICE_PREFIX}-}" "$status" "$role" "$transport" "$addr"
        svc_array+=("$svc")
        ((i++))
    done <<< "$services"

    echo ""
    read -rp "$(echo -e "${YELLOW}  Choice [1-$((i-1))]: ${NC}")" idx
    idx="${idx:-0}"

    if [[ "$idx" -lt 1 || "$idx" -ge "$i" ]]; then
        err "Invalid selection."
        return 1
    fi

    echo "${svc_array[$((idx-1))]}"
}

manage_services() {
    while true; do
        draw_header
        bold "  ╔═ Service Management ═══════════════════════════════════╗"
        echo ""

        local services
        services=$(list_tunnel_services)

        if [[ -z "$services" ]]; then
            warn "  No tunnel services configured yet."
            echo ""
            echo -e "  Go to ${CYAN}Create New Tunnel${NC} to get started."
            pause; return
        fi

        echo -e "  ${BOLD}Configured Tunnels:${NC}"
        echo ""

        local i=1
        local -a svc_array=()
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            local icon status config role transport addr
            icon=$(service_status_icon "$svc")
            status=$(service_status_text "$svc")
            config=$(config_from_service "$svc")
            role=$(get_tunnel_role "$config")
            transport=$(get_tunnel_transport "$config")
            addr=$(get_tunnel_bind_or_remote "$config")

            printf "  %b ${BOLD}%d)${NC} %-25s  %b  ${DIM}%s/%s  %s${NC}\n" \
                "$icon" "$i" "${svc#${SERVICE_PREFIX}-}" "$status" "$role" "$transport" "$addr"
            svc_array+=("$svc")
            ((i++))
        done <<< "$services"

        echo ""
        echo -e "  ${BOLD}Actions:${NC}"
        echo -e "  ${CYAN}s)${NC} Start    ${CYAN}p)${NC} Stop     ${CYAN}r)${NC} Restart"
        echo -e "  ${CYAN}e)${NC} Enable   ${CYAN}d)${NC} Disable  ${CYAN}l)${NC} View Logs"
        echo -e "  ${CYAN}i)${NC} Status   ${CYAN}v)${NC} View Config"
        echo -e "  ${CYAN}x)${NC} Delete Tunnel   ${CYAN}b)${NC} Back"
        echo ""
        read -rp "$(echo -e "${YELLOW}  Action: ${NC}")" action

        case "${action,,}" in
            b|"") return ;;
            s)
                local svc
                svc=$(select_tunnel "Select tunnel to start:") || { pause; continue; }
                require_root
                systemctl start "${svc}.service" && ok "Started: ${svc}" || err "Failed to start."
                pause
                ;;
            p)
                local svc
                svc=$(select_tunnel "Select tunnel to stop:") || { pause; continue; }
                require_root
                systemctl stop "${svc}.service" && ok "Stopped: ${svc}" || err "Failed to stop."
                pause
                ;;
            r)
                local svc
                svc=$(select_tunnel "Select tunnel to restart:") || { pause; continue; }
                require_root
                systemctl restart "${svc}.service" && ok "Restarted: ${svc}" || err "Failed to restart."
                pause
                ;;
            e)
                local svc
                svc=$(select_tunnel "Select tunnel to enable:") || { pause; continue; }
                require_root
                systemctl enable "${svc}.service" && ok "Enabled: ${svc}" || err "Failed to enable."
                pause
                ;;
            d)
                local svc
                svc=$(select_tunnel "Select tunnel to disable:") || { pause; continue; }
                require_root
                systemctl disable "${svc}.service" && ok "Disabled: ${svc}" || err "Failed to disable."
                pause
                ;;
            l)
                local svc
                svc=$(select_tunnel "Select tunnel to view logs:") || { pause; continue; }
                echo ""
                info "Showing live logs for ${svc} (Ctrl+C to stop):"
                echo ""
                journalctl -u "${svc}.service" -f --no-pager -n 50 || true
                pause
                ;;
            i)
                local svc
                svc=$(select_tunnel "Select tunnel for status:") || { pause; continue; }
                echo ""
                systemctl status "${svc}.service" --no-pager || true
                pause
                ;;
            v)
                local svc config
                svc=$(select_tunnel "Select tunnel to view config:") || { pause; continue; }
                config=$(config_from_service "$svc")
                echo ""
                if [[ -f "$config" ]]; then
                    echo -e "${CYAN}━━━ ${config} ━━━${NC}"
                    cat "$config"
                    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                else
                    warn "Config file not found: ${config}"
                fi
                pause
                ;;
            x)
                local svc
                svc=$(select_tunnel "Select tunnel to DELETE:") || { pause; continue; }
                require_root
                echo ""
                warn "This will stop, disable, and permanently remove the tunnel '${svc}'."
                if confirm "Confirm deletion of '${svc}'?"; then
                    systemctl stop "${svc}.service" 2>/dev/null || true
                    systemctl disable "${svc}.service" 2>/dev/null || true
                    rm -f "/etc/systemd/system/${svc}.service"
                    systemctl daemon-reload

                    local config
                    config=$(config_from_service "$svc")
                    if confirm "Also delete config file: ${config}?"; then
                        rm -f "$config"
                        ok "Config removed."
                    fi
                    ok "Tunnel '${svc}' deleted."
                fi
                pause
                ;;
            *)
                warn "Unknown action."
                pause
                ;;
        esac
    done
}

# ─── Diagnostics ─────────────────────────────────────────────
run_diagnostics() {
    draw_header
    bold "  ╔═ System Diagnostics ═══════════════════════════════════╗"
    echo ""

    # Binary
    echo -e "  ${BOLD}[ Binary ]${NC}"
    if is_installed; then
        ok "  Binary found   : ${BINARY_PATH}"
        ok "  Version        : $(installed_version)"
    else
        err "  Binary NOT installed."
    fi
    echo ""

    # systemd
    echo -e "  ${BOLD}[ systemd ]${NC}"
    if systemctl --version &>/dev/null; then
        ok "  systemd available: $(systemctl --version | head -1)"
    else
        err "  systemd not found!"
    fi
    echo ""

    # Services
    echo -e "  ${BOLD}[ Tunnel Services ]${NC}"
    local services
    services=$(list_tunnel_services)
    if [[ -z "$services" ]]; then
        info "  No tunnel services configured."
    else
        while IFS= read -r svc; do
            [[ -z "$svc" ]] && continue
            local icon status
            icon=$(service_status_icon "$svc")
            status=$(service_status_text "$svc")
            printf "  %b %-30s %b\n" "$icon" "$svc" "$status"
        done <<< "$services"
    fi
    echo ""

    # Network
    echo -e "  ${BOLD}[ Network ]${NC}"
    if command -v ss &>/dev/null; then
        local listening
        listening=$(ss -tlnp 2>/dev/null | grep backhaul || echo "  (none)")
        info "  Backhaul listening sockets:"
        echo "$listening" | sed 's/^/    /'
    fi
    echo ""

    # Disk
    echo -e "  ${BOLD}[ Disk Usage ]${NC}"
    [[ -d "$CONFIG_DIR" ]] && info "  Config dir  : $(du -sh "${CONFIG_DIR}" 2>/dev/null | cut -f1)"
    [[ -d "$LOG_DIR"    ]] && info "  Log dir     : $(du -sh "${LOG_DIR}" 2>/dev/null | cut -f1)"
    echo ""

    # Kernel
    echo -e "  ${BOLD}[ System ]${NC}"
    info "  Kernel  : $(uname -r)"
    info "  OS      : $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || uname -s)"
    info "  Arch    : $(uname -m) ($(detect_arch))"
    info "  Uptime  : $(uptime -p 2>/dev/null || uptime)"

    pause
}

# ─── Quick Log Viewer ─────────────────────────────────────────
view_logs_menu() {
    draw_header
    bold "  ╔═ View Logs ════════════════════════════════════════════╗"
    echo ""

    local services
    services=$(list_tunnel_services)

    if [[ -z "$services" ]]; then
        warn "No tunnel services found."
        pause; return
    fi

    local svc
    svc=$(select_tunnel "Select tunnel to view logs:") || { pause; return; }

    echo ""
    echo -e "  ${BOLD}Log Options:${NC}"
    echo -e "  ${CYAN}1)${NC} Live tail (follow)"
    echo -e "  ${CYAN}2)${NC} Last 100 lines"
    echo -e "  ${CYAN}3)${NC} Last 500 lines"
    echo -e "  ${CYAN}4)${NC} Since boot"
    echo -e "  ${CYAN}5)${NC} Filter errors only"
    echo ""
    read -rp "$(echo -e "${YELLOW}  Choice [1-5]: ${NC}")" log_choice

    echo ""
    case "$log_choice" in
        1) journalctl -u "${svc}.service" -f --no-pager ;;
        2) journalctl -u "${svc}.service" -n 100 --no-pager ;;
        3) journalctl -u "${svc}.service" -n 500 --no-pager ;;
        4) journalctl -u "${svc}.service" -b --no-pager ;;
        5) journalctl -u "${svc}.service" -p err --no-pager ;;
        *) journalctl -u "${svc}.service" -n 50 --no-pager ;;
    esac

    pause
}

# ─── Quick Setup Wizard ───────────────────────────────────────
quick_setup_wizard() {
    require_root
    draw_header
    bold "  ╔═ Quick Setup Wizard ═══════════════════════════════════╗"
    echo ""
    echo -e "  ${DIM}This wizard sets up a common Iran↔Abroad tunnel in minutes.${NC}"
    echo ""

    if ! is_installed; then
        warn "Backhaul is not installed."
        if confirm "Install Backhaul now?"; then
            install_backhaul
            if ! is_installed; then
                err "Installation failed. Cannot continue."
                pause; return 1
            fi
        else
            return
        fi
    fi

    echo -e "  ${BOLD}What is this machine?${NC}"
    echo ""
    echo -e "  ${CYAN}1)${NC} Iran Server     ${DIM}(restricted side — inside Iran, has panel/services)${NC}"
    echo -e "  ${CYAN}2)${NC} Foreign Server  ${DIM}(free side — outside Iran, acts as tunnel client)${NC}"
    echo ""
    read -rp "$(echo -e "${YELLOW}  Choice [1/2]: ${NC}")" machine_type

    local name="main-tunnel"
    read -rp "$(echo -e "${YELLOW}  Tunnel name [${name}]: ${NC}")" user_name
    name="${user_name:-$name}"
    name="${name//[^a-zA-Z0-9_-]/}"

    case "$machine_type" in
        1)
            echo ""
            info "Setting up IRAN SERVER (Backhaul server side)"
            echo ""
            echo -e "  ${BOLD}Recommended transports for Iran:${NC}"
            echo -e "  ${CYAN}1)${NC} tcpmux  - Best performance + multiplexing"
            echo -e "  ${CYAN}2)${NC} wsmux   - Good for bypassing DPI/firewalls"
            echo -e "  ${CYAN}3)${NC} wssmux  - Encrypted WebSocket (most secure)"
            echo -e "  ${CYAN}4)${NC} tcp     - Simple and stable"
            read -rp "$(echo -e "${YELLOW}  Choice [1]: ${NC}")" t_choice
            local transport
            case "${t_choice:-1}" in
                1) transport="tcpmux" ;;
                2) transport="wsmux" ;;
                3) transport="wssmux" ;;
                4) transport="tcp" ;;
                *) transport="tcpmux" ;;
            esac
            create_server_config "$name" "$transport" > /dev/null
            local config_file="${CONFIG_DIR}/${name}.toml"
            local svc_name
            svc_name=$(create_systemd_service "$name" "$config_file")
            echo ""
            systemctl enable "${svc_name}.service"
            systemctl start "${svc_name}.service"
            sleep 1
            if systemctl is-active --quiet "${svc_name}.service"; then
                ok "Iran server tunnel is running!"
            fi
            ;;
        2)
            echo ""
            info "Setting up FOREIGN CLIENT (Backhaul client side)"
            echo ""
            echo -e "  ${DIM}Enter the transport protocol — must match the Iran server.${NC}"
            local transport
            transport=$(pick_transport)
            create_client_config "$name" "$transport" > /dev/null
            local config_file="${CONFIG_DIR}/${name}.toml"
            local svc_name
            svc_name=$(create_systemd_service "$name" "$config_file")
            echo ""
            systemctl enable "${svc_name}.service"
            systemctl start "${svc_name}.service"
            sleep 1
            if systemctl is-active --quiet "${svc_name}.service"; then
                ok "Foreign client tunnel is running!"
            fi
            ;;
        *)
            err "Invalid choice."
            pause; return 1
            ;;
    esac

    echo ""
    ok "Wizard complete! Run 'Manage Services' to check status."
    pause
}

# ─── Main Menu ────────────────────────────────────────────────
main_menu() {
    while true; do
        draw_header
        echo -e "  ${BOLD}Main Menu${NC}"
        echo ""
        echo -e "  ${CYAN}1)${NC}  Quick Setup Wizard    ${DIM}(recommended for first-time users)${NC}"
        echo -e "  ${CYAN}2)${NC}  Create New Tunnel      ${DIM}(manual, full control)${NC}"
        echo -e "  ${CYAN}3)${NC}  Manage Tunnel Services ${DIM}(start / stop / restart / logs)${NC}"
        echo -e "  ${CYAN}4)${NC}  View Logs"
        echo -e "  ${CYAN}5)${NC}  System Diagnostics"
        echo ""
        echo -e "  ${CYAN}6)${NC}  Install / Update Backhaul Binary"
        echo -e "  ${CYAN}7)${NC}  Uninstall Backhaul"
        echo ""
        echo -e "  ${RED}0)${NC}  Exit"
        echo ""
        read -rp "$(echo -e "${YELLOW}  Choice: ${NC}")" choice

        case "$choice" in
            1) quick_setup_wizard ;;
            2) create_tunnel ;;
            3) manage_services ;;
            4) view_logs_menu ;;
            5) run_diagnostics ;;
            6) install_backhaul ;;
            7) uninstall_backhaul ;;
            0|q|Q|exit|quit)
                echo ""
                ok "Goodbye!"
                echo ""
                exit 0
                ;;
            *) warn "Invalid option."; sleep 1 ;;
        esac
    done
}

# ─── Entry Point ─────────────────────────────────────────────
main() {
    # Check dependencies
    local missing=()
    for cmd in systemctl curl tar openssl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}[!] Missing required tools: ${missing[*]}${NC}"
        echo -e "${YELLOW}    Install with: apt-get install -y ${missing[*]}${NC}"
        exit 1
    fi

    # Handle CLI arguments for non-interactive use
    case "${1:-}" in
        install)   require_root; install_backhaul; exit 0 ;;
        uninstall) require_root; uninstall_backhaul; exit 0 ;;
        diag)      run_diagnostics; exit 0 ;;
        *)         main_menu ;;
    esac
}

main "$@"
