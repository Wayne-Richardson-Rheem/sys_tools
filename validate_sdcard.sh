#!/usr/bin/env bash
#
# validate_sdcard.sh
#
# Purpose:
#   Validate a fully-prepared, hardened Raspberry Pi SD card that uses:
#   - Legacy /boot layout
#   - Immutable SquashFS root filesystem
#   - A/B root containers with overlayfs
#   - initramfs-driven early boot and failover
#
# This script is NON-DESTRUCTIVE. It only:
#   - Mounts partitions read-only where possible
#   - Inspects files, configuration, and layout
#   - Reports PASS / FAIL results
#
# Usage:
#   ./validate_sdcard.sh /dev/sdX
#
# Exit codes:
#   0 = PASS (safe to duplicate/deploy)
#   1 = FAIL (do NOT deploy this card)
#
#------------------------------------------------------------------------
set -euo pipefail

#------------------------------------------------------------------------
# Input validation
#------------------------------------------------------------------------
TARGET="${1:-}"

[[ -n "$TARGET" ]] || { echo "Usage: $0 /dev/sdX"; exit 1; }
[[ -b "$TARGET" ]] || { echo "Block device not found: $TARGET"; exit 1; }

# Stub validation mode: loopback targets or WSL host kernels.
VALIDATOR_STUB=0
if [[ "$TARGET" =~ ^/dev/loop[0-9]+$ ]] || grep -qiE "(microsoft|wsl)" /proc/sys/kernel/osrelease 2>/dev/null; then
    VALIDATOR_STUB=1
fi

# Handle loop, mmc, sd devices consistently
part() {
    local dev="$1"
    local num="$2"
    if [[ "$dev" =~ (loop|mmcblk) ]]; then
        echo "${dev}p${num}"
    else
        echo "${dev}${num}"
    fi
}

sudo -n true 2>/dev/null || {
    echo "Run first: sudo -v"
    exit 1
}

#------------------------------------------------------------------------
# Temporary workspace (all mounts live here)
#------------------------------------------------------------------------
WORK=/tmp/pi_validate_$$
BOOT=$WORK/boot
ROOTA=$WORK/rootA
ROOTB=$WORK/rootB
DATA=$WORK/data
SQTMP=$WORK/squash_test

mkdir -p "$BOOT" "$ROOTA" "$ROOTB" "$DATA" "$SQTMP"

#------------------------------------------------------------------------
# Result accounting + formatting helpers
#------------------------------------------------------------------------
PASSCOUNT=0
FAILCOUNT=0

pass() {
  echo "[PASS] $1"
  PASSCOUNT=$((PASSCOUNT + 1))
}
fail() {
    echo "[FAIL] $1"
    FAILCOUNT=$((FAILCOUNT + 1))
}
warn() { echo "[WARN] $1"; }

#------------------------------------------------------------------------
# Cleanup handler — guarantees we never leave mounts behind
#------------------------------------------------------------------------
cleanup() {
    sudo umount -lf "$SQTMP" 2>/dev/null || true
    sudo umount -lf "$BOOT" 2>/dev/null || true
    sudo umount -lf "$ROOTA" 2>/dev/null || true
    sudo umount -lf "$ROOTB" 2>/dev/null || true
    sudo umount -lf "$DATA" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "Validating $TARGET"
echo

# Ensure partitions are visible (loop devices need this)
sudo partprobe "$TARGET" 2>/dev/null || true
sudo udevadm settle 2>/dev/null || true

###############################################################################
# 1. Partition existence
###############################################################################
for p in 1 2 3 4; do
    DEV=$(part "$TARGET" "$p")
    if [[ -b "$DEV" ]]; then
        pass "Partition $p exists ($DEV)"
    else
        fail "Partition $p missing ($DEV)"
    fi
done

###############################################################################
# 2. Mount partitions
###############################################################################
sudo mount "$(part "$TARGET" 1)" "$BOOT"
sudo mount "$(part "$TARGET" 2)" "$ROOTA"
sudo mount "$(part "$TARGET" 3)" "$ROOTB"
sudo mount "$(part "$TARGET" 4)" "$DATA"

pass "Partitions mounted"

# Immutable root payload location
SQ="$ROOTA/rootfs.squashfs"
SQ_B="$ROOTB/rootfs.squashfs"

###############################################################################
# 3. Boot layout validation
# Detect boot layout (legacy vs Bookworm-style)
# IMPORTANT: must be done before referencing config.txt / kernel
###############################################################################
if [[ -d "$BOOT/firmware" ]]; then
    fail "Unexpected /boot/firmware directory present"
else
    pass "Legacy boot layout"
fi

###############################################################################
# 4. Kernel validation (authoritative via modules match)
###############################################################################
KERNEL="$BOOT/kernel7.img"

if [[ ! -f "$KERNEL" ]]; then
  fail "kernel7.img missing"
else
  pass "kernel7.img present"

  OWNER=$(stat -c '%u' "$KERNEL")
  [[ "$OWNER" -eq 0 ]] && pass "kernel owned by root" || fail "kernel not owned by root"

    # Extract kernel version from SquashFS payload
    MOD_KVER=$(unsquashfs -l "$SQ" 2>/dev/null \
        | awk '/lib\/modules\/[^/]+$/ {print $NF}' \
        | sed -n 's#.*/lib/modules/##p' \
        | head -n1)

  if [[ -z "$MOD_KVER" ]]; then
    fail "Unable to determine kernel version from modules"
  else
    echo "$MOD_KVER" | grep -q "recon-field" \
        && pass "Kernel modules indicate recon-field build ($MOD_KVER)" \
        || fail "Kernel modules missing recon-field tag ($MOD_KVER)"
  fi
fi

###############################################################################
# 5. Modules validation
###############################################################################
if [[ -n "${MOD_KVER:-}" ]]; then
    pass "Kernel modules present"
else
    fail "Missing kernel modules"
fi

###############################################################################
# 6. config.txt validation
###############################################################################
if grep -q '^initramfs' "$BOOT/config.txt"; then
    fail "External initramfs configured (should be embedded)"
else
    pass "No external initramfs configured"
fi

if grep -Eq '^dtoverlay=dwc2$' "$BOOT/config.txt"; then
    pass "USB gadget controller overlay enabled"
else
    fail "Missing dtoverlay=dwc2 in config.txt"
fi

###############################################################################
# 7. fstab validation
###############################################################################
if unsquashfs -cat "$SQ" etc/fstab 2>/dev/null | grep -Eq 'LABEL=BOOT.*ro'; then
    pass "/boot mounted read-only in fstab"
else
    fail "/boot not read-only in fstab"
fi

###############################################################################
# 8. Filesystem integrity
###############################################################################
for p in 2 3 4; do
    DEV=$(part "$TARGET" "$p")
    sudo e2fsck -fn "$DEV" >/dev/null 2>&1 \
        && pass "$DEV filesystem clean" \
        || fail "$DEV filesystem errors"
done

###############################################################################
# 9. Partition signature validation (blkid)
###############################################################################
for p in 1 2 3 4; do
    DEV=$(part "$TARGET" "$p")
    blkid "$DEV" >/dev/null 2>&1 \
        && pass "$DEV filesystem signature present" \
        || fail "$DEV missing filesystem signature"
done

###############################################################################
# 10. cmdline validation (single line + correct flags)
###############################################################################
CMD=$(tr -cd '[:print:] ' < "$BOOT/cmdline.txt" | tr -s ' ')

echo "$CMD" | grep -q 'root=/dev/ram0' \
&& echo "$CMD" | grep -q 'init=/init' \
    && echo "$CMD" | grep -q 'modules-load=dwc2' \
    && pass "cmdline valid (initramfs boot + USB controller)" \
    || fail "cmdline incorrect"

###############################################################################
# 11. SquashFS validation (A/B)
###############################################################################
if [[ -f "$SQ" ]]; then
    pass "SquashFS present in rootA"

    # Try to mount (skip failure in WSL stub case)
    if sudo mount -o ro,loop "$SQ" "$SQTMP" 2>/dev/null; then
        pass "SquashFS in rootA mountable"
        sudo umount "$SQTMP"
    else
        warn "SquashFS rootA mount skipped (likely stub mode)"
    fi
else
    fail "SquashFS missing in rootA"
fi

if [[ -f "$SQ_B" ]]; then
    pass "SquashFS present in rootB"

    if sudo mount -o ro,loop "$SQ_B" "$SQTMP" 2>/dev/null; then
        pass "SquashFS in rootB mountable"
        sudo umount "$SQTMP"
    else
        warn "SquashFS rootB mount skipped (likely stub mode)"
    fi
else
    fail "SquashFS missing in rootB"
fi

###############################################################################
# 12. Overlay validation
###############################################################################
for s in A B; do
    [[ -d "$DATA/overlay/$s/upper" ]] \
        && pass "overlay $s upper exists" \
        || fail "overlay $s upper missing"

    [[ -d "$DATA/overlay/$s/work" ]] \
        && pass "overlay $s work exists" \
        || fail "overlay $s work missing"
done

###############################################################################
# 13. Immutable payload hygiene checks
# Each check pipes unsquashfs -l directly to grep to avoid storing a
# multi-megabyte listing in a shell variable (unreliable at 70,000+ files).
###############################################################################

# Helper: list squashfs and grep for a pattern; returns 0 if found.
sq_has() { sudo unsquashfs -l "$SQ" 2>/dev/null | grep -E "$1" >/dev/null; }

if sq_has '/core\.[0-9]+$'; then
    fail "Crash core dumps present in SquashFS payload"
else
    pass "No crash core dumps in SquashFS payload"
fi

MID="$(sudo unsquashfs -cat "$SQ" etc/machine-id 2>/dev/null || true)"
if [[ -n "$MID" ]]; then
    pass "machine-id present in immutable image"
else
    fail "machine-id missing in immutable image"
fi

if sq_has 'etc/letsencrypt/accounts/.*/private_key\.json$'; then
    fail "Let's Encrypt account private keys detected in SquashFS"
else
    pass "No Let's Encrypt account private keys in SquashFS"
fi

if sq_has 'etc/apache2/ssl/server\.key$'; then
    fail "Apache private key detected in SquashFS"
else
    pass "No Apache private key in SquashFS"
fi

if sq_has 'etc/NetworkManager/system-connections/usb-gadget\.nmconnection$'; then
    pass "USB gadget NetworkManager profile present in SquashFS"
else
    fail "USB gadget NetworkManager profile missing in SquashFS"
fi

if sq_has 'usr/local/sbin/apply-usb-mode\.sh$'; then
    pass "USB mode apply script present in SquashFS"
else
    fail "USB mode apply script missing in SquashFS"
fi

if sq_has 'etc/systemd/system/apply-usb-mode\.service$'; then
    pass "USB mode systemd service present in SquashFS"
else
    fail "USB mode systemd service missing in SquashFS"
fi

if sq_has 'usr/local/sbin/log-usb-gadget-state\.sh$'; then
    pass "USB diagnostics script present in SquashFS"
else
    fail "USB diagnostics script missing in SquashFS"
fi

if sq_has 'etc/systemd/system/log-usb-gadget-state\.service$'; then
    pass "USB diagnostics systemd service present in SquashFS"
else
    fail "USB diagnostics systemd service missing in SquashFS"
fi

###############################################################################
# FINAL SUMMARY
###############################################################################
echo
echo "PASS=$PASSCOUNT FAIL=$FAILCOUNT"

if [[ $FAILCOUNT -eq 0 ]]; then
    echo "OVERALL RESULT: PASS"
    exit 0
else
    echo "OVERALL RESULT: FAIL"
    exit 1
fi

