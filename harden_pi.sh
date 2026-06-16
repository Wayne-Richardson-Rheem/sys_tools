#!/bin/bash
set -euo pipefail
[[ "${DEBUG:-0}" == "1" ]] && set -x

###############################################################################
# ENVIRONMENT DETECTION (ROBUST WSL CHECK)
###############################################################################
if [[ -n "${WSL_INTEROP:-}" ]] || grep -qiE "(microsoft|wsl)" /proc/sys/kernel/osrelease 2>/dev/null; then
  STUB_MODE=1
  ENVIRONMENT="WSL"
else
  STUB_MODE=0
  ENVIRONMENT="PI"
fi

echo "Detected ENVIRONMENT = $ENVIRONMENT"

echo "============================================================"
echo " BUILD ENVIRONMENT: $ENVIRONMENT"
echo "============================================================"

###############################################################################
# Hardened A/B SquashFS Builder for Raspberry Pi Zero 2W
# (A/B SquashFS + overlayfs via initramfs)
###############################################################################

############################################################
# CONFIG
############################################################
TARGET="${1:-}"
LOOP_IMAGE=""
LOOP_DEV=""

DATE=$(date +"%Y-%m-%d_%H-%M-%S")
export DEBIAN_FRONTEND=noninteractive

BOOT_MNT=/mnt/boot
DATA_MNT=/mnt/data
ROOTA_MNT=/mnt/rootA
ROOTB_MNT=/mnt/rootB
REALUSER="${SUDO_USER:-$USER}"
REALHOME="$(getent passwd "$REALUSER" | cut -d: -f6)"
EXTRACT_IKCONFIG="$HOME/linux/scripts/extract-ikconfig"
DEBUG_INIT_SRC="${DEBUG_INIT_SRC:-$REALHOME/sys_tools/debug-init.sh}"
HOME_SEED_INCLUDE_FILE="${HOME_SEED_INCLUDE_FILE:-$REALHOME/sys_tools/home_seed_include.txt}"
HOME_SEED_EXCLUDE_FILE="${HOME_SEED_EXCLUDE_FILE:-$REALHOME/sys_tools/home_seed_exclude.txt}"
LAPTOPKILLER_SRC="${LAPTOPKILLER_SRC:-$REALHOME/Dev/LaptopKiller}"
EXPANDER_SRC="${EXPANDER_SRC:-$REALHOME/Dev/Expander}"
LOGFILE_XFR_SRC="${LOGFILE_XFR_SRC:-$REALHOME/Dev/LogFileXfr}"


###############################################################################
# TOOLCHAIN CONFIGURATION (WSL cross-compile support)
###############################################################################
if [[ "$ENVIRONMENT" == "WSL" ]]; then
    echo "[EnvSetup] WSL detected — enabling ARM cross-compile"
    export ARCH=arm

    # Use ccache if available
    if command -v ccache >/dev/null 2>&1; then
        echo "[EnvSetup] ccache enabled"
        export CROSS_COMPILE="ccache arm-linux-gnueabihf-"
    else
        echo "[EnvSetup] ccache NOT found"
        export CROSS_COMPILE=arm-linux-gnueabihf-
    fi

    # Sanity check
    if ! command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
        fatal "Cross compiler not installed: arm-linux-gnueabihf-gcc"
    fi
else
    echo "[EnvSetup] Native Pi build environment"
fi


###############################################################################
# Logging
###############################################################################
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$HOME/harden_pi_logs"
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/harden_pi_${TIMESTAMP}.log"
exec > >(tee -a "$LOGFILE" | sed 's/\x08//g') 2>&1

###############################################################################
# Logging helpers (timestamped)
###############################################################################
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

info()  { echo "[$(timestamp)] [INFO] $*"; }
warn()  { echo "[$(timestamp)] [WARN] $*"; }
fatal() { echo "[$(timestamp)] [ERROR] $*"; exit 1; }

info "Logging to: $LOGFILE"


###############################################################################
# Cleanup
###############################################################################
cleanup() {
  info "Cleaning up mounts..."

  # Force kill users of the loop device (WSL-safe)
  sudo fuser -km "$TARGET" 2>/dev/null || true

  # Unmount known mount points (force + recursive)
  for mnt in \
    /mnt/root_check \
    /mnt/data_check \
    "$ROOTA_MNT" \
    "$ROOTB_MNT" \
    "$DATA_MNT" \
    "$BOOT_MNT"
  do
    sudo umount -R "$mnt" 2>/dev/null || true
    sudo umount -l "$mnt" 2>/dev/null || true
  done

  # Detach loop device if used
  if [[ -n "${LOOP_DEV:-}" ]]; then
    info "Detaching loop device $LOOP_DEV"
    sudo losetup -d "$LOOP_DEV" 2>/dev/null || true
  fi

  info "Cleanup complete"
}
trap cleanup EXIT
trap 'echo; info "Interrupted — forcing cleanup..."; cleanup; exit 1' INT TERM


###############################################################################
# Device partition helper
#
# Handles:
#   /dev/sdX  → /dev/sdX1
#   /dev/mmcblk0 → /dev/mmcblk0p1
#   /dev/loop0 → /dev/loop0p1
###############################################################################
part() {
  local dev="$1"
  local num="$2"

  if [[ "$dev" =~ (mmcblk|loop) ]]; then
    echo "${dev}p${num}"
  else
    echo "${dev}${num}"
  fi
}


###############################################################################
# STUB HELPERS
###############################################################################
create_stub_rootfs() {
    info "[STUB] Creating minimal root filesystem..."

    sudo mkdir -p "$BUILD_ROOT"/{bin,sbin,etc,lib,usr,usr/bin,usr/sbin,usr/lib,dev,proc,sys,var/log,tmp,run,home}
    sudo chmod 1777 "$BUILD_ROOT/tmp"

    # /bin/sh (must exist)
    echo -e "#!/bin/sh\necho STUB SH\nexec /bin/sh" | sudo tee "$BUILD_ROOT/bin/sh" > /dev/null
    sudo chmod +x "$BUILD_ROOT/bin/sh"

    sudo chmod +x "$BUILD_ROOT/bin/sh"

    # init
    echo -e "#!/bin/sh\necho STUB INIT\nexec /bin/sh" | sudo tee "$BUILD_ROOT/sbin/init" >/dev/null
    sudo chmod +x "$BUILD_ROOT/sbin/init"

    # bash
    echo -e "#!/bin/sh\necho STUB BASH\nexec /bin/sh" | sudo tee "$BUILD_ROOT/usr/bin/bash" >/dev/null
    sudo chmod +x "$BUILD_ROOT/usr/bin/bash"

    # systemctl
    echo -e "#!/bin/sh\necho STUB SYSTEMCTL" | sudo tee "$BUILD_ROOT/usr/bin/systemctl" >/dev/null
    sudo chmod +x "$BUILD_ROOT/usr/bin/systemctl"

    # dynamic loader placeholder
    sudo mkdir -p "$BUILD_ROOT/lib/arm-linux-gnueabihf"
    sudo touch "$BUILD_ROOT/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3"

    # hostname
    echo "stub-rootfs" | sudo tee "$BUILD_ROOT/etc/hostname" >/dev/null
    sync
}

create_stub_home() {
    info "[STUB] Creating minimal /data/home..."

    sudo mkdir -p "$DATA_MNT/home/$REALUSER"
    echo "stub-home" | sudo tee "$DATA_MNT/home/$REALUSER/README.txt" >/dev/null
  sudo chown -R "$REALUSER:$REALUSER" "$DATA_MNT/home/$REALUSER"
  sudo chmod 755 "$DATA_MNT" "$DATA_MNT/home" "$DATA_MNT/home/$REALUSER"
}

seed_home_content() {
  local dest="$1"
  local src="/home/$REALUSER"

  info "Seeding home content into: $dest"
  sudo mkdir -p "$dest"

  # Include mode: if include list exists and has content, copy ONLY listed paths.
  if [[ -f "$HOME_SEED_INCLUDE_FILE" && -s "$HOME_SEED_INCLUDE_FILE" ]]; then
    info "Seeding home from include list: $HOME_SEED_INCLUDE_FILE"
    while IFS= read -r rel || [[ -n "$rel" ]]; do
      rel="${rel%$'\r'}"
      [[ -z "$rel" ]] && continue
      [[ "$rel" =~ ^[[:space:]]*# ]] && continue

      rel="${rel#/}"
      rel="${rel%/}"
      [[ -z "$rel" ]] && continue

      if [[ -e "$src/$rel" ]]; then
        # Preserve each include path exactly under $dest.
        sudo rsync -aHx --numeric-ids --relative "$src/./$rel" "$dest/"
      else
        warn "Include path missing, skipping: $src/$rel"
      fi
    done < "$HOME_SEED_INCLUDE_FILE"
    return 0
  fi

  # Exclude mode (default): copy everything except built-in and optional custom exclusions.
  local -a rsync_args=(
    -aHx --numeric-ids
    --exclude=".initramfs_root/*"
    --exclude="linux*"
    --exclude="linux-build/*"
    --exclude="root-build/*"
    --exclude="kernel_*/"
    --exclude="harden_pi_logs/*"
    --exclude="*.img"
  )

  if [[ -f "$HOME_SEED_EXCLUDE_FILE" ]]; then
    info "Applying custom home excludes from: $HOME_SEED_EXCLUDE_FILE"
    rsync_args+=("--exclude-from=$HOME_SEED_EXCLUDE_FILE")
  fi

  sudo rsync "${rsync_args[@]}" "$src/" "$dest/"
}

create_stub_boot() {
    info "[STUB] Creating minimal /boot/config.txt..."

    BOOTCFG="$BOOT_MNT/config.txt"

    sudo mkdir -p "$BOOT_MNT"

    cat <<EOF | sudo tee "$BOOTCFG" >/dev/null
kernel=kernel7.img
arm_64bit=0
enable_uart=1
dtoverlay=dwc2
disable_overscan=1
EOF
}

###############################################################################
# Require sudo privileges upfront (fail fast)
###############################################################################
if ! sudo -v; then
    fatal "sudo privileges are required"
fi

###############################################################################
# AUTOMATIC LOOP DEVICE MANAGEMENT (WSL SAFE)
###############################################################################
if [[ "$ENVIRONMENT" == "WSL" ]]; then

  info "[LOOP] Managing loop device..."

  LOOP_IMAGE="${LOOP_IMAGE:-$HOME/pi_loop.img}"

  # If TARGET provided but is stale → clear it
  if [[ -n "$TARGET" && "$TARGET" == /dev/loop* ]]; then
    SIZE_BYTES=$(sudo blockdev --getsize64 "$TARGET" 2>/dev/null || echo 0)

    if (( SIZE_BYTES == 0 )); then
      warn "[LOOP] Detected stale loop device: $TARGET — detaching"
      sudo losetup -d "$TARGET" 2>/dev/null || true
      TARGET=""
    fi
  fi

  # If no valid target → create and attach loop device
  if [[ -z "$TARGET" ]]; then
    info "[LOOP] Creating/attaching loop image..."

    # Create image if it does not exist
    if [[ ! -f "$LOOP_IMAGE" ]]; then
      info "[LOOP] Creating new loop image: $LOOP_IMAGE"
      truncate -s 13G "$LOOP_IMAGE"
    fi

    # Attach loop device
    LOOP_DEV=$(sudo losetup --find --show -P "$LOOP_IMAGE")
    TARGET="$LOOP_DEV"

    info "[LOOP] Using loop device: $TARGET"
  else
    LOOP_DEV="$TARGET"
    info "[LOOP] Using existing loop device: $TARGET"
  fi
fi




###############################################################################
# PREFLIGHT VALIDATION
#
# PURPOSE:
#   Fail fast before any destructive or heavy operations.
#
# VALIDATES:
#   - environment (WSL vs Pi)
#   - required tools
#   - kernel artifacts
#   - module consistency
#   - filesystem structure
#   - disk target sanity
###############################################################################

info "[PREFLIGHT] Starting validation..."

###############################################################################
# 1. Required tools
###############################################################################
REQUIRED_CMDS=(
  parted mkfs.vfat mkfs.ext4 rsync mount umount blkid lsblk
  wipefs partprobe udevadm tune2fs mksquashfs unsquashfs
  losetup fuser file dd truncate
)

for cmd in "${REQUIRED_CMDS[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || fatal "Missing required tool: $cmd"
done

info "[PREFLIGHT] Required tools OK"

###############################################################################
# 2. Kernel artifacts validation
###############################################################################
LATEST_KERNEL=$(ls -t "$HOME/kernel_artifacts/kernel7.img-"* 2>/dev/null | grep -v '\.sha256$' | head -n1 || true)

[[ -n "$LATEST_KERNEL" ]] || fatal "No kernel artifact found"

KVER_FROM_ARTIFACT=$(basename "$LATEST_KERNEL")
KVER_FROM_ARTIFACT=${KVER_FROM_ARTIFACT#kernel7.img-}

MODULES_DIR="$HOME/kernel_artifacts/modules-$KVER_FROM_ARTIFACT"

[[ -d "$MODULES_DIR" ]] || fatal "Missing modules: $MODULES_DIR"

info "[PREFLIGHT] Kernel + modules OK"

###############################################################################
# 3. Kernel artifact contains embedded initramfs
###############################################################################
info "[PREFLIGHT] Validating embedded initramfs in kernel artifact..."

[[ -x "$EXTRACT_IKCONFIG" ]] || fatal "Missing extractor: $EXTRACT_IKCONFIG"

TMPCFG=$(mktemp)
if ! "$EXTRACT_IKCONFIG" "$LATEST_KERNEL" > "$TMPCFG" 2>/dev/null; then
  rm -f "$TMPCFG"
  fatal "Failed to extract IKCONFIG from $(basename "$LATEST_KERNEL")"
fi

grep -q '^CONFIG_BLK_DEV_INITRD=y' "$TMPCFG" || {
  rm -f "$TMPCFG"
  fatal "Kernel artifact missing CONFIG_BLK_DEV_INITRD=y"
}

grep -q '^CONFIG_INITRAMFS_SOURCE=".*"' "$TMPCFG" || {
  rm -f "$TMPCFG"
  fatal "Kernel artifact missing CONFIG_INITRAMFS_SOURCE"
}

rm -f "$TMPCFG"
info "[PREFLIGHT] Embedded initramfs config verified in kernel artifact"


###############################################################################
# 4. Rootfs stub / structure expectations (WSL only)
###############################################################################
if [[ "$STUB_MODE" == "1" ]]; then
    info "[PREFLIGHT] WSL stub mode active"
fi

###############################################################################
# 5. Target device validation
###############################################################################
if [[ -n "$TARGET" ]]; then

    [[ -b "$TARGET" ]] || fatal "Invalid target: $TARGET"

    if [[ "$ENVIRONMENT" == "WSL" ]]; then
        if [[ "$TARGET" != /dev/loop* ]]; then
            fatal "WSL requires loop device"
        fi
    fi

    info "[PREFLIGHT] Target device OK: $TARGET"
else
    info "[PREFLIGHT] No target specified (auto mode likely)"
fi

###############################################################################
# 6. Disk size sanity (and loop device integrity)
###############################################################################
if [[ -n "$TARGET" && -b "$TARGET" ]]; then

    # Get size safely
    SIZE_BYTES=$(sudo blockdev --getsize64 "$TARGET" 2>/dev/null || echo 0)

    # Detect broken / detached loop device
    if (( SIZE_BYTES == 0 )); then
        fatal "Device $TARGET is not attached to a backing file (loop device is empty or stale)"
    fi

    SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
    info "[PREFLIGHT] Target size: ${SIZE_GB}GB"

    if (( SIZE_GB < 8 )); then
        fatal "Disk too small (<8GB)"
    fi
fi


###############################################################################
# 7. Mount points sanity
###############################################################################
for d in "$BOOT_MNT" "$ROOTA_MNT" "$ROOTB_MNT" "$DATA_MNT"; do
    if [[ -e "$d" && ! -d "$d" ]]; then
        fatal "Path exists but is not directory: $d"
    fi
done

info "[PREFLIGHT] Mount points OK"

###############################################################################
# 8. Loop image contamination warning (WSL)
###############################################################################
if [[ "$ENVIRONMENT" == "WSL" ]]; then
    if [[ -f "$HOME/pi_loop.img" ]]; then
        info "[PREFLIGHT] Loop image detected: $HOME/pi_loop.img"
    fi
fi

###############################################################################
# Mount directories (created once)
###############################################################################
sudo mkdir -p \
  "$BOOT_MNT" \
  "$ROOTA_MNT" \
  "$ROOTB_MNT" \
  "$DATA_MNT" \
  /mnt/testsq \
  /mnt/root_check \
  /mnt/data_check

###############################################################################
# Pre-flight security validation (NO SECRETS ALLOWED)
###############################################################################
SECRETS_CHECK="$REALHOME/sys_tools/check_for_secrets.sh"

if [[ "$ENVIRONMENT" != "WSL" ]]; then
  info "Running pre-flight secrets verification..."

  if [ ! -x "$SECRETS_CHECK" ]; then
    fatal "Secrets check script not found or not executable: $SECRETS_CHECK"
  fi

  # Run strictly as the real user (never root)
  if ! sudo -u "$REALUSER" "$SECRETS_CHECK"; then
    fatal "Secrets detected — refusing to build image"
  fi

  info "Secrets verification passed. Safe to proceed."
else
  info "Skipping secrets check in WSL environment"
fi

###############################################################################
# PREFLIGHT SUMMARY CHECKLIST
###############################################################################
info "[PREFLIGHT] Summary:"

echo "------------------------------------------------------------"
echo "✔ Environment        : $ENVIRONMENT"
echo "✔ Stub Mode          : $STUB_MODE"
echo "✔ Kernel Artifact    : $(basename "$LATEST_KERNEL")"
echo "✔ Modules            : $(basename "$MODULES_DIR")"

if [[ -n "$TARGET" ]]; then
    SIZE_BYTES=$(sudo blockdev --getsize64 "$TARGET" 2>/dev/null || echo 0)
    SIZE_GB=$((SIZE_BYTES / 1024 / 1024 / 1024))
    echo "✔ Target Device      : $TARGET (${SIZE_GB}GB)"
fi

echo "✔ Required Tools     : OK"
echo "✔ Kernel + Modules   : OK"
echo "✔ Initramfs Embedded : OK"
echo "------------------------------------------------------------"

info "[PREFLIGHT] Validation PASSED"
info "[PREFLIGHT] READY TO BUILD"


###############################################################################
# Kernel artifacts are already validated during preflight and reused below.
###############################################################################
info "Using preflight-validated kernel artifact: $LATEST_KERNEL"
info "Using preflight-validated modules: $MODULES_DIR"


###############################################################################
# Input Validation
###############################################################################
###############################################################################
# WSL LOOPBACK AUTO-CREATION
#
# WHAT:
#   Automatically creates a loopback disk image in WSL
#
# WHY:
#   Allows full SD-card simulation without requiring physical media
###############################################################################
if [[ "$ENVIRONMENT" == "WSL" ]]; then

  info "WSL detected — using loopback disk simulation"
  # If user did NOT provide a target → auto-create loop image
  if [[ -z "$TARGET" ]]; then
    LOOP_IMAGE="$HOME/pi_loop.img"

    info "Creating loopback disk image: $LOOP_IMAGE"

    # Create 12GB image (matches the SD partition scheme)
    if [[ ! -f "$LOOP_IMAGE" ]]; then
      dd if=/dev/zero of="$LOOP_IMAGE" bs=1M count=12288 status=progress
    else
      info "Reusing existing image: $LOOP_IMAGE"
    fi

    # Attach loop device with partition support
    LOOP_DEV=$(sudo losetup --find --show -P "$LOOP_IMAGE")

    info "Attached loop device: $LOOP_DEV"

    TARGET="$LOOP_DEV"
  else
    # If user passed something → enforce loop device
    if [[ "$TARGET" != /dev/loop* ]]; then
        fatal "WSL requires loop device or no argument (auto mode)"
    fi
  fi
fi

# Check for input parameter.  If blank, then output message
if [[ -z "$TARGET" ]]; then
    fatal "Usage: $0 /dev/sdX"
fi

# Check if the input paramater is valid (/dev/sdX is visible)
if [[ ! -b "$TARGET" ]]; then
    fatal "Device $TARGET not found"
fi


###############################################################################
# WSL LOOP SIMULATION MODE
###############################################################################
if [[ "$ENVIRONMENT" == "WSL" ]]; then
    if [[ "$TARGET" != /dev/loop* ]]; then
        fatal "WSL requires loop device target (e.g., /dev/loop0)"
    fi
    info "WSL loopback simulation ENABLED"
fi


# Do not format the booted device
if findmnt -no SOURCE / | grep -q "$TARGET"; then
    fatal "Refusing to write to the running OS device"
fi

###############################################################################
# Check for removable media (suspicious)
###############################################################################
REMOVABLE=$(cat /sys/block/"$(basename "$TARGET")"/removable)

# Skip removable check for WSL loop devices
if [[ "$ENVIRONMENT" != "WSL" && "$REMOVABLE" != "1" ]]; then
    warn "Device $TARGET does not appear to be removable."
  printf "Are you ABSOLUTELY SURE? (type YES): " > /dev/tty
    read -r confirm < /dev/tty
    shopt -s nocasematch
    if [[ "$confirm" != "YES" ]]; then
        fatal "User abort."
    fi
    shopt -u nocasematch
fi

# DESTRUCTIVE CONFIRMATION
if [[ "$ENVIRONMENT" != "WSL" ]]; then
  printf "WARNING: ALL DATA ON %s WILL BE ERASED\n" "$TARGET" > /dev/tty
  printf "Type YES to continue (case-insensitive): " > /dev/tty
  read -r confirm < /dev/tty

  shopt -s nocasematch
  if [[ "$confirm" != "YES" ]]; then
    fatal "User aborted — typed '$confirm' instead of YES."
  fi
  shopt -u nocasematch
else
  info "Skipping destructive confirmation (WSL loop mode)"
fi

START_TS=$(date +%s)

############################################################
# Update Live System (So Cloned OS Is Patched)
############################################################
#info "Applying security updates to live system"
#sudo apt-get update -y
#sudo apt-get upgrade -y
#
#info "Live system fully updated. Proceeding…"


###############################################################################
# Step 1. Partitioning (MBR - Pi Zero 2W)
###############################################################################
info "[1/13] Partitioning target..."

info "Ensuring $TARGET is not mounted or in use..."
# Force unmount all partitions
for part in $(lsblk -ln -o NAME "/dev/$(basename "$TARGET")" | tail -n +2); do
    sudo umount -f "/dev/$part" 2>/dev/null || true
done

# Kill processes locking the device
sudo fuser -km "$TARGET" 2>/dev/null || true
sleep 1

# Double-safe unmount
for p in ${TARGET}?; do
    sudo umount -f "$p" 2>/dev/null || true
done


# Delete all partitions on the target card
info "Wiping filesystem signatures..."
sudo wipefs -a "$TARGET"
sudo parted -s "$TARGET" mklabel msdos

# p1 boot (FAT32)
info "Creating 257MB FAT32 Boot partition"
sudo parted -s "$TARGET" mkpart primary fat32 1MiB 257MiB
sudo parted -s "$TARGET" set 1 boot on

# p2 rootA
info "Creating 6GB EXT4 rootA partition"
sudo parted -s "$TARGET" mkpart primary ext4 257MiB 6GiB

# p3 rootB
info "Creating 6GB EXT4 rootB partition"
sudo parted -s "$TARGET" mkpart primary ext4 6GiB 11900MiB

# p4 data
info "Creating EXT4 /data partition (rest of space)"
sudo parted -s "$TARGET" mkpart primary ext4 11900MiB 100%

# Inform kernel of new partition table
sudo partprobe "$TARGET" 
sudo udevadm settle
sleep 1

info "Verify partition layout (blkid)"
sudo blkid "${TARGET}"*


###############################################################################
# Step 2. Formatting
###############################################################################
info "[2/13] Formatting partitions..."

# Format the boot partition (FAT32)
sudo mkfs.vfat -F32 -n BOOT "$(part "$TARGET" 1)"

# Format the rootA partition
sudo mkfs.ext4 -i 65536 -L rootA -O ^metadata_csum,^64bit "$(part "$TARGET" 2)"

# Format the rootB partition
sudo mkfs.ext4 -i 65536 -L rootB -O ^metadata_csum,^64bit "$(part "$TARGET" 3)"

# Format the data partition (ext4, wear minimized, disable journaling)
sudo mkfs.ext4 -i 4096 -L data -O ^has_journal,^metadata_csum,^64bit "$(part "$TARGET" 4)"

# Verify (should NOT see has_journal)
sudo tune2fs -l "$(part "$TARGET" 4)" | grep 'Filesystem features'
sync


###############################################################################
# Step 3. Mounting
###############################################################################
info "[3/13] Mounting partitions..."
# Unmount partitions
sudo mount "$(part "$TARGET" 1)" "$BOOT_MNT" || fatal "BOOT mount failed"
sudo mount "$(part "$TARGET" 2)" "$ROOTA_MNT" || fatal "rootA mount failed"
sudo mount "$(part "$TARGET" 3)" "$ROOTB_MNT" || fatal "rootB mount failed"
sudo mount "$(part "$TARGET" 4)" "$DATA_MNT" || fatal "data mount failed"

# ✅ CRITICAL: VERIFY each mount explicitly
mount | grep "$(part "$TARGET" 1)" || fatal "BOOT not mounted"
mount | grep "$(part "$TARGET" 2)" || fatal "rootA not mounted"
mount | grep "$(part "$TARGET" 3)" || fatal "rootB not mounted"
mount | grep "$(part "$TARGET" 4)" || fatal "data not mounted"

# ✅ DEBUG visibility
info "Mounted partitions:"
mount | grep "$TARGET"


###############################################################################
# Step 4. Safe root clone (one filesystem)
# Create a static image of the current build system into a temporary location.
# This needs to be done because trying to make a squashfs image of a changing 
# system will fail
###############################################################################
info "[4/13] Cloning system → BUILD_ROOT..."
BUILD_ROOT="$HOME/root_build"

# if the script is running on the WSL, fake a file system.  Otherwise, create the file system (pi only)
if [[ "$STUB_MODE" == "1" ]]; then
  info "[4/13] Creating minimal stub rootfs..."
  create_stub_rootfs "$BUILD_ROOT"
else
  # This is the Pi build system
  sudo rm -rf "$BUILD_ROOT"
  mkdir -p "$BUILD_ROOT"
  info "Checking available space for BUILD_ROOT..."
  df -h "$BUILD_ROOT"
  info "Cloning live system (controlled snapshot)..."
  sudo rsync -aHAXx --numeric-ids \
    --one-file-system \
    \
    --exclude=/dev/* \
    --exclude=/proc/* \
    --exclude=/sys/* \
    --exclude=/tmp/* \
    --exclude=/run/* \
    --exclude=/mnt/* \
    --exclude=/media/* \
    --exclude=/boot/* \
    --exclude=/home/* \
    --exclude=/usr/src/* \
    \
    --exclude=/var/log/* \
    --exclude=/var/tmp/* \
    --exclude=/var/cache/* \
    --exclude=/var/lib/apt/* \
    --exclude=/var/lib/dpkg/* \
    --exclude=/var/lib/systemd/random-seed \
    --exclude=/etc/letsencrypt/accounts/* \
    --exclude=/etc/letsencrypt/archive/* \
    --exclude=/etc/letsencrypt/live/* \
    --exclude=/etc/apache2/ssl/server.key \
    \
    --exclude=/lost+found \
    --exclude=/data/* \
    \
    /. "$BUILD_ROOT"
  
  sync
  
  # ✅ Sanity check
  [ -d "$BUILD_ROOT/etc" ] || fatal "BUILD_ROOT missing /etc after rsync"
  info "BUILD_ROOT size (uncompressed):"
  sudo du -sh "$BUILD_ROOT"
fi

# Ensure /home and the user home mountpoint exist in root.
sudo mkdir -p "$BUILD_ROOT/home"
sudo mkdir -p "$BUILD_ROOT/home/$REALUSER"
sudo chmod 755 "$BUILD_ROOT/home"
sudo chmod 755 "$BUILD_ROOT/home/$REALUSER"
sync

# Remove the machine-id so that there aren't duplicates on the cloned image
info "Removing machine-id, SSH host keys, and unnecessary directories so devices generate their own…"
sudo rm -f "$BUILD_ROOT"/etc/machine-id
sudo touch "$BUILD_ROOT"/etc/machine-id
sudo rm -f "$BUILD_ROOT"/etc/ssh/ssh_host_*
sudo rm -rf "$BUILD_ROOT"/var/lib/apt/lists/*

# Verify that the files copied (you should see things such as: bin boot etc lib lib64 sbin usr var)
ls "$BUILD_ROOT" | head

# Check for critical files: (all should report OK)
for f in \
  "$BUILD_ROOT"/sbin/init \
  "$BUILD_ROOT"/usr/bin/bash \
  "$BUILD_ROOT"/usr/bin/systemctl \
  "$BUILD_ROOT"/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3
do
  if [ -e "$f" ]; then
    echo "OK: $f"
  else
    fatal "MISSING: $f"
  fi
done

###############################################################################
# Make sure that we are good size-wise (tells us roughly how big the squashfs image will be)
# Typical expectations:
#   Live root: ~7-10GB
#   GZIP SquashFS: ~2.5-4GB
# Should fit comfortably in the 6GB root partitions.
###############################################################################
sudo du -sh "$BUILD_ROOT"

###############################################################################
# Install recon-field kernel modules into rootA (ARTIFACT-BASED, NO BUILD)
###############################################################################
info "Removing existing kernel modules from cloned rootA..."
sudo rm -rf "$BUILD_ROOT/lib/modules"

info "Installing recon-field kernel modules into BUILD_ROOT..."

# Determine kernel version from module artifact
#EXPECTED_KVER=$(basename "$(ls -d "$HOME/kernel_artifacts/modules-"*)" | sed 's/modules-//')
EXPECTED_KVER=$(ls -d "$HOME/kernel_artifacts/modules-"* | sort -V | tail -n1 | xargs basename | sed 's/modules-//')

info "Expected kernel version: '$EXPECTED_KVER'"

# Locate module artifact
MODULES_ART="$HOME/kernel_artifacts/modules-$EXPECTED_KVER"

[[ -d "$MODULES_ART/lib/modules/$EXPECTED_KVER" ]] \
  || fatal "Missing module artifact: $MODULES_ART"

# Install modules into rootA
sudo mkdir -p "$BUILD_ROOT/lib/modules"
sudo cp -a "$MODULES_ART/lib/modules" "$BUILD_ROOT/lib/"
sync

###############################################################################
# Verify module installation
###############################################################################
info "Kernel modules staged into BUILD_ROOT (validation deferred to validate_sdcard.sh)"

# Resolve target UID/GID from the cloned root so seeded /data/home ownership
# always matches the account that exists inside the immutable image.
TARGET_UID="$(awk -F: -v u="$REALUSER" '$1==u{print $3; exit}' "$BUILD_ROOT/etc/passwd" 2>/dev/null || true)"
TARGET_GID="$(awk -F: -v u="$REALUSER" '$1==u{print $4; exit}' "$BUILD_ROOT/etc/passwd" 2>/dev/null || true)"
if [[ -z "$TARGET_UID" || -z "$TARGET_GID" ]]; then
  warn "User '$REALUSER' not found in cloned rootfs; falling back to host UID/GID"
  TARGET_UID="$(id -u "$REALUSER")"
  TARGET_GID="$(id -g "$REALUSER")"
fi


###############################################################################
# Step 5. Populate boot and clean BUILD_ROOT before making squashfs
# IMPORTANT:
#   - There must be ONLY ONE boot tree
#   - All firmware, kernel, DTBs live in /boot
###############################################################################
info "[5/13] Cleaning BUILD_ROOT..."

# Required placeholders
sudo mkdir -p "$BUILD_ROOT/home"
sudo mkdir -p "$BUILD_ROOT/home/$REALUSER"
sudo mkdir -p "$BUILD_ROOT/opt"
sudo chmod 755 "$BUILD_ROOT/home"
sudo chown "$TARGET_UID:$TARGET_GID" "$BUILD_ROOT/home/$REALUSER"
sudo chmod 755 "$BUILD_ROOT/home/$REALUSER"
sudo ln -sfn /data/laptopkiller "$BUILD_ROOT/opt/laptopkiller"
sudo ln -sfn /data/expander "$BUILD_ROOT/opt/expander"
sudo ln -sfn /data/logfile_xfr "$BUILD_ROOT/opt/logfile_xfr"

# Machine identity reset
sudo rm -f "$BUILD_ROOT/etc/machine-id"
sudo rm -f "$BUILD_ROOT/var/lib/dbus/machine-id"
sudo mkdir -p "$BUILD_ROOT/var/lib/dbus"
sudo systemd-machine-id-setup --root="$BUILD_ROOT" >/dev/null
sudo ln -sf /etc/machine-id "$BUILD_ROOT/var/lib/dbus/machine-id"
sudo rm -f "$BUILD_ROOT/etc/ssh/ssh_host_"*

# Pre-generate fresh SSH host keys for this image so sshd never starts without them.
# (Generating here avoids a runtime ssh-keygen -A dependency and ensures the squashfs
#  always contains valid keys.  All standard types are created.)
for _ktype in rsa ecdsa ed25519; do
  sudo ssh-keygen -t "$_ktype" -N "" \
    -f "$BUILD_ROOT/etc/ssh/ssh_host_${_ktype}_key" -C "" -q 2>/dev/null || true
done
unset _ktype

# Remove stale crash dumps and transient diagnostics from the immutable payload.
sudo find "$BUILD_ROOT" -type f -name 'core.*' -delete 2>/dev/null || true

# Remove runtime junk defensively
sudo rm -rf "$BUILD_ROOT/var/log/"*
sudo rm -rf "$BUILD_ROOT/var/tmp/"*
sudo rm -rf "$BUILD_ROOT/var/cache/"*
sudo rm -rf "$BUILD_ROOT/tmp"
sudo mkdir -p "$BUILD_ROOT/tmp"
sudo chmod 1777 "$BUILD_ROOT/tmp"

# Remove host-bound certificate/key material that should not ship in immutable images.
sudo rm -rf "$BUILD_ROOT/etc/letsencrypt/accounts" \
            "$BUILD_ROOT/etc/letsencrypt/archive" \
            "$BUILD_ROOT/etc/letsencrypt/live"
sudo rm -f "$BUILD_ROOT/etc/apache2/ssl/server.key"
sync

###############################################################################
# Populate boot partition (BASE COPY FIRST)
###############################################################################
info "[BOOT] Populating boot partition from host /boot..."
if [[ -d /boot ]]; then
  sudo rsync -a --delete --copy-links --exclude 'firmware/' --exclude 'issue.txt' /boot/ "$BOOT_MNT/"
else
  warn "Host /boot not found; creating minimal boot tree"
  sudo rm -rf "$BOOT_MNT"/*
fi
sync

###############################################################################
# Install REQUIRED firmware files (MUST be AFTER rsync)
###############################################################################
info "[BOOT] Installing Raspberry Pi firmware files..."

FIRMWARE_SRC=""
for candidate in /boot/firmware /boot; do
  if [[ -f "$candidate/start.elf" && -f "$candidate/fixup.dat" && -d "$candidate/overlays" ]]; then
    FIRMWARE_SRC="$candidate"
    break
  fi
done

if [[ -z "$FIRMWARE_SRC" ]]; then
  if [[ "$STUB_MODE" == "1" ]]; then
    warn "Firmware files not found on host in WSL stub mode; continuing with stub boot config"
    create_stub_boot
  else
    fatal "Missing Raspberry Pi firmware files (start.elf/fixup.dat/overlays)"
  fi
else
  sudo cp "$FIRMWARE_SRC/start.elf" "$BOOT_MNT/"
  sudo cp "$FIRMWARE_SRC/fixup.dat" "$BOOT_MNT/"

  # Optional but safe for Zero / compatibility
  if [[ -f "$FIRMWARE_SRC/bootcode.bin" ]]; then
      sudo cp "$FIRMWARE_SRC/bootcode.bin" "$BOOT_MNT/"
  fi

  # Overlays (required)
  sudo cp -r "$FIRMWARE_SRC/overlays" "$BOOT_MNT/"
fi

###############################################################################
# Install kernel (deterministic)
###############################################################################
info "[BOOT] Installing kernel..."
sudo cp "$LATEST_KERNEL" "$BOOT_MNT/kernel7.img"

###############################################################################
# Enforce minimal, known-good config.txt
###############################################################################
info "[BOOT] Writing minimal config.txt..."
sudo tee "$BOOT_MNT/config.txt" > /dev/null << 'EOF'
kernel=kernel7.img
arm_64bit=0
enable_uart=1
dtoverlay=dwc2
EOF

###############################################################################
# CLEAN boot partition (remove junk that breaks firmware)
###############################################################################
info "[BOOT] Cleaning unnecessary files..."
sudo rm -f "$BOOT_MNT"/initrd.img* \
           "$BOOT_MNT"/vmlinuz* \
           "$BOOT_MNT"/System.map-* \
           "$BOOT_MNT"/config-* \
           "$BOOT_MNT"/debug-init.sh 2>/dev/null || true

###############################################################################
# Optional debug init hook (presence-based)
###############################################################################
if [[ -f "$DEBUG_INIT_SRC" ]]; then
  info "[BOOT] Installing debug init hook from: $DEBUG_INIT_SRC"
  sudo install -m 0755 "$DEBUG_INIT_SRC" "$BOOT_MNT/debug-init.sh"
else
  info "[BOOT] No debug-init.sh found at $DEBUG_INIT_SRC, skipping"
fi

###############################################################################
# Sanity check: ensure no /boot/firmware directory leaked through
###############################################################################
if [[ -d "$BOOT_MNT/firmware" ]]; then
    fatal "Unexpected /boot/firmware detected on target – legacy layout violated"
fi

###############################################################################
# Offline-safe service hardening (no chroot/systemctl required)
###############################################################################
info "Applying offline service hardening..."
sudo mkdir -p "$BUILD_ROOT/etc/systemd/system"

# Mask services directly so they cannot start in the deployed image.
for svc in bluetooth.service rpi-resize-swapfile.service dphys-swapfile.service; do
  sudo ln -sf /dev/null "$BUILD_ROOT/etc/systemd/system/$svc"
done

# Disable swap activation path for immutable SD-card deployments.
sudo ln -sf /dev/null "$BUILD_ROOT/etc/systemd/system/swap.target"

# Remove explicit enablement links if present.
sudo rm -f "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/bluetooth.service"
sudo rm -f "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/rpi-resize-swapfile.service"
sudo rm -f "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/dphys-swapfile.service"

# If avahi was masked in source image state, unmask it so it can start.
if [[ -L "$BUILD_ROOT/etc/systemd/system/avahi-daemon.service" ]]; then
  if [[ "$(sudo readlink "$BUILD_ROOT/etc/systemd/system/avahi-daemon.service" 2>/dev/null || true)" == "/dev/null" ]]; then
    sudo rm -f "$BUILD_ROOT/etc/systemd/system/avahi-daemon.service"
  fi
fi

# Ensure sshd runtime directory exists on each boot (common failure cause).
sudo mkdir -p "$BUILD_ROOT/etc/tmpfiles.d"
cat <<'EOF' | sudo tee "$BUILD_ROOT/etc/tmpfiles.d/sshd.conf" > /dev/null
d /run/sshd 0755 root root -
EOF

# Ensure /run/sshd exists before sshd starts (systemd RuntimeDirectory should handle
# this, but an explicit ExecStartPre is belt-and-suspenders for older Pi OS images).
sudo mkdir -p "$BUILD_ROOT/etc/systemd/system/ssh.service.d"
cat <<'EOF' | sudo tee "$BUILD_ROOT/etc/systemd/system/ssh.service.d/override.conf" > /dev/null
[Service]
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
ExecStartPre=/usr/bin/install -d -m 0755 /run/sshd
EOF

# Ensure ssh is enabled unless explicitly removed by user image policy.
sudo mkdir -p "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants"
if [[ -f "$BUILD_ROOT/lib/systemd/system/ssh.service" ]]; then
  sudo ln -sfn /lib/systemd/system/ssh.service \
    "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/ssh.service"
elif [[ -f "$BUILD_ROOT/usr/lib/systemd/system/ssh.service" ]]; then
  sudo ln -sfn /usr/lib/systemd/system/ssh.service \
    "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/ssh.service"
fi

# Keep SSH enabled on hardened images (do not gate via /boot/ssh marker).
sudo rm -f "$BUILD_ROOT/etc/ssh/sshd_not_to_be_run"
sudo ln -sfn /dev/null "$BUILD_ROOT/etc/systemd/system/sshswitch.service"
sudo rm -f "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/sshswitch.service"

if [[ -L "$BUILD_ROOT/etc/systemd/system/ssh.service" ]]; then
  if [[ "$(sudo readlink "$BUILD_ROOT/etc/systemd/system/ssh.service" 2>/dev/null || true)" == "/dev/null" ]]; then
    sudo rm -f "$BUILD_ROOT/etc/systemd/system/ssh.service"
  fi
fi

# If Apache SSL key is intentionally removed, disable only the SSL site so
# apache2 can still start for HTTP workloads.
if [[ ! -f "$BUILD_ROOT/etc/apache2/ssl/server.key" ]]; then
  sudo rm -f "$BUILD_ROOT/etc/apache2/sites-enabled/default-ssl.conf"
fi

# Ensure Apache does not listen on 443 when SSL is disabled.
if [[ -f "$BUILD_ROOT/etc/apache2/ports.conf" ]]; then
  sudo sed -i '/^[[:space:]]*Listen[[:space:]]\+443[[:space:]]*$/d' \
    "$BUILD_ROOT/etc/apache2/ports.conf"
fi

# networks.py writes scan logs here; create it for CGI runtime.
sudo mkdir -p "$BUILD_ROOT/var/log/recon"
sudo chown 33:33 "$BUILD_ROOT/var/log/recon" || true
sudo chmod 0755 "$BUILD_ROOT/var/log/recon"

# Install Wi-Fi scan CGI script from this workspace into the image.
NETWORKS_PY_SRC="$REALHOME/sys_tools/networks.py"
if [[ -f "$NETWORKS_PY_SRC" ]]; then
  sudo mkdir -p "$BUILD_ROOT/usr/lib/cgi-bin"
  sudo install -m 0755 "$NETWORKS_PY_SRC" "$BUILD_ROOT/usr/lib/cgi-bin/networks.py"
else
  warn "Missing networks.py source in workspace: $NETWORKS_PY_SRC"
fi

# Install Wi-Fi connect CGI script from this workspace into the image.
CONNECT_PY_SRC="$REALHOME/sys_tools/connect.py"
if [[ -f "$CONNECT_PY_SRC" ]]; then
  sudo mkdir -p "$BUILD_ROOT/usr/lib/cgi-bin"
  sudo install -m 0755 "$CONNECT_PY_SRC" "$BUILD_ROOT/usr/lib/cgi-bin/connect.py"
else
  warn "Missing connect.py source in workspace: $CONNECT_PY_SRC"
fi

# Allow Apache CGI (www-data) to run iw for AP-mode scanning.
cat <<'EOF' | sudo tee "$BUILD_ROOT/etc/sudoers.d/www-data-iw" > /dev/null
www-data ALL=(root) NOPASSWD: /usr/sbin/iw, /usr/bin/iw
EOF
sudo chmod 0440 "$BUILD_ROOT/etc/sudoers.d/www-data-iw"

# Normalize Laptop Killer service to the /opt -> /data app layout and ensure
# it is enabled in the image when the unit exists.
for lk_unit in laptop_killer.service laptopkiller.service; do
  LK_UNIT_PATH="$BUILD_ROOT/etc/systemd/system/$lk_unit"
  if [[ -f "$LK_UNIT_PATH" ]]; then
    info "Normalizing $lk_unit paths to /opt/laptopkiller"
    sudo sed -i \
      -e 's#^ExecStart=.*#ExecStart=/opt/laptopkiller/runtime/bin/laptop_killer#' \
      -e 's#^WorkingDirectory=.*#WorkingDirectory=/opt/laptopkiller/runtime#' \
      -e 's#^EnvironmentFile=.*#EnvironmentFile=-/opt/laptopkiller/laptop_killer.env#' \
      "$LK_UNIT_PATH"

    sudo mkdir -p "$BUILD_ROOT/etc/systemd/system/$lk_unit.d"
    cat <<'EOF' | sudo tee "$BUILD_ROOT/etc/systemd/system/$lk_unit.d/override.conf" > /dev/null
[Unit]
RequiresMountsFor=/data/laptopkiller /opt/laptopkiller
Wants=network-online.target
After=data.mount network-online.target

[Service]
WorkingDirectory=/opt/laptopkiller/runtime
ExecStart=
ExecStart=/opt/laptopkiller/runtime/bin/laptop_killer
EnvironmentFile=-/opt/laptopkiller/laptop_killer.env
StandardOutput=journal
StandardError=journal
EOF

    sudo mkdir -p "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants"
    sudo ln -sfn "/etc/systemd/system/$lk_unit" \
      "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/$lk_unit"
  fi
done

sync

###############################################################################
# Verify boot partition contents
###############################################################################
info "Verifying boot partition contents (legacy layout)..."
ls -lh "$BOOT_MNT"

###############################################################################
# Capture PARTUUIDs (used later)
###############################################################################
info "Partition PARTUUIDs:"
blkid "$(part "$TARGET" 1)"
blkid "$(part "$TARGET" 2)"
blkid "$(part "$TARGET" 3)"
blkid "$(part "$TARGET" 4)"

###############################################################################
# No chroot mounts were used for hardening.
###############################################################################

# NOTE: root= and initramfs parameters will be replaced for squashfs+overlay boot


###############################################################################
# Stage immutable runtime files in BUILD_ROOT BEFORE SquashFS creation
###############################################################################
info "Staging immutable runtime files in BUILD_ROOT..."

cat <<EOF | sudo tee "$BUILD_ROOT/etc/fstab" > /dev/null
#--------------------------------------------------
# Immutable SquashFS system — fstab
# Root (/) is mounted by initramfs
#--------------------------------------------------

proc            /proc           proc    nosuid,nodev,noexec          0 0
sysfs           /sys            sysfs   nosuid,nodev,noexec          0 0
devpts          /dev/pts        devpts  gid=5,mode=620              0 0
tmpfs           /tmp            tmpfs   nosuid,nodev                 0 0

LABEL=BOOT      /boot           vfat    ro,nofail,nosuid,nodev,noexec  0 0
LABEL=data      /data           ext4    rw,nofail,noatime            0 0
/data/home      /home           none    bind,nofail,x-systemd.requires-mounts-for=/data/home,x-systemd.after=data.mount  0 0
EOF

USB_GADGET_UUID="$(cat /proc/sys/kernel/random/uuid)"
sudo mkdir -p "$BUILD_ROOT/etc/NetworkManager/system-connections"
cat <<EOF | sudo tee "$BUILD_ROOT/etc/NetworkManager/system-connections/usb-gadget.nmconnection" > /dev/null
[connection]
id=usb-gadget
uuid=$USB_GADGET_UUID
type=ethernet
interface-name=usb0
autoconnect=true

[ethernet]

[ipv4]
address1=192.168.7.1/24
method=shared

[ipv6]
method=disabled

[proxy]
EOF
sudo chmod 600 "$BUILD_ROOT/etc/NetworkManager/system-connections/usb-gadget.nmconnection"

sudo install -d -m 0755 "$BUILD_ROOT/usr/local/sbin"
cat <<'EOF' | sudo tee "$BUILD_ROOT/usr/local/sbin/apply-usb-mode.sh" > /dev/null
#!/bin/sh
set -eu

USB_MODE_CONF="/boot/usb-mode.conf"
USB_MODE="host"
GADGET_DIR="/sys/kernel/config/usb_gadget/recon_g1"

if [ -f "$USB_MODE_CONF" ]; then
  USB_MODE="$(sed -n 's/^[[:space:]]*MODE[[:space:]]*=[[:space:]]*//p' "$USB_MODE_CONF" | head -n1 | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
fi

case "$USB_MODE" in
  ""|host)
    USB_MODE="host"
    ;;
  gadget)
    ;;
  *)
    logger -t apply-usb-mode "Unknown MODE='$USB_MODE'; defaulting to host"
    USB_MODE="host"
    ;;
esac

cleanup_configfs_gadget() {
  [ -d "$GADGET_DIR" ] || return 0

  if [ -f "$GADGET_DIR/UDC" ]; then
    echo "" > "$GADGET_DIR/UDC" 2>/dev/null || true
  fi

  rm -f "$GADGET_DIR/configs/c.1/rndis.usb0" 2>/dev/null || true
  rm -f "$GADGET_DIR/os_desc/c.1" 2>/dev/null || true
  rmdir "$GADGET_DIR/functions/rndis.usb0" 2>/dev/null || true
  rmdir "$GADGET_DIR/configs/c.1/strings/0x409" 2>/dev/null || true
  rmdir "$GADGET_DIR/configs/c.1" 2>/dev/null || true
  rmdir "$GADGET_DIR/strings/0x409" 2>/dev/null || true
  rmdir "$GADGET_DIR/os_desc" 2>/dev/null || true
  rmdir "$GADGET_DIR" 2>/dev/null || true
}

setup_rndis_configfs_gadget() {
  modprobe libcomposite >/dev/null 2>&1 || {
    logger -t apply-usb-mode "Failed to load libcomposite"
    return 1
  }

  mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

  mkdir -p "$GADGET_DIR"

  echo 0x1d6b > "$GADGET_DIR/idVendor"
  echo 0x0104 > "$GADGET_DIR/idProduct"
  echo 0x0100 > "$GADGET_DIR/bcdDevice"
  echo 0x0200 > "$GADGET_DIR/bcdUSB"
  echo 0xEF > "$GADGET_DIR/bDeviceClass"
  echo 0x02 > "$GADGET_DIR/bDeviceSubClass"
  echo 0x01 > "$GADGET_DIR/bDeviceProtocol"

  mkdir -p "$GADGET_DIR/strings/0x409"
  if [ -r /etc/machine-id ]; then
    MID="$(cat /etc/machine-id | tr -d '\n' | cut -c1-12)"
  else
    MID="recon00000000"
  fi
  echo "$MID" > "$GADGET_DIR/strings/0x409/serialnumber"
  echo "Recon Field" > "$GADGET_DIR/strings/0x409/manufacturer"
  echo "Recon USB Ethernet" > "$GADGET_DIR/strings/0x409/product"

  mkdir -p "$GADGET_DIR/configs/c.1/strings/0x409"
  echo "RNDIS" > "$GADGET_DIR/configs/c.1/strings/0x409/configuration"
  echo 250 > "$GADGET_DIR/configs/c.1/MaxPower"

  mkdir -p "$GADGET_DIR/functions/rndis.usb0"
  echo "02:00:00:00:00:01" > "$GADGET_DIR/functions/rndis.usb0/host_addr"
  echo "02:00:00:00:00:02" > "$GADGET_DIR/functions/rndis.usb0/dev_addr"

  mkdir -p "$GADGET_DIR/os_desc"
  echo 1 > "$GADGET_DIR/os_desc/use"
  echo 0xcd > "$GADGET_DIR/os_desc/b_vendor_code"
  echo MSFT100 > "$GADGET_DIR/os_desc/qw_sign"
  mkdir -p "$GADGET_DIR/functions/rndis.usb0/os_desc/interface.rndis"
  echo RNDIS > "$GADGET_DIR/functions/rndis.usb0/os_desc/interface.rndis/compatible_id"
  echo 5162001 > "$GADGET_DIR/functions/rndis.usb0/os_desc/interface.rndis/sub_compatible_id"

  ln -s "$GADGET_DIR/functions/rndis.usb0" "$GADGET_DIR/configs/c.1/rndis.usb0"
  ln -s "$GADGET_DIR/configs/c.1" "$GADGET_DIR/os_desc/c.1"

  UDC_DEV="$(ls /sys/class/udc 2>/dev/null | head -n1 || true)"
  [ -n "$UDC_DEV" ] || {
    logger -t apply-usb-mode "No UDC device found"
    return 1
  }

  echo "$UDC_DEV" > "$GADGET_DIR/UDC"
  return 0
}

if [ "$USB_MODE" = "host" ]; then
  nmcli connection down usb-gadget >/dev/null 2>&1 || true
  modprobe -r g_ether usb_f_rndis usb_f_ecm u_ether >/dev/null 2>&1 || true
  cleanup_configfs_gadget
  exit 0
fi

# Prefer explicit configfs RNDIS gadget for deterministic Windows behavior.
modprobe -r g_ether usb_f_rndis usb_f_ecm u_ether >/dev/null 2>&1 || true
cleanup_configfs_gadget

if ! setup_rndis_configfs_gadget; then
  logger -t apply-usb-mode "Failed to configure RNDIS gadget via configfs"
  exit 1
fi

nmcli connection reload >/dev/null 2>&1 || true

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ip link show usb0 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

nmcli connection up usb-gadget >/dev/null 2>&1 || true
exit 0
EOF
sudo chmod 755 "$BUILD_ROOT/usr/local/sbin/apply-usb-mode.sh"

cat <<'EOF' | sudo tee "$BUILD_ROOT/usr/local/sbin/log-usb-gadget-state.sh" > /dev/null
#!/bin/sh
set -eu

LOG_DIR="/data/diagnostics"
LOG_FILE="$LOG_DIR/usb-gadget.log"

mkdir -p "$LOG_DIR"

{
  echo "============================================================"
  echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S %z')"

  if ls /sys/class/udc/*/state >/dev/null 2>&1; then
    echo "udc_state:"
    cat /sys/class/udc/*/state
  else
    echo "udc_state: unavailable"
  fi

  echo "lsmod (dwc2/g_ether/rndis):"
  lsmod | grep -E 'dwc2|g_ether|u_ether|usb_f_rndis|libcomposite' || true

  echo "usb0 link:"
  ip -br link show usb0 2>/dev/null || echo "usb0 missing"

  echo "usb0 ipv4:"
  ip -4 addr show usb0 2>/dev/null || true

  echo "nm active connections:"
  nmcli -t -f NAME,DEVICE,TYPE,ACTIVE con show 2>/dev/null || true

  echo "recent dmesg (dwc2/g_ether/rndis/usb0):"
  dmesg | grep -Ei 'dwc2|g_ether|rndis|usb0|udc' | tail -n 40 || true
} >> "$LOG_FILE"

exit 0
EOF
sudo chmod 755 "$BUILD_ROOT/usr/local/sbin/log-usb-gadget-state.sh"

sudo mkdir -p "$BUILD_ROOT/etc/systemd/system"
sudo mkdir -p "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants"

cat <<'EOF' | sudo tee "$BUILD_ROOT/etc/systemd/system/mark-slot-good.service" > /dev/null
[Unit]
Description=Mark boot slot successful
After=multi-user.target boot.mount
Wants=boot.mount
ConditionPathExists=/boot/slot.active

[Service]
Type=oneshot
ExecStart=-/boot/mark-slot-good.sh

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' | sudo tee "$BUILD_ROOT/etc/systemd/system/apply-usb-mode.service" > /dev/null
[Unit]
Description=Apply USB OTG mode from /boot/usb-mode.conf
After=boot.mount NetworkManager.service
Wants=boot.mount NetworkManager.service
ConditionPathExists=/boot

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/apply-usb-mode.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat <<'EOF' | sudo tee "$BUILD_ROOT/etc/systemd/system/log-usb-gadget-state.service" > /dev/null
[Unit]
Description=Log USB gadget diagnostics to /data/diagnostics
After=data.mount apply-usb-mode.service NetworkManager.service
Wants=data.mount apply-usb-mode.service NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/log-usb-gadget-state.sh

[Install]
WantedBy=multi-user.target
EOF

sudo ln -sf \
  /etc/systemd/system/mark-slot-good.service \
  "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/mark-slot-good.service"
sudo ln -sf \
  /etc/systemd/system/apply-usb-mode.service \
  "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/apply-usb-mode.service"
sudo ln -sf \
  /etc/systemd/system/log-usb-gadget-state.service \
  "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/log-usb-gadget-state.service"

# Sanitize credential-bearing network files copied from the build host.
if sudo test -d "$BUILD_ROOT/etc/NetworkManager/system-connections"; then
  info "Sanitizing NetworkManager connection secrets..."
  while IFS= read -r -d '' nm_file; do
    sudo sed -i -E '/^[[:space:]]*(psk|password|sae-password|wep-key[0-9]*|leap-password|private-key-password)=/d' "$nm_file"
    sudo chmod 600 "$nm_file" 2>/dev/null || true
  done < <(sudo find "$BUILD_ROOT/etc/NetworkManager/system-connections" -type f -print0 2>/dev/null)
fi

for ppp_file in "$BUILD_ROOT/etc/ppp/pap-secrets" "$BUILD_ROOT/etc/ppp/chap-secrets"; do
  if sudo test -f "$ppp_file"; then
    info "Sanitizing $(basename "$ppp_file")..."
    # Keep comments/blank lines only; drop credential rows.
    sudo sed -i '/^[[:space:]]*#/!{/^[[:space:]]*$/!d;}' "$ppp_file"
  fi
done

# Build-time hygiene gate for sensitive material that should not ship in
# immutable production images.
if sudo find "$BUILD_ROOT/etc/letsencrypt/accounts" -type f -name 'private_key.json' -print -quit 2>/dev/null | grep -q .; then
  fatal "Sensitive Let's Encrypt account keys found in BUILD_ROOT"
fi

if sudo test -s "$BUILD_ROOT/etc/apache2/ssl/server.key"; then
  fatal "Sensitive TLS private key found at /etc/apache2/ssl/server.key"
fi

if sudo grep -RqsE '(^|[[:space:]])(psk|password)=' "$BUILD_ROOT/etc/NetworkManager/system-connections" 2>/dev/null; then
  fatal "NetworkManager credentials found in system-connections"
fi

for secret_file in "$BUILD_ROOT/etc/ppp/pap-secrets" "$BUILD_ROOT/etc/ppp/chap-secrets"; do
  if sudo test -f "$secret_file" && sudo awk '!/^[[:space:]]*($|#)/ {print; exit 0} END {exit 1}' "$secret_file" >/dev/null 2>&1; then
    fatal "PPP credentials present in $(basename "$secret_file")"
  fi
done

if ! sudo test -s "$BUILD_ROOT/etc/machine-id"; then
  fatal "/etc/machine-id was not generated in BUILD_ROOT"
fi

sync


###############################################################################
# Step 6. Build squashfs from BUILD_ROOT and then Overlay directory 
# preparation (NO firmware copy here)
###############################################################################
info "[6/13] Creating squashfs image..."

SQUASH_DIR="$DATA_MNT/squashfs"
SQUASH_IMG="$SQUASH_DIR/rootA.squashfs"

sudo mkdir -p "$SQUASH_DIR"
sudo rm -f "$SQUASH_IMG"

# Make the squashfs image
sudo mksquashfs "$BUILD_ROOT" "$SQUASH_IMG" -comp xz -b 1M -noappend
sync

# Verify
[ -f "$SQUASH_IMG" ] || fatal "SquashFS image not created"

info "SquashFS size (sould be ~2-4GB):"
ls -lh "$SQUASH_IMG"

# Check key directories in the squashfs image
unsquashfs -l "$SQUASH_IMG" | grep -E 'sbin/init|usr/bin/bash|etc/' || fatal "SquashFS validation failed"

info "Create overlay directory structure..."
# Prepare /data mount (persistent overlay storage)
# Create A/B specific overlay directories
sudo mkdir -p "$DATA_MNT"/overlay/A/upper "$DATA_MNT"/overlay/A/work
sudo mkdir -p "$DATA_MNT"/overlay/B/upper "$DATA_MNT"/overlay/B/work

# Set safe permissions
sudo chmod 755 "$DATA_MNT"/overlay
sudo chmod 755 "$DATA_MNT"/overlay/A/upper "$DATA_MNT"/overlay/B/upper 2>/dev/null || true
sudo chmod 700 "$DATA_MNT"/overlay/A/work "$DATA_MNT"/overlay/B/work 2>/dev/null || true

info "Overlay directory structure created:"
info "  $DATA_MNT/overlay/A/{upper,work}"
info "  $DATA_MNT/overlay/B/{upper,work}"

sudo mkdir -p "$DATA_MNT/home/$REALUSER"
sudo chmod 755 "$DATA_MNT" "$DATA_MNT/home" "$DATA_MNT/home/$REALUSER"

###############################################################################
# Seed /home/$REALUSER into /data
###############################################################################
info "Seeding /home/$REALUSER into /data..."
sudo install -d -m 0755 -o "$TARGET_UID" -g "$TARGET_GID" "$DATA_MNT/home/$REALUSER"

if [[ "$STUB_MODE" == "1" ]]; then
    create_stub_home
else
  seed_home_content "$DATA_MNT/home/$REALUSER"

  sudo chown -R "$TARGET_UID:$TARGET_GID" "$DATA_MNT/home/$REALUSER"
  sudo find "$DATA_MNT/home/$REALUSER" -type d -exec chmod 755 {} +
  sudo chmod 755 "$DATA_MNT" "$DATA_MNT/home" "$DATA_MNT/home/$REALUSER"
fi

info "Runtime home path permissions on data partition:"
sudo stat -c '%A %u:%g %n' "$DATA_MNT" "$DATA_MNT/home" "$DATA_MNT/home/$REALUSER"
info "Runtime home mountpoint permissions in BUILD_ROOT:"
sudo stat -c '%A %u:%g %n' "$BUILD_ROOT/home" "$BUILD_ROOT/home/$REALUSER"

###############################################################################
# Seed Laptop Killer app into /data (single writable app location)
###############################################################################
info "Seeding Laptop Killer app into /data/laptopkiller..."
sudo mkdir -p "$DATA_MNT/laptopkiller"

if [[ "$STUB_MODE" == "1" ]]; then
  warn "WSL stub mode: creating minimal /data/laptopkiller placeholder"
  echo "stub-laptopkiller" | sudo tee "$DATA_MNT/laptopkiller/README.txt" >/dev/null
else
  if [[ -d "$LAPTOPKILLER_SRC" ]]; then
    sudo rsync -aHx --numeric-ids --delete \
      --exclude="runtime/logs/*" \
      "$LAPTOPKILLER_SRC/" "$DATA_MNT/laptopkiller/"
  else
    warn "Laptop Killer source not found, skipping app seed: $LAPTOPKILLER_SRC"
  fi
fi

sudo mkdir -p "$DATA_MNT/laptopkiller/runtime/logs/Archive" "$DATA_MNT/laptopkiller/runtime/logs/xfer"

info "Cleaning Laptop Killer runtime logs (preserve Archive/ and xfer/ directories)..."
# Remove everything directly under runtime/logs except Archive and xfer directories.
sudo find "$DATA_MNT/laptopkiller/runtime/logs" -mindepth 1 -maxdepth 1 \
  ! -name Archive ! -name xfer -exec rm -rf {} +
# Clean contents inside Archive and xfer while keeping the directories.
sudo find "$DATA_MNT/laptopkiller/runtime/logs/Archive" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true
sudo find "$DATA_MNT/laptopkiller/runtime/logs/xfer" -mindepth 1 -exec rm -rf {} + 2>/dev/null || true

sudo chown -R "$TARGET_UID:$TARGET_GID" "$DATA_MNT/laptopkiller"
sudo find "$DATA_MNT/laptopkiller" -type d -exec chmod 755 {} +
sudo chmod 755 "$DATA_MNT/laptopkiller/runtime" "$DATA_MNT/laptopkiller/runtime/logs" \
  "$DATA_MNT/laptopkiller/runtime/logs/Archive" "$DATA_MNT/laptopkiller/runtime/logs/xfer" 2>/dev/null || true

info "Laptop Killer app path permissions on data partition:"
sudo stat -c '%A %u:%g %n' "$DATA_MNT/laptopkiller" "$DATA_MNT/laptopkiller/runtime" "$DATA_MNT/laptopkiller/runtime/logs" 2>/dev/null || true

###############################################################################
# Seed Expander app runtime into /data
###############################################################################
info "Seeding Expander app into /data/expander..."
sudo mkdir -p "$DATA_MNT/expander/runtime/bin" "$DATA_MNT/expander/logs"

if [[ -f "$EXPANDER_SRC/runtime/bin/expander" ]]; then
  sudo cp -f "$EXPANDER_SRC/runtime/bin/expander" "$DATA_MNT/expander/runtime/bin/expander"
  sudo chmod 755 "$DATA_MNT/expander/runtime/bin/expander"
else
  warn "Expander runtime binary not found at $EXPANDER_SRC/runtime/bin/expander"
fi

sudo chown -R "$TARGET_UID:$TARGET_GID" "$DATA_MNT/expander"
sudo find "$DATA_MNT/expander" -type d -exec chmod 755 {} +
sudo chmod 755 "$DATA_MNT/expander/runtime" "$DATA_MNT/expander/runtime/bin" "$DATA_MNT/expander/logs" 2>/dev/null || true

###############################################################################
# Seed LogFileXfr app runtime into /data
###############################################################################
info "Seeding LogFileXfr app into /data/logfile_xfr..."
sudo mkdir -p "$DATA_MNT/logfile_xfr/runtime/bin" "$DATA_MNT/logfile_xfr/logs"

if [[ -f "$LOGFILE_XFR_SRC/runtime/bin/logfile_xfr" ]]; then
  sudo cp -f "$LOGFILE_XFR_SRC/runtime/bin/logfile_xfr" "$DATA_MNT/logfile_xfr/runtime/bin/logfile_xfr"
  sudo chmod 755 "$DATA_MNT/logfile_xfr/runtime/bin/logfile_xfr"
else
  warn "LogFileXfr runtime binary not found at $LOGFILE_XFR_SRC/runtime/bin/logfile_xfr"
fi

sudo chown -R "$TARGET_UID:$TARGET_GID" "$DATA_MNT/logfile_xfr"
sudo find "$DATA_MNT/logfile_xfr" -type d -exec chmod 755 {} +
sudo chmod 755 "$DATA_MNT/logfile_xfr/runtime" "$DATA_MNT/logfile_xfr/runtime/bin" "$DATA_MNT/logfile_xfr/logs" 2>/dev/null || true

# NOTE:
#  - Do NOT copy /boot here
#  - /boot is populated exactly ONCE in Step 5
#  - Avoid duplicate /boot trees at all costs



###############################################################################
# Step 7. Install kernel artifact (EMBEDDED INITRAMFS ONLY)
###############################################################################
info "[7/13] Installing embedded-initramfs kernel (Option A immutable boot)..."

KVER=$(ls "$BUILD_ROOT/lib/modules" | sort -V | tail -n1)
[[ -n "$KVER" ]] || fatal "No kernel modules found in rootA"

KERNEL_ART="$LATEST_KERNEL"
[[ -f "$KERNEL_ART" ]] || fatal "Missing kernel artifact"

info "Installing kernel -> /boot/kernel7.img"
sudo cp "$KERNEL_ART" "$BOOT_MNT/kernel7.img"
sudo chmod 755 "$BOOT_MNT/kernel7.img"
sync

###############################################################################
# HARD GUARANTEE: no external initramfs allowed
###############################################################################
info "Ensuring no external initramfs is referenced..."

BOOTCFG="$BOOT_MNT/config.txt"
if [[ "$STUB_MODE" == "1" ]]; then
    create_stub_boot
fi

# Remove any legacy initramfs references
sudo sed -i '/^initramfs/d' "$BOOTCFG"

# Explicitly enforce embedded initramfs mode
if ! grep -q "^auto_initramfs=0" "$BOOTCFG"; then
    echo "auto_initramfs=0" | sudo tee -a "$BOOTCFG" >/dev/null
fi

###############################################################################
# Verify selected kernel artifact still reports embedded initramfs
###############################################################################
info "Verifying selected kernel artifact reports embedded initramfs..."

TMPCFG=$(mktemp)
if ! "$EXTRACT_IKCONFIG" "$KERNEL_ART" > "$TMPCFG" 2>/dev/null; then
  rm -f "$TMPCFG"
  fatal "Failed to inspect kernel artifact config"
fi

grep -q '^CONFIG_INITRAMFS_SOURCE=".*"' "$TMPCFG" || {
  rm -f "$TMPCFG"
  fatal "Selected kernel artifact lacks embedded initramfs config"
}

rm -f "$TMPCFG"
info "Kernel artifact embedded initramfs config verified"

###############################################################################
# Step 8. Verify immutable runtime files were staged before SquashFS
###############################################################################
info "[8/13] Verifying immutable runtime files in BUILD_ROOT..."

[[ -f "$BUILD_ROOT/etc/fstab" ]] || fatal "Missing staged fstab in BUILD_ROOT"
[[ -f "$BUILD_ROOT/etc/systemd/system/mark-slot-good.service" ]] || fatal "Missing mark-slot-good.service in BUILD_ROOT"
[[ -L "$BUILD_ROOT/etc/systemd/system/multi-user.target.wants/mark-slot-good.service" ]] || fatal "mark-slot-good service not enabled in BUILD_ROOT"

info "Verify /home and /home/$REALUSER in SquashFS root"
if [ ! -d "$BUILD_ROOT/home" ]; then
  fatal "/home missing in root"
fi
[ -d "$BUILD_ROOT/home/$REALUSER" ] || fatal "/home/$REALUSER missing in BUILD_ROOT"
[ -d "$DATA_MNT/home/$REALUSER" ] || fatal "/data/home/$REALUSER missing"
[ -L "$BUILD_ROOT/opt/laptopkiller" ] || fatal "/opt/laptopkiller symlink missing in BUILD_ROOT"
[ -L "$BUILD_ROOT/opt/expander" ] || fatal "/opt/expander symlink missing in BUILD_ROOT"
[ -L "$BUILD_ROOT/opt/logfile_xfr" ] || fatal "/opt/logfile_xfr symlink missing in BUILD_ROOT"
[ -d "$DATA_MNT/laptopkiller" ] || fatal "/data/laptopkiller missing"
[ -d "$DATA_MNT/expander" ] || fatal "/data/expander missing"
[ -d "$DATA_MNT/logfile_xfr" ] || fatal "/data/logfile_xfr missing"



###############################################################################
# Step 9. Validate the squashfs image (built earlier in Step 6)
###############################################################################
info "[9/13] Verify squashfs image at $DATA_MNT/squashfs/rootA.squashfs..."

SQUASH_IMG="$DATA_MNT/squashfs/rootA.squashfs"

[[ -f "$SQUASH_IMG" ]] || fatal "SquashFS image not found at $SQUASH_IMG"

info "SquashFS image size (should be roughly 2.5 - 4GB)..."
ls -lh "$SQUASH_IMG"

###############################################################################
# Verify squashfs contents (quick structural validation)
###############################################################################
info "Checking critical files inside squashfs..."

SQUASH_LIST=$(unsquashfs -l "$SQUASH_IMG")

grep -Eq 'sbin/init|usr/bin/bash|etc/' <<< "$SQUASH_LIST" \
  || fatal "SquashFS missing critical system components"

# Ensure staged immutable runtime files are present in the artifact.
grep -Eq '(^|/)etc/fstab$' <<< "$SQUASH_LIST" \
  || fatal "SquashFS missing /etc/fstab"
grep -Eq '(^|/)etc/systemd/system/mark-slot-good.service$' <<< "$SQUASH_LIST" \
  || fatal "SquashFS missing mark-slot-good.service"
grep -Eq '(^|/)etc/systemd/system/multi-user.target.wants/mark-slot-good.service$' <<< "$SQUASH_LIST" \
  || fatal "SquashFS missing enabled mark-slot-good.service link"

###############################################################################
# Mount squashfs to validate runtime contents
###############################################################################
info "Verifying squashfs via mount..."

# Ensure mount point exists
sudo mkdir -p /mnt/testsq

# Clean up any previous mount
if sudo mountpoint -q /mnt/testsq; then
    sudo umount /mnt/testsq || fatal "Failed to unmount /mnt/testsq"
fi

# Only validate real squashfs (skip stub mode)
if [[ "$STUB_MODE" == "1" ]]; then
  info "WSL stub mode: skipping squashfs mount validation"
else
  sudo mount -t squashfs -o ro "$SQUASH_IMG" /mnt/testsq \
        || fatal "Failed to mount squashfs"

  # Check expected structure
  ls /mnt/testsq
  ls /mnt/testsq/sbin/init || fatal "init missing inside squashfs"

  # Optional: verify kernel modules location
  ls /mnt/testsq/lib/modules || warn "modules directory not found (unexpected)"

  sudo umount /mnt/testsq
fi

###############################################################################
# Optional deeper validation using loop mount
###############################################################################
info "Performing secondary squashfs validation..."

# Ensure mount point exists
sudo mkdir -p /mnt/testsq

# Clean any previous mount
if sudo mountpoint -q /mnt/testsq; then
    sudo umount /mnt/testsq || fatal "Failed to unmount /mnt/testsq"
fi

if [[ "$STUB_MODE" == "1" ]]; then
  info "WSL stub mode: skipping loop mount validation"
else
  sudo mount -o ro,loop "$SQUASH_IMG" /mnt/testsq \
      || fatal "Failed to mount squashfs via loop"

  ls /mnt/testsq/sbin/init || fatal "init missing after loop mount"

  sudo umount /mnt/testsq
fi

info "SquashFS validation complete ✅"



###############################################################################
# Step 10. Populate rootA and rootB with SquashFS image
###############################################################################
info "[10/13] Populating rootA and rootB with SquashFS image..."

# Clean any stale content
sudo rm -f "$ROOTA_MNT"/rootfs.squashfs
sudo rm -f "$ROOTB_MNT"/rootfs.squashfs

# Copy SquashFS image to both A/B partitions
sudo cp "$DATA_MNT"/squashfs/rootA.squashfs "$ROOTA_MNT"/rootfs.squashfs
sudo cp "$DATA_MNT"/squashfs/rootA.squashfs "$ROOTB_MNT"/rootfs.squashfs
sync

info "rootA/rootB populated successfully"
info "Verify ext4 filesystems..."
blkid "$(part "$TARGET" 2)"
blkid "$(part "$TARGET" 3)"

info "Verify squashfs image in rootA and rootB..."
ls -lh "$ROOTA_MNT"/rootfs.squashfs
ls -lh "$ROOTB_MNT"/rootfs.squashfs
sync


###############################################################################
# Step 11. Failover marking (boot slot state)
###############################################################################
info "[11/13] Installing failover marking script..."

sudo mkdir -p "$BOOT_MNT"

cat <<'EOF' | sudo tee "$BOOT_MNT/mark-slot-bad.sh" > /dev/null
#!/bin/sh
SLOT_FILE=/boot/slot.active

if ! mountpoint -q /boot 2>/dev/null; then
  mount /boot >/dev/null 2>&1 || exit 0
fi

mount -o remount,rw /boot || exit 0

if [ ! -f "$SLOT_FILE" ]; then
    echo "No active slot file; refusing to mark bad"
    mount -o remount,ro /boot
  exit 0
fi

SLOT=$(cat "$SLOT_FILE")
touch "/boot/slot.bad.$SLOT"
sync
mount -o remount,ro /boot
EOF

cat <<'EOF' | sudo tee "$BOOT_MNT/mark-slot-good.sh" > /dev/null
#!/bin/sh
SLOT_FILE=/boot/slot.active

if ! mountpoint -q /boot 2>/dev/null; then
  mount /boot >/dev/null 2>&1 || exit 0
fi

mount -o remount,rw /boot || exit 0

if [ ! -f "$SLOT_FILE" ]; then
    echo "No active slot file; cannot mark good"
    mount -o remount,ro /boot
  exit 0
fi

SLOT=$(cat "$SLOT_FILE")
rm -f "/boot/slot.bad.$SLOT"
echo 0 > "/boot/bootcount.$SLOT"
sync
mount -o remount,ro /boot
EOF

sudo chmod +x "$BOOT_MNT"/mark-slot-*.sh

info "Starting with slot A as the active boot slot"
echo "A" | sudo tee "$BOOT_MNT/slot.active"
sync

cat <<'EOF' | sudo tee "$BOOT_MNT/shared-etc-files.txt" > /dev/null
# Additional /etc paths to keep shared across slots.
# One entry per line, relative to /etc or absolute (/etc/...).
# Defaults (already shared even if omitted):
# hostname
# hosts

# Example:
# resolv.conf
# ssh/sshd_config
EOF
sync

cat <<'EOF' | sudo tee "$BOOT_MNT/usb-mode.conf" > /dev/null
# USB OTG data-port role.
# MODE=gadget  -> Pi appears as USB Ethernet device to a PC.
# MODE=host    -> Leave the OTG port free for an OTG hub, modem, or thumbdrive.
MODE=gadget
EOF
sync


###############################################################################
# Step 12. cmdline.txt (STRICT A/B + INITRAMFS-FIRST BOOT MODEL)
###############################################################################
info "[12/13] Writing hardened cmdline.txt..."

CMD="$BOOT_MNT/cmdline.txt"
#echo "console=tty1 root=/dev/ram0 rw rootwait loglevel=3 quiet panic=10 bootpanic=10 overlay_root=1 recon_ab=1 init=/init" | sudo tee "$CMD" > /dev/null
echo "console=tty1 root=/dev/ram0 rw rootwait loglevel=7 panic=10 bootpanic=10 overlay_root=1 recon_ab=1 modules-load=dwc2 init=/init" | sudo tee "$CMD" > /dev/null
sync

###############################################################################
# Verify single-line boot integrity (Pi firmware requirement)
###############################################################################
info "Verifying cmdline.txt format..."

LINES=$(wc -l < "$CMD")
[[ "$LINES" -eq 1 ]] || fatal "cmdline.txt must be single line (got $LINES)"

info "cmdline.txt validated for immutable boot chain"


###############################################################################
# Step 13. Final Validation (Delegate to validate_sdcard.sh)
###############################################################################
info "[13/13] Running external SD card validation..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure partitions are still mounted BEFORE validation
info "Ensuring partitions are mounted for validation..."

for part_num in 1 2 3 4; do
    DEV="$(part "$TARGET" "$part_num")"
    mount | grep -q "^$DEV " || fatal "Partition $DEV is not mounted before validation"
done

# Run validator (authoritative)
if "$SCRIPT_DIR/validate_sdcard.sh" "$TARGET"; then
    echo
    echo -e "\033[1;32m====================================================\033[0m"
    echo -e "\033[1;32m IMAGE VALIDATION PASSED\033[0m"
    echo -e "\033[1;32m====================================================\033[0m"
else
    echo
    echo -e "\033[1;31m====================================================\033[0m"
    echo -e "\033[1;31m IMAGE VALIDATION FAILED\033[0m"
    echo -e "\033[1;31m DO NOT DEPLOY THIS CARD\033[0m"
    echo -e "\033[1;31m====================================================\033[0m"
    exit 1
fi

END_TS=$(date +%s)
info "Elapsed: $((END_TS - START_TS)) seconds"
info "Elapsed: $(((END_TS - START_TS)/60)) minutes"
ELAPSED_HR=$(awk "BEGIN {printf \"%.1f\", ($END_TS - $START_TS)/3600}")
info "Elapsed: ${ELAPSED_HR} hours"
