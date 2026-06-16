#!/bin/bash
###############################################################################
# update_field_systems.sh
#
# Purpose: Update LogFileXfr and Expander apps on immutable Raspberry Pi
#          field systems with A/B SquashFS + /data partition layout.
#
# Usage:
#   ./update_field_systems.sh /dev/sdb
#   ./update_field_systems.sh /mnt/data
#   ./update_field_systems.sh (auto-detect /data if already mounted)
#
# Environment Variables (optional):
#   LOGFILE_XFR_GH_REPO        GitHub repo (default: Wayne-Richardson-Rheem/LogFileXfr-Releases)
#   EXPANDER_GH_REPO           GitHub repo (default: Wayne-Richardson-Rheem/Expander-Releases)
#   LOGFILE_XFR_RELEASE_TAG    Version tag (default: latest)
#   EXPANDER_RELEASE_TAG       Version tag (default: latest)
#   GITHUB_TOKEN               GitHub PAT for private repos (optional)
#   DRY_RUN                    Set to 1 to show what would happen without making changes
#
###############################################################################

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
LOGFILE_XFR_GH_REPO="${LOGFILE_XFR_GH_REPO:-Wayne-Richardson-Rheem/LogFileXfr-Releases}"
EXPANDER_GH_REPO="${EXPANDER_GH_REPO:-Wayne-Richardson-Rheem/Expander-Releases}"
LOGFILE_XFR_RELEASE_TAG="${LOGFILE_XFR_RELEASE_TAG:-latest}"
EXPANDER_RELEASE_TAG="${EXPANDER_RELEASE_TAG:-latest}"
GITHUB_API_BASE="https://api.github.com/repos"
GITHUB_RAW_BASE="https://raw.githubusercontent.com"
DRY_RUN="${DRY_RUN:-0}"

# Get script directory (safely handle piped execution where BASH_SOURCE is unset)
SCRIPT_DIR=""
set +u
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]%/*}" != "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
fi
set -u
if [[ -z "$SCRIPT_DIR" ]]; then
    SCRIPT_DIR="$(pwd)"
fi
TEMP_DIR="/tmp/update_field_$RANDOM"
MOUNT_POINT=""

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

pass() {
    echo -e "${GREEN}[PASS]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

fatal() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    cleanup
    exit 1
}

cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    if [[ -n "$MOUNT_POINT" && "$MOUNT_POINT" != "/data" ]]; then
        if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
            log "Unmounting $MOUNT_POINT..."
            sudo umount "$MOUNT_POINT" 2>/dev/null || true
        fi
        if [[ -d "$MOUNT_POINT" ]]; then
            sudo rmdir "$MOUNT_POINT" 2>/dev/null || true
        fi
    fi
}

trap cleanup EXIT

# Parse arguments
TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
    # Try to auto-detect /data mount
    if mountpoint -q /data 2>/dev/null; then
        MOUNT_POINT="/data"
    else
        fatal "Usage: $0 [/dev/sdX | /mount/point]"
    fi
elif [[ -b "$TARGET" ]]; then
    # Device path provided
    log "Mounting $TARGET for update..."
    MOUNT_POINT="/mnt/update_field_$$"
    mkdir -p "$MOUNT_POINT"
    
    # Find /data partition (usually 3rd partition, type 83)
    DATA_PARTITION="${TARGET}3"
    if ! sudo mount "$DATA_PARTITION" "$MOUNT_POINT"; then
        fatal "Failed to mount $DATA_PARTITION"
    fi
    pass "Mounted $DATA_PARTITION to $MOUNT_POINT"
elif [[ -d "$TARGET" ]]; then
    # Mount point provided
    if ! mountpoint -q "$TARGET" 2>/dev/null; then
        fatal "$TARGET is not a mounted filesystem"
    fi
    MOUNT_POINT="$TARGET"
    pass "Using mounted filesystem at $MOUNT_POINT"
else
    fatal "Invalid target: $TARGET (not a block device or directory)"
fi

# Verify /data structure (or create it)
if [[ ! -d "$MOUNT_POINT/expander" ]]; then
    log "Creating $MOUNT_POINT/expander directory structure..."
    sudo mkdir -p "$MOUNT_POINT/expander/runtime/bin" "$MOUNT_POINT/expander/logs"
fi
if [[ ! -d "$MOUNT_POINT/logfile_xfr" ]]; then
    log "Creating $MOUNT_POINT/logfile_xfr directory structure..."
    sudo mkdir -p "$MOUNT_POINT/logfile_xfr/runtime/bin" "$MOUNT_POINT/logfile_xfr/logs"
fi
pass "Verified /data structure at $MOUNT_POINT"

# Ensure stable runtime paths for cron/systemd on live field systems.
if [[ "$MOUNT_POINT" == "/data" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would create symlink: /opt/logfile_xfr -> /data/logfile_xfr"
        log "[DRY_RUN] Would create symlink: /opt/expander -> /data/expander"
    else
        sudo mkdir -p /opt
        sudo ln -sfn /data/logfile_xfr /opt/logfile_xfr
        sudo ln -sfn /data/expander /opt/expander
        pass "Ensured symlink /opt/logfile_xfr -> /data/logfile_xfr"
        pass "Ensured symlink /opt/expander -> /data/expander"
    fi
else
    warn "Skipping /opt symlink updates because target is mounted at $MOUNT_POINT"
fi

# Helper functions from harden_pi.sh
github_api_get() {
    local endpoint="$1"
    local auth_header=""
    
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        auth_header="-H Authorization: Bearer $GITHUB_TOKEN"
    fi
    
    curl -sSf $auth_header "$endpoint"
}

github_raw_get() {
    local url="$1"
    curl -sSf "$url"
}

verify_runtime_checksum() {
    local checksum_file="$1"
    local runtime_dir="$2"
    local runtime_base
    
    runtime_base=$(basename "$runtime_dir")
    
    if sha256sum -c "$checksum_file" --ignore-missing >/dev/null 2>&1; then
        return 0
    fi
    
    warn "Direct checksum verification failed, attempting path normalization..."
    
    if [[ ! -f "$checksum_file" ]]; then
        fatal "Checksum file not found: $checksum_file"
    fi
    
    local normalized_file="${checksum_file%.sha256}.sha256.normalized"
    
    awk -v rb="$runtime_base" '
        NF >= 2 {
            file=$2
            sub(/^\*+/, "", file)
            n=split(file, p, "/")
            filename=p[n]
            # Match if exact name or starts with basename (handles versioned names like "logfile_xfr-0.1.0")
            if (filename == rb || (length(filename) > length(rb) && substr(filename, 1, length(rb)+1) == rb "-")) {
                $2=rb
            }
            print
            next
        }
        { print }
    ' "$checksum_file" > "$normalized_file"
    
    if sha256sum -c "$normalized_file" --ignore-missing >/dev/null 2>&1; then
        pass "Checksum verified (with path normalization)"
        return 0
    fi
    
    fatal "Checksum verification failed for $runtime_base"
}

stage_runtime_payload() {
    local src_payload="$1"
    local dest_dir="$2"
    local app_name
    
    app_name=$(basename "$dest_dir")
    
    if [[ "$src_payload" == *.tar.gz ]]; then
        log "Extracting $app_name from tar.gz..."
        mkdir -p "$dest_dir/runtime"
        if [[ "$DRY_RUN" == "1" ]]; then
            log "[DRY_RUN] Would extract: tar -xzf $src_payload -C $dest_dir/runtime"
        else
            tar -xzf "$src_payload" -C "$dest_dir/runtime"
        fi
    else
        log "Copying $app_name binary..."
        mkdir -p "$dest_dir/runtime/bin"
        if [[ "$DRY_RUN" == "1" ]]; then
            log "[DRY_RUN] Would copy: $src_payload -> $dest_dir/runtime/bin/$app_name"
        else
            rm -f "$dest_dir/runtime/bin/$app_name"
            cp "$src_payload" "$dest_dir/runtime/bin/$app_name"
            chmod 755 "$dest_dir/runtime/bin/$app_name"
        fi
    fi
    pass "Staged $app_name runtime"
}

fetch_runtime_from_repo_files() {
    local repo="$1"
    local tag="$2"
    local app_name="$3"
    local temp_stage="$4"
    local version owner repo_name api_url

    # Split repo into owner/name
    owner="${repo%%/*}"
    repo_name="${repo##*/}"

    # Get latest release tag from GitHub Releases API
    log "Fetching latest release for $app_name from $repo..."
    api_url="https://api.github.com/repos/$repo/releases/latest"
    version=$(curl -sSf "$api_url" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")

    if [[ -z "$version" ]]; then
        fatal "Failed to fetch latest release version from $repo"
    fi

    log "Latest version: $version"

    # Download assets from GitHub Release
    local assets_json
    assets_json=$(curl -sSf "https://api.github.com/repos/$repo/releases/latest" | \
        python3 -c "import sys,json; [print(a['browser_download_url']) for a in json.load(sys.stdin)['assets']]")

    local release_url checksum_url
    release_url=$(echo "$assets_json" | grep -E "/${app_name}-${version}$" | head -1)
    checksum_url=$(echo "$assets_json" | grep -E "/${app_name}-${version}\.sha256$" | head -1)

    if [[ -z "$release_url" ]]; then
        fatal "Could not find release asset for ${app_name}-${version} in $repo"
    fi
    if [[ -z "$checksum_url" ]]; then
        fatal "Could not find checksum asset for ${app_name}-${version}.sha256 in $repo"
    fi

    log "Downloading $app_name checksum..."
    if ! curl -sSfL "$checksum_url" > "$temp_stage/${app_name}.sha256"; then
        fatal "Failed to download checksum from $repo"
    fi

    if [[ ! -s "$temp_stage/${app_name}.sha256" ]]; then
        fatal "Checksum file is empty: $checksum_url"
    fi

    log "Downloading $app_name runtime..."
    if ! curl -sSfL "$release_url" > "$temp_stage/$app_name"; then
        fatal "Failed to download $app_name from $repo"
    fi

    if [[ ! -s "$temp_stage/$app_name" ]]; then
        fatal "Downloaded binary is empty: $release_url"
    fi

    # Verify checksum
    cd "$temp_stage"
    verify_runtime_checksum "${app_name}.sha256" "$app_name"
    cd - >/dev/null

    pass "Downloaded and verified $app_name version $version"
}

# Create temporary staging directory
mkdir -p "$TEMP_DIR"
log "Using temporary directory: $TEMP_DIR"

# Update LogFileXfr
log ""
log "=== Updating LogFileXfr ==="
fetch_runtime_from_repo_files "$LOGFILE_XFR_GH_REPO" "$LOGFILE_XFR_RELEASE_TAG" "logfile_xfr" "$TEMP_DIR"
stage_runtime_payload "$TEMP_DIR/logfile_xfr" "$MOUNT_POINT/logfile_xfr"

if [[ "$DRY_RUN" != "1" ]]; then
    # Change ownership to pi user if it exists, otherwise leave as is
    if id pi >/dev/null 2>&1; then
        sudo chown -R pi:pi "$MOUNT_POINT/logfile_xfr" 2>/dev/null || true
    fi
    chmod 755 "$MOUNT_POINT/logfile_xfr/runtime" "$MOUNT_POINT/logfile_xfr/runtime/bin" 2>/dev/null || true
fi

# Update Expander
log ""
log "=== Updating Expander ==="
fetch_runtime_from_repo_files "$EXPANDER_GH_REPO" "$EXPANDER_RELEASE_TAG" "expander" "$TEMP_DIR"
stage_runtime_payload "$TEMP_DIR/expander" "$MOUNT_POINT/expander"

if [[ "$DRY_RUN" != "1" ]]; then
    # Change ownership to pi user if it exists, otherwise leave as is
    if id pi >/dev/null 2>&1; then
        sudo chown -R pi:pi "$MOUNT_POINT/expander" 2>/dev/null || true
    fi
    chmod 755 "$MOUNT_POINT/expander/runtime" "$MOUNT_POINT/expander/runtime/bin" 2>/dev/null || true
fi

# Verify update
log ""
log "=== Verifying Update ==="

if [[ "$DRY_RUN" == "1" ]]; then
    pass "[DRY_RUN] Verification would check:"
    pass "[DRY_RUN]   - $MOUNT_POINT/logfile_xfr/runtime/bin/logfile_xfr (executable)"
    pass "[DRY_RUN]   - $MOUNT_POINT/expander/runtime/bin/expander (executable)"
else
    if [[ -x "$MOUNT_POINT/logfile_xfr/runtime/bin/logfile_xfr" ]]; then
        pass "LogFileXfr executable verified"
    else
        fatal "LogFileXfr executable not found or not executable"
    fi
    
    if [[ -x "$MOUNT_POINT/expander/runtime/bin/expander" ]]; then
        pass "Expander executable verified"
    else
        fatal "Expander executable not found or not executable"
    fi
    
    # Test binaries if possible
    if command -v file >/dev/null 2>&1; then
        log "Checking binary types..."
        file "$MOUNT_POINT/logfile_xfr/runtime/bin/logfile_xfr" || warn "Could not verify logfile_xfr binary type"
        file "$MOUNT_POINT/expander/runtime/bin/expander" || warn "Could not verify expander binary type"
    fi
fi

log ""
pass "=== Update Complete ==="
log "LogFileXfr and Expander have been successfully updated on this system."
log "Changes will take effect when services are restarted."

if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY_RUN] Run without DRY_RUN=1 to actually apply changes"
fi

exit 0

