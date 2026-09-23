#!/system/bin/sh
# Deeper AVD-detection hiding: /proc/{cpuinfo,version,cmdline,modules}
# redirected via SUSFS to fake files, and AVD-specific /dev nodes
# (qemu_pipe) hidden via SUSFS sus_path.
#
# NOTE: we used to also sus_path /dev/goldfish_address_space, _sync, and
# _pipe_dprctd, but on the newer SUSFS we ship with the custom kernel,
# those sus_path entries also block system services like mapper.ranchu
# from opening them -- which fails graphics bringup ("GoldfishAddressSpace
# HostMemoryAllocator failed to open") and gives a black screen. We now
# leave the goldfish devnodes visible; apps detect by reading /proc/cpuinfo
# etc. which we still spoof, and by directly opening goldfish_* which we
# can't hide here without breaking SurfaceFlinger.

LOG=/data/adb/avd-deeper-spoof.log
SUSFS=/data/adb/ksu/bin/ksu_susfs
FAKE_DIR=/data/adb/avd-fake

# add_open_redirect REQUIRES THREE ARGS: <target> <redirect> <uid_scheme>.
# This script used to pass only two, so ksu_susfs printed its usage text and did
# NOTHING -- on every boot since the first commit -- while the unconditional
# `echo "redirect ..."` on the next line reported success. All four /proc
# redirects have therefore never existed; only the 07 bind-mounts were holding
# Layer 3 up. uid_scheme 2 = "effective for non-su processes", which is what
# covers app processes such as com.google.android.gms.
#   0 non-app (uid<10000) | 1 root non-su | 2 all non-su | 3 umounted apps | 4 umounted
REDIRECT_UID_SCHEME=2

# Run a ksu_susfs subcommand and report real success/failure. ksu_susfs exits 0
# even when it only prints usage, so detect that explicitly.
susfs_do() {
    _out=$("$SUSFS" "$@" 2>&1); _rc=$?
    case "$_out" in
        *"usage: ksu_susfs"*)
            echo "  !! BAD ARGS (ksu_susfs printed usage): $*"
            return 1 ;;
    esac
    [ "$_rc" -ne 0 ] && { echo "  !! FAILED (rc=$_rc): $*"; return 1; }
    return 0
}

{
  echo "=== $(date) avd-deeper-spoof start ==="

  if [ ! -d "$FAKE_DIR" ]; then
    echo "WARN: $FAKE_DIR missing -- skip redirects"
    exit 0
  fi

  if [ -f "$FAKE_DIR/cpuinfo" ]; then
    susfs_do add_open_redirect /proc/cpuinfo "$FAKE_DIR/cpuinfo" "$REDIRECT_UID_SCHEME" && echo "redirect /proc/cpuinfo"
  fi
  if [ -f "$FAKE_DIR/version" ]; then
    susfs_do add_open_redirect /proc/version "$FAKE_DIR/version" "$REDIRECT_UID_SCHEME" && echo "redirect /proc/version"
  fi
  if [ -f "$FAKE_DIR/modules" ]; then
    susfs_do add_open_redirect /proc/modules "$FAKE_DIR/modules" "$REDIRECT_UID_SCHEME" && echo "redirect /proc/modules"
  fi
  if [ -f /data/adb/susfs4ksu/spoofed_cmdline ]; then
    susfs_do add_open_redirect /proc/cmdline /data/adb/susfs4ksu/spoofed_cmdline "$REDIRECT_UID_SCHEME" && echo "redirect /proc/cmdline"
  fi

  # Hide ONLY qemu-named devnodes. Not goldfish_* (system services need those).
  for node in /dev/qemu_pipe /dev/qemu_trace; do
    if [ -e "$node" ]; then
      $SUSFS add_sus_path "$node" 2>&1
      echo "sus_path $node"
    fi
  done

  # Hide every Zygisk module's injected .so file from /proc/self/maps.
  # Without this, gms.unstable and com.android.vending can see the strings
  # "playintegrityfix", "zygisk_vector", "rezygisk", "tricky_store" in
  # their own memory map -- that's a direct Play Integrity failure.
  for so in \
      /data/adb/modules/playintegrityfix/zygisk/arm64-v8a.so \
      /data/adb/modules/zygisk_vector/zygisk/arm64-v8a.so \
      /data/adb/modules/rezygisk/lib64/libzygisk.so \
      /data/adb/modules/tricky_store/libTEESimulator.so
  do
      [ -f "$so" ] && { susfs_do add_sus_map "$so" && echo "sus_map $so"; }
  done

  echo "=== done ==="
} >> "$LOG" 2>&1
