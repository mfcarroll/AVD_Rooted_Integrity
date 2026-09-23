#!/usr/bin/env bash
# Push the on-device integrity setup (device/data_adb/) onto a running, rooted
# AVD and install your keybox. Run this AFTER the AVD is booted with the custom
# kernel and the prerequisite modules are installed (see device/modules.md).
#
# It is idempotent: re-running overwrites the on-device copies.
#
# What it does:
#   1. Pushes post-fs-data.d/, service.d/, avd-fake/, susfs4ksu/ configs, and
#      tricky_store/ configs into /data/adb/.
#   2. Installs your keybox (device/data_adb/tricky_store/keybox.xml) at
#      /data/adb/tricky_store/keybox.xml with 0600 root:root.
#   3. Fixes exec bits and ownership.
#
# It does NOT install KSU-Next, the kernel, or the Magisk/KSU modules
# themselves — those are prerequisites (device/modules.md).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_ADB="$REPO_ROOT/device/data_adb"
KEYBOX="$DATA_ADB/tricky_store/keybox.xml"
PIF_PROFILE="$REPO_ROOT/device/pif/custom.pif.prop"

command -v adb >/dev/null 2>&1 || { echo "ERROR: adb not on PATH" >&2; exit 1; }
adb wait-for-device

# Confirm root is available.
if ! adb shell 'su -c id' 2>/dev/null | grep -q 'uid=0'; then
    echo "ERROR: 'su -c id' did not return uid=0. Is this AVD rooted (KSU-Next)?" >&2
    exit 1
fi

# PlayIntegrityFork must already be installed — it owns the profile file that is
# now the SINGLE SOURCE OF TRUTH for the whole spoof (00-make-fakes.sh derives
# the per-partition props, build.prop, dt_compatible, and security_patch from it).
if ! adb shell 'su -c "test -d /data/adb/modules/playintegrityfix && echo ok"' 2>/dev/null | grep -q ok; then
    echo "ERROR: /data/adb/modules/playintegrityfix not found." >&2
    echo "Install the PlayIntegrityFork module first (see device/modules.md), then re-run." >&2
    exit 1
fi
if [[ ! -f "$PIF_PROFILE" ]]; then
    echo "ERROR: $PIF_PROFILE not found (the device profile)." >&2
    exit 1
fi

# Keybox sanity check — refuse to push the placeholder.
if [[ ! -f "$KEYBOX" ]]; then
    echo "ERROR: $KEYBOX not found." >&2
    echo "Copy your real keybox there (it is .gitignored). See keybox.xml.example." >&2
    exit 1
fi
if grep -q 'REPLACE_WITH_YOUR' "$KEYBOX" 2>/dev/null; then
    echo "ERROR: $KEYBOX is still the placeholder. Install a real keybox first." >&2
    exit 1
fi

STAGE=/data/local/tmp/avd-setup
echo "==> staging files to $STAGE"
adb shell "rm -rf $STAGE && mkdir -p $STAGE"
adb push "$DATA_ADB/post-fs-data.d" "$STAGE/" >/dev/null
adb push "$DATA_ADB/service.d"      "$STAGE/" >/dev/null
adb push "$DATA_ADB/avd-fake"       "$STAGE/" >/dev/null
adb push "$DATA_ADB/susfs4ksu"      "$STAGE/susfs4ksu" >/dev/null
adb push "$DATA_ADB/tricky_store"   "$STAGE/tricky_store" >/dev/null
adb push "$PIF_PROFILE"             "$STAGE/custom.pif.prop" >/dev/null

echo "==> installing into /data/adb (as root)"
# NOTE: no 'set -e' on purpose. A previous boot may have chattr +i'd
# security_patch.txt / tee_status.txt; a single EPERM must not abort the whole
# install and leave /data/adb half-written. We clear every immutable bit FIRST,
# then copy, so the install is idempotent and self-healing.
adb shell "su -c '
  # 0) Clear any immutable bits left by a prior boot (so every cp below works).
  chattr -i /data/adb/tricky_store/security_patch.txt 2>/dev/null
  chattr -i /data/adb/tricky_store/tee_status.txt     2>/dev/null

  mkdir -p /data/adb/post-fs-data.d /data/adb/service.d
  cp -f  $STAGE/post-fs-data.d/*.sh /data/adb/post-fs-data.d/
  cp -f  $STAGE/service.d/*.sh      /data/adb/service.d/
  mkdir -p /data/adb/avd-fake
  cp -f  $STAGE/avd-fake/*          /data/adb/avd-fake/

  # SUSFS + TrickyStore config (do not clobber the keybox via the wildcard).
  mkdir -p /data/adb/susfs4ksu /data/adb/tricky_store
  cp -f  $STAGE/susfs4ksu/*        /data/adb/susfs4ksu/
  cp -f  $STAGE/tricky_store/target.txt         /data/adb/tricky_store/
  cp -f  $STAGE/tricky_store/security_patch.txt /data/adb/tricky_store/

  # Keybox: 0644 root:root. It must be world-READABLE: TEESimulator runs
  # injected into the keystore2/keymint process (not as root), so a 0600
  # root-only keybox is unreadable there and TEESimulator silently falls back to
  # PATCH mode (broken chain). The known-good reference AVD ships it 0644.
  cp -f  $STAGE/tricky_store/keybox.xml /data/adb/tricky_store/keybox.xml
  chown root:root /data/adb/tricky_store/keybox.xml
  chmod 644 /data/adb/tricky_store/keybox.xml

  # tee_status.txt = tee_broken=true (08-tee-broken.sh re-asserts + locks at boot).
  cp -f  $STAGE/tricky_store/tee_status.txt /data/adb/tricky_store/tee_status.txt

  # Install the PIF profile (single source of truth). PIF reads custom.pif.prop
  # for its Build.* spoof; 00-make-fakes.sh derives everything else from it.
  if [ -d /data/adb/modules/playintegrityfix ]; then
    cp -f  $STAGE/custom.pif.prop /data/adb/modules/playintegrityfix/custom.pif.prop
    chmod 644 /data/adb/modules/playintegrityfix/custom.pif.prop
  fi
  # Belt-and-suspenders: also seed modules_update/ so PIF does not autopif-fetch
  # a different profile on first activation.
  if [ -d /data/adb/modules_update/playintegrityfix ]; then
    cp -f $STAGE/custom.pif.prop /data/adb/modules_update/playintegrityfix/custom.pif.prop
  fi

  chmod 0755 /data/adb/post-fs-data.d/*.sh /data/adb/service.d/*.sh
  rm -rf $STAGE
  echo OK
'"

echo
echo "==> done. Apply with a clean COLD REBOOT:"
echo "      adb reboot"
echo
echo "    Do NOT 'killall keystore2 / keymint / TEESimulator' to apply this."
echo "    A manual restart flips TEESimulator into PATCH mode and the Play"
echo "    Integrity verdict comes back EMPTY. Cold reboot is the only correct"
echo "    way to apply changes (and the only recovery if integrity is lost)."
echo "    See docs/INTEGRITY_CHAIN.md 'Layer 1b' / docs/REPRODUCTION.md §7."
echo
echo "    After boot, verify with:  ./scripts/verify-integrity.sh"
