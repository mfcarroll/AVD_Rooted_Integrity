#!/system/bin/sh
# Prop spoof driven by the ACTIVE PROFILE (single source of truth).
#
# BUG THIS FIXES: this script used to HARDCODE the tokay/CANARY build values,
# which silently contradicted device/modules.md ("applies every per-partition
# prop + fingerprint from the same profile.env"). It never read profile.env.
#
# The effect was that editing custom.pif.prop updated PIF's Build.* spoof,
# profile.env, the bind-mounted vendor_build.prop AND security_patch.txt — but
# these resetprop calls kept re-asserting the OLD build on every boot. So the
# device profile could not actually be changed, and worse, the live props ended
# up DISAGREEING with the bind-mounted build.prop: exactly the cross-layer
# inconsistency that produces CANNOT_ATTEST_IDS / an empty Play Integrity
# verdict. Any profile change silently did nothing.
#
# It now sources /data/adb/avd-fake/profile.env (written by 00-make-fakes.sh
# from custom.pif.prop). The literals below are ONLY a fallback for when that
# file is missing.

LOG=/data/adb/avd-prop-spoof.log
RP=/data/adb/ksu/bin/resetprop
PROFILE=/data/adb/avd-fake/profile.env

# Fallback values (used only if profile.env is absent).
PIX_FP="google/tokay_beta/tokay:CANARY/ZP11.260417.009/15372612:user/release-keys"
PIX_DEV=tokay
PIX_PROD=tokay_beta
PIX_BRD=tokay
PIX_BRAND=google
PIX_MFR=Google
PIX_MODEL="Pixel 9"
PIX_ID=ZP11.260417.009
PIX_INC=15372612
PIX_PATCH=2026-05-05

# Prefer the generated profile so this layer can never drift from the others.
if [ -f "$PROFILE" ]; then
  . "$PROFILE"
  [ -n "$FINGERPRINT" ]    && PIX_FP="$FINGERPRINT"
  [ -n "$DEVICE" ]         && PIX_DEV="$DEVICE"
  [ -n "$DEVICE" ]         && PIX_BRD="$DEVICE"
  [ -n "$PRODUCT" ]        && PIX_PROD="$PRODUCT"
  [ -n "$BRAND" ]          && PIX_BRAND="$BRAND"
  [ -n "$MANUFACTURER" ]   && PIX_MFR="$MANUFACTURER"
  [ -n "$MODEL" ]          && PIX_MODEL="$MODEL"
  [ -n "$BUILD_ID" ]       && PIX_ID="$BUILD_ID"
  [ -n "$INCREMENTAL" ]    && PIX_INC="$INCREMENTAL"
  [ -n "$SECURITY_PATCH" ] && PIX_PATCH="$SECURITY_PATCH"
  PROFILE_SRC="profile.env"
else
  PROFILE_SRC="HARDCODED FALLBACK (profile.env missing!)"
fi

{
  echo "=== $(date) avd-prop-spoof start (source: $PROFILE_SRC) ==="
  echo "    fp=$PIX_FP patch=$PIX_PATCH"

  # Clear qemu-detection knobs
  $RP -n -d ro.boot.qemu 2>/dev/null
  $RP -n ro.kernel.qemu 0
  $RP -n ro.kernel.qemu.gles 0
  $RP -n -d ro.boot.virtio_mmio 2>/dev/null

  # Hardware
  $RP -n ro.hardware "$PIX_DEV"
  $RP -n ro.boot.hardware "$PIX_DEV"
  $RP -n ro.boot.hardware.platform "$PIX_DEV"
  $RP -n ro.product.board "$PIX_BRD"
  $RP -n ro.board.platform "$PIX_BRD"

  # Product props (all partitions)
  for P in "" .vendor .system .odm .product .system_ext .system_dlkm .vendor_dlkm; do
    $RP -n "ro.product${P}.brand"        "$PIX_BRAND"
    $RP -n "ro.product${P}.device"       "$PIX_DEV"
    $RP -n "ro.product${P}.manufacturer" "$PIX_MFR"
    $RP -n "ro.product${P}.model"        "$PIX_MODEL"
    $RP -n "ro.product${P}.name"         "$PIX_PROD"
  done

  # Build fingerprints (all partitions)
  for P in "" .vendor .system .odm .product .system_ext .system_dlkm .vendor_dlkm .bootimage .boot; do
    $RP -n "ro${P}.build.fingerprint" "$PIX_FP"
  done

  $RP -n ro.build.product       "$PIX_PROD"
  $RP -n ro.build.id            "$PIX_ID"
  $RP -n ro.build.version.incremental "$PIX_INC"
  $RP -n ro.build.version.security_patch "$PIX_PATCH"
  $RP -n ro.build.tags          "release-keys"
  $RP -n ro.build.type          "user"

  # Vendor build
  $RP -n ro.vendor.build.security_patch "$PIX_PATCH"

  # Verified boot state
  $RP -n ro.boot.flash.locked       "1"
  $RP -n ro.boot.veritymode         "enforcing"
  $RP -n ro.boot.vbmeta.device_state "locked"
  $RP -n ro.boot.verifiedbootstate  "green"
  $RP -n ro.debuggable              "0"
  $RP -n ro.secure                  "1"

  # Bootloader
  $RP -n ro.bootloader      "${PIX_DEV}-1.0-13344233"
  $RP -n ro.boot.bootloader "${PIX_DEV}-1.0-13344233"

  # SoC
  $RP -n ro.soc.model        "Tensor G4"
  $RP -n ro.soc.manufacturer "Google"

  echo "=== done $(date) ==="
} >> "$LOG" 2>&1
