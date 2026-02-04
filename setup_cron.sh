#!/bin/bash
#
# Setup persistent cron job for GitHub backup
# Runs every 24 hours and persists after reboot
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/github_backup.sh"
LOG_FILE="${SCRIPT_DIR}/backup.log"

# Load environment variables
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Default backup time (24-hour format HH:MM)
BACKUP_TIME="${BACKUP_TIME:-00:01}"

# Cron job identifier (used to find/replace existing entry)
CRON_ID="# github_backup_job"

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_usage() {
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  install     Install the cron job (default if no option given)"
    echo "  remove      Remove the cron job"
    echo "  status      Show current cron job status"
    echo "  help        Show this help message"
    echo ""
    echo "The cron job runs daily at the time configured in .env (BACKUP_TIME, default: 00:01)"
    echo "Logs are written to: $LOG_FILE"
}

check_backup_script() {
    if [[ ! -f "$BACKUP_SCRIPT" ]]; then
        log_error "Backup script not found: $BACKUP_SCRIPT"
        exit 1
    fi

    if [[ ! -x "$BACKUP_SCRIPT" ]]; then
        log_info "Making backup script executable..."
        chmod +x "$BACKUP_SCRIPT"
    fi
}

get_current_cron() {
    crontab -l 2>/dev/null || true
}

has_existing_job() {
    get_current_cron | grep -q "$CRON_ID"
}

install_cron() {
    check_backup_script

    log_info "Installing cron job for daily backup..."

    # Parse BACKUP_TIME (format: HH:MM)
    local hour minute
    hour=$(echo "$BACKUP_TIME" | cut -d':' -f1)
    minute=$(echo "$BACKUP_TIME" | cut -d':' -f2)

    # Remove leading zeros for cron compatibility
    hour=$((10#$hour))
    minute=$((10#$minute))

    # Build cron line: run daily at configured time
    # Format: minute hour * * * command
    local cron_line="${minute} ${hour} * * * ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1 ${CRON_ID}"

    # Get existing crontab, remove old job if exists, add new one
    local new_crontab
    new_crontab=$(get_current_cron | grep -v "$CRON_ID" || true)

    # Add new cron job
    if [[ -n "$new_crontab" ]]; then
        new_crontab="${new_crontab}"$'\n'"${cron_line}"
    else
        new_crontab="${cron_line}"
    fi

    # Install new crontab
    echo "$new_crontab" | crontab -

    if has_existing_job; then
        log_success "Cron job installed successfully!"
        log_info "Schedule: Daily at ${BACKUP_TIME} (configured in .env)"
        log_info "Log file: ${LOG_FILE}"
        echo ""
        log_info "Current cron entry:"
        get_current_cron | grep "$CRON_ID"
    else
        log_error "Failed to install cron job"
        exit 1
    fi
}

remove_cron() {
    if ! has_existing_job; then
        log_warning "No existing cron job found"
        return 0
    fi

    log_info "Removing cron job..."

    # Get existing crontab and remove our job
    local new_crontab
    new_crontab=$(get_current_cron | grep -v "$CRON_ID" || true)

    if [[ -n "$new_crontab" ]]; then
        echo "$new_crontab" | crontab -
    else
        # Empty crontab
        crontab -r 2>/dev/null || true
    fi

    if ! has_existing_job; then
        log_success "Cron job removed successfully!"
    else
        log_error "Failed to remove cron job"
        exit 1
    fi
}

show_status() {
    log_info "Checking cron job status..."
    echo ""

    if has_existing_job; then
        log_success "Cron job is INSTALLED"
        echo ""
        echo "Current entry:"
        get_current_cron | grep "$CRON_ID"
        echo ""

        # Show last backup time if log exists
        if [[ -f "$LOG_FILE" ]]; then
            local last_run
            last_run=$(grep -o "Timestamp: [0-9_]*" "$LOG_FILE" 2>/dev/null | tail -1 || true)
            if [[ -n "$last_run" ]]; then
                log_info "Last backup: $last_run"
            fi

            local log_size
            log_size=$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)
            log_info "Log file size: $log_size"
        fi
    else
        log_warning "Cron job is NOT installed"
        log_info "Run '$0 install' to set up daily backups"
    fi
}

# Main
case "${1:-install}" in
    install)
        install_cron
        ;;
    remove|uninstall|delete)
        remove_cron
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
