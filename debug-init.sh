#!/bin/sh

echo "===== EXTERNAL DEBUG INIT ====="

# Mount core pseudo-filesystems only if they are not already mounted.
grep -q " /proc " /proc/mounts || mount -t proc proc /proc
grep -q " /sys " /proc/mounts || mount -t sysfs sys /sys
grep -q " /dev " /proc/mounts || mount -t devtmpfs dev /dev

[ -e /dev/console ] || mknod -m 600 /dev/console c 5 1
exec > /dev/console 2>&1

echo "Devices:"
ls /dev

# Optional interactive debug mode:
# create /boot/debug-shell to pause boot and drop to shell.
if [ -f /boot/debug-shell ]; then
    echo "debug-shell trigger found. Dropping to shell..."
    while true; do
        /bin/sh
    done
fi

echo "Debug checks complete. Returning to initramfs flow."
exit 0
