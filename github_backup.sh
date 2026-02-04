#!/bin/bash
#
# GitHub Repository Backup Script
#
# This script:
# 1. Reads repository list from a markdown file
# 2. Clones repos if not exists, updates master and recent branches
# 3. Creates zip backups for master and non-merged files in recent branches
# 4. Monitors disk space and backup size
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

# Default values (can be overridden by .env)
REPO_LIST_FILE="${REPO_LIST_FILE:-backup_gits.md}"
CLONE_DIR="${CLONE_DIR:-repos}"
BACKUP_DIR="${BACKUP_DIR:-backups}"
HOURS_THRESHOLD="${HOURS_THRESHOLD:-24.5}"
BACKUP_SIZE_WARNING_GB="${BACKUP_SIZE_WARNING_GB:-10}"
FREE_SPACE_ERROR_GB="${FREE_SPACE_ERROR_GB:-20}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
ZIP_FOLDER_NAME="${ZIP_FOLDER_NAME:-zips}"

# Convert to absolute paths if relative
[[ "$REPO_LIST_FILE" != /* ]] && REPO_LIST_FILE="${SCRIPT_DIR}/${REPO_LIST_FILE}"
[[ "$CLONE_DIR" != /* ]] && CLONE_DIR="${SCRIPT_DIR}/${CLONE_DIR}"
[[ "$BACKUP_DIR" != /* ]] && BACKUP_DIR="${SCRIPT_DIR}/${BACKUP_DIR}"

# Timestamp for backups
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Convert GB to bytes
gb_to_bytes() {
    echo "$1" | awk '{printf "%.0f", $1 * 1024 * 1024 * 1024}'
}

# Convert bytes to GB (human readable)
bytes_to_gb() {
    echo "$1" | awk '{printf "%.2f", $1 / 1024 / 1024 / 1024}'
}

# Check free disk space
check_free_space() {
    local path="$1"
    local min_gb="$2"
    local min_bytes
    min_bytes=$(gb_to_bytes "$min_gb")

    # Get available space in bytes
    local available
    available=$(df --output=avail -B1 "$path" 2>/dev/null | tail -1)

    if [[ -z "$available" ]]; then
        log_warning "Could not determine free disk space"
        return 0
    fi

    local available_gb
    available_gb=$(bytes_to_gb "$available")

    if (( available < min_bytes )); then
        log_error "Free disk space (${available_gb}GB) is below threshold (${min_gb}GB)!"
        return 1
    fi

    log_info "Free disk space: ${available_gb}GB (threshold: ${min_gb}GB)"
    return 0
}

# Check total backup size
check_backup_size() {
    local backup_path="$1"
    local warn_gb="$2"
    local warn_bytes
    warn_bytes=$(gb_to_bytes "$warn_gb")

    if [[ ! -d "$backup_path" ]]; then
        return 0
    fi

    # Get total size of backup directory
    local total_size
    total_size=$(du -sb "$backup_path" 2>/dev/null | cut -f1)

    if [[ -z "$total_size" ]]; then
        return 0
    fi

    local total_gb
    total_gb=$(bytes_to_gb "$total_size")

    if (( total_size > warn_bytes )); then
        log_warning "Total backup size (${total_gb}GB) exceeds warning threshold (${warn_gb}GB)!"
    else
        log_info "Total backup size: ${total_gb}GB (warning threshold: ${warn_gb}GB)"
    fi
}

# Parse repository URL and extract owner/repo
parse_repo_url() {
    local input="$1"
    local repo_url=""
    local repo_name=""

    # Remove trailing .git if present
    input="${input%.git}"

    # Handle different formats
    if [[ "$input" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
        # Full HTTPS URL
        repo_url="https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
        repo_name="${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^git@github\.com:([^/]+)/([^/]+)$ ]]; then
        # SSH URL
        repo_url="git@github.com:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
        repo_name="${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
    elif [[ "$input" =~ ^([^/]+)/([^/]+)$ ]]; then
        # Short format: owner/repo
        repo_url="https://github.com/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.git"
        repo_name="${BASH_REMATCH[1]}_${BASH_REMATCH[2]}"
    else
        log_error "Invalid repository format: $input"
        return 1
    fi

    # If token is set, use it for HTTPS URLs
    if [[ -n "$GITHUB_TOKEN" && "$repo_url" =~ ^https:// ]]; then
        repo_url="${repo_url/https:\/\//https:\/\/${GITHUB_TOKEN}@}"
    fi

    echo "$repo_url|$repo_name"
}

# Read repositories from markdown file
read_repo_list() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        log_error "Repository list file not found: $file"
        exit 1
    fi

    local repos=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        repos+=("$line")
    done < "$file"

    printf '%s\n' "${repos[@]}"
}

# Clone or update repository
clone_or_update_repo() {
    local repo_url="$1"
    local repo_name="$2"
    local repo_path="${CLONE_DIR}/${repo_name}"

    mkdir -p "$CLONE_DIR"

    if [[ -d "$repo_path/.git" ]]; then
        log_info "Updating existing repository: $repo_name"
        cd "$repo_path"

        # Fetch all branches
        git fetch --all --prune 2>/dev/null || {
            log_warning "Failed to fetch updates for $repo_name"
            cd "$SCRIPT_DIR"
            return 1
        }

        # Get default branch (master or main)
        local default_branch
        default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "master")

        # Update default branch
        git checkout "$default_branch" 2>/dev/null || git checkout -b "$default_branch" "origin/$default_branch" 2>/dev/null
        git pull origin "$default_branch" 2>/dev/null || log_warning "Failed to pull $default_branch for $repo_name"

        cd "$SCRIPT_DIR"
    else
        log_info "Cloning new repository: $repo_name"
        rm -rf "$repo_path"
        git clone "$repo_url" "$repo_path" 2>/dev/null || {
            log_error "Failed to clone $repo_name"
            return 1
        }

        cd "$repo_path"
        git fetch --all 2>/dev/null
        cd "$SCRIPT_DIR"
    fi

    log_success "Repository ready: $repo_name"
    return 0
}

# Get branches updated within threshold hours
get_recent_branches() {
    local repo_path="$1"
    local hours="$2"

    cd "$repo_path"

    # Calculate cutoff timestamp
    local cutoff_seconds
    cutoff_seconds=$(echo "$hours * 3600" | bc)
    local cutoff_timestamp
    cutoff_timestamp=$(($(date +%s) - ${cutoff_seconds%.*}))

    # Get default branch
    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "master")

    # Get all remote branches with their last commit time
    local branches=()
    while IFS= read -r branch; do
        branch=$(echo "$branch" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$branch" || "$branch" == "HEAD" ]] && continue

        # Get last commit timestamp for this branch
        local last_commit
        last_commit=$(git log -1 --format="%ct" "origin/$branch" 2>/dev/null || echo "0")

        if (( last_commit > cutoff_timestamp )); then
            # Skip default branch (will be handled separately)
            if [[ "$branch" != "$default_branch" ]]; then
                branches+=("$branch")
            fi
        fi
    done < <(git branch -r 2>/dev/null | sed 's/origin\///' | grep -v '\->')

    cd "$SCRIPT_DIR"
    printf '%s\n' "${branches[@]}"
}

# Get files that differ from master (non-merged files)
get_non_merged_files() {
    local repo_path="$1"
    local branch="$2"

    cd "$repo_path"

    # Get default branch
    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "master")

    # Get list of files that differ between branch and default branch
    git diff --name-only "origin/$default_branch...origin/$branch" 2>/dev/null || true

    cd "$SCRIPT_DIR"
}

# Create backup of master branch
backup_master() {
    local repo_path="$1"
    local repo_name="$2"
    local backup_path="${BACKUP_DIR}/${repo_name}/master/${ZIP_FOLDER_NAME}"

    mkdir -p "$backup_path"

    cd "$repo_path"

    # Get default branch
    local default_branch
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "master")

    # Checkout default branch
    git checkout "$default_branch" 2>/dev/null || {
        log_warning "Failed to checkout $default_branch in $repo_name"
        cd "$SCRIPT_DIR"
        return 1
    }

    local zip_file="${backup_path}/${default_branch}_${TIMESTAMP}.zip"

    # Create zip archive of the entire repo (excluding .git)
    log_info "Creating master backup: $zip_file"
    zip -r -q "$zip_file" . -x ".git/*" -x ".git" 2>/dev/null || {
        log_warning "Failed to create zip for master branch"
        cd "$SCRIPT_DIR"
        return 1
    }

    log_success "Master backup created: $(basename "$zip_file")"
    cd "$SCRIPT_DIR"
}

# Create backup of branch (only non-merged files)
backup_branch() {
    local repo_path="$1"
    local repo_name="$2"
    local branch="$3"

    # Sanitize branch name for directory/file name
    local safe_branch
    safe_branch=$(echo "$branch" | sed 's/[^a-zA-Z0-9._-]/_/g')

    local backup_path="${BACKUP_DIR}/${repo_name}/${safe_branch}/${ZIP_FOLDER_NAME}"
    mkdir -p "$backup_path"

    cd "$repo_path"

    # Checkout the branch
    git checkout -f "origin/$branch" 2>/dev/null || {
        log_warning "Failed to checkout branch $branch in $repo_name"
        cd "$SCRIPT_DIR"
        return 1
    }

    # Get non-merged files
    local files
    files=$(get_non_merged_files "$repo_path" "$branch")

    if [[ -z "$files" ]]; then
        log_info "No non-merged files in branch $branch"
        cd "$SCRIPT_DIR"
        return 0
    fi

    local zip_file="${backup_path}/${safe_branch}_${TIMESTAMP}.zip"

    # Create zip archive with only the non-merged files
    log_info "Creating branch backup: $branch -> $(basename "$zip_file")"

    # Create temporary file list
    local tmp_list
    tmp_list=$(mktemp)
    echo "$files" > "$tmp_list"

    # Zip only the files that exist
    local existing_files=""
    while IFS= read -r file; do
        [[ -f "$file" ]] && existing_files+="$file"$'\n'
    done < "$tmp_list"
    rm -f "$tmp_list"

    if [[ -n "$existing_files" ]]; then
        echo "$existing_files" | zip -@ -q "$zip_file" 2>/dev/null || {
            log_warning "Failed to create zip for branch $branch"
            cd "$SCRIPT_DIR"
            return 1
        }
        log_success "Branch backup created: $(basename "$zip_file") ($(echo "$existing_files" | wc -l) files)"
    else
        log_info "No existing files to backup in branch $branch"
    fi

    cd "$SCRIPT_DIR"
}

# Main function
main() {
    log_info "=========================================="
    log_info "GitHub Backup Script Started"
    log_info "Timestamp: $TIMESTAMP"
    log_info "=========================================="

    # Check free disk space first
    if ! check_free_space "$SCRIPT_DIR" "$FREE_SPACE_ERROR_GB"; then
        log_error "Aborting due to insufficient disk space!"
        exit 1
    fi

    # Create directories
    mkdir -p "$CLONE_DIR" "$BACKUP_DIR"

    # Read repository list
    log_info "Reading repository list from: $REPO_LIST_FILE"
    local repos
    repos=$(read_repo_list "$REPO_LIST_FILE")

    if [[ -z "$repos" ]]; then
        log_warning "No repositories found in $REPO_LIST_FILE"
        log_info "Please add repositories to the file (see format examples in the file)"
        exit 0
    fi

    local repo_count
    repo_count=$(echo "$repos" | wc -l)
    log_info "Found $repo_count repositories to process"

    # Process each repository
    while IFS= read -r repo_input; do
        [[ -z "$repo_input" ]] && continue

        log_info "------------------------------------------"
        log_info "Processing: $repo_input"

        # Parse repository URL
        local parsed
        parsed=$(parse_repo_url "$repo_input") || continue

        local repo_url repo_name
        repo_url=$(echo "$parsed" | cut -d'|' -f1)
        repo_name=$(echo "$parsed" | cut -d'|' -f2)

        # Clone or update repository
        if ! clone_or_update_repo "$repo_url" "$repo_name"; then
            continue
        fi

        local repo_path="${CLONE_DIR}/${repo_name}"

        # Backup master branch
        backup_master "$repo_path" "$repo_name"

        # Get and backup recent branches
        log_info "Finding branches updated in last ${HOURS_THRESHOLD} hours..."
        local branches
        branches=$(get_recent_branches "$repo_path" "$HOURS_THRESHOLD")

        if [[ -n "$branches" ]]; then
            local branch_count
            branch_count=$(echo "$branches" | wc -l)
            log_info "Found $branch_count recent branch(es)"

            while IFS= read -r branch; do
                [[ -z "$branch" ]] && continue
                backup_branch "$repo_path" "$repo_name" "$branch"
            done <<< "$branches"
        else
            log_info "No recently updated branches found"
        fi

        # Check free space after each repo
        if ! check_free_space "$SCRIPT_DIR" "$FREE_SPACE_ERROR_GB"; then
            log_error "Aborting due to insufficient disk space!"
            exit 1
        fi

    done <<< "$repos"

    log_info "------------------------------------------"

    # Final space checks
    check_backup_size "$BACKUP_DIR" "$BACKUP_SIZE_WARNING_GB"
    check_free_space "$SCRIPT_DIR" "$FREE_SPACE_ERROR_GB"

    log_info "=========================================="
    log_success "Backup completed!"
    log_info "Backups stored in: $BACKUP_DIR"
    log_info "=========================================="
}

# Run main function
main "$@"
