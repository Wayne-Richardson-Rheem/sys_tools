#!/usr/bin/env bash
#
# build_and_prepare_sd.sh
#
# Menu-driven orchestrator for:
#   1) Kernel build
#   2) SD card hardening
#   3) SD card validation
#
# Design goals:
#   - One entry point
#   - Stop-on-failure
#   - Unified top-level logging (Option B)
#   - No logic duplication
#   - Safe for repeated field use
#

set -euo pipefail

###############################################################################
# Logging (Option B)
###############################################################################
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="build_orchestrator_${TIMESTAMP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo
echo "===================================================="
echo " BUILD / PREPARE SD — ORCHESTRATOR START"
echo " Timestamp : $TIMESTAMP"
echo " Log file  : $LOG_FILE"
echo "===================================================="
echo

###############################################################################
# Helper functions
###############################################################################
info()  { echo "[INFO] $*"; }
fatal() { echo "[ERROR] $*"; exit 1; }

select_sd_device() {
    # All UI output goes to STDERR so it is visible
    echo >&2
    echo "Detecting writable block devices (excluding system disk)..." >&2
    echo >&2

    # Detect disk backing /
    ROOT_SRC=$(findmnt -no SOURCE /)
    ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC")

    [[ -n "$ROOT_DISK" ]] || {
        echo "ERROR: Failed to detect root disk" >&2
        exit 1
    }

    # Find candidate disks using structured lsblk output
    mapfile -t DISKS < <(
        lsblk -J -o NAME,TYPE | jq -r '
          .blockdevices[]
          | select(.type=="disk")
          | select(.children != null)
          | .name
        ' | grep -v "^${ROOT_DISK}$"
    )

    if [[ "${#DISKS[@]}" -eq 0 ]]; then
        echo "ERROR: No suitable SD-card devices found." >&2
        exit 1
    fi

    # Print menu to STDERR
    for i in "${!DISKS[@]}"; do
        DEV="${DISKS[$i]}"
        SIZE=$(lsblk -dn -o SIZE "/dev/$DEV")
        MODEL=$(lsblk -dn -o MODEL "/dev/$DEV")
        printf "  %d) /dev/%s  %s  %s\n" "$((i+1))" "$DEV" "$SIZE" "$MODEL" >&2
    done

    echo >&2
    read -rp "Select target device [1-${#DISKS[@]}]: " CHOICE < /dev/tty

    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] ||
       ((CHOICE < 1 || CHOICE > ${#DISKS[@]})); then
        echo "Invalid selection." >&2
        exit 1
    fi

    SD_DEV="/dev/${DISKS[$((CHOICE-1))]}"

    echo >&2
    echo "Selected device: $SD_DEV" >&2
    # ONLY the final selection goes to STDOUT
    echo "$SD_DEV"
}

###############################################################################
# Menu
###############################################################################
echo "Select an operation:"
echo
echo "  1) Build kernel only"
echo "  2) Harden SD card only"
echo "  3) Validate SD card only"
echo "  4) Build kernel + Harden SD card + Validate SD card"
echo
read -rp "Enter choice [1-4]: " CHOICE

echo

###############################################################################
# Execute selection
###############################################################################
case "$CHOICE" in
    1)
        info "Selected: Build kernel only"
        ./compile_kernel.sh normal
        ;;

    2)
        SD_DEV=$(select_sd_device)
        ls "$HOME/kernel_artifacts"/kernel7.img-*-recon-field >/dev/null 2>&1 \
          || fatal "Kernel artifact missing; run build first"

        ls "$HOME/kernel_artifacts"/initramfs7-*-recon-field >/dev/null 2>&1 \
          || fatal "Initramfs artifact missing; run build first"

        info "Selected: Harden SD card only ($SD_DEV)"
        ./harden_pi.sh "$SD_DEV"
        ;;

    3)
        SD_DEV=$(select_sd_device)

        info "Selected: Validate SD card only ($SD_DEV)"
        ./validate_sdcard.sh "$SD_DEV"
        ;;

    4)
        SD_DEV=$(select_sd_device)

        ls "$HOME/kernel_artifacts"/kernel7.img-*-recon-field >/dev/null 2>&1 \
          || fatal "Kernel artifact missing; run build first"

        ls "$HOME/kernel_artifacts"/initramfs7-*-recon-field >/dev/null 2>&1 \
          || fatal "Initramfs artifact missing; run build first"

        info "Selected: Full pipeline (build → harden → validate)"

        echo
        echo "----------------------------------------------------"
        echo " STEP 1: Building kernel"
        echo "----------------------------------------------------"
        ./compile_kernel.sh normal

        echo
        echo "----------------------------------------------------"
        echo " STEP 2: Hardening SD card ($SD_DEV)"
        echo "----------------------------------------------------"
        ./harden_pi.sh "$SD_DEV"

        echo
        echo "----------------------------------------------------"
        echo " STEP 3: Validating SD card ($SD_DEV)"
        echo "----------------------------------------------------"
        ./validate_sdcard.sh "$SD_DEV"
        ;;

    *)
        fatal "Invalid selection. Choose 1–4."
        ;;
esac

###############################################################################
# Completion
###############################################################################
echo
echo "===================================================="
echo " OPERATION COMPLETED SUCCESSFULLY"
echo "===================================================="
echo "Log file: $LOG_FILE"
echo
