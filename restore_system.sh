#!/bin/bash
set -euo pipefail

MOUNT_POINT="/mnt/usb-backup"

echo "=== RESTORE STARTED: $(date) ==="

# --- Safety checks -------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root."
  exit 1
fi

if ! mountpoint -q "$MOUNT_POINT"; then
  echo "ERROR: Backup mount point not mounted: $MOUNT_POINT"
  exit 1
fi

echo "Remounting backup read-write..."
mount -o remount,rw "$MOUNT_POINT"

# --- Restore /home -------------------------------------------------

if [[ -d "$MOUNT_POINT/home" ]]; then
  echo "Restoring /home..."
  rsync -aAX \
    "$MOUNT_POINT/home/" \
    /home/
else
  echo "WARNING: No /home backup found, skipping."
fi

# --- Restore custom systemd units ---------------------------------

if [[ -d "$MOUNT_POINT/systemd-custom" ]]; then
  echo "Restoring custom systemd units..."
  rsync -aAX \
    "$MOUNT_POINT/systemd-custom/" \
    /etc/systemd/system/
else
  echo "WARNING: No systemd-custom backup found, skipping."
fi

# --- Restore /usr/local/bin ---------------------------------------

if [[ -d "$MOUNT_POINT/usr-local-bin" ]]; then
  echo "Restoring /usr/local/bin..."
  rsync -aAX \
    "$MOUNT_POINT/usr-local-bin/" \
    /usr/local/bin/
else
  echo "WARNING: No /usr/local/bin backup found, skipping."
fi

# --- Restore /var/www ---------------------------------------------

if [[ -d "$MOUNT_POINT/var-www" ]]; then
  echo "Restoring /var/www..."
  rsync -aAX \
    "$MOUNT_POINT/var-www/" \
    /var/www/
else
  echo "WARNING: No /var/www backup found, skipping."
fi

# --- Systemd reload -----------------------------------------------

echo "Reloading systemd daemon..."
systemctl daemon-reload

# --- Lock backup again --------------------------------------------

echo "Remounting backup read-only..."
sync
mount -o remount,ro "$MOUNT_POINT"

echo "=== RESTORE COMPLETED SUCCESSFULLY: $(date) ==="

