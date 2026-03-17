#!/bin/bash

# SheyyBot System Service Setup Script
# This script is idempotent - can be run multiple times safely

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
SERVICE_USER="sheyybot"
INSTALL_DIR="/usr/local/bin"
WORK_DIR="/var/lib/sheyybot"
SERVICE_NAME="sheyybot"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS"
        exit 1
    fi
    
    log_info "Detected OS: $OS $VERSION"
}

install_zig() {
    if command -v zig &> /dev/null; then
        ZIG_VERSION=$(zig version)
        log_info "Zig already installed: $ZIG_VERSION"
        return 0
    fi
    
    log_info "Installing Zig..."
    
    case $OS in
        ubuntu|debian)
            apt-get update
            apt-get install -y wget tar
            ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y wget tar
            ;;
        *)
            log_error "Unsupported OS for automatic Zig installation: $OS"
            exit 1
            ;;
    esac
    
    # Download and install Zig 0.15.2
    ZIG_VERSION="0.15.2"
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ZIG_ARCH="x86_64"
            ;;
        aarch64)
            ZIG_ARCH="aarch64"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    
    ZIG_TARBALL="zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"
    
    cd /tmp
    wget -q "$ZIG_URL"
    tar -xf "$ZIG_TARBALL"
    mv "zig-linux-${ZIG_ARCH}-${ZIG_VERSION}" /usr/local/zig
    ln -sf /usr/local/zig/zig /usr/local/bin/zig
    rm -f "$ZIG_TARBALL"
    
    log_info "Zig installed successfully"
}

build_project() {
    log_info "Building project..."
    
    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    
    cd "$PROJECT_DIR"
    
    # Clean previous builds
    rm -rf zig-out .zig-cache
    
    # Build in release mode
    zig build -Doptimize=ReleaseFast
    
    if [ ! -f "zig-out/bin/my_zig_agent" ]; then
        log_error "Build failed - binary not found"
        exit 1
    fi
    
    log_info "Build successful"
}

create_user() {
    if id "$SERVICE_USER" &>/dev/null; then
        log_info "User $SERVICE_USER already exists"
    else
        log_info "Creating system user $SERVICE_USER..."
        useradd --system --no-create-home --shell /bin/false "$SERVICE_USER"
        log_info "User created"
    fi
}

setup_directories() {
    log_info "Setting up directories..."
    
    # Create working directory
    mkdir -p "$WORK_DIR"
    
    # Create subdirectories
    mkdir -p "$WORK_DIR/agents"
    mkdir -p "$WORK_DIR/teams"
    mkdir -p "$WORK_DIR/skills"
    mkdir -p "$WORK_DIR/memory"
    mkdir -p "$WORK_DIR/workspaces"
    
    # Set ownership
    chown -R "$SERVICE_USER:$SERVICE_USER" "$WORK_DIR"
    chmod 750 "$WORK_DIR"
    
    log_info "Directories created"
}

install_binary() {
    log_info "Installing binary..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    
    cp "$PROJECT_DIR/zig-out/bin/my_zig_agent" "$INSTALL_DIR/$SERVICE_NAME"
    chmod 755 "$INSTALL_DIR/$SERVICE_NAME"
    
    log_info "Binary installed to $INSTALL_DIR/$SERVICE_NAME"
}

install_systemd_service() {
    log_info "Installing systemd service..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    
    cp "$PROJECT_DIR/systemd/$SERVICE_NAME.service" "/etc/systemd/system/"
    chmod 644 "/etc/systemd/system/$SERVICE_NAME.service"
    
    systemctl daemon-reload
    
    log_info "Systemd service installed"
}

main() {
    log_info "Starting SheyyBot service setup..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
    
    detect_os
    install_zig
    build_project
    create_user
    setup_directories
    install_binary
    install_systemd_service
    
    log_info "========================================="
    log_info "Setup complete!"
    log_info ""
    log_info "Next steps:"
    log_info "1. Copy your config files to $WORK_DIR:"
    log_info "   - auth.json"
    log_info "   - models.json"
    log_info "   - allowed_users.json (optional)"
    log_info "   - mcp_servers.json (optional)"
    log_info "   - agents/*.json"
    log_info "   - teams/*.json"
    log_info "   - skills/*.md"
    log_info ""
    log_info "2. Run: sudo ./scripts/deploy.sh"
    log_info ""
    log_info "Or manually:"
    log_info "   sudo systemctl enable $SERVICE_NAME"
    log_info "   sudo systemctl start $SERVICE_NAME"
    log_info "   sudo systemctl status $SERVICE_NAME"
    log_info "========================================="
}

main "$@"
