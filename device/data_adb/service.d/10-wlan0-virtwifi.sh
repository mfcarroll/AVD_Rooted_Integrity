#!/system/bin/sh
# Bring up wlan0 (virt_wifi over eth0) and connect it to the emulator's VirtWifi
# AP, so ConnectivityService sees a real, VALIDATED WIFI transport.
#
# IMPORTANT — why every framework command goes through run():
#   `settings`, `svc`, `cmd` and `am` hand their stdout fd to system_server over
#   binder. If that fd points at a file under /data/adb (adb_data_file),
#   system_server is DENIED `append` and the entire call dies with:
#       "Failure calling service wifi: Failed transaction (2147483646)"
#   Worse, the error lands in the very log that can't be written, so the failure
#   is completely silent: Wi-Fi never connects, GMS never checks in, and the
#   Play Integrity verdict goes empty while every structural check still passes.
#
#   run() captures output via command substitution, so the fd handed to
#   system_server is a PIPE, not the log file. (Piped commands always worked —
#   that's why the `dumpsys | grep` lines below used to appear in the log while
#   the `settings`/`cmd` lines showed only "Failure calling service".)
#
#   This used to be masked by a hand-made /data/adb/magiskpolicy +
#   zygisk-sepolicy.rules pair that was never tracked in this repo and vanished
#   on an image rebuild. Do NOT reintroduce that dependency — keep using run().

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 25

LOG=/data/adb/wlan0-setup.log

log() { echo "$*" >> "$LOG"; }

# Run a framework command with its stdout on a pipe; log output and exit code.
run() {
    _out=$("$@" 2>&1); _rc=$?
    [ -n "$_out" ] && log "$_out"
    [ "$_rc" -ne 0 ] && log "  !! FAILED (rc=$_rc): $*"
    return $_rc
}

log "=== $(date) start ==="

/system/bin/ip link set eth0 up 2>/dev/null
if ! /system/bin/ip link show wlan0 >/dev/null 2>&1; then
    run /system/bin/ip link add link eth0 name wlan0 type virt_wifi
fi
/system/bin/ip link set wlan0 up 2>/dev/null
sleep 3

run /system/bin/settings put global captive_portal_mode 0
run /system/bin/settings put global captive_portal_detection_enabled 0

run /system/bin/svc wifi enable
sleep 12

run /system/bin/cmd wifi connect-network VirtWifi open
sleep 15

log "--- post-connect ---"
log "$(/system/bin/cmd wifi status 2>&1 | head -2)"
log "$(/system/bin/ip addr show wlan0 2>/dev/null | grep 'inet ' | head -2)"

# Single-line assertion so a regression is obvious at a glance.
if /system/bin/dumpsys connectivity 2>/dev/null | grep 'Transports: WIFI' | grep -q VALIDATED; then
    log "RESULT: OK - wlan0 has a VALIDATED WIFI network"
else
    log "RESULT: FAIL - no VALIDATED WIFI network (check the !! lines above)"
fi
log "=== done $(date) ==="
