#!/bin/bash
# backup_and_clone.sh – FINAL FIXED VERSION
# Backs up system → clones SSD to SD → auto-fixes PARTUUIDs (Pi Zero 2W-safe)

set -euo pipefail

# ---------------- CONFIGURATION ----------------
BACKUP_SCRIPT="/home/rheemtest/sys_tools/backup_system.sh"

LOG_DIR="/var/log/recon"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
LOG_FILE="$LOG_DIR/backup_and_clone_${TIMESTAMP}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$TIMESTAMP] $*"
}
# ------------------------------------------------


# ---------------- STEP 1: BACKUP ----------------
log "=== STEP 1: Running backup_system.sh ==="

if [[ ! -x "$BACKUP_SCRIPT" ]]; then
    log "❌ ERROR: Backup script not found: $BACKUP_SCRIPT"
    exit 1
fi

"$BACKUP_SCRIPT"

log "✔ Backup completed"


# ---------------- STEP 2: DETECT SSD ----------------
log "=== STEP 2: Detecting SSD based on root filesystem ==="

ROOT_DEV=$(df / | tail -1 | awk '{print $1}')
SSD_PARENT=$(lsblk -no PKNAME "$ROOT_DEV")
SSD_DEV="/dev/$SSD_PARENT"

log "Detected SSD root device: $ROOT_DEV"
log "SSD parent block device:  $SSD_DEV"


# ---------------- STEP 3: DETECT SD CARD ----------------
log "=== STEP 3: Detecting SD card in USB reader ==="

detect_sd_card() {
    SD_CANDIDATES=()

    for block in /sys/block/sd*; do
        base=$(basename "$block")
        dev="/dev/$base"

        # skip SSD
        [[ "$dev" == "$SSD_DEV" ]] && continue

        # skip if not removable USB media
        if [[ "$(cat "$block/removable")" != "1" ]]; then continue; fi

        # must have partitions
        if ls "${dev}"*1 >/dev/null 2>&1; then
            SD_CANDIDATES+=("$dev")
        fi
    done

    if (( ${#SD_CANDIDATES[@]} == 1 )); then
        SD_DEV="${SD_CANDIDATES[0]}"
        log "Detected SD card: $SD_DEV"
    else
        log "Multiple or no SD candidates found:"
        printf '%s\n' "${SD_CANDIDATES[@]}"
        read -p "Enter SD device to use (e.g. /dev/sdb): " SD_DEV
    fi
}

detect_sd_card


# ---------------- STEP 4: SIZE CHECK ----------------
log "=== SIZE CHECK: Ensuring SSD data fits on SD card ==="

SSD_USED=$(df --output=used -B1 / | tail -1)
SD_SIZE=$(lsblk -bdno SIZE "$SD_DEV")

log "SSD used: $SSD_USED bytes"
log "SD size:  $SD_SIZE bytes"

if (( SSD_USED > SD_SIZE )); then
    log "❌ ERROR: SSD contains more data than SD card can hold!"
    exit 1
fi

log "✔ Size check OK"


# ---------------- STEP 5: CLONE SSD → SD ----------------
log "=== STEP 5: Cloning SSD → SD card ==="

umount "${SD_DEV}"* || true

rpi-clone -f "$SD_DEV" 2>&1 | tee -a "$LOG_FILE"

log "✔ Clone complete"


# ---------------- STEP 6: WAIT FOR PARTITIONS ----------------
log "=== STEP 6: Waiting for SD partitions to settle ==="

sleep 2
sudo partprobe "$SD_DEV" || true
sleep 1

until blkid "${SD_DEV}p1" &>/dev/null && blkid "${SD_DEV}p2" &>/dev/null; do
    log "Partitions not ready yet, retrying..."
    sleep 1
done

log "✔ SD partitions are ready"


# ---------------- STEP 7: FIX PARTUUIDS ----------------
log "=== STEP 7: Fixing PARTUUIDs ==="

mount "${SD_DEV}p2" /mnt
mount "${SD_DEV}p1" /mnt/boot

ROOT_UUID=$(blkid -s PARTUUID -o value "${SD_DEV}p2")
BOOT_UUID=$(blkid -s PARTUUID -o value "${SD_DEV}p1")

log "Boot PARTUUID: $BOOT_UUID"
log "Root PARTUUID: $ROOT_UUID"

sed -i "s|root=PARTUUID=[^ ]*|root=PARTUUID=${ROOT_UUID}|g" /mnt/boot/cmdline.txt
sed -i "s|PARTUUID=.*-01|PARTUUID=${BOOT_UUID}|g" /mnt/etc/fstab
sed -i "s|PARTUUID=.*-02|PARTUUID=${ROOT_UUID}|g" /mnt/etc/fstab

sync

umount /mnt/boot
umount /mnt

log "✔ PARTUUIDs updated"


# ---------------- STEP 8: DONE ----------------
log "=== DONE ==="
log "SD card ready for deployment."
log "Log saved to: $LOG_FILE"

exit 0
