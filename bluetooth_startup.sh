#!/bin/bash

# Redirect all output and errors to a log file in /run (safe early in boot)
exec > /run/bluetooth_startup.log 2>&1
set -x  # Enable command tracing
echo "Script started at $(date)"

# Ensure Bluetooth is unblocked
rfkill unblock bluetooth

# Restart Bluetooth service
systemctl restart bluetooth
sleep 5

# Remove previously paired devices
for dev in $(bluetoothctl devices | awk '{print $2}'); do
    bluetoothctl remove "$dev"
done

# Configure Bluetooth
bluetoothctl power on
sleep 1
bluetoothctl agent NoInputNoOutput
sleep 1
bluetoothctl default-agent
sleep 1
bluetoothctl pairable on
sleep 1
bluetoothctl discoverable on
sleep 1

## Monitor new pairings and trust automatically
#(
#  echo "Starting bluetoothctl monitor loop" >> /run/bluetooth_startup.log
#  bluetoothctl monitor | while read -r line; do
#    echo "Monitor output: $line" >> /run/bluetooth_startup.log
#    if [[ "$line" =~ "Paired: yes" ]]; then
#      dev=$(echo "$line" | awk '{print $2}')
#      bluetoothctl trust "$dev"
#      echo "Trusted new device: $dev" >> /run/bluetooth_startup.log
#    fi
#  done
#) &

# Add the serial protocol
echo "Adding the serial protocol via sdptool"
sdptool add SP

# Enable Serial Port Profile (SPP)
echo "Calling rfcomm watch hci0"
rfcomm watch hci0 &

# Wait for 5 seconds
echo "Delaying for 5 seconds"
sleep 5

# Ensure /run exists before touching the file
echo "Creating/run/bt_startup_done file"
while [ ! -d /run ]; do
    sleep 0.1
done
touch /run/bt_startup_done || echo "Failed to create /run/bt_startup_done"

echo "Script finished at $(date)"

