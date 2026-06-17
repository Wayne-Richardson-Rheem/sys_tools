#!/bin/bash
###############################################################################
# update_field_systems.sh
#
# Purpose: Update LogFileXfr, Expander, and LaptopKiller apps on immutable
#          Raspberry Pi field systems with A/B SquashFS + /data partition layout.
#
# Usage:
#   ./update_field_systems.sh /dev/sdb
#   ./update_field_systems.sh /mnt/data
#   ./update_field_systems.sh (auto-detect /data if already mounted)
#
# Environment Variables (optional):
#   LOGFILE_XFR_GH_REPO        GitHub repo (default: Wayne-Richardson-Rheem/LogFileXfr-Releases)
#   EXPANDER_GH_REPO           GitHub repo (default: Wayne-Richardson-Rheem/Expander-Releases)
#   LAPTOP_KILLER_GH_REPO      GitHub repo (default: Wayne-Richardson-Rheem/LaptopKiller-Releases)
#   LOGFILE_XFR_RELEASE_TAG    Version tag (default: latest)
#   EXPANDER_RELEASE_TAG       Version tag (default: latest)
#   LAPTOP_KILLER_RELEASE_TAG  Version tag (default: latest)
#   LOGFILE_XFR_OTA_PUBKEY_URL OTA public key URL (optional)
#   EXPANDER_OTA_PUBKEY_URL    OTA public key URL (optional)
#   LAPTOP_KILLER_OTA_PUBKEY_URL OTA public key URL (optional)
#   LOGFILE_XFR_OTA_PUBKEY_URL_FALLBACK Additional logfile_xfr pubkey URL (optional)
#   EXPANDER_OTA_PUBKEY_URL_FALLBACK Additional expander pubkey URL (optional)
#   LAPTOP_KILLER_OTA_PUBKEY_URL_FALLBACK Additional laptop_killer pubkey URL (optional)
#   LOGFILE_XFR_MIRROR_SCRIPT_URL URL for logfile_xfr mirror_release.sh override (optional)
#   EXPANDER_MIRROR_SCRIPT_URL URL for expander mirror_release.sh override (optional)
#   LAPTOP_KILLER_MIRROR_SCRIPT_URL URL for laptop_killer mirror_release.sh override (optional)
#   LOGFILE_XFR_OTA_ENABLE_TIMER Enable LogFileXfr OTA timer (1/0)
#   EXPANDER_OTA_ENABLE_TIMER  Enable Expander OTA timer (1/0)
#   LAPTOP_KILLER_OTA_ENABLE_TIMER Enable LaptopKiller OTA timer (1/0)
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
LAPTOP_KILLER_GH_REPO="${LAPTOP_KILLER_GH_REPO:-Wayne-Richardson-Rheem/LaptopKiller-Releases}"
LOGFILE_XFR_RELEASE_TAG="${LOGFILE_XFR_RELEASE_TAG:-latest}"
EXPANDER_RELEASE_TAG="${EXPANDER_RELEASE_TAG:-latest}"
LAPTOP_KILLER_RELEASE_TAG="${LAPTOP_KILLER_RELEASE_TAG:-latest}"
LOGFILE_XFR_OTA_PUBKEY_URL="${LOGFILE_XFR_OTA_PUBKEY_URL:-https://raw.githubusercontent.com/Wayne-Richardson-Rheem/LogFileXfr-Releases/main/logfile_xfr_ota_pubkey.asc}"
EXPANDER_OTA_PUBKEY_URL="${EXPANDER_OTA_PUBKEY_URL:-https://raw.githubusercontent.com/Wayne-Richardson-Rheem/Expander-Releases/main/expander_ota_pubkey.asc}"
LAPTOP_KILLER_OTA_PUBKEY_URL="${LAPTOP_KILLER_OTA_PUBKEY_URL:-https://raw.githubusercontent.com/Wayne-Richardson-Rheem/LaptopKiller-Releases/main/laptop_killer_ota_pubkey.asc}"
LOGFILE_XFR_OTA_PUBKEY_URL_FALLBACK="${LOGFILE_XFR_OTA_PUBKEY_URL_FALLBACK:-https://raw.githubusercontent.com/Wayne-Richardson-Rheem/LogFileXfr/main/logfile_xfr_ota_pubkey.asc}"
EXPANDER_OTA_PUBKEY_URL_FALLBACK="${EXPANDER_OTA_PUBKEY_URL_FALLBACK:-https://raw.githubusercontent.com/Wayne-Richardson-Rheem/Expander/main/expander_ota_pubkey.asc}"
LAPTOP_KILLER_OTA_PUBKEY_URL_FALLBACK="${LAPTOP_KILLER_OTA_PUBKEY_URL_FALLBACK:-https://raw.githubusercontent.com/Wayne-Richardson-Rheem/LaptopKiller/main/laptop_killer_ota_pubkey.asc}"
LOGFILE_XFR_MIRROR_SCRIPT_URL="${LOGFILE_XFR_MIRROR_SCRIPT_URL:-}"
EXPANDER_MIRROR_SCRIPT_URL="${EXPANDER_MIRROR_SCRIPT_URL:-}"
LAPTOP_KILLER_MIRROR_SCRIPT_URL="${LAPTOP_KILLER_MIRROR_SCRIPT_URL:-}"
LOGFILE_XFR_OTA_ENABLE_TIMER="${LOGFILE_XFR_OTA_ENABLE_TIMER:-1}"
EXPANDER_OTA_ENABLE_TIMER="${EXPANDER_OTA_ENABLE_TIMER:-1}"
LAPTOP_KILLER_OTA_ENABLE_TIMER="${LAPTOP_KILLER_OTA_ENABLE_TIMER:-1}"
GITHUB_API_BASE="https://api.github.com/repos"
GITHUB_RAW_BASE="https://raw.githubusercontent.com"
DRY_RUN="${DRY_RUN:-0}"

LOGFILE_XFR_VERSION=""
EXPANDER_VERSION=""
LAPTOP_KILLER_VERSION=""

# Get script directory (safely handle piped execution where BASH_SOURCE is unset)
SCRIPT_DIR=""
set +u
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
set -u
TEMP_DIR="/tmp/update_field_$RANDOM"
MOUNT_POINT=""
APP_OWNER="${SUDO_USER:-}"

if [[ -z "$APP_OWNER" || "$APP_OWNER" == "root" ]]; then
    APP_OWNER="${USER:-}"
fi

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
fi
if [[ ! -d "$MOUNT_POINT/logfile_xfr" ]]; then
    log "Creating $MOUNT_POINT/logfile_xfr directory structure..."
fi
if [[ ! -d "$MOUNT_POINT/laptopkiller" ]]; then
    log "Creating $MOUNT_POINT/laptopkiller directory structure..."
fi

# Always ensure required subdirectories exist (handles partially initialized systems).
if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY_RUN] Would ensure $MOUNT_POINT/expander/runtime/bin and $MOUNT_POINT/expander/runtime/logs"
    log "[DRY_RUN] Would ensure $MOUNT_POINT/logfile_xfr/runtime/bin and $MOUNT_POINT/logfile_xfr/runtime/logs"
    log "[DRY_RUN] Would ensure $MOUNT_POINT/laptopkiller/runtime/bin and $MOUNT_POINT/laptopkiller/runtime/logs"
else
    sudo mkdir -p "$MOUNT_POINT/expander/runtime/bin" "$MOUNT_POINT/expander/runtime/logs"
    sudo mkdir -p "$MOUNT_POINT/logfile_xfr/runtime/bin" "$MOUNT_POINT/logfile_xfr/runtime/logs"
    sudo mkdir -p "$MOUNT_POINT/laptopkiller/runtime/bin" "$MOUNT_POINT/laptopkiller/runtime/logs"
fi
pass "Verified /data structure at $MOUNT_POINT"

# Ensure stable runtime paths for cron/systemd on live field systems.
if [[ "$MOUNT_POINT" == "/data" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would create symlink: /opt/logfile_xfr -> /data/logfile_xfr"
        log "[DRY_RUN] Would create symlink: /opt/expander -> /data/expander"
        log "[DRY_RUN] Would create symlink: /opt/laptopkiller -> /data/laptopkiller"
    else
        sudo mkdir -p /opt
        sudo ln -sfn /data/logfile_xfr /opt/logfile_xfr
        sudo ln -sfn /data/expander /opt/expander
        sudo ln -sfn /data/laptopkiller /opt/laptopkiller
        pass "Ensured symlink /opt/logfile_xfr -> /data/logfile_xfr"
        pass "Ensured symlink /opt/expander -> /data/expander"
        pass "Ensured symlink /opt/laptopkiller -> /data/laptopkiller"
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

# Normalize app log layout to a single directory at runtime/logs.
normalize_logs_layout() {
    local app_root="$1"
    local app_name
    local old_logs
    local runtime_logs

    app_name="$(basename "$app_root")"
    old_logs="$app_root/logs"
    runtime_logs="$app_root/runtime/logs"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would ensure logs directory exists: $runtime_logs"
        if [[ -d "$old_logs" ]]; then
            log "[DRY_RUN] Would migrate legacy logs from $old_logs to $runtime_logs"
            log "[DRY_RUN] Would remove legacy logs directory: $old_logs"
        fi
        return 0
    fi

    sudo mkdir -p "$runtime_logs"

    if [[ -d "$old_logs" ]]; then
        # Copy then remove to preserve history on systems with existing top-level logs.
        sudo cp -a "$old_logs/." "$runtime_logs/" 2>/dev/null || true
        sudo rm -rf "$old_logs"
        pass "Normalized $app_name logs to $runtime_logs"
    fi
}

install_mirror_script() {
    local app_name="$1"
    local script_url="$2"
    local mirror_script="$3"
    local tmp_script="$4"
    local target
    local mirror_repo_url
    local mirror_repo_dir

    if [[ "$app_name" == "logfile_xfr" ]]; then
        target="logfile_xfr"
        mirror_repo_url="https://github.com/Wayne-Richardson-Rheem/LogFileXfr-Releases.git"
        mirror_repo_dir='$HOME/Dev/LogFileXfr-Releases'
    elif [[ "$app_name" == "expander" ]]; then
        target="expander"
        mirror_repo_url="https://github.com/Wayne-Richardson-Rheem/Expander-Releases.git"
        mirror_repo_dir='$HOME/Dev/Expander-Releases'
    else
        target="laptop_killer"
        mirror_repo_url="https://github.com/Wayne-Richardson-Rheem/LaptopKiller-Releases.git"
        mirror_repo_dir='$HOME/Dev/LaptopKiller-Releases'
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        if [[ -n "$script_url" ]]; then
            log "[DRY_RUN] Would download $app_name mirror_release.sh from $script_url"
        else
            log "[DRY_RUN] No mirror URL provided for $app_name; would install embedded mirror_release.sh"
        fi
        log "[DRY_RUN] Would install mirror_release.sh at $mirror_script"
        return 0
    fi

    if [[ -n "$script_url" ]] && curl -fsSL "$script_url" -o "$tmp_script" 2>/dev/null && [[ -s "$tmp_script" ]]; then
        sudo install -m 755 "$tmp_script" "$mirror_script"
        return 0
    fi

    if [[ -n "$script_url" ]]; then
        warn "Could not download mirror_release.sh for $app_name from override URL; installing embedded script"
    else
        log "Installing embedded mirror_release.sh for $app_name"
    fi

    cat > "$tmp_script" <<EOF
#!/bin/bash
set -euo pipefail

ROOT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$target"
VERSION="\$(tr -d '\\n\\r' < "\$ROOT_DIR/VERSION")"
DIST_DIR="\$ROOT_DIR/dist"

MIRROR_DIR="\${MIRROR_DIR:-$mirror_repo_dir}"
MIRROR_REPO_URL="\${MIRROR_REPO_URL:-$mirror_repo_url}"

BIN_FILE="\$TARGET-\$VERSION"
VERSION_DIR="\$MIRROR_DIR/releases/v\$VERSION"

for artifact in \
    "\$DIST_DIR/\$BIN_FILE" \
    "\$DIST_DIR/\$BIN_FILE.sha256" \
    "\$DIST_DIR/\$BIN_FILE.sha256.asc"
do
    if [[ ! -f "\$artifact" ]]; then
        echo "ERROR: missing release artifact: \$artifact"
        exit 1
    fi
done

if [[ ! -d "\$MIRROR_DIR/.git" ]]; then
    git clone "\$MIRROR_REPO_URL" "\$MIRROR_DIR"
fi

cd "\$MIRROR_DIR"
git pull --ff-only origin main

mkdir -p "\$VERSION_DIR"

cp "\$DIST_DIR/\$BIN_FILE" "\$VERSION_DIR/"
cp "\$DIST_DIR/\$BIN_FILE.sha256" "\$VERSION_DIR/"
cp "\$DIST_DIR/\$BIN_FILE.sha256.asc" "\$VERSION_DIR/"

printf '%s\\n' "\$VERSION" > "\$MIRROR_DIR/latest.txt"

git add \
    "\$MIRROR_DIR/latest.txt" \
    "\$VERSION_DIR/\$BIN_FILE" \
    "\$VERSION_DIR/\$BIN_FILE.sha256" \
    "\$VERSION_DIR/\$BIN_FILE.sha256.asc"

if git diff --cached --quiet; then
    echo "Mirror already up to date for v\$VERSION"
    exit 0
fi

git commit -m "Publish \$TARGET \$VERSION"
git push origin main

echo "Mirrored \$TARGET v\$VERSION to \$MIRROR_DIR"
EOF
    sudo install -m 755 "$tmp_script" "$mirror_script"
}

install_ota_pubkey() {
    local app_name="$1"
    local key_file="$2"
    local local_pubkey="$3"
    local pubkey_url="$4"
    local tmp_pubkey="$5"
    shift 5
    local url
    local candidate_urls=("$pubkey_url" "$@")

    if [[ -n "$local_pubkey" && -f "$local_pubkey" ]]; then
        if [[ "$DRY_RUN" == "1" ]]; then
            log "[DRY_RUN] Would install OTA pubkey for $app_name from $local_pubkey to $key_file"
        else
            sudo install -m 644 "$local_pubkey" "$key_file"
        fi
        return 0
    fi

    if [[ -n "$local_pubkey" ]]; then
        warn "Local OTA pubkey not found at $local_pubkey; trying URL"
    else
        log "No local OTA pubkey path (script executed via pipe); trying URL"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would download OTA pubkey for $app_name from $pubkey_url to $key_file"
        return 0
    fi

    for url in "${candidate_urls[@]}"; do
        if [[ -z "$url" ]]; then
            continue
        fi
        if curl -fsSL "$url" -o "$tmp_pubkey" 2>/dev/null && [[ -s "$tmp_pubkey" ]]; then
            sudo install -m 644 "$tmp_pubkey" "$key_file"
            log "Installed OTA pubkey for $app_name from $url"
            return 0
        fi
    done

    warn "Could not download OTA pubkey for $app_name from configured URLs; OTA signature verification will fail until key is installed"
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
    local version="$3"
    local app_name
    
    app_name=$(basename "$dest_dir")
    
    if [[ "$src_payload" == *.tar.gz ]]; then
        log "Extracting $app_name from tar.gz..."
        sudo mkdir -p "$dest_dir/runtime"
        if [[ "$DRY_RUN" == "1" ]]; then
            log "[DRY_RUN] Would extract: tar -xzf $src_payload -C $dest_dir/runtime"
        else
            sudo tar -xzf "$src_payload" -C "$dest_dir/runtime"
        fi
    else
        log "Copying $app_name binary..."
        sudo mkdir -p "$dest_dir/runtime/bin"
        local versioned_name="$app_name-$version"
        if [[ "$DRY_RUN" == "1" ]]; then
            log "[DRY_RUN] Would copy: $src_payload -> $dest_dir/runtime/bin/$versioned_name"
            log "[DRY_RUN] Would set symlink: $dest_dir/runtime/bin/$app_name -> $versioned_name"
        else
            sudo cp "$src_payload" "$dest_dir/runtime/bin/$versioned_name"
            sudo chmod 755 "$dest_dir/runtime/bin/$versioned_name"
            sudo ln -sfn "$versioned_name" "$dest_dir/runtime/bin/$app_name"
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

    # Resolve release endpoint from requested tag.
    log "Fetching release metadata for $app_name from $repo..."
    if [[ "$tag" == "latest" ]]; then
        api_url="https://api.github.com/repos/$repo/releases/latest"
    else
        api_url="https://api.github.com/repos/$repo/releases/tags/$tag"
    fi

    version=$(curl -sSf "$api_url" | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'].lstrip('v'))")

    if [[ -z "$version" ]]; then
        fatal "Failed to fetch latest release version from $repo"
    fi

    log "Latest version: $version"

    # Download assets from GitHub Release
    local assets_json
    assets_json=$(curl -sSf "$api_url" | \
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

    if [[ "$app_name" == "logfile_xfr" ]]; then
        LOGFILE_XFR_VERSION="$version"
    elif [[ "$app_name" == "expander" ]]; then
        EXPANDER_VERSION="$version"
    elif [[ "$app_name" == "laptop_killer" ]]; then
        LAPTOP_KILLER_VERSION="$version"
    fi
}

install_logfile_xfr_ota() {
    local dest_dir="$1"
    local ota_dir="$dest_dir/runtime/ota"
    local key_dir="$ota_dir/keys"
    local tools_dir="$dest_dir/tools"
    local ota_script="$tools_dir/ota.sh"
    local mirror_script="$tools_dir/mirror_release.sh"
    local key_file="$key_dir/logfile_xfr_ota_pubkey.asc"
    local local_pubkey=""
    if [[ -n "$SCRIPT_DIR" ]]; then
        local_pubkey="$SCRIPT_DIR/logfile_xfr_ota_pubkey.asc"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would ensure OTA directories: $ota_dir and $key_dir"
        log "[DRY_RUN] Would install OTA updater script at $ota_script"
        log "[DRY_RUN] Would install mirror_release.sh at $mirror_script"
    else
        sudo mkdir -p "$ota_dir" "$key_dir" "$tools_dir"
        cat > "$TEMP_DIR/logfile_xfr_ota.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

BIN="logfile_xfr"

RUNTIME="${RUNTIME:-/opt/logfile_xfr/runtime}"
BIN_DIR="$RUNTIME/bin"
OTA_DIR="$RUNTIME/ota"
KEY_DIR="$OTA_DIR/keys"

BASE_URL="https://raw.githubusercontent.com/Wayne-Richardson-Rheem/LogFileXfr-Releases/main/releases"

mkdir -p "$OTA_DIR"
cd "$OTA_DIR"

if [[ ! -x "$BIN_DIR/$BIN" ]]; then
  echo "[OTA] ERROR: $BIN_DIR/$BIN does not exist or is not executable"
  exit 1
fi

CURRENT_VERSION="$($BIN_DIR/$BIN --version | tr -d '\n\r')"
echo "[OTA] Current version: $CURRENT_VERSION"

echo "[OTA] Checking for update..."
LATEST_VERSION="$(curl -fsSL "$BASE_URL/../latest.txt" | tr -d '\n\r')"
echo "[OTA] Latest available version: $LATEST_VERSION"

if [[ "$LATEST_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "[OTA] Already up to date ($CURRENT_VERSION)"
  exit 0
fi

# Do not downgrade if release metadata is stale.
if [[ "$(printf '%s\n%s\n' "$LATEST_VERSION" "$CURRENT_VERSION" | sort -V | tail -n1)" != "$LATEST_VERSION" ]]; then
    echo "[OTA] Repository version ($LATEST_VERSION) is older than current ($CURRENT_VERSION); skipping downgrade"
    exit 0
fi

VERSION="$LATEST_VERSION"
BIN_FILE="$BIN-$VERSION"
VERSION_DIR="$BASE_URL/v$VERSION"

echo "[OTA] Downloading v$VERSION..."
curl -fsSLO "$VERSION_DIR/$BIN_FILE"
curl -fsSLO "$VERSION_DIR/$BIN_FILE.sha256"
curl -fsSLO "$VERSION_DIR/$BIN_FILE.sha256.asc"

echo "[OTA] Verifying signature..."
gpg --batch --no-default-keyring \
  --keyring "$OTA_DIR/ota-keyring.gpg" \
  --import "$KEY_DIR/logfile_xfr_ota_pubkey.asc" >/dev/null 2>&1 || true

gpg --batch --no-default-keyring \
  --keyring "$OTA_DIR/ota-keyring.gpg" \
  --verify "$BIN_FILE.sha256.asc" "$BIN_FILE.sha256"

echo "[OTA] Verifying checksum..."
awk -v bin="$BIN_FILE" '{print $1 "  " bin}' "$BIN_FILE.sha256" | sha256sum -c -

echo "[OTA] Saving rollback version..."
echo "$CURRENT_VERSION" > "$OTA_DIR/last-good"

echo "[OTA] Installing new binary..."
install -m 755 "$BIN_FILE" "$BIN_DIR/$BIN_FILE"

echo "[OTA] Switching symlink..."
ln -sfn "$BIN_FILE" "$BIN_DIR/$BIN"

echo "[OTA] Running smoke test..."
NEW_VERSION="$($BIN_DIR/$BIN --version | tr -d '\n\r')" || true

if [[ "$NEW_VERSION" != "$VERSION" ]]; then
  echo "[OTA] Smoke test failed - rolling back"
  OLD_VERSION="$(cat "$OTA_DIR/last-good")"
  ln -sfn "$BIN-$OLD_VERSION" "$BIN_DIR/$BIN"
  exit 1
fi

echo "[OTA] Update successful ($VERSION)"
EOF
        sudo install -m 755 "$TEMP_DIR/logfile_xfr_ota.sh" "$ota_script"

        install_mirror_script "logfile_xfr" "$LOGFILE_XFR_MIRROR_SCRIPT_URL" "$mirror_script" "$TEMP_DIR/logfile_xfr_mirror_release.sh"
    fi

    install_ota_pubkey "logfile_xfr" "$key_file" "$local_pubkey" "$LOGFILE_XFR_OTA_PUBKEY_URL" "$TEMP_DIR/logfile_xfr_ota_pubkey.asc" "$LOGFILE_XFR_OTA_PUBKEY_URL_FALLBACK"

    pass "Configured LogFileXfr OTA assets"
}

install_logfile_xfr_ota_timer() {
    if [[ "$LOGFILE_XFR_OTA_ENABLE_TIMER" != "1" ]]; then
        log "Skipping OTA timer setup (LOGFILE_XFR_OTA_ENABLE_TIMER=$LOGFILE_XFR_OTA_ENABLE_TIMER)"
        return 0
    fi

    if [[ "$MOUNT_POINT" != "/data" ]]; then
        warn "Skipping OTA timer setup because target is mounted at $MOUNT_POINT"
        return 0
    fi

    local svc_path="/etc/systemd/system/logfile-xfr-ota.service"
    local timer_path="/etc/systemd/system/logfile-xfr-ota.timer"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would install $svc_path"
        log "[DRY_RUN] Would install $timer_path"
        log "[DRY_RUN] Would run: systemctl daemon-reload && systemctl enable --now logfile-xfr-ota.timer"
        return 0
    fi

    cat > "$TEMP_DIR/logfile-xfr-ota.service" <<'EOF'
[Unit]
Description=LogFileXfr OTA Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=RUNTIME=/opt/logfile_xfr/runtime
ExecStart=/opt/logfile_xfr/tools/ota.sh
User=root
Group=root
EOF

    cat > "$TEMP_DIR/logfile-xfr-ota.timer" <<'EOF'
[Unit]
Description=Run LogFileXfr OTA Update Daily

[Timer]
OnBootSec=5min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo install -m 644 "$TEMP_DIR/logfile-xfr-ota.service" "$svc_path"
    sudo install -m 644 "$TEMP_DIR/logfile-xfr-ota.timer" "$timer_path"
    sudo systemctl daemon-reload
    sudo systemctl enable --now logfile-xfr-ota.timer

    pass "Enabled logfile-xfr-ota.timer"
}

install_expander_ota() {
    local dest_dir="$1"
    local ota_dir="$dest_dir/runtime/ota"
    local key_dir="$ota_dir/keys"
    local tools_dir="$dest_dir/tools"
    local ota_script="$tools_dir/ota.sh"
    local mirror_script="$tools_dir/mirror_release.sh"
    local key_file="$key_dir/expander_ota_pubkey.asc"
    local local_pubkey=""
    if [[ -n "$SCRIPT_DIR" ]]; then
        local_pubkey="$SCRIPT_DIR/expander_ota_pubkey.asc"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would ensure OTA directories: $ota_dir and $key_dir"
        log "[DRY_RUN] Would install OTA updater script at $ota_script"
        log "[DRY_RUN] Would install mirror_release.sh at $mirror_script"
    else
        sudo mkdir -p "$ota_dir" "$key_dir" "$tools_dir"
        cat > "$TEMP_DIR/expander_ota.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

BIN="expander"

RUNTIME="${RUNTIME:-/opt/expander/runtime}"
BIN_DIR="$RUNTIME/bin"
OTA_DIR="$RUNTIME/ota"
KEY_DIR="$OTA_DIR/keys"

BASE_URL="https://raw.githubusercontent.com/Wayne-Richardson-Rheem/Expander-Releases/main/releases"

mkdir -p "$OTA_DIR"
cd "$OTA_DIR"

if [[ ! -x "$BIN_DIR/$BIN" ]]; then
  echo "[OTA] ERROR: $BIN_DIR/$BIN does not exist or is not executable"
  exit 1
fi

CURRENT_VERSION="$($BIN_DIR/$BIN --version | tr -d '\n\r')"
echo "[OTA] Current version: $CURRENT_VERSION"

echo "[OTA] Checking for update..."
LATEST_VERSION="$(curl -fsSL "$BASE_URL/../latest.txt" | tr -d '\n\r')"
echo "[OTA] Latest available version: $LATEST_VERSION"

if [[ "$LATEST_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "[OTA] Already up to date ($CURRENT_VERSION)"
  exit 0
fi

# Do not downgrade if release metadata is stale.
if [[ "$(printf '%s\n%s\n' "$LATEST_VERSION" "$CURRENT_VERSION" | sort -V | tail -n1)" != "$LATEST_VERSION" ]]; then
    echo "[OTA] Repository version ($LATEST_VERSION) is older than current ($CURRENT_VERSION); skipping downgrade"
    exit 0
fi

VERSION="$LATEST_VERSION"
BIN_FILE="$BIN-$VERSION"
VERSION_DIR="$BASE_URL/v$VERSION"

echo "[OTA] Downloading v$VERSION..."
curl -fsSLO "$VERSION_DIR/$BIN_FILE"
curl -fsSLO "$VERSION_DIR/$BIN_FILE.sha256"
curl -fsSLO "$VERSION_DIR/$BIN_FILE.sha256.asc"

echo "[OTA] Verifying signature..."
gpg --batch --no-default-keyring \
  --keyring "$OTA_DIR/ota-keyring.gpg" \
  --import "$KEY_DIR/expander_ota_pubkey.asc" >/dev/null 2>&1 || true

gpg --batch --no-default-keyring \
  --keyring "$OTA_DIR/ota-keyring.gpg" \
  --verify "$BIN_FILE.sha256.asc" "$BIN_FILE.sha256"

echo "[OTA] Verifying checksum..."
awk -v bin="$BIN_FILE" '{print $1 "  " bin}' "$BIN_FILE.sha256" | sha256sum -c -

echo "[OTA] Saving rollback version..."
echo "$CURRENT_VERSION" > "$OTA_DIR/last-good"

echo "[OTA] Installing new binary..."
install -m 755 "$BIN_FILE" "$BIN_DIR/$BIN_FILE"

echo "[OTA] Switching symlink..."
ln -sfn "$BIN_FILE" "$BIN_DIR/$BIN"

echo "[OTA] Running smoke test..."
NEW_VERSION="$($BIN_DIR/$BIN --version | tr -d '\n\r')" || true

if [[ "$NEW_VERSION" != "$VERSION" ]]; then
  echo "[OTA] Smoke test failed - rolling back"
  OLD_VERSION="$(cat "$OTA_DIR/last-good")"
  ln -sfn "$BIN-$OLD_VERSION" "$BIN_DIR/$BIN"
  exit 1
fi

echo "[OTA] Update successful ($VERSION)"
EOF
        sudo install -m 755 "$TEMP_DIR/expander_ota.sh" "$ota_script"

        install_mirror_script "expander" "$EXPANDER_MIRROR_SCRIPT_URL" "$mirror_script" "$TEMP_DIR/expander_mirror_release.sh"
    fi

    install_ota_pubkey "expander" "$key_file" "$local_pubkey" "$EXPANDER_OTA_PUBKEY_URL" "$TEMP_DIR/expander_ota_pubkey.asc" "$EXPANDER_OTA_PUBKEY_URL_FALLBACK"

    pass "Configured Expander OTA assets"
}

install_expander_ota_timer() {
    if [[ "$EXPANDER_OTA_ENABLE_TIMER" != "1" ]]; then
        log "Skipping OTA timer setup (EXPANDER_OTA_ENABLE_TIMER=$EXPANDER_OTA_ENABLE_TIMER)"
        return 0
    fi

    if [[ "$MOUNT_POINT" != "/data" ]]; then
        warn "Skipping OTA timer setup because target is mounted at $MOUNT_POINT"
        return 0
    fi

    local svc_path="/etc/systemd/system/expander-ota.service"
    local timer_path="/etc/systemd/system/expander-ota.timer"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would install $svc_path"
        log "[DRY_RUN] Would install $timer_path"
        log "[DRY_RUN] Would run: systemctl daemon-reload && systemctl enable --now expander-ota.timer"
        return 0
    fi

    cat > "$TEMP_DIR/expander-ota.service" <<'EOF'
[Unit]
Description=Expander OTA Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=RUNTIME=/opt/expander/runtime
ExecStart=/opt/expander/tools/ota.sh
User=root
Group=root
EOF

    cat > "$TEMP_DIR/expander-ota.timer" <<'EOF'
[Unit]
Description=Run Expander OTA Update Daily

[Timer]
OnBootSec=7min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo install -m 644 "$TEMP_DIR/expander-ota.service" "$svc_path"
    sudo install -m 644 "$TEMP_DIR/expander-ota.timer" "$timer_path"
    sudo systemctl daemon-reload
    sudo systemctl enable --now expander-ota.timer

    pass "Enabled expander-ota.timer"
}

install_laptop_killer_ota() {
    local dest_dir="$1"
    local ota_dir="$dest_dir/runtime/ota"
    local key_dir="$ota_dir/keys"
    local tools_dir="$dest_dir/tools"
    local ota_script="$tools_dir/ota.sh"
    local mirror_script="$tools_dir/mirror_release.sh"
    local key_file="$key_dir/laptop_killer_ota_pubkey.asc"
    local local_pubkey=""
    if [[ -n "$SCRIPT_DIR" ]]; then
        local_pubkey="$SCRIPT_DIR/laptop_killer_ota_pubkey.asc"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would ensure OTA directories: $ota_dir and $key_dir"
        log "[DRY_RUN] Would install OTA updater script at $ota_script"
        log "[DRY_RUN] Would install mirror_release.sh at $mirror_script"
    else
        sudo mkdir -p "$ota_dir" "$key_dir" "$tools_dir"
        cat > "$TEMP_DIR/laptop_killer_ota.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

BIN="laptop_killer"

RUNTIME="${RUNTIME:-/opt/laptopkiller/runtime}"
BIN_DIR="$RUNTIME/bin"
OTA_DIR="$RUNTIME/ota"
KEY_DIR="$OTA_DIR/keys"

BASE_URL="https://raw.githubusercontent.com/Wayne-Richardson-Rheem/LaptopKiller-Releases/main/releases"

mkdir -p "$OTA_DIR"
cd "$OTA_DIR"

if [[ ! -x "$BIN_DIR/$BIN" ]]; then
  echo "[OTA] ERROR: $BIN_DIR/$BIN does not exist or is not executable"
  exit 1
fi

CURRENT_VERSION="$($BIN_DIR/$BIN --version | tr -d '\n\r')"
echo "[OTA] Current version: $CURRENT_VERSION"

echo "[OTA] Checking for update..."
LATEST_VERSION="$(curl -fsSL "$BASE_URL/../latest.txt" | tr -d '\n\r')"
echo "[OTA] Latest available version: $LATEST_VERSION"

if [[ "$LATEST_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "[OTA] Already up to date ($CURRENT_VERSION)"
  exit 0
fi

# Do not downgrade if release metadata is stale.
if [[ "$(printf '%s\n%s\n' "$LATEST_VERSION" "$CURRENT_VERSION" | sort -V | tail -n1)" != "$LATEST_VERSION" ]]; then
    echo "[OTA] Repository version ($LATEST_VERSION) is older than current ($CURRENT_VERSION); skipping downgrade"
    exit 0
fi

VERSION="$LATEST_VERSION"
BIN_FILE="$BIN-$VERSION"
VERSION_DIR="$BASE_URL/v$VERSION"

echo "[OTA] Downloading v$VERSION..."
curl -fsSLO "$VERSION_DIR/$BIN_FILE"
curl -fsSLO "$VERSION_DIR/$BIN_FILE.sha256"
curl -fsSLO "$VERSION_DIR/$BIN_FILE.sha256.asc"

echo "[OTA] Verifying signature..."
gpg --batch --no-default-keyring \
  --keyring "$OTA_DIR/ota-keyring.gpg" \
  --import "$KEY_DIR/laptop_killer_ota_pubkey.asc" >/dev/null 2>&1 || true

gpg --batch --no-default-keyring \
  --keyring "$OTA_DIR/ota-keyring.gpg" \
  --verify "$BIN_FILE.sha256.asc" "$BIN_FILE.sha256"

echo "[OTA] Verifying checksum..."
awk -v bin="$BIN_FILE" '{print $1 "  " bin}' "$BIN_FILE.sha256" | sha256sum -c -

echo "[OTA] Saving rollback version..."
echo "$CURRENT_VERSION" > "$OTA_DIR/last-good"

echo "[OTA] Installing new binary..."
install -m 755 "$BIN_FILE" "$BIN_DIR/$BIN_FILE"

echo "[OTA] Switching symlink..."
ln -sfn "$BIN_FILE" "$BIN_DIR/$BIN"

echo "[OTA] Running smoke test..."
NEW_VERSION="$($BIN_DIR/$BIN --version | tr -d '\n\r')" || true

if [[ "$NEW_VERSION" != "$VERSION" ]]; then
  echo "[OTA] Smoke test failed - rolling back"
  OLD_VERSION="$(cat "$OTA_DIR/last-good")"
  ln -sfn "$BIN-$OLD_VERSION" "$BIN_DIR/$BIN"
  exit 1
fi

echo "[OTA] Update successful ($VERSION)"
EOF
        sudo install -m 755 "$TEMP_DIR/laptop_killer_ota.sh" "$ota_script"

        install_mirror_script "laptop_killer" "$LAPTOP_KILLER_MIRROR_SCRIPT_URL" "$mirror_script" "$TEMP_DIR/laptop_killer_mirror_release.sh"
    fi

    install_ota_pubkey "laptop_killer" "$key_file" "$local_pubkey" "$LAPTOP_KILLER_OTA_PUBKEY_URL" "$TEMP_DIR/laptop_killer_ota_pubkey.asc" "$LAPTOP_KILLER_OTA_PUBKEY_URL_FALLBACK"

    pass "Configured LaptopKiller OTA assets"
}

install_laptop_killer_ota_timer() {
    if [[ "$LAPTOP_KILLER_OTA_ENABLE_TIMER" != "1" ]]; then
        log "Skipping OTA timer setup (LAPTOP_KILLER_OTA_ENABLE_TIMER=$LAPTOP_KILLER_OTA_ENABLE_TIMER)"
        return 0
    fi

    if [[ "$MOUNT_POINT" != "/data" ]]; then
        warn "Skipping OTA timer setup because target is mounted at $MOUNT_POINT"
        return 0
    fi

    local svc_path="/etc/systemd/system/laptopkiller-ota.service"
    local timer_path="/etc/systemd/system/laptopkiller-ota.timer"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "[DRY_RUN] Would install $svc_path"
        log "[DRY_RUN] Would install $timer_path"
        log "[DRY_RUN] Would run: systemctl daemon-reload && systemctl enable --now laptopkiller-ota.timer"
        return 0
    fi

    cat > "$TEMP_DIR/laptopkiller-ota.service" <<'EOF'
[Unit]
Description=LaptopKiller OTA Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=RUNTIME=/opt/laptopkiller/runtime
ExecStart=/opt/laptopkiller/tools/ota.sh
User=root
Group=root
EOF

    cat > "$TEMP_DIR/laptopkiller-ota.timer" <<'EOF'
[Unit]
Description=Run LaptopKiller OTA Update Daily

[Timer]
OnBootSec=9min
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo install -m 644 "$TEMP_DIR/laptopkiller-ota.service" "$svc_path"
    sudo install -m 644 "$TEMP_DIR/laptopkiller-ota.timer" "$timer_path"
    sudo systemctl daemon-reload
    sudo systemctl enable --now laptopkiller-ota.timer

    pass "Enabled laptopkiller-ota.timer"
}

# Create temporary staging directory
mkdir -p "$TEMP_DIR"
log "Using temporary directory: $TEMP_DIR"

# Update LogFileXfr
log ""
log "=== Updating LogFileXfr ==="
fetch_runtime_from_repo_files "$LOGFILE_XFR_GH_REPO" "$LOGFILE_XFR_RELEASE_TAG" "logfile_xfr" "$TEMP_DIR"
stage_runtime_payload "$TEMP_DIR/logfile_xfr" "$MOUNT_POINT/logfile_xfr" "$LOGFILE_XFR_VERSION"
install_logfile_xfr_ota "$MOUNT_POINT/logfile_xfr"
normalize_logs_layout "$MOUNT_POINT/logfile_xfr"

if [[ "$DRY_RUN" != "1" ]]; then
    # Ensure app data is writable by the invoking non-root user.
    if id "$APP_OWNER" >/dev/null 2>&1 && [[ "$APP_OWNER" != "root" ]]; then
        sudo chown -R "$APP_OWNER:$APP_OWNER" "$MOUNT_POINT/logfile_xfr" 2>/dev/null || true
    else
        warn "Could not resolve non-root owner; leaving logfile_xfr ownership unchanged"
    fi
    chmod 755 "$MOUNT_POINT/logfile_xfr/runtime" "$MOUNT_POINT/logfile_xfr/runtime/bin" 2>/dev/null || true
fi

# Update Expander
log ""
log "=== Updating Expander ==="
fetch_runtime_from_repo_files "$EXPANDER_GH_REPO" "$EXPANDER_RELEASE_TAG" "expander" "$TEMP_DIR"
stage_runtime_payload "$TEMP_DIR/expander" "$MOUNT_POINT/expander" "$EXPANDER_VERSION"
install_expander_ota "$MOUNT_POINT/expander"
normalize_logs_layout "$MOUNT_POINT/expander"

if [[ "$DRY_RUN" != "1" ]]; then
    # Ensure app data is writable by the invoking non-root user.
    if id "$APP_OWNER" >/dev/null 2>&1 && [[ "$APP_OWNER" != "root" ]]; then
        sudo chown -R "$APP_OWNER:$APP_OWNER" "$MOUNT_POINT/expander" 2>/dev/null || true
    else
        warn "Could not resolve non-root owner; leaving expander ownership unchanged"
    fi
    chmod 755 "$MOUNT_POINT/expander/runtime" "$MOUNT_POINT/expander/runtime/bin" 2>/dev/null || true
fi

# Update LaptopKiller
log ""
log "=== Updating LaptopKiller ==="
fetch_runtime_from_repo_files "$LAPTOP_KILLER_GH_REPO" "$LAPTOP_KILLER_RELEASE_TAG" "laptop_killer" "$TEMP_DIR"
stage_runtime_payload "$TEMP_DIR/laptop_killer" "$MOUNT_POINT/laptopkiller" "$LAPTOP_KILLER_VERSION"
install_laptop_killer_ota "$MOUNT_POINT/laptopkiller"
normalize_logs_layout "$MOUNT_POINT/laptopkiller"

if [[ "$DRY_RUN" != "1" ]]; then
    # Ensure app data is writable by the invoking non-root user.
    if id "$APP_OWNER" >/dev/null 2>&1 && [[ "$APP_OWNER" != "root" ]]; then
        sudo chown -R "$APP_OWNER:$APP_OWNER" "$MOUNT_POINT/laptopkiller" 2>/dev/null || true
    else
        warn "Could not resolve non-root owner; leaving laptopkiller ownership unchanged"
    fi
    chmod 755 "$MOUNT_POINT/laptopkiller/runtime" "$MOUNT_POINT/laptopkiller/runtime/bin" 2>/dev/null || true
fi

# Verify update
log ""
log "=== Verifying Update ==="

if [[ "$DRY_RUN" == "1" ]]; then
    pass "[DRY_RUN] Verification would check:"
    pass "[DRY_RUN]   - $MOUNT_POINT/logfile_xfr/runtime/bin/logfile_xfr (executable)"
    pass "[DRY_RUN]   - $MOUNT_POINT/expander/runtime/bin/expander (executable)"
    pass "[DRY_RUN]   - $MOUNT_POINT/laptopkiller/runtime/bin/laptop_killer (executable)"
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
    
    if [[ -x "$MOUNT_POINT/laptopkiller/runtime/bin/laptop_killer" ]]; then
        pass "LaptopKiller executable verified"
    else
        fatal "LaptopKiller executable not found or not executable"
    fi
    
    # Test binaries if possible
    if command -v file >/dev/null 2>&1; then
        log "Checking binary types..."
        file "$MOUNT_POINT/logfile_xfr/runtime/bin/logfile_xfr" || warn "Could not verify logfile_xfr binary type"
        file "$MOUNT_POINT/expander/runtime/bin/expander" || warn "Could not verify expander binary type"
        file "$MOUNT_POINT/laptopkiller/runtime/bin/laptop_killer" || warn "Could not verify laptop_killer binary type"
    fi
fi

install_logfile_xfr_ota_timer
install_expander_ota_timer
install_laptop_killer_ota_timer

log ""
pass "=== Update Complete ==="
log "LogFileXfr, Expander, and LaptopKiller have been successfully updated on this system."
log "Changes will take effect when services are restarted."

if [[ "$DRY_RUN" == "1" ]]; then
    log "[DRY_RUN] Run without DRY_RUN=1 to actually apply changes"
fi

exit 0

