#!/bin/bash
# ============================================================
# compile_kernel.sh
#
# PURPOSE:
#   Build a deterministic, production-ready Raspberry Pi kernel
#   with embedded initramfs and required filesystem features.
#
# DESIGN GOALS:
#   - Fully reproducible kernel builds
#   - No runtime module dependency (critical features built-in)
#   - Embedded initramfs for immutable boot pipeline
#   - Strict validation of config AND final artifact
#
# ============================================================

# Fail on:
#  - any command error (-e)
#  - undefined variables (-u)
#  - pipeline failure (-o pipefail)
# This prevents silent corruption of build artifacts.
set -euo pipefail


###############################################################################
# CONFIG SECTION
###############################################################################
# Defines:
#   - kernel source repo/branch
#   - build directories
#   - fragment locations
#   - logging and parallelism
#
# These are intentionally centralized for reproducibility and clarity.

KERNEL_REPO="https://github.com/raspberrypi/linux"
KERNEL_BRANCH="rpi-6.12.y"
KERNEL_DIR="$HOME/linux"          # kernel source location
BUILD_DIR="$HOME/linux-build"     # out-of-tree build directory
ARTIFACT_DIR="$HOME/kernel_artifacts"  # final outputs (immutable artifacts)
STATE_FILE="$BUILD_DIR/.build_state"  # persistent build state tracking
CONFIG_ROOT="$HOME/kernel_config"
FRAG_DIR="$HOME/kernel_config/kconfig/fragments"
FRAG="$FRAG_DIR/production.config"
ARCH="arm"
HOST_ARCH="$(uname -m)"

if [[ "$HOST_ARCH" == "armv7l" ]]; then
  # 32-bit ARM host building 32-bit ARM target.
  CROSS_COMPILE=""
  echo "[ENV] Native ARMv7 build"
elif [[ "$HOST_ARCH" == "aarch64" ]]; then
  # 64-bit ARM host building 32-bit ARM target.
  CROSS_COMPILE="arm-linux-gnueabihf-"
  echo "[ENV] aarch64 host, cross-compiling for ARMv7"
  echo "ARCH=$ARCH"
  echo "CROSS_COMPILE=$CROSS_COMPILE"
else
  # x86/other host building 32-bit ARM target.
  CROSS_COMPILE="arm-linux-gnueabihf-"
  echo "[ENV] Cross-compiling for ARM"
  echo "ARCH=$ARCH"
  echo "CROSS_COMPILE=$CROSS_COMPILE"
fi

export TMPDIR="$BUILD_DIR/tmp"
mkdir -p "$TMPDIR"

# Parallel build jobs (leave 1 CPU free)
JOBS=$(( $(nproc) - 1 )) 
(( JOBS < 1 )) && JOBS=1

MODE_RAW="${1:-normal}"
case "$MODE_RAW" in
  --help|-h)
    MODE="help"
    ;;
  -*)
    MODE="${MODE_RAW#-}"
    ;;
  *)
    MODE="$MODE_RAW"
    ;;
esac

# Logging setup
LOG_DIR="$HOME/kernel_build_logs"
mkdir -p "$LOG_DIR" "$BUILD_DIR" "$ARTIFACT_DIR" "$FRAG_DIR"

LOG_FILE="$LOG_DIR/kernel_$(date +%Y%m%d_%H%M%S).log"

# Redirect ALL output to both console and log file
exec > >(tee -a "$LOG_FILE") 2>&1


###############################################################################
# STATE MACHINE
###############################################################################
# The script uses a checkpoint/state system so builds can resume safely.
#
# Each step:
#   - Runs only if needed
#   - Updates state on success
#
# This makes the build:
#   ✅ resumable
#   ✅ deterministic
#   ✅ efficient

STATE_ORDER=(
  SOURCE_READY
  DEFAULT_CONFIG
  CONFIG_READY
  CONFIG_ENFORCED
  CONFIG_VERIFIED
  INITRAMFS_READY
  FINAL_BUILD
)


###############################################################################
# HELPER FUNCTIONS
###############################################################################

# Timestamped logging helper
log() { echo "[$(date '+%F %T')] $*"; }

# Read current state (or NONE if no prior run)
get_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "NONE"; }

# Persist new state
set_state() { echo "$1" > "$STATE_FILE"; }

# Decide whether a step should run
should_run_step() {
  local step="$1"
  local current="$(get_state)"

  if [[ "$MODE" == "dry-run" ]]; then
    # dry-run intentionally executes config/validation steps and skips build steps.
    case "$step" in
      DEFAULT_CONFIG|CONFIG_READY|CONFIG_ENFORCED|CONFIG_VERIFIED)
        return 0
        ;;
      INITRAMFS_READY|FINAL_BUILD)
        return 1
        ;;
    esac
  fi

  # If no prior state → run everything
  [[ "$current" == "NONE" ]] && return 0

  local step_i=-1 current_i=-1 i=0

  # Find numeric positions of step and current state
  for s in "${STATE_ORDER[@]}"; do
    [[ "$s" == "$step" ]] && step_i=$i
    [[ "$s" == "$current" ]] && current_i=$i
    ((i++))
  done

  # Unknown state → run everything (fail-safe behavior)
  [[ "$current_i" -lt 0 ]] && return 0
  [[ "$step_i" -lt 0 ]] && return 0

  # Only run if this step is AFTER current state
  (( step_i > current_i ))
}

print_help() {
  cat <<EOF

Usage:
  ./compile_kernel.sh [mode]

Modes:
  -normal (default)
      Run build using state machine (only necessary steps executed)

  -dry-run
      Run config + validation only, do not build kernel

  -rebuild-initramfs
      Rebuild from config-enforcement stage (Step 4 → Step 7)
      Use when you modify initramfs contents or boot logic

  -rebuild-all
      Reset state and rebuild everything from scratch

  -show-state
      Display current build state and exit

  -help / --help / -h
      Show this help message

Examples:
  ./compile_kernel.sh
      → normal stateful build

  ./compile_kernel.sh -rebuild-initramfs
      → rebuild enforced config, initramfs, and kernel

  ./compile_kernel.sh -rebuild-all
      → full rebuild

  ./compile_kernel.sh -show-state
      → show current state

EOF
}

# ----- Help / usage -----
if [[ "$MODE" == "help" || "$MODE" == "--help" || "$MODE" == "-h" ]]; then
  print_help
  exit 0
fi

# ----- Show state -----
if [[ "$MODE" == "show-state" ]]; then
  echo "Current state: $(get_state)"
  echo "State order: ${STATE_ORDER[*]}"
  exit 0
fi

# ----- Rebuild controls -----
if [[ "$MODE" == "rebuild-initramfs" ]]; then
  log "[Mode] Forcing rebuild from INITRAMFS step"
  # Resume at Step 4 (CONFIG_ENFORCED) on next execution.
  set_state "CONFIG_READY"
fi

if [[ "$MODE" == "rebuild-all" ]]; then
  log "[Mode] Full rebuild (clearing state)"
  rm -f "$STATE_FILE"
fi


START_TS=$(date +%s)

log "=== BUILD START ($MODE) ==="
log "STATE=$(get_state)"


###############################################################################
# STEP 1: SOURCE SYNC
#
# WHAT:
#   Clone or update kernel source tree
#
# WHY:
#   Ensures build uses latest known-good upstream state
#   while remaining deterministic (hard reset to branch head)
###############################################################################
if should_run_step "SOURCE_READY"; then
  log "[Step 1] Recreating repo (clean shallow clone)"

  rm -rf "$KERNEL_DIR"

  # Retry clone to tolerate transient network issues.
  attempt=1
  max_attempts=3
  while (( attempt <= max_attempts )); do
    if git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"; then
      break
    fi

    if (( attempt == max_attempts )); then
      log "FATAL: failed to clone kernel repo after $max_attempts attempts"
      exit 1
    fi

    log "Clone attempt $attempt failed, retrying..."
    ((attempt++))
  done

  set_state "SOURCE_READY"
else
  log "[Skip] Step 1 (state: $(get_state))"
fi


###############################################################################
# STEP 2: BASE DEFAULT_CONFIG
#
# WHAT:
#   Generate default Raspberry Pi config
#
# WHY:
#   Provides a stable baseline before applying custom fragments
###############################################################################
if should_run_step "DEFAULT_CONFIG"; then
  log "[Step 2] Making default configuration"
  make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" bcm2709_defconfig
  set_state "DEFAULT_CONFIG"
else
  log "[Skip] Step 2 (state: $(get_state))"
fi


###############################################################################
# STEP 3: CONFIG MERGE PIPELINE
#
# WHAT:
#   Build final kernel config using:
#     - dependency backbone
#     - base config ~/kernel_build/kconfig/fragments/00-base.config
#     - feature config ~/kernel_build/kconfig/fragments/10-features.config
#     - production config ~/kernel_build/kconfig/fragments/20-production.config
#
# WHY:
#   Ensures:
#     ✅ deterministic config
#     ✅ dependency-safe resolution
#     ✅ modular configuration management
###############################################################################
if should_run_step "CONFIG_READY"; then
  log "[Step 3] Kconfig merge (fully dependency-safe)"

  BASE="$FRAG_DIR/00-base.config"
  FEAT="$FRAG_DIR/10-features.config"
  PROD="$FRAG_DIR/20-production.config"

  [[ -f "$BASE" && -f "$FEAT" && -f "$PROD" ]] || {
    log "FATAL missing fragments"
    exit 1
  }

  # Reset baseline config before merging
  make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" bcm2709_defconfig

  # Dependency backbone (ensures core infrastructure exists BEFORE features)
  # Prevents Kconfig from silently disabling features later.
  cat > "$BUILD_DIR/deps.config" <<EOF
CONFIG_BLOCK=y
CONFIG_BLK_DEV=y
CONFIG_CRYPTO=y
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_XZ=y
CONFIG_CRYPTO_ZSTD=y
CONFIG_ZLIB_INFLATE=y
CONFIG_XZ_DEC=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_FB=y
CONFIG_FB_SIMPLE=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_SYSFB=y
CONFIG_OF=y
CONFIG_HAS_IOMEM=y
CONFIG_SERIAL_CORE=y
CONFIG_SERIAL_CORE_CONSOLE=y
CONFIG_ARM_AMBA=y
EOF

  # Apply dependency layer
  bash "$KERNEL_DIR/scripts/kconfig/merge_config.sh" \
    -m "$BUILD_DIR/.config" "$BUILD_DIR/deps.config"

  # Apply feature + production layers
  bash "$KERNEL_DIR/scripts/kconfig/merge_config.sh" \
    -m "$BUILD_DIR/.config" \
    "$BASE" "$FEAT" "$PROD"

  # Resolve final dependencies after merging fragments
  make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" olddefconfig

  # Validate critical features exist
  CFG="$BUILD_DIR/.config"
  for opt in CONFIG_SQUASHFS CONFIG_OVERLAY_FS CONFIG_BLK_DEV_INITRD; do
    grep -Eq "^$opt=y|^$opt=m" "$CFG" || {
      log "FATAL missing required config: $opt"
      exit 1
    }
  done

  set_state "CONFIG_READY"
else
  log "[Skip] Step 3 (state: $(get_state))"
fi


###############################################################################
# STEP 4: FINAL CONFIG ENFORCEMENT
#
# WHAT:
#   Final Kconfig resolution + enforce IKCONFIG
#
# WHY:
#   Guarantees:
#     ✅ kernel embeds its own config (critical for verification)
#     ✅ no unresolved dependencies remain
###############################################################################
if should_run_step "CONFIG_ENFORCED"; then
  log "[Step 4] Final configuration for kernel"

  # Apply enorced options (IKCONFIG, overlays, etc.) Re-resolve dependencies after forcing config
  make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  log "Locking critical built-in configs (IKCONFIG + rootfs + version)"

  "$KERNEL_DIR/scripts/config" --file "$BUILD_DIR/.config" \
    --enable CONFIG_IKCONFIG \
    --enable CONFIG_IKCONFIG_PROC \
    --enable CONFIG_SQUASHFS \
    --enable CONFIG_SQUASHFS_XZ \
    --enable CONFIG_OVERLAY_FS \
    --enable CONFIG_USB \
    --enable CONFIG_USB_GADGET \
    --module CONFIG_USB_DWC2 \
    --enable CONFIG_USB_DWC2_DUAL_ROLE \
    --module CONFIG_USB_ETH \
    --enable CONFIG_DRM_VC4 \
    --enable CONFIG_SERIAL_AMBA_PL011 \
    --enable CONFIG_SERIAL_AMBA_PL011_CONSOLE \
    --set-str CONFIG_LOCALVERSION "-recon-field" \
    --disable CONFIG_LOCALVERSION_AUTO

  # Re-resolve dependencies after forced config edits so Step 5 validates
  # a fully settled configuration.
  make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig
  
  set_state "CONFIG_ENFORCED"
else
  log "[Skip] Step 4 (state: $(get_state))"
fi


###############################################################################
# STEP 5: FINAL CONFIG VERIFICATION
#
# WHAT:
#   Validate kernel configuration BEFORE build
#
# WHY:
#   Prevents building invalid kernels:
#     ✅ ensures required subsystems exist
#     ✅ enforces built-in vs module rules
###############################################################################
if should_run_step "CONFIG_VERIFIED"; then

  log "[Step 5] Verifying FINAL resolved configuration"

  CFG="$BUILD_DIR/.config"

  [[ -f "$CFG" ]] || {
    log "FATAL missing .config"
    exit 1
  }

  # Critical features required for target system (squashfs + overlayfs + console)
  REQUIRED_Y=(
    CONFIG_SQUASHFS
    CONFIG_OVERLAY_FS
    CONFIG_BLK_DEV_INITRD
    CONFIG_RD_XZ
    CONFIG_XZ_DEC
    CONFIG_DEVTMPFS
    CONFIG_TTY
    CONFIG_VT
    CONFIG_VT_CONSOLE
    CONFIG_FRAMEBUFFER_CONSOLE

    CONFIG_DRM
    CONFIG_DRM_VC4

    CONFIG_USB
    CONFIG_USB_GADGET
    CONFIG_USB_DWC2
    CONFIG_USB_ETH

    CONFIG_USB_HID
    CONFIG_HID
    CONFIG_HID_GENERIC
    CONFIG_INPUT_EVDEV

    CONFIG_SERIAL_CORE
    CONFIG_SERIAL_AMBA_PL011
    CONFIG_SERIAL_AMBA_PL011_CONSOLE

    CONFIG_IKCONFIG
    CONFIG_IKCONFIG_PROC
  )

  # Enforce built-in (not modules) where required
  STRICT_Y_ONLY=(
    CONFIG_IKCONFIG
    CONFIG_SQUASHFS
    CONFIG_OVERLAY_FS
    CONFIG_RD_XZ
    CONFIG_XZ_DEC
  )

  for opt in "${REQUIRED_Y[@]}"; do
    grep -Eq "^$opt=y$|^$opt=m$" "$CFG" || {
      log "FATAL missing required config: $opt"
      exit 1
    }
  done

  for opt in "${STRICT_Y_ONLY[@]}"; do
    grep -q "^$opt=y$" "$CFG" || {
      log "FATAL: $opt must be built-in (=y)"
      exit 1
    }
  done

  log "[OK] FINAL CONFIG VERIFIED"
  set_state "CONFIG_VERIFIED"
else
  log "[Skip] Step 5 (state: $(get_state))"
fi


###############################################################################
# STEP 6: INITRAMFS BUILD
#
# WHAT:
#   Construct embedded initramfs filesystem
#
# WHY:
#   Provides:
#     ✅ early userspace
#     ✅ recovery shell / boot logic
#     ✅ foundation for squashfs + overlay mount system
###############################################################################
if should_run_step "INITRAMFS_READY"; then
  log "[Step 6] building embedded initramfs"

  WORK="$BUILD_DIR/initramfs_recon"
  rm -rf "$WORK"
  mkdir -p "$WORK"/{bin,sbin,etc,proc,sys,dev,tmp,mnt,ro,merged,upper,work,boot,data}

  # Include busybox (minimal userspace)
  BUSYBOX="$(command -v busybox)"
  cp "$BUSYBOX" "$WORK/bin/busybox"
  chmod +x "$WORK/bin/busybox"

  # Create symlinks to required utilities
  for c in sh mount umount ls cat echo mkdir mknod switch_root sleep grep chmod chown ln rm cp; do
    ln -sf busybox "$WORK/bin/$c"
  done

  # Init entrypoint
  # This is the FIRST userspace process at boot
cat > "$WORK/init" <<'EOF'
#!/bin/sh
#set -x

echo "===== INIT STARTED ====="

# --------------------------------------------------
# Basic mounts (must succeed or continue visibly)
# --------------------------------------------------
mount -t proc proc /proc || echo "proc mount failed"
mount -t sysfs sys /sys || echo "sysfs mount failed"
mount -t devtmpfs dev /dev || echo "devtmpfs mount failed"
[ -e /dev/console ] || mknod -m 600 /dev/console c 5 1
exec > /dev/console 2>&1

# Fix console (CRITICAL for visibility)
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts || echo "devpts mount failed"
echo "Devices present:"
ls /dev

# --------------------------------------------------
# Wait for MMC devices (Pi Zero 2W timing issue)
# --------------------------------------------------
echo "Waiting for MMC devices..."

for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -b /dev/mmcblk0p1 ] && break
    sleep 1
done

if [ ! -b /dev/mmcblk0p1 ]; then
    echo "MMC devices not detected!"
    while true; do
      /bin/sh
      sleep 1
    done
fi

echo "MMC ready"

# --------------------------------------------------
# Mount boot (non-fatal)
# --------------------------------------------------
mkdir -p /boot

for i in 1 2 3 4 5; do
    mount /dev/mmcblk0p1 /boot && break
    echo "retry boot mount..."
    sleep 1
done

echo "Boot mounted"
# --------------------------------------------------
# Optional debug handoff (presence-based)
# --------------------------------------------------
if [ -x /boot/debug-init.sh ]; then
    echo "Running external debug-init.sh..."
  /boot/debug-init.sh || echo "debug-init.sh exited with error"
  echo "debug-init.sh complete, returning to normal init flow"
else
  echo "No debug-init.sh found, continuing normal init"
fi

# --------------------------------------------------
# Determine active slot
# --------------------------------------------------
SLOT="A"

if [ -f /boot/slot.active ]; then
    SLOT=$(cat /boot/slot.active)
fi

echo "Active slot: $SLOT"

if [ "$SLOT" = "A" ]; then
    ROOT_DEV="/dev/mmcblk0p2"
else
    ROOT_DEV="/dev/mmcblk0p3"
fi

echo "Root device: $ROOT_DEV"

# --------------------------------------------------
# Mount root partition (retry logic)
# --------------------------------------------------
mkdir -p /mnt/root

for i in 1 2 3 4 5; do
    mount "$ROOT_DEV" /mnt/root && break
    echo "retry root mount..."
    sleep 1
done

if ! grep -q " /mnt/root " /proc/mounts; then
    echo "Failed to mount root partition"
    while true; do
      /bin/sh
      sleep 1
    done
fi

echo "Root partition mounted"

# --------------------------------------------------
# Verify squashfs exists
# --------------------------------------------------
if [ ! -f /mnt/root/rootfs.squashfs ]; then
    echo "Missing squashfs image!"
    while true; do
      /bin/sh
      sleep 1
    done
fi

# --------------------------------------------------
# Mount squashfs
# --------------------------------------------------
mkdir -p /ro

if ! mount -t squashfs /mnt/root/rootfs.squashfs /ro; then
    echo "Failed to mount squashfs"
    while true; do
      /bin/sh
      sleep 1
    done
fi

echo "SquashFS mounted"

# --------------------------------------------------
# Mount data partition
# --------------------------------------------------
mkdir -p /data

for i in 1 2 3 4 5; do
    mount /dev/mmcblk0p4 /data && break
    echo "retry data mount..."
    sleep 1
done

if ! grep -q " /data " /proc/mounts; then
    echo "Failed to mount data partition"
    while true; do
      /bin/sh
      sleep 1
    done
fi

echo "Data partition mounted"

# --------------------------------------------------
# Setup overlay
# --------------------------------------------------
mkdir -p /data/overlay/$SLOT/upper
mkdir -p /data/overlay/$SLOT/work
mkdir -p /merged
chmod 755 /data/overlay/$SLOT/upper /merged
chmod 700 /data/overlay/$SLOT/work

if ! mount -t overlay overlay \
    -o lowerdir=/ro,upperdir=/data/overlay/$SLOT/upper,workdir=/data/overlay/$SLOT/work \
    /merged; then
    echo "Failed to mount overlay"
    while true; do
      /bin/sh
      sleep 1
    done
fi

echo "Overlay mounted"
chmod 755 /merged

# --------------------------------------------------
# Shared /etc files across A/B slots
#
# Files listed here are stored under /data/shared-etc and bind-mounted into
# /etc so both slots see the same content.
#
# Defaults:
#   - /etc/hostname
#   - /etc/hosts
# Optional list file:
#   - /boot/shared-etc-files.txt (one /etc-relative path per line)
# --------------------------------------------------
SHARED_ETC_ROOT="/data/shared-etc"
SHARED_ETC_LIST="/boot/shared-etc-files.txt"

mkdir -p "$SHARED_ETC_ROOT"

share_etc_file() {
  rel="$1"
  [ -n "$rel" ] || return 0

  target="/merged/etc/$rel"
  shared="$SHARED_ETC_ROOT/$rel"
  target_dir="${target%/*}"
  shared_dir="${shared%/*}"

  mkdir -p "$target_dir" "$shared_dir"

  # First boot seeds the shared copy from immutable/default content.
  if [ ! -f "$shared" ] && [ -f "$target" ]; then
    cp "$target" "$shared"
  fi

  if [ -f "$shared" ]; then
    mount --bind "$shared" "$target" || echo "Failed to bind $rel"
  else
    echo "Shared file unavailable for bind: $rel"
  fi
}

share_etc_file "hostname"
share_etc_file "hosts"

if [ -f "$SHARED_ETC_LIST" ]; then
  while IFS= read -r rel || [ -n "$rel" ]; do
    case "$rel" in
      ""|\#*) continue ;;
    esac

    rel="${rel#/etc/}"
    rel="${rel#/}"
    [ -n "$rel" ] || continue

    share_etc_file "$rel"
  done < "$SHARED_ETC_LIST"
fi

# Avoid mount-option conflicts with systemd-fstab-generator after switch_root.
# /boot is only needed here for slot/debug reads; let systemd mount it later.
umount /boot 2>/dev/null || true

echo "Fixing /data home permissions before switch_root..."
if [ -d /data/home ]; then
    mkdir -p /data/home/rheemtest
    chown -R 1000:1000 /data/home/rheemtest
    chmod 755 /data /data/home /data/home/rheemtest
fi

echo "Ensuring runtime home exists in merged root..."
mkdir -p /merged/home/rheemtest
chown 1000:1000 /merged/home/rheemtest
chmod 755 /merged/home /merged/home/rheemtest

echo "Ensuring machine-id exists in merged root..."
if [ ! -s /merged/etc/machine-id ]; then
  cat /proc/sys/kernel/random/uuid > /merged/etc/machine-id
fi
mkdir -p /merged/var/lib/dbus
rm -f /merged/var/lib/dbus/machine-id
ln -sf /etc/machine-id /merged/var/lib/dbus/machine-id

echo "===== PRE-SWITCH ROOT DEBUG ====="
echo "passwd entry for rheemtest:"
grep '^rheemtest:' /merged/etc/passwd || echo "rheemtest entry missing from /merged/etc/passwd"
echo "mount table:"
cat /proc/mounts
echo "path ownership/mode (numeric):"
ls -ldn /merged /merged/home /merged/home/rheemtest 2>/dev/null || true
ls -ldn /data /data/home /data/home/rheemtest 2>/dev/null || true
echo "machine-id contents:"
cat /merged/etc/machine-id 2>/dev/null || echo "machine-id missing"

# --------------------------------------------------
# Switch root
# --------------------------------------------------
echo "Switching root..."

exec switch_root /merged /sbin/init
EOF

  chmod +x "$WORK/init"

  # Device node spec for initramfs: ensures early /dev/console and /dev/null
  # exist even before devtmpfs is mounted.
  NODES_FILE="$BUILD_DIR/initramfs_nodes.txt"
  cat > "$NODES_FILE" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
EOF

  # Tell kernel to embed this filesystem
  "$KERNEL_DIR/scripts/config" \
    --file "$BUILD_DIR/.config" \
    --set-str CONFIG_INITRAMFS_SOURCE "$WORK $NODES_FILE"

  "$KERNEL_DIR/scripts/config" \
    --file "$BUILD_DIR/.config" \
    --enable CONFIG_BLK_DEV_INITRD

  # Force kernel to regenerate initramfs (avoid stale cache)
  rm -f "$BUILD_DIR/usr/initramfs_data.cpio"

  # CRITICAL: resolve config WITHOUT prompting
  # Inject initramfs into the config and let Kconfig resolve dependencies
  make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

  # Verify initramfs config stuck
  grep -Eq "CONFIG_INITRAMFS_SOURCE=\".*$WORK.*\"" "$BUILD_DIR/.config" || {
    log "FATAL: INITRAMFS_SOURCE lost after olddefconfig"
    exit 1
  }
  grep -Eq "CONFIG_INITRAMFS_SOURCE=\".*$NODES_FILE.*\"" "$BUILD_DIR/.config" || {
    log "FATAL: INITRAMFS_SOURCE missing node spec after olddefconfig"
    exit 1
  }

  # Sanity check initramfs contents
  [ -f "$WORK/init" ] || {
    log "FATAL: initramfs missing /init"
    exit 1
  }

  [ -x "$WORK/bin/sh" ] || {
    log "FATAL: busybox not properly installed in initramfs"
    exit 1
  }
  set_state "INITRAMFS_READY"
else
  log "[Skip] Step 6 (state: $(get_state))"
fi


###############################################################################
# STEP 7: FINAL BUILD + VERIFICATION
#
# WHAT:
#   Build kernel AND verify embedded config directly in artifact
#
# WHY:
#   Ensures:
#     ✅ kernel matches intended configuration
#     ✅ initramfs actually embedded
#     ✅ no silent config drift occurred
###############################################################################
if should_run_step "FINAL_BUILD"; then
  log "[Step 7] final build with embedded initramfs"

  # Force initramfs rebuild
  rm -rf "$BUILD_DIR/usr"
  # Force rebuild of IKCONFIG embedding
  rm -f "$BUILD_DIR/kernel/configs.o"
  rm -f "$BUILD_DIR/kernel/config_data.gz"

  # Make the image
  make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS" zImage modules dtbs

  log "Verifying initramfs contents..."
  INITRAMFS="$BUILD_DIR/usr/initramfs_data.cpio"
  [[ -f "$INITRAMFS" ]] || {
    log "FATAL: initramfs_data.cpio missing after build"
    exit 1
  }
  
  if ! cpio -t < "$INITRAMFS" | grep -q "^init$"; then
    log "FATAL: initramfs missing /init"
    exit 1
  fi
  log "[OK] initramfs contains /init"

  KIMG="$BUILD_DIR/arch/arm/boot/zImage"
  VMLINUX="$BUILD_DIR/vmlinux"
  TMPCFG=$(mktemp)
  "$KERNEL_DIR/scripts/extract-ikconfig" "$VMLINUX" > "$TMPCFG" || {
    log "FATAL: cannot extract config from vmlinux"
    exit 1
  }

  # Secondary check: ensure shipped zImage also carries extractable IKCONFIG.
  TMP_ZCFG=$(mktemp)
  "$KERNEL_DIR/scripts/extract-ikconfig" "$KIMG" > "$TMP_ZCFG" || {
    log "FATAL: cannot extract config from zImage"
    exit 1
  }

  log "Testing for the initramfs embedded in kernel"
  # Check 1: Kernel config includes initramfs
  if ! grep -q '^CONFIG_INITRAMFS_SOURCE=' "$TMPCFG"; then
    log "FATAL: initramfs NOT embedded in kernel image"
    exit 1
  fi
  
  log "initramfs is embedded in kernel image"
  
  # Check 2: initramfs content exists and is valid
  log "Verifying embedded initramfs..."
  INITRAMFS="$BUILD_DIR/usr/initramfs_data.cpio"
  
  [[ -f "$INITRAMFS" ]] || {
    log "FATAL: initramfs_data.cpio missing"
    exit 1
  }
  
  SIZE=$(stat -c%s "$INITRAMFS")
  log "Initramfs size: $SIZE bytes"
  
  [[ "$SIZE" -gt 100000 ]] || {
    log "FATAL: initramfs appears too small"
    exit 1
  }
  
  log "[OK] Initramfs content verified"

  tr -d '\r' < "$TMPCFG" > "$TMPCFG.clean"
  CFG_CLEAN="$TMPCFG.clean"
  grep -q '^CONFIG_SQUASHFS=y' "$CFG_CLEAN" || {
    log "FATAL: No CONFIG_SQUASHFS=y in embedded kernel config"
    exit 1
  }
  grep -q '^CONFIG_OVERLAY_FS=y' "$CFG_CLEAN" || {
    log "FATAL: No CONFIG_OVERLAY_FS=y in embedded kernel config"
    exit 1
  }
  grep -q '^CONFIG_RD_XZ=y' "$CFG_CLEAN" || {
    log "FATAL: No CONFIG_RD_XZ=y in embedded kernel config"
    exit 1
  }
  grep -q '^CONFIG_LOCALVERSION="-recon-field"' "$CFG_CLEAN" || {
    log "FATAL: No expected CONFIG_LOCALVERSION in embedded kernel config"
    exit 1
  }

  rm -f "$TMPCFG" "$TMPCFG.clean" "$TMP_ZCFG"

  # Export final artifact (immutable kernel image)
  KVER=$(make -s -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)
  OUT="$ARTIFACT_DIR/kernel7.img-$KVER"

  cp "$KIMG" "$OUT"
  sha256sum "$OUT" > "$OUT.sha256"

  # Copy device tree needed for boot
  cp "$BUILD_DIR/arch/arm/boot/dts/broadcom/bcm2710-rpi-zero-2-w.dtb" \
     "$ARTIFACT_DIR/"

  # Export kernel modules as artifact
  MODULES_OUT="$ARTIFACT_DIR/modules-$KVER"
  log "[Step 7] Exporting kernel modules → $MODULES_OUT"
  rm -rf "$MODULES_OUT"
  mkdir -p "$MODULES_OUT"
  make -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" INSTALL_MOD_PATH="$MODULES_OUT" modules_install > /dev/null

  # Sanity check
  [[ -d "$MODULES_OUT/lib/modules/$KVER" ]] || {
    log "FATAL: Module export failed"
    exit 1
  }

  EXPECTED_KVER=$(make -s -C "$KERNEL_DIR" O="$BUILD_DIR" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" kernelrelease)

  [[ "$KVER" == "$EXPECTED_KVER" ]] || {
    log "FATAL: kernelrelease mismatch after build"
    exit 1
  }
  set_state "FINAL_BUILD"

else
  log "[Skip] Step 7 (state: $(get_state))"
fi


###############################################################################
# FINAL SUMMARY
#
# WHAT:
#   Print build summary and timing
#
# WHY:
#   Gives visibility into:
#     ✅ duration
#     ✅ artifact location
#     ✅ logging location
###############################################################################
END_TS=$(date +%s)

log "=== BUILD COMPLETE ==="
log "Artifacts: $ARTIFACT_DIR"
log "Elapsed: $((END_TS - START_TS)) seconds"
log "Elapsed: $(((END_TS - START_TS)/60)) minutes"
ELAPSED_HR=$(awk "BEGIN {printf \"%.1f\", ($END_TS - $START_TS)/3600}")
log "Elapsed: ${ELAPSED_HR} hours"
log "Log: $LOG_FILE"

