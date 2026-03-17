#!/bin/bash

# SheyyBot Deployment Script
# Copies configuration and starts the service
# This script is idempotent - can be run multiple times safely

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SERVICE_NAME="sheyybot"
WORK_DIR="/var/lib/sheyybot"
SERVICE_USER="sheyybot"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi
}

copy_configs() {
    log_step "Copying configuration files..."
    
    # Get the directory where this script is located
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    
    # Required config files
    if [ -f "$PROJECT_DIR/auth.json" ]; then
        cp "$PROJECT_DIR/auth.json" "$WORK_DIR/"
        log_info "Copied auth.json"
    else
        log_error "auth.json not found in project directory"
        exit 1
    fi
    
    if [ -f "$PROJECT_DIR/models.json" ]; then
        cp "$PROJECT_DIR/models.json" "$WORK_DIR/"
        log_info "Copied models.json"
    else
        log_error "models.json not found in project directory"
        exit 1
    fi
    
    # Optional config files
    if [ -f "$PROJECT_DIR/allowed_users.json" ]; then
        cp "$PROJECT_DIR/allowed_users.json" "$WORK_DIR/"
        log_info "Copied allowed_users.json"
    else
        log_warn "allowed_users.json not found, skipping"
    fi
    
    if [ -f "$PROJECT_DIR/mcp_servers.json" ]; then
        cp "$PROJECT_DIR/mcp_servers.json" "$WORK_DIR/"
        log_info "Copied mcp_servers.json"
    else
        log_warn "mcp_servers.json not found, skipping"
    fi
}

copy_agents() {
    log_step "Copying agents..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    
    if [ -d "$PROJECT_DIR/agents" ]; then
        rm -rf "$WORK_DIR/agents"
        cp -r "$PROJECT_DIR/agents" "$WORK_DIR/"
        AGENT_COUNT=$(find "$WORK_DIR/agents" -name "*.json" | wc -l)
        log_info "Copied $AGENT_COUNT agent definitions"
    else
        log_warn "agents directory not found, creating empty"
        mkdir -p "$WORK_DIR/agents"
    fi
}

copy_teams() {
    log_step "Copying teams..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    
    if [ -d "$PROJECT_DIR/teams" ]; then
        rm -rf "$WORK_DIR/teams"
        cp -r "$PROJECT_DIR/teams" "$WORK_DIR/"
        TEAM_COUNT=$(find "$WORK_DIR/teams" -name "*.json" | wc -l)
        log_info "Copied $TEAM_COUNT team definitions"
    else
        log_warn "teams directory not found, creating empty"
        mkdir -p "$WORK_DIR/teams"
    fi
}

copy_skills() {
    log_step "Copying skills..."
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
    
    if [ -d "$PROJECT_DIR/skills" ]; then
        rm -rf "$WORK_DIR/skills"
        cp -r "$PROJECT_DIR/skills" "$WORK_DIR/"
        SKILL_COUNT=$(find "$WORK_DIR/skills" -name "*.md" | wc -l)
        log_info "Copied $SKILL_COUNT skill files"
    else
        log_warn "skills directory not found, creating empty"
        mkdir -p "$WORK_DIR/skills"
    fi
}

setup_directories() {
    log_step "Setting up runtime directories..."
    
    # Ensure memory directory exists (preserve existing memory)
    mkdir -p "$WORK_DIR/memory"
    
    # Clean and recreate workspaces (don't preserve old workspaces)
    rm -rf "$WORK_DIR/workspaces"
    mkdir -p "$WORK_DIR/workspaces"
    
    log_info "Runtime directories ready"
}

set_permissions() {
    log_step "Setting permissions..."
    
    chown -R "$SERVICE_USER:$SERVICE_USER" "$WORK_DIR"
    chmod 750 "$WORK_DIR"
    chmod 640 "$WORK_DIR"/*.json 2>/dev/null || true
    chmod 750 "$WORK_DIR/agents" "$WORK_DIR/teams" "$WORK_DIR/skills" "$WORK_DIR/memory" "$WORK_DIR/workspaces" 2>/dev/null || true
    
    log_info "Permissions set"
}

reload_systemd() {
    log_step "Reloading systemd..."
    systemctl daemon-reload
    log_info "Systemd reloaded"
}

start_service() {
    log_step "Starting service..."
    
    # Enable service to start on boot
    systemctl enable "$SERVICE_NAME"
    
    # Stop if running
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Stopping existing service..."
        systemctl stop "$SERVICE_NAME"
        sleep 2
    fi
    
    # Start service
    systemctl start "$SERVICE_NAME"
    
    # Wait a moment for service to start
    sleep 2
    
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_info "Service started successfully"
    else
        log_error "Service failed to start"
        show_status
        exit 1
    fi
}

show_status() {
    log_step "Service status:"
    echo ""
    systemctl status "$SERVICE_NAME" --no-pager
    echo ""
    log_info "View logs with: sudo journalctl -u $SERVICE_NAME -f"
}

main() {
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}    SheyyBot Deployment Script${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo ""
    
    check_root
    copy_configs
    copy_agents
    copy_teams
    copy_skills
    setup_directories
    set_permissions
    reload_systemd
    start_service
    show_status
    
    echo ""
    log_info "========================================="
    log_info "Deployment complete!"
    log_info ""
    log_info "Useful commands:"
    log_info "  sudo systemctl status $SERVICE_NAME"
    log_info "  sudo systemctl stop $SERVICE_NAME"
    log_info "  sudo systemctl restart $SERVICE_NAME"
    log_info "  sudo journalctl -u $SERVICE_NAME -f"
    log_info "========================================="
}

main "$@"
