#!/bin/bash
# wifi-toggle-live.sh - toggle Wi-Fi and watch network-fallback log in real time

WIFI_IF="wlan0"
SLEEP_TIME=600
LOG_FILE="/var/log/network-fallback.log"

# Check if Wi-Fi is currently connected
STATUS=$(nmcli -t -f DEVICE,STATE dev | grep "^$WIFI_IF:" | cut -d: -f2)
if [ "$STATUS" != "connected" ]; then
    echo "Wi-Fi ($WIFI_IF) is not connected. Aborting toggle."
    exit 1
fi

echo "Starting live log watch..."
sudo tail -f "$LOG_FILE" &
TAIL_PID=$!

# Disconnect Wi-Fi
echo "Disconnecting Wi-Fi ($WIFI_IF)..."
sudo nmcli device disconnect "$WIFI_IF"

echo "Sleeping for $SLEEP_TIME seconds while Wi-Fi is down..."
sleep "$SLEEP_TIME"

# Reconnect Wi-Fi
echo "Reconnecting Wi-Fi ($WIFI_IF)..."
sudo nmcli device connect "$WIFI_IF"

echo "Wi-Fi reconnected. You can Ctrl+C to stop log watch."

# Wait for user to exit tail
wait $TAIL_PID

