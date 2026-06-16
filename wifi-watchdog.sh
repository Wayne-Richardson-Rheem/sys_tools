#!/bin/bash

#***********************************************************************************************************************
# Wi-Fi wathdog ensures wlan0 stays connected via NetworkManager using dynamic connection detetion
#***********************************************************************************************************************

INTERFACE="wlan0"

#***********************************************************************************************************************
# Use the journalctl logger functionality
#***********************************************************************************************************************
log()
{
  logger -t "wifi-watchdog" "$1"
}


#***********************************************************************************************************************
# Try to get an active connection name
#***********************************************************************************************************************
get_active_connection_name()
{
  #*********************************************************************************************************************
  # Try to get the active connection for wlan0
  #*********************************************************************************************************************
  nmcli -t -f NAME,DEVICE connection show --active | grep ":${INTERFACE}$" | cut -d: -f1
}


#***********************************************************************************************************************
# Disable the power save for the Wi-Fi 
#***********************************************************************************************************************
disable_power_save()
{
  local power_save
  power_save=$(iw "$INTERFACE" get power_save 2>/dev/null | awk '{print $N}')

  if [ "$power_save" = "on" ]; then
    iw dev "$NTERFACE" set power_save off
    log "Power Management was on -> Set to Off"
  fi
}



#***********************************************************************************************************************
# Log the current state of the Wi-Fi 
#***********************************************************************************************************************
log_monitor_data()
{
  local signal power_save disconnectes

  # Signal Strength
  signal=$(iwconfig "$INTERFACE" 2>/dev/null | grep -i 'Signal level' | awk -F '=' '{print $3}' | awk '{print $1}')

  # Power save status
  power_save=$(iw "$INTERFACE" get power_save 2>/dev/null | awk '{print $NF}')

  # Recent disconnect events
  disconnects=$(journalctl -u NetworkManager -n 20 | grep -i 'disconnected')

  log "Signal: ${signal:-N/A} dBm | power save: ${power_save:-N/A}"

  if [ -n "$disconnects" ]; then
    log "Recent disconnect events:"
    while read r line; do
      log " $line"
    done <<< "$disconnects"
  fi
}


#***********************************************************************************************************************
# Check for active connection for wlan0 and if found, exit.  If not found, search for a previous saved
# profile and try to connect to that one
#***********************************************************************************************************************
check_and_reconnect()
{
  local conn_name
  conn_name=$(get_active_connection_name)

  if [ -z "$conn_name" ]; then
    #*******************************************************************************************************************
    # No active connection, try to find a saved Wi-Fi profile for wlan
    #*******************************************************************************************************************
    conn_name=$(nmcli -t -f NAME,TYPE,DEVICE connection show | grep "802-11-wireless:" | cut -d: -f1 | head -n1)

    if [ -n "$conn_name" ]; then
      #*****************************************************************************************************************
      # A previous Wi-Fi profile for the wlan0 has been found
      #*****************************************************************************************************************
      log "Wi-Fi not connected.  Attempting to reconnect using profile: ${conn_name}"
      nmcli connection up "${conn_name}"
    else
      log "No saved Wi-Fi profiles found for ${INTERFACE}.  Cannot reconnect."
    fi
  fi
}



#***********************************************************************************************************************
# Run
#***********************************************************************************************************************
log "Starting Wi-Fi Watchdog + Monitor (journalctl only)"
check_and_reconnect
disable_power_save
log_monitor_data


#***********************************************************************************************************************
# Check every 5 minutes
#***********************************************************************************************************************
while true; do
    sleep 300
    check_and_reconnect
    disable_power_save
    log_monitor_data
done

