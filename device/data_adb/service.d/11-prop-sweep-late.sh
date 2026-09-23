#!/system/bin/sh
# LATE emulator-property scrub — runs at boot_completed, after the HALs start.
#
# TWO SEPARATE BUGS made ~22-33 emulator properties readable by ANY app, with
# no root, on every boot since the first commit:
#
#   1. BROKEN REGEX (the main one). 04-prop-sweep.sh extracted property names
#      with  sed -n 's/...\(ranchu\|qemu\|goldfish\)...'  — but \| alternation
#      is a GNU sed extension that toybox sed (Android's sed) does NOT support.
#      The pattern matched NOTHING, so those loops deleted 0 props every boot
#      and logged "deleted 0 init.svc.* emulator props" as though that were a
#      clean result. The steps that did work (ro.boot.qemu.*, qemu.*) are the
#      ones whose patterns have no alternation. Fixed there by prefiltering
#      with grep -E, which does support alternation.
#
#   2. PHASE. Even with a working regex, post-fs-data is too early for the
#      init.svc.* properties: init creates init.svc.<name> when a service
#      STARTS, and the ranchu/goldfish HALs start well after post-fs-data.
#      That is what this script is for.
#
# Verified on-device: 33 such properties present -> 33 deleted -> 0 remaining,
# with adb and the HALs unaffected.
#
# LIMITATIONS (do not oversell this):
#   - init RE-CREATES init.svc.<name> whenever that service changes state, so
#     this re-sweeps while services settle, then stops. A HAL restarting later
#     brings its property back.
#   - It cannot rename the running processes themselves
#     (android.hardware.camera.provider.ranchu, qemu-props, ...), which remain
#     enumerable by anything that walks /proc. This closes the PROPERTY vector
#     only, not the PROCESS vector.

LOG=/data/adb/prop-sweep-late.log
RP=/data/adb/ksu/bin/resetprop

# ro.boot.qemu.adb.pubkey is load-bearing (adbd) — never delete it.
sweep_once() {
    _n=0
    for _p in $(getprop 2>/dev/null \
            | grep -E '^\[(init\.svc|ro\.boottime)[^]]*(ranchu|qemu|goldfish)' \
            | sed -n 's/^\[\([^]]*\)\].*/\1/p'); do
        [ "$_p" = "ro.boot.qemu.adb.pubkey" ] && continue
        $RP -n -d "$_p" 2>/dev/null && _n=$((_n + 1))
    done
    for _p in $(getprop 2>/dev/null \
            | grep -E '^\[qemu\.' \
            | sed -n 's/^\[\([^]]*\)\].*/\1/p'); do
        [ "$_p" = "ro.boot.qemu.adb.pubkey" ] && continue
        $RP -n -d "$_p" 2>/dev/null && _n=$((_n + 1))
    done
    echo "$_n"
}

visible_now() {
    getprop 2>/dev/null \
        | grep -cE '^\[(init\.svc|ro\.boottime|qemu\.)[^]]*(ranchu|qemu|goldfish)'
}

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done

{
    echo "=== $(date) late prop-sweep start ==="
    echo "visible BEFORE: $(visible_now)"
    i=0
    while [ "$i" -lt 12 ]; do
        d=$(sweep_once)
        echo "  pass $i: deleted $d   still visible: $(visible_now)"
        i=$((i + 1))
        sleep 10
    done
    echo "visible AFTER: $(visible_now)"
    echo "=== done $(date) ==="
} >> "$LOG" 2>&1
