#!/system/bin/sh
# Comprehensive emulator-property scrub. Runs at post-fs-data after
# 01-avd-prop-spoof.sh sets the Pixel identity. This deletes / overwrites
# every ro.boot.qemu.*, ro.boottime.*emulator*, qemu.*, ranchu* and goldfish*
# property that's visible via getprop.
#
# These properties get re-set by init from /system/etc/build.prop and
# /vendor/build.prop on every boot, so post-fs-data is the right phase.

LOG=/data/adb/prop-sweep.log
RP=/data/adb/ksu/bin/resetprop

{
  echo "=== $(date) prop-sweep start ==="

  # 1) DELETE all visible init.svc.*/init.svc_debug_pid.* with emulator names
  DEL=0
  # NOTE: this used to use sed with \| alternation, which toybox sed (Android's
  # sed) does NOT support — it is a GNU extension. The pattern silently matched
  # NOTHING, so this loop deleted 0 props on every boot since the first commit
  # while logging "deleted 0" as if that were success. grep -E does support
  # alternation, so prefilter with it and keep the sed trivial.
  for prop in $(getprop 2>/dev/null \
                | grep -E '^\[init\.svc[^]]*(ranchu|qemu|goldfish)' \
                | sed -n 's/^\[\([^]]*\)\].*/\1/p'); do
    $RP -n -d "$prop" 2>/dev/null && DEL=$((DEL + 1))
  done
  echo "deleted $DEL init.svc.* emulator props"

  # 2) DELETE every ro.boottime.* with emulator names (visible to apps)
  DEL=0
  for prop in $(getprop 2>/dev/null \
                | grep -E '^\[ro\.boottime[^]]*(ranchu|qemu|goldfish)' \
                | sed -n 's/^\[\([^]]*\)\].*/\1/p'); do
    $RP -n -d "$prop" 2>/dev/null && DEL=$((DEL + 1))
  done
  echo "deleted $DEL ro.boottime.* emulator props"

  # 3) DELETE / overwrite ro.boot.qemu.* (literal "qemu" in the name)
  # We can't delete ro.boot.qemu.adb.pubkey -- adbd uses it -- so we keep that.
  DEL=0
  for prop in $(getprop 2>/dev/null \
                | sed -n 's/^\[\(ro\.boot\.qemu\.[^]]*\)\].*/\1/p'); do
    case "$prop" in
      ro.boot.qemu.adb.pubkey) continue ;;
    esac
    $RP -n -d "$prop" 2>/dev/null && DEL=$((DEL + 1))
  done
  echo "deleted $DEL ro.boot.qemu.* props"

  # 4) DELETE qemu.* user-mutable props
  DEL=0
  for prop in $(getprop 2>/dev/null \
                | sed -n 's/^\[\(qemu\.[^]]*\)\].*/\1/p'); do
    $RP -n -d "$prop" 2>/dev/null && DEL=$((DEL + 1))
  done
  echo "deleted $DEL qemu.* props"

  # 5) OVERWRITE specific ranchu/goldfish-valued props with Pixel-shaped vals.
  # Derive the device name from the active profile (single source of truth) so
  # this never contradicts 01-avd-prop-spoof.sh. (Previously hardcoded "comet" =
  # Pixel 9 Pro Fold, which disagreed with a tokay profile.)
  DEVICE=tokay
  [ -f /data/adb/avd-fake/profile.env ] && . /data/adb/avd-fake/profile.env
  $RP -n ro.boot.hardware.vulkan   "$DEVICE"
  $RP -n ro.hardware.vulkan        "$DEVICE"
  $RP -n ro.hardware.audio.primary cs35l45
  $RP -n ro.boot.hardware          "$DEVICE"
  $RP -n ro.hardware               "$DEVICE"

  # 6) Final accounting
  echo "remaining ranchu  occurrences: $(getprop 2>/dev/null | grep -c ranchu)"
  echo "remaining qemu    occurrences: $(getprop 2>/dev/null | grep -c qemu)"
  echo "remaining goldfish occurrences: $(getprop 2>/dev/null | grep -c goldfish)"

  echo "=== done ==="
} >> "$LOG" 2>&1
