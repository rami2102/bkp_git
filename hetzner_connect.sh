#!/bin/bash
#
# Connect to Hetzner Storage Box via SSHFS
# Mounts the remote storage to a local directory
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Hetzner Storage Box settings (from .env)
HETZNER_USER="${HETZNER_USER:-}"
HETZNER_HOST="${HETZNER_HOST:-}"
HETZNER_PORT="${HETZNER_PORT:-23}"
HETZNER_MOUNT_POINT="${HETZNER_MOUNT_POINT:-${SCRIPT_DIR}/hetzner_mount}"
HETZNER_REMOTE_PATH="${HETZNER_REMOTE_PATH:-/}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_dependencies() {
    if ! command -v sshfs &> /dev/null; then
        log_error "sshfs is not installed. Install it with:"
        echo "  Ubuntu/Debian: sudo apt install sshfs"
        echo "  macOS: brew install macfuse && brew install sshfs"
        exit 1
    fi
}

check_config() {
    if [[ -z "$HETZNER_USER" ]]; then
        log_error "HETZNER_USER is not set in .env"
        exit 1
    fi
    if [[ -z "$HETZNER_HOST" ]]; then
        log_error "HETZNER_HOST is not set in .env"
        exit 1
    fi
}

is_mounted() {
    mountpoint -q "$HETZNER_MOUNT_POINT" 2>/dev/null
}

connect() {
    check_dependencies
    check_config

    log_info "Connecting to Hetzner Storage Box..."
    log_info "Host: ${HETZNER_USER}@${HETZNER_HOST}:${HETZNER_PORT}"
    log_info "Remote path: ${HETZNER_REMOTE_PATH}"
    log_info "Mount point: ${HETZNER_MOUNT_POINT}"

    # Create mount point if it doesn't exist
    mkdir -p "$HETZNER_MOUNT_POINT"

    # Check if already mounted
    if is_mounted; then
        log_warning "Already mounted at ${HETZNER_MOUNT_POINT}"
        exit 0
    fi

    # Mount using sshfs
    sshfs "${HETZNER_USER}@${HETZNER_HOST}:${HETZNER_REMOTE_PATH}" "$HETZNER_MOUNT_POINT" \
        -p "$HETZNER_PORT" \
        -o reconnect \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=3 \
        -o allow_other \
        -o default_permissions \
        2>/dev/null || {
            # Try without allow_other (requires /etc/fuse.conf user_allow_other)
            sshfs "${HETZNER_USER}@${HETZNER_HOST}:${HETZNER_REMOTE_PATH}" "$HETZNER_MOUNT_POINT" \
                -p "$HETZNER_PORT" \
                -o reconnect \
                -o ServerAliveInterval=15 \
                -o ServerAliveCountMax=3 || {
                    log_error "Failed to mount Hetzner Storage Box"
                    log_info "Make sure your SSH key is set up or you'll be prompted for password"
                    exit 1
                }
        }

    if is_mounted; then
        log_success "Hetzner Storage Box mounted at: ${HETZNER_MOUNT_POINT}"
        log_info "Contents:"
        ls -la "$HETZNER_MOUNT_POINT" 2>/dev/null | head -10
    else
        log_error "Mount verification failed"
        exit 1
    fi
}

show_status() {
    check_config

    if is_mounted; then
        log_success "Hetzner Storage Box is CONNECTED"
        log_info "Mount point: ${HETZNER_MOUNT_POINT}"

        # Show disk usage
        df -h "$HETZNER_MOUNT_POINT" 2>/dev/null || true
    else
        log_warning "Hetzner Storage Box is NOT connected"
    fi
}

show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  connect     Connect to Hetzner Storage Box (default)"
    echo "  status      Show connection status"
    echo "  help        Show this help message"
    echo ""
    echo "Required .env variables:"
    echo "  HETZNER_USER    - Your Storage Box username (e.g., u123456)"
    echo "  HETZNER_HOST    - Your Storage Box host (e.g., u123456.your-storagebox.de)"
    echo ""
    echo "Optional .env variables:"
    echo "  HETZNER_PORT        - SSH port (default: 23)"
    echo "  HETZNER_MOUNT_POINT - Local mount directory (default: ./hetzner_mount)"
    echo "  HETZNER_REMOTE_PATH - Remote path to mount (default: /)"
}

# Main
case "${1:-connect}" in
    connect)
        connect
        ;;
    status|check)
        show_status
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        log_error "Unknown option: $1"
        show_usage
        exit 1
        ;;
esac
