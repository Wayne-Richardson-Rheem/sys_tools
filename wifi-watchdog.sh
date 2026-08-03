#!/bin/bash

#####################################################################
# Wi-Fi Monitoring Watchdog
#
# Purpose:
#   Observe and log Wi-Fi state for troubleshooting.
#
# This script NEVER:
#   - Activates connections
#   - Disconnects connections
#   - Modifies Wi-Fi state
#   - Modifies NetworkManager
#
# Safe to run alongside:
#   wifi-ap.sh
#   connect.py
#   recon-ap-connect.sh
#####################################################################

INTERFACE="wlan0"
LOG_TAG="wifi-watchdog"
LOG_FILE="/var/log/recon/wifi-watchdog.log"

mkdir -p /var/log/recon 2>/dev/null || true

if [ ! -f "$LOG_FILE" ]; then
    touch "$LOG_FILE"
    chown root:reconlog "$LOG_FILE" 2>/dev/null || true
    chmod 664 "$LOG_FILE" 2>/dev/null || true
fi

#####################################################################
# Logger
#####################################################################

log()
{
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    logger -t "$LOG_TAG" "$1"
}

#####################################################################
# NetworkManager State
#####################################################################

get_nm_state()
{
    nmcli -g GENERAL.STATE device show "$INTERFACE" 2>/dev/null
}

#####################################################################
# Active Connection Name
#####################################################################

get_active_connection()
{
    nmcli -g GENERAL.CONNECTION device show "$INTERFACE" 2>/dev/null
}

#####################################################################
# IPv4 Address
#####################################################################

get_ip()
{
    nmcli -g IP4.ADDRESS device show "$INTERFACE" 2>/dev/null | head -n1
}

#####################################################################
# Gateway
#####################################################################

get_gateway()
{
    nmcli -g IP4.GATEWAY device show "$INTERFACE" 2>/dev/null | head -n1
}

#####################################################################
# Signal Strength (dBm)
#####################################################################

get_signal()
{
    iw dev "$INTERFACE" link 2>/dev/null | \
        awk '/signal:/ {print $2}'
}

#####################################################################
# Associated BSSID
#####################################################################

get_bssid()
{
    iw dev "$INTERFACE" link 2>/dev/null | \
        awk '/Connected to/ {print $3}'
}

#####################################################################
# Power Save Status
#####################################################################

get_power_save()
{
    iw dev "$INTERFACE" get power_save 2>/dev/null | \
        awk '{print $NF}'
}

#####################################################################
# Tx Retry Counter
#####################################################################

get_tx_retries()
{
    iwconfig "$INTERFACE" 2>/dev/null | \
        sed -n 's/.*Tx excessive retries:\([0-9]*\).*/\1/p'
}

#####################################################################
# Get the wlan0 link information
#####################################################################

get_link_info()
{
    iw dev wlan0 link 2>/dev/null
}

#####################################################################
# Get the Wi-Fi Station Statistics
#####################################################################

get_station_info()
{
    iw dev wlan0 station dump 2>/dev/null
}

#####################################################################
# Get the NetworkManager Disconnect Reason
#####################################################################

get_nm_reason()
{
    nmcli -g GENERAL.REASON device show wlan0 2>/dev/null
}

#####################################################################
# Check Internet reachability
#####################################################################

check_internet()
{
    ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "OK"
    else
        echo "FAILED"
    fi
}

#####################################################################
# Log Recent NM Events
#####################################################################

log_recent_events()
{
    local events

    events=$(
        journalctl -u NetworkManager \
        --since "-5 min" \
        --no-pager 2>/dev/null | \
        grep -Ei 'disconnect|deauth|fail|timeout|supplicant|dhcp'
    )

    if [ -n "$events" ]; then
        log "Recent NetworkManager events:"

        while IFS= read -r line
        do
            log "  $line"
        done <<< "$events"
    fi
}

#####################################################################
# Current Status Snapshot
#####################################################################

log_state()
{
    local state
    local conn
    local ip
    local gw
    local signal
    local bssid
    local power
    local retries

    state=$(get_nm_state)
    conn=$(get_active_connection)
    ip=$(get_ip)
    gw=$(get_gateway)
    signal=$(get_signal)
    bssid=$(get_bssid)
    power=$(get_power_save)
    retries=$(get_tx_retries)

    log "STATE=${state:-unknown}"
    log "CONNECTION=${conn:-none}"
    log "IP=${ip:-none}"
    log "GATEWAY=${gw:-none}"
    log "BSSID=${bssid:-none}"
    log "SIGNAL=${signal:-unknown} dBm"
    log "POWERSAVE=${power:-unknown}"
    log "TX_RETRIES=${retries:-unknown}"

    if [ -n "$gw" ]; then
        if ping -c1 -W1 "$gw" >/dev/null 2>&1; then
            log "GATEWAY_PING=OK"
        else
            log "GATEWAY_PING=FAILED"
        fi
    else
        log "GATEWAY_PING=N/A"
    fi

    #################################################################
    # Internet connectivity test
    #################################################################

    if ping -c2 -W2 8.8.8.8 >/dev/null 2>&1; then
        log "INTERNET_PING=OK"
    else
        log "INTERNET_PING=FAILED"
    fi

    #################################################################
    # Wi-Fi link details
    #################################################################

    log "Wi-Fi Link Information:"

    iw dev wlan0 link 2>/dev/null | while read -r line; do
        log "  $line"
    done

    #################################################################
    # Wi-Fi station statistics
    #################################################################

    log "Wi-Fi Station Information:"

    iw dev wlan0 station dump 2>/dev/null | while read -r line; do
        case "$line" in
            *signal:*|*tx\ bitrate:*|*rx\ bitrate:*|*tx\ retries:*|*tx\ failed:*|*beacon\ loss:*|*inactive\ time:*|*connected\ time:*|*rx\ packets:*|*tx\ packets:*)
                log "  $line"
                ;;
        esac
    done

    #################################################################
    # NetworkManager reason code
    #################################################################

    nm_reason=$(nmcli -g GENERAL.REASON device show wlan0 2>/dev/null)

    if [ -n "$nm_reason" ]; then
        log "NM_REASON=$nm_reason"
    fi
}

#####################################################################
# State Change Detection
#####################################################################

LAST_STATE=""
LAST_CONN=""

check_transitions()
{
    local state
    local conn

    state=$(get_nm_state)
    conn=$(get_active_connection)

    if [ "$state" != "$LAST_STATE" ]; then
        log "STATE_CHANGE: '${LAST_STATE}' -> '${state}'"
        LAST_STATE="$state"
    fi

    if [ "$conn" != "$LAST_CONN" ]; then
        log "CONNECTION_CHANGE: '${LAST_CONN}' -> '${conn}'"
        LAST_CONN="$conn"
    fi
}

#####################################################################
# Tailscale status
#####################################################################

get_tailscale_state()
{
    tailscale status >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "ONLINE"
    else
        echo "OFFLINE"
    fi
}


#####################################################################
# Startup
#####################################################################

log "========================================================"
log "Wi-Fi monitoring watchdog started"
log "========================================================"

#####################################################################
# Main Loop
#####################################################################

while true
do
  check_transitions
  log_state
  log_recent_events
  log "TAILSCALE=$(get_tailscale_state)"

  sleep 300
done
