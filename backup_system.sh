#!/bin/bash
# backup_system.sh – Server backup version (no USB backup)
# Backs up all important system/user directories to remote server.

set -euo pipefail

# ---------------- CONFIGURATION ----------------
REMOTE_USER="rheemtest"
REMOTE_HOST="wayner5820.local"
REMOTE_DIR="/home/rheemtest/recon-device-backup"

LOG_DIR="/var/log/recon"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/backup_${TIMESTAMP}.log"

EXCLUDES="/home/rheemtest/sys_tools/backup-excludes.txt"

# Backup source directories (same as original script)
HOME_SRC="/home/"
SYSTEMD_SRC="/etc/systemd/system/"
USR_LOCAL_BIN_SRC="/usr/local/bin/"
VAR_WWW_SRC="/var/www/"
CGI_BIN_SRC="/usr/lib/cgi-bin/"
# ------------------------------------------------


# Create log directory if missing
mkdir -p "$LOG_DIR"

# Write everything to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$TIMESTAMP] $*"
}

log "=== Backup started ==="

# Ensure excludes file exists
if [[ ! -f "$EXCLUDES" ]]; then
    log "WARNING: Excludes file not found: $EXCLUDES"
    EXCLUDES=""
fi


# ---------------- SELECT RSYNC OPTIONS ----------------
# Detect if remote filesystem supports Linux permissions
log "Detecting remote filesystem type..."
REMOTE_FS=$(ssh -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" \
    "stat -f -c %T \"$REMOTE_DIR\" 2>/dev/null" || echo "unknown")

if [[ "$REMOTE_FS" =~ (ext|xfs|btrfs) ]]; then
    log "Remote filesystem supports Linux attributes → enabling -A -X"
    RSYNC_COMMON=(-aAX --delete --itemize-changes)
else
    log "Remote filesystem does NOT support Linux attributes → disabling -A -X"
    RSYNC_COMMON=(-a --delete --itemize-changes)
fi


# ---------------- BACKUP FUNCTION ----------------
run_backup() {
    local label="$1"
    local src="$2"
    local dst="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/${label}/"

    log "Backing up ${label} → ${dst}"

    rsync "${RSYNC_COMMON[@]}" \
        ${EXCLUDES:+--exclude-from="$EXCLUDES"} \
        -e ssh \
        "$src" "$dst"
}

# ---------------- RUN BACKUPS ----------------

run_backup "home" "$HOME_SRC"

log "Backing up custom systemd units..."
SYSTEMD_OUTPUT="$(
    rsync "${RSYNC_COMMON[@]}" \
        -e ssh \
        --prune-empty-dirs \
        --include='*/' \
        --include='*.service' \
        --include='*.path' \
        --include='*.service.d/***' \
        --include='*.path.d/***' \
        --exclude='*.wants/**' \
        --exclude='*.requires/**' \
        --exclude='*' \
        --no-links \
        "$SYSTEMD_SRC" \
        "${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR}/systemd-custom/" 2>&1
)"

[[ -n "${SYSTEMD_OUTPUT//$'\n'/}" ]] && log "$SYSTEMD_OUTPUT" || log "(no systemd changes)"

run_backup "usr-local-bin" "$USR_LOCAL_BIN_SRC"
run_backup "var-www" "$VAR_WWW_SRC"
run_backup "cgi-bin" "$CGI_BIN_SRC"

log "=== Backup completed successfully ==="
log "Log saved: $LOG_FILE"
exit 0

