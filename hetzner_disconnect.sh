#!/bin/bash
#
# Disconnect from Hetzner Storage Box
# Unmounts the SSHFS mount point
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
HETZNER_MOUNT_POINT="${HETZNER_MOUNT_POINT:-${SCRIPT_DIR}/hetzner_mount}"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

is_mounted() {
    mountpoint -q "$HETZNER_MOUNT_POINT" 2>/dev/null
}

disconnect() {
    log_info "Disconnecting from Hetzner Storage Box..."

    if ! is_mounted; then
        log_warning "Not currently mounted at ${HETZNER_MOUNT_POINT}"
        exit 0
    fi

    # Try normal unmount first
    if fusermount -u "$HETZNER_MOUNT_POINT" 2>/dev/null; then
        log_success "Hetzner Storage Box disconnected"
    elif umount "$HETZNER_MOUNT_POINT" 2>/dev/null; then
        log_success "Hetzner Storage Box disconnected"
    else
        log_warning "Normal unmount failed, trying lazy unmount..."
        if fusermount -uz "$HETZNER_MOUNT_POINT" 2>/dev/null || umount -l "$HETZNER_MOUNT_POINT" 2>/dev/null; then
            log_success "Hetzner Storage Box disconnected (lazy unmount)"
        else
            log_error "Failed to unmount. There may be processes using the mount."
            log_info "Try: lsof +D ${HETZNER_MOUNT_POINT}"
            exit 1
        fi
    fi

    # Verify unmount
    if ! is_mounted; then
        log_success "Mount point is now free: ${HETZNER_MOUNT_POINT}"
    fi
}

force_disconnect() {
    log_warning "Force disconnecting from Hetzner Storage Box..."

    if ! is_mounted; then
        log_warning "Not currently mounted at ${HETZNER_MOUNT_POINT}"
        exit 0
    fi

    # Force lazy unmount
    fusermount -uz "$HETZNER_MOUNT_POINT" 2>/dev/null || umount -l "$HETZNER_MOUNT_POINT" 2>/dev/null || {
        log_error "Failed to force unmount"
        exit 1
    }

    log_success "Hetzner Storage Box force disconnected"
}

show_status() {
    if is_mounted; then
        log_success "Hetzner Storage Box is CONNECTED"
        log_info "Mount point: ${HETZNER_MOUNT_POINT}"
        df -h "$HETZNER_MOUNT_POINT" 2>/dev/null || true
    else
        log_warning "Hetzner Storage Box is NOT connected"
    fi
}

show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  disconnect  Disconnect from Hetzner Storage Box (default)"
    echo "  force       Force disconnect (lazy unmount)"
    echo "  status      Show connection status"
    echo "  help        Show this help message"
}

# Main
case "${1:-disconnect}" in
    disconnect)
        disconnect
        ;;
    force)
        force_disconnect
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
