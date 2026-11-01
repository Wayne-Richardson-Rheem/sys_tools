#!/bin/bash

LOGFILE="/var/log/recon/network-recovery.log"
STATEFILE="/var/log/recon/network-recovery.failcount"

mkdir -p /var/log/recon

log()
{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

FAILCOUNT=0

if [ -f "$STATEFILE" ]; then
    FAILCOUNT=$(cat "$STATEFILE")
fi

########################################################################
# Check 1: Internet Connectivity
########################################################################

if ping -c2 -W3 8.8.8.8 >/dev/null 2>&1; then
    INTERNET_OK=1
else
    INTERNET_OK=0
fi

########################################################################
# Check 3: NetworkManager
########################################################################

if systemctl is-active --quiet NetworkManager; then
    NM_OK=1
else
    NM_OK=0
fi

########################################################################
# Decision Logic
########################################################################

if [ "$INTERNET_OK" -eq 1 ] && \
   [ "$NM_OK" -eq 1 ]; then

    echo 0 > "$STATEFILE"

    log "HEALTHY: Internet=OK NetworkManager=OK"

    exit 0
fi

FAILCOUNT=$((FAILCOUNT + 1))

echo "$FAILCOUNT" > "$STATEFILE"

log "FAILURE $FAILCOUNT: Internet=$INTERNET_OK NetworkManager=$NM_OK"

########################################################################
# Restart NetworkManager after 3 failures
########################################################################

if [ "$FAILCOUNT" -ge 3 ]; then

    log "Restarting NetworkManager"

    systemctl restart NetworkManager

    sleep 15

    echo 0 > "$STATEFILE"

    log "NetworkManager restart completed"
fi
