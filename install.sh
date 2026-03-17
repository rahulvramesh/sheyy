#!/usr/bin/env bash
#
# SheyyBot Installer
# One-command install for the SheyyBot multi-agent Telegram bot.
#
# Usage:
#   sudo ./install.sh
#   curl -sSL <url> | sudo bash
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; }
step()    { echo -e "\n${CYAN}${BOLD}=> $*${NC}"; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ZIG_VERSION="0.14.0"
ZIG_INSTALL_DIR="/usr/local/lib/zig"
SERVICE_USER="sheyybot"
SERVICE_GROUP="sheyybot"
WORK_DIR="/var/lib/sheyybot"
BINARY_DEST="/usr/local/bin/sheyybot"
SERVICE_FILE="/etc/systemd/system/sheyybot.service"

# Determine the project source directory.
# When piped via curl the script lands in a temp file, so we fall back to
# the current working directory.  When run directly, SCRIPT_DIR points at the
# repo checkout.
if [[ "${BASH_SOURCE[0]}" == *"install.sh"* ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
step "Pre-flight checks"

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
    exit 1
fi
success "Running as root"

if [[ ! -f "${SCRIPT_DIR}/build.zig" ]]; then
    error "Cannot find build.zig in ${SCRIPT_DIR}."
    error "Please run this script from the project root, or clone the repo first."
    exit 1
fi
success "Project directory: ${SCRIPT_DIR}"

# ---------------------------------------------------------------------------
# Detect OS
# ---------------------------------------------------------------------------
step "Detecting operating system"

DISTRO="unknown"
PKG_INSTALL=""

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID}" in
        ubuntu|debian|linuxmint|pop)
            DISTRO="debian"
            PKG_INSTALL="apt-get install -y"
            ;;
        rhel|centos|rocky|almalinux|fedora)
            DISTRO="rhel"
            if command -v dnf &>/dev/null; then
                PKG_INSTALL="dnf install -y"
            else
                PKG_INSTALL="yum install -y"
            fi
            ;;
        arch|manjaro|endeavouros)
            DISTRO="arch"
            PKG_INSTALL="pacman -S --noconfirm"
            ;;
        *)
            warn "Unrecognized distribution: ${ID}. Will attempt generic install."
            ;;
    esac
fi

if [[ "${DISTRO}" == "unknown" ]]; then
    # Fallback heuristics
    if command -v apt-get &>/dev/null; then
        DISTRO="debian"
        PKG_INSTALL="apt-get install -y"
    elif command -v dnf &>/dev/null; then
        DISTRO="rhel"
        PKG_INSTALL="dnf install -y"
    elif command -v yum &>/dev/null; then
        DISTRO="rhel"
        PKG_INSTALL="yum install -y"
    elif command -v pacman &>/dev/null; then
        DISTRO="arch"
        PKG_INSTALL="pacman -S --noconfirm"
    fi
fi

success "Detected distribution family: ${DISTRO}"

# ---------------------------------------------------------------------------
# Install system dependencies
# ---------------------------------------------------------------------------
step "Installing system dependencies"

install_deps() {
    local deps=(curl tar xz-utils)
    if [[ "${DISTRO}" == "rhel" ]]; then
        deps=(curl tar xz)
    elif [[ "${DISTRO}" == "arch" ]]; then
        deps=(curl tar xz)
    fi

    if [[ -n "${PKG_INSTALL}" ]]; then
        if [[ "${DISTRO}" == "debian" ]]; then
            apt-get update -qq 2>/dev/null || true
        fi
        ${PKG_INSTALL} "${deps[@]}" 2>/dev/null || true
    fi
}

install_deps
success "System dependencies ready"

# ---------------------------------------------------------------------------
# Install Zig 0.14.0
# ---------------------------------------------------------------------------
step "Checking for Zig ${ZIG_VERSION}"

install_zig() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64)  arch="x86_64"  ;;
        aarch64) arch="aarch64" ;;
        armv7l)  arch="armv7a"  ;;
        *)
            error "Unsupported architecture: ${arch}"
            exit 1
            ;;
    esac

    local tarball="zig-linux-${arch}-${ZIG_VERSION}.tar.xz"
    local url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"

    info "Downloading Zig ${ZIG_VERSION} for ${arch}..."
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '${tmpdir}'" RETURN

    if ! curl -fSL --progress-bar -o "${tmpdir}/${tarball}" "${url}"; then
        error "Failed to download Zig from ${url}"
        exit 1
    fi

    info "Extracting..."
    rm -rf "${ZIG_INSTALL_DIR}"
    mkdir -p "${ZIG_INSTALL_DIR}"
    tar -xf "${tmpdir}/${tarball}" -C "${ZIG_INSTALL_DIR}" --strip-components=1

    # Symlink into PATH
    ln -sf "${ZIG_INSTALL_DIR}/zig" /usr/local/bin/zig

    rm -rf "${tmpdir}"
    trap - RETURN
}

NEED_ZIG=false
if command -v zig &>/dev/null; then
    CURRENT_ZIG="$(zig version 2>/dev/null || echo "0")"
    if [[ "${CURRENT_ZIG}" == "${ZIG_VERSION}" ]]; then
        success "Zig ${ZIG_VERSION} is already installed"
    else
        warn "Found Zig ${CURRENT_ZIG}, need ${ZIG_VERSION}"
        NEED_ZIG=true
    fi
else
    info "Zig not found"
    NEED_ZIG=true
fi

if [[ "${NEED_ZIG}" == "true" ]]; then
    install_zig
    success "Zig ${ZIG_VERSION} installed to ${ZIG_INSTALL_DIR}"
fi

# Verify
if ! zig version &>/dev/null; then
    error "Zig installation failed. Cannot continue."
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the project
# ---------------------------------------------------------------------------
step "Building SheyyBot (ReleaseFast)"

cd "${SCRIPT_DIR}"
if ! zig build -Doptimize=ReleaseFast; then
    error "Build failed. Check the output above for details."
    exit 1
fi

BUILT_BINARY="${SCRIPT_DIR}/zig-out/bin/my_zig_agent"
if [[ ! -f "${BUILT_BINARY}" ]]; then
    error "Build succeeded but binary not found at ${BUILT_BINARY}"
    exit 1
fi
success "Build complete"

# ---------------------------------------------------------------------------
# Create system user
# ---------------------------------------------------------------------------
step "Creating system user '${SERVICE_USER}'"

if id "${SERVICE_USER}" &>/dev/null; then
    success "User '${SERVICE_USER}' already exists"
else
    useradd --system --no-create-home --home-dir "${WORK_DIR}" \
            --shell /usr/sbin/nologin "${SERVICE_USER}"
    success "Created system user '${SERVICE_USER}'"
fi

# ---------------------------------------------------------------------------
# Create working directory structure
# ---------------------------------------------------------------------------
step "Setting up working directory: ${WORK_DIR}"

for subdir in agents teams skills memory workspaces; do
    mkdir -p "${WORK_DIR}/${subdir}"
done
success "Directory structure created"

# ---------------------------------------------------------------------------
# Install binary
# ---------------------------------------------------------------------------
step "Installing binary"

cp -f "${BUILT_BINARY}" "${BINARY_DEST}"
chmod 755 "${BINARY_DEST}"
success "Binary installed to ${BINARY_DEST}"

# ---------------------------------------------------------------------------
# Copy agents, teams, skills from repo (always overwrite)
# ---------------------------------------------------------------------------
step "Copying agent definitions, teams, and skills"

# Agents
if ls "${SCRIPT_DIR}/agents/"*.json &>/dev/null; then
    cp -f "${SCRIPT_DIR}/agents/"*.json "${WORK_DIR}/agents/"
    success "Agents copied ($(ls "${SCRIPT_DIR}/agents/"*.json | wc -l) files)"
else
    warn "No agent JSON files found in ${SCRIPT_DIR}/agents/"
fi

# Teams
if ls "${SCRIPT_DIR}/teams/"*.json &>/dev/null; then
    cp -f "${SCRIPT_DIR}/teams/"*.json "${WORK_DIR}/teams/"
    success "Teams copied ($(ls "${SCRIPT_DIR}/teams/"*.json | wc -l) files)"
else
    warn "No team JSON files found in ${SCRIPT_DIR}/teams/"
fi

# Skills
if ls "${SCRIPT_DIR}/skills/"*.md &>/dev/null; then
    cp -f "${SCRIPT_DIR}/skills/"*.md "${WORK_DIR}/skills/"
    success "Skills copied ($(ls "${SCRIPT_DIR}/skills/"*.md | wc -l) files)"
else
    warn "No skill markdown files found in ${SCRIPT_DIR}/skills/"
fi

# Copy allowed_users.json if it exists in repo and not yet in work dir
if [[ -f "${SCRIPT_DIR}/allowed_users.json" ]] && [[ ! -f "${WORK_DIR}/allowed_users.json" ]]; then
    cp "${SCRIPT_DIR}/allowed_users.json" "${WORK_DIR}/allowed_users.json"
    info "Copied default allowed_users.json"
fi

# Copy mcp_servers.json if it exists in repo and not yet in work dir
if [[ -f "${SCRIPT_DIR}/mcp_servers.json" ]] && [[ ! -f "${WORK_DIR}/mcp_servers.json" ]]; then
    cp "${SCRIPT_DIR}/mcp_servers.json" "${WORK_DIR}/mcp_servers.json"
    info "Copied default mcp_servers.json"
fi

# ---------------------------------------------------------------------------
# Install systemd service
# ---------------------------------------------------------------------------
step "Installing systemd service"

if [[ -f "${SCRIPT_DIR}/systemd/sheyybot.service" ]]; then
    cp -f "${SCRIPT_DIR}/systemd/sheyybot.service" "${SERVICE_FILE}"
    success "Service file installed from project"
else
    warn "systemd/sheyybot.service not found in project; generating one inline"
    cat > "${SERVICE_FILE}" <<'UNIT'
[Unit]
Description=SheyyBot Multi-Agent Telegram Bot
After=network.target
Wants=network.target

[Service]
Type=simple
User=sheyybot
Group=sheyybot
WorkingDirectory=/var/lib/sheyybot
ExecStart=/usr/local/bin/sheyybot /var/lib/sheyybot
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sheyybot

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/sheyybot

LimitNOFILE=65536
TimeoutStopSec=30
KillSignal=SIGTERM

[Install]
WantedBy=multi-user.target
UNIT
    success "Service file generated"
fi

systemctl daemon-reload
success "systemd reloaded"

# ---------------------------------------------------------------------------
# Handle auth.json and models.json (never overwrite user configs)
# ---------------------------------------------------------------------------
step "Checking configuration files"

CONFIG_NEEDED=false

if [[ ! -f "${WORK_DIR}/auth.json" ]]; then
    CONFIG_NEEDED=true
    warn "auth.json not found in ${WORK_DIR}"
    cat > "${WORK_DIR}/auth.json" <<'JSON'
{
    "telegram_token": "YOUR_TELEGRAM_BOT_TOKEN_HERE",
    "api_keys": {
        "openai": "YOUR_OPENAI_API_KEY",
        "anthropic": "YOUR_ANTHROPIC_API_KEY"
    }
}
JSON
    info "Created template auth.json -- you MUST edit it with your real tokens"
else
    success "auth.json already exists (not overwriting)"
fi

if [[ ! -f "${WORK_DIR}/models.json" ]]; then
    CONFIG_NEEDED=true
    warn "models.json not found in ${WORK_DIR}"
    cat > "${WORK_DIR}/models.json" <<'JSON'
{
    "default": "gpt-4o",
    "models": {
        "gpt-4o": {
            "id": "gpt-4o",
            "api_format": "openai",
            "base_url": "https://api.openai.com/v1"
        },
        "claude-sonnet-4-20250514": {
            "id": "claude-sonnet-4-20250514",
            "api_format": "anthropic",
            "base_url": "https://api.anthropic.com"
        }
    }
}
JSON
    info "Created template models.json -- edit it to match your preferred models"
else
    success "models.json already exists (not overwriting)"
fi

# ---------------------------------------------------------------------------
# Set ownership and permissions
# ---------------------------------------------------------------------------
step "Setting permissions"

chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${WORK_DIR}"
chmod 750 "${WORK_DIR}"
# Protect secrets
if [[ -f "${WORK_DIR}/auth.json" ]]; then
    chmod 640 "${WORK_DIR}/auth.json"
fi
success "Ownership set to ${SERVICE_USER}:${SERVICE_GROUP}"

# ---------------------------------------------------------------------------
# Enable and start service
# ---------------------------------------------------------------------------
step "Enabling and starting SheyyBot service"

systemctl enable sheyybot.service 2>/dev/null
success "Service enabled (will start on boot)"

if [[ "${CONFIG_NEEDED}" == "true" ]]; then
    warn "Service NOT started -- configuration files need editing first."
    warn "Edit the files listed below, then run: sudo systemctl start sheyybot"
else
    if systemctl start sheyybot.service; then
        success "Service started"
    else
        warn "Service failed to start. Check logs: journalctl -u sheyybot -n 50"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}${BOLD}============================================${NC}"
echo -e "${GREEN}${BOLD}  SheyyBot installation complete!${NC}"
echo -e "${GREEN}${BOLD}============================================${NC}"
echo ""
echo -e "  ${BOLD}Binary:${NC}       ${BINARY_DEST}"
echo -e "  ${BOLD}Working dir:${NC}  ${WORK_DIR}"
echo -e "  ${BOLD}Service:${NC}      ${SERVICE_FILE}"
echo -e "  ${BOLD}User:${NC}         ${SERVICE_USER}"
echo ""

if [[ "${CONFIG_NEEDED}" == "true" ]]; then
    echo -e "${YELLOW}${BOLD}  ACTION REQUIRED:${NC}"
    echo ""
    if [[ ! -f "${WORK_DIR}/auth.json" ]] || grep -q "YOUR_" "${WORK_DIR}/auth.json" 2>/dev/null; then
        echo -e "  1. Edit ${BOLD}${WORK_DIR}/auth.json${NC}"
        echo -e "     Add your Telegram bot token and LLM API keys."
    fi
    if [[ ! -f "${WORK_DIR}/models.json" ]] || grep -q "YOUR_" "${WORK_DIR}/models.json" 2>/dev/null; then
        echo -e "  2. Edit ${BOLD}${WORK_DIR}/models.json${NC}"
        echo -e "     Configure your preferred LLM models."
    fi
    echo ""
    echo -e "  Then start the bot:"
    echo -e "    ${CYAN}sudo systemctl start sheyybot${NC}"
fi

echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    ${CYAN}sudo systemctl status sheyybot${NC}      # Check status"
echo -e "    ${CYAN}sudo journalctl -u sheyybot -f${NC}      # Follow logs"
echo -e "    ${CYAN}sudo systemctl restart sheyybot${NC}     # Restart"
echo -e "    ${CYAN}sudo systemctl stop sheyybot${NC}        # Stop"
echo ""
echo -e "  To update SheyyBot, pull the latest code and re-run:"
echo -e "    ${CYAN}sudo ./install.sh${NC}"
echo ""
