#!/system/bin/sh
# Nudge a Google check-in once the network is actually up.
#
# On a fresh device GMS fires its first check-in during early boot — before
# wlan0 (brought up by 10-wlan0-virtwifi.sh via virt_wifi ~25s in) is connected.
# That early attempt fails and GMS backs off for hours, so the device never gets
# a GSF android_id and Google never evaluates it: result is uncertified +
# empty Play Integrity deviceIntegrity. A single check-in after the network
# validates registers the device with the spoofed (tokay) fingerprint.
#
# TWO THINGS ARE LOAD-BEARING HERE:
#
# 1. run() / command substitution. `am` hands its stdout fd to system_server
#    over binder; if that fd points into /data/adb (adb_data_file) the append is
#    DENIED and the broadcast dies with "Failure calling service activity:
#    Failed transaction (2147483646)" — silently, into the unwritable log.
#    Capture through a pipe instead. See 10-wlan0-virtwifi.sh for the full story.
#
# 2. Waiting for a validated *WIFI* network, not just any VALIDATED one. The
#    emulator's cellular/eth0 network is VALIDATED almost immediately, so a bare
#    `grep -q VALIDATED` matched at ~0s and fired the nudge long before wlan0
#    existed — exactly the too-early check-in this script exists to avoid.
#
# Logs to /data/adb/checkin-nudge.log

LOG=/data/adb/checkin-nudge.log

log() { echo "$*" >> "$LOG"; }

run() {
    _out=$("$@" 2>&1); _rc=$?
    [ -n "$_out" ] && log "$_out"
    [ "$_rc" -ne 0 ] && log "  !! FAILED (rc=$_rc): $*"
    return $_rc
}

wifi_validated() {
    /system/bin/dumpsys connectivity 2>/dev/null \
        | grep 'Transports: WIFI' | grep -q VALIDATED
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done

# Wait (up to ~180s) for a validated WIFI network; 10-wlan0-virtwifi.sh needs
# ~55s after boot_completed before wlan0 is associated.
i=0
while [ "$i" -lt 90 ]; do
    wifi_validated && break
    sleep 2; i=$((i + 1))
done
sleep 5

if wifi_validated; then
    log "=== $(date) checkin-nudge: WIFI validated after ~$((i * 2))s ==="
else
    log "=== $(date) checkin-nudge: no WIFI after ~$((i * 2))s, nudging anyway ==="
fi

run /system/bin/am broadcast -a android.server.checkin.CHECKIN
log "=== broadcast sent ==="
