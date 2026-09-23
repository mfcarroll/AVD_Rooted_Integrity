#!/system/bin/sh
# Late SUSFS/SELinux fixes — things that provably do NOT take effect at
# post-fs-data and must be (re)applied after boot_completed.
#
# 1. sus_map (Layer 4). 02-avd-deeper-spoof.sh calls add_sus_map at
#    post-fs-data. Verified by kernel log: those calls produce ZERO
#    `susfs_add_sus_map` entries, while identical calls after boot register
#    immediately. So Layer 4 -- which INTEGRITY_CHAIN.md says "alone fails PI"
#    if it leaks -- has never actually been applied on a normal boot. Re-apply
#    here and CONFIRM against dmesg rather than trusting the exit code.
#
# 2. SELinux read access to the faked /proc files. 07-procbind-safe.sh
#    bind-mounts /data/adb/avd-fake/* over /proc/{cpuinfo,version,modules,
#    cmdline}. The bind mount carries the SOURCE label with it, so those /proc
#    entries end up labelled u:object_r:adb_data_file:s0 instead of a proc
#    type. App domains cannot read adb_data_file, so this was observed live:
#      avc: denied { read } name="cpuinfo" scontext=u:r:gmscore_app ...
#      avc: denied { read } name="modules" scontext=u:r:gmscore_app ...
#      avc: denied { read } name="cpuinfo" scontext=u:r:system_server ...
#    i.e. Google Play Services could not read /proc/cpuinfo at all. No real
#    device denies that; an EACCES there is a louder anomaly than leaking
#    "ranchu" would be. chcon to a proc type is refused by policy, so grant the
#    read instead. KernelSU-Next ships this as `ksud sepolicy` (the repo's
#    00-zygisk-sepolicy.sh wants /data/adb/magiskpolicy, which has never
#    existed here).
#
# NOTE: neither fix changed the Play Integrity verdict in testing
# (MEETS_DEVICE_INTEGRITY either way). They are correctness fixes for
# documented layers that were silently broken, not a verdict cure.

LOG=/data/adb/susfs-late.log
SUSFS=/data/adb/ksu/bin/ksu_susfs
KSUD=/data/adb/ksud

log() { echo "$*" >> "$LOG"; }

while [ "$(getprop sys.boot_completed)" != "1" ]; do sleep 2; done
sleep 20

{
    echo "=== $(date) susfs-late start ==="
} >> "$LOG"

# --- 1. sus_map, verified against the kernel log -----------------------------
before=$(dmesg 2>/dev/null | grep -c susfs_add_sus_map)
for so in /data/adb/modules/playintegrityfix/zygisk/arm64-v8a.so \
          /data/adb/modules/zygisk_vector/zygisk/arm64-v8a.so \
          /data/adb/modules/rezygisk/lib64/libzygisk.so \
          /data/adb/modules/tricky_store/libTEESimulator.so; do
    [ -f "$so" ] || continue
    "$SUSFS" add_sus_map "$so" >/dev/null 2>&1
done
after=$(dmesg 2>/dev/null | grep -c susfs_add_sus_map)
log "sus_map: kernel entries ${before} -> ${after} ($(( (after - before) / 2 )) libs registered)"
[ "$after" -gt "$before" ] || log "  !! sus_map did NOT register — Layer 4 is not applied"

# --- 2. let app domains read the bind-mounted /proc fakes --------------------
if [ -x "$KSUD" ]; then
    n=0
    for dom in gmscore_app system_server untrusted_app priv_app platform_app shell; do
        "$KSUD" sepolicy patch "allow $dom adb_data_file file { read open getattr }" \
            >/dev/null 2>&1 && n=$((n + 1))
    done
    log "sepolicy: granted adb_data_file read to $n/6 domains"
else
    log "  !! ksud not found — /proc fakes stay unreadable to apps"
fi

log "=== done $(date) ==="
