#!/bin/bash
set -euo pipefail

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
    echo "Usage: $0 /dev/sdX"
    exit 1
fi

echo "⚠️  THIS WILL OVERWRITE ALL DATA ON $TARGET"
read -p "Type YES to continue: " confirm
[[ "$confirm" == "YES" ]] || exit 1


############################################################
# FULL CLEANUP OF ANY PREVIOUS MOUNTS OF THIS DEVICE
############################################################
echo "==> Cleaning up stale mounts..."

# List all mounted partitions of this device
while read -r line; do
    DEV=$(echo "$line" | awk '{print $1}')
    MPT=$(echo "$line" | awk '{print $2}')
    echo "   -> Unmounting $DEV from $MPT"
    sudo umount -f "$MPT" || true
done < <(mount | grep "^$TARGET")

# Also unmount leftover testing directories if they exist
sudo umount -f /mnt/rootA_test 2>/dev/null || true
sudo rm -rf /mnt/rootA_test

echo "==> Verifying device is unused..."
if mount | grep -q "^$TARGET"; then
    echo "❌ ERROR: Device is still mounted:"
    mount | grep "^$TARGET"
    exit 1
fi


############################################################
# PARTITION TARGET
############################################################
echo "==> Creating MBR partition table on $TARGET..."
sudo parted -s "$TARGET" mklabel msdos

echo "==> Creating rootA partition..."
sudo parted -s "$TARGET" mkpart primary ext4 1MiB 6GiB

sleep 1


############################################################
# FORMAT PARTITION
############################################################
echo "==> Formatting ${TARGET}1..."
sudo mkfs.ext4 -F "${TARGET}1"


############################################################
# MOUNT TARGET
############################################################
echo "==> Mounting ${TARGET}1 at /mnt/rootA_test..."
sudo mkdir -p /mnt/rootA_test
sudo mount "${TARGET}1" /mnt/rootA_test


############################################################
# SAFE RSYNC CLONE (NO BIND MOUNTS)
############################################################
echo "==> Starting SAFE rsync clone..."

sudo rsync -aHAX --numeric-ids --one-file-system \
    --exclude={"/mnt/*","/proc/*","/sys/*","/dev/*","/tmp/*","/run/*","/boot/*"} \
    / /mnt/rootA_test/


############################################################
# VALIDATION
############################################################
echo "==> Validating essential system files..."

CRIT=(
    usr/bin/ls
    usr/bin/bash
    usr/bin/systemctl
    usr/bin/python3
    lib/arm-linux-gnueabihf/ld-linux-armhf.so.3
    sbin/init
)

for f in "${CRIT[@]}"; do
    if [[ ! -e "/mnt/rootA_test/$f" ]]; then
        echo "❌ ERROR: Missing critical file: $f"
        echo "Target clone is INCOMPLETE. DO NOT PROCEED."
        sudo umount /mnt/rootA_test
        exit 1
    fi
done

echo "✔ Clone test PASSED — all critical files are present."

sudo umount /mnt/rootA_test
sudo rm -rf /mnt/rootA_test

echo "DONE."
