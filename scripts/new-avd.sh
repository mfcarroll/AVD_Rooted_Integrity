#!/usr/bin/env bash
# Build a rooted Pixel-class AVD from scratch, end to end.
#
# WHY: the manual setup is ~20 steps and easy to get subtly wrong, and a device
# whose Play Integrity identity has been burned cannot be un-burned — you need a
# FRESH device to measure anything. This makes rotation cheap so you can test a
# hypothesis on a clean identity instead of on a device Google has already
# judged.
#
# Usage:
#   ./scripts/new-avd.sh all            # run every phase in order
#   ./scripts/new-avd.sh create         # just make the AVD
#   ./scripts/new-avd.sh boot|root|harden|verify
#   AVD=My_Test_AVD ./scripts/new-avd.sh all
#
# Phases:
#   create  create the AVD on android-36 google_apis_playstore arm64-v8a and
#           apply device/avd-config/ (hw.wifi.enabled, advancedFeatures)
#   boot    cold boot on kernel-build/out/Image.gz
#   root    install the KSU-Next manager + the 4 modules, restore the shell-root
#           allowlist, reboot
#   harden  run install-device-setup.sh (keybox + profile + all boot scripts),
#           cold boot
#   verify  audit the hardening AND report the Google check-in id so you can see
#           immediately whether the identity actually rotated
#
# TWO MANUAL GATES (by design — neither can be scripted safely):
#   * after `root`  — if shell root is not active, open the KSU-Next manager and
#                     grant root to "shell". The allowlist restore usually makes
#                     this unnecessary.
#   * after `verify` — sign in to Google yourself. Never scripted here.
#
# DELIBERATELY NOT DONE: debloat. Your 3-green run was NOT debloated and the
# degraded run WAS. Until that is tested in isolation, debloating during setup
# bakes in an unattributable variable. Build, sign in, TEST, and only then
# debloat and test again.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AVD_NAME="${AVD:-Pixel_9_Fresh}"
# Resolve the SDK: explicit env first, then any location that actually has
# avdmanager AND the system image. $HOME/Library/Android/sdk often has the
# emulator binary but NOT the system images, which fails confusingly later.
resolve_sdk() {
    local c
    for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
             /Users/Shared/android/sdk "$HOME/Library/Android/sdk"; do
        [ -n "$c" ] || continue
        [ -x "$c/cmdline-tools/latest/bin/avdmanager" ] || continue
        [ -d "$c/system-images/android-36/google_apis_playstore/arm64-v8a" ] || continue
        printf '%s' "$c"; return 0
    done
    # second pass: accept avdmanager even without the image, so the error is
    # about the missing image rather than about avdmanager
    for c in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" \
             /Users/Shared/android/sdk "$HOME/Library/Android/sdk"; do
        [ -n "$c" ] && [ -x "$c/cmdline-tools/latest/bin/avdmanager" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
SDK="$(resolve_sdk)" || SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
IMAGE="system-images;android-36;google_apis_playstore;arm64-v8a"
CACHE="$REPO_ROOT/setup-cache"
KERNEL="$REPO_ROOT/kernel-build/out/Image.gz"
KSUD=/data/adb/ksud

# Local payloads are preferred over downloading: they are the exact set behind
# the known-good run, and the manager APK there is the "-spoofed" build whose
# package name is randomised (the installed one is kwlkkw.odbaum.pebxnq). A
# fresh download from GitHub would give you the STOCK package name and you would
# have to re-hide it by hand.
PAYLOADS="${PAYLOADS:-/Users/Shared/code/personal/avd-cloud-portable/payloads/ksu_modules}"

# Fallbacks if PAYLOADS is unavailable (device/modules.md — validated set).
MANAGER_URL="https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v3.2.0/KernelSU_Next_v3.2.0_33129-release.apk"
MOD_URLS="https://github.com/sidex15/susfs4ksu-module/releases/download/v1.5.2%2B_R27/ksu_module_susfs_1.5.2%2B.zip
https://github.com/PerformanC/ReZygisk/releases/download/v1.0.0/ReZygisk-v1.0.0-release.zip
https://github.com/osm0sis/PlayIntegrityFork/releases/download/v18/PlayIntegrityFork-v18.zip
https://github.com/JingMatrix/TEESimulator/releases/download/v3.2/TEESimulator-v3.2-67-Release.zip"

# NOT INSTALLED, deliberately: specter. It was only ever used to source
# keyboxes, and it actively fights this repo — it rewrites tricky_store/
# target.txt on EVERY boot (11 entries -> 2) and re-rolls the keybox whenever
# its action pipeline runs. Its one unique contribution, ro.boot.vbmeta.digest
# via boot_hash, is now handled by 01-avd-prop-spoof.sh, so nothing is lost.
# scripts/check-keybox.sh replaces its (demonstrably unreliable) revocation check.

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not on PATH"; }
need adb

wait_boot() {
    adb wait-for-device
    local i=0
    until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
        sleep 5; i=$((i+1)); [ "$i" -gt 90 ] && die "timed out waiting for boot"
    done
    say "boot_completed; letting boot scripts settle (~100s)"
    sleep 100
}

cold_boot() {
    adb emu kill >/dev/null 2>&1
    sleep 8
    say "cold booting $AVD_NAME on the custom kernel"
    ( cd "$REPO_ROOT" && ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK" \
        AVD="$AVD_NAME" nohup ./scripts/start_avd.sh \
        > "$CACHE/boot-$(date +%H%M%S).log" 2>&1 & )
    sleep 5
    wait_boot
}

# IMPORTANT: adb emu kill is a plug-pull and does NOT flush the guest
# filesystem. Anything just written to /data is lost unless you sync first.
# This cost us a silently-lost install once already.
sync_guest() { adb shell "su -c 'sync; sync'" >/dev/null 2>&1; }

phase_create() {
    say "PHASE create"
    local avdmanager="$SDK/cmdline-tools/latest/bin/avdmanager"
    [ -x "$avdmanager" ] || die "avdmanager not found under $SDK"
    [ -d "$SDK/$(echo "$IMAGE" | tr ';' '/')" ] || die "system image missing: $IMAGE"
    local avd_home="${ANDROID_AVD_HOME:-$HOME/.android/avd}"

    if [ -d "$avd_home/${AVD_NAME}.avd" ]; then
        ok "AVD $AVD_NAME already exists (skipping create)"
    else
        echo no | "$avdmanager" create avd -n "$AVD_NAME" -k "$IMAGE" -d pixel_9_pro_xl \
            >/dev/null 2>&1 || die "avdmanager create failed"
        ok "created AVD $AVD_NAME"
    fi

    local cfg="$avd_home/${AVD_NAME}.avd/config.ini"
    grep -q '^hw.wifi.enabled' "$cfg" 2>/dev/null || echo "hw.wifi.enabled = yes" >> "$cfg"
    # NOTE: advancedFeatures.ini (VirtioWifi=off) forces mac80211_hwsim, which
    # means Wi-Fi only comes up via service.d/10-wlan0-virtwifi.sh. Leaving it
    # OUT lets the emulator's VirtioWifi auto-connect, which is simpler and was
    # verified working. Copy it in only if you specifically need hwsim.
    ok "config.ini patched (hw.wifi.enabled=yes)"
    ok "advancedFeatures.ini deliberately NOT applied — VirtioWifi auto-connects"
}

phase_boot() {
    say "PHASE boot"
    [ -f "$KERNEL" ] || die "kernel missing: $KERNEL (build kernel-build/ first)"
    mkdir -p "$CACHE"
    cold_boot
    adb shell getprop ro.build.version.sdk | tr -d '\r' | grep -q 36 \
        && ok "booted, sdk=36" || bad "unexpected sdk level"
}

phase_root() {
    say "PHASE root"
    mkdir -p "$CACHE"
    need curl

    # --- manager APK ---
    local apk=""
    if [ -d "$PAYLOADS" ]; then
        apk=$(ls "$PAYLOADS"/*.apk 2>/dev/null | head -1)
        [ -n "$apk" ] && ok "manager from payloads: $(basename "$apk")"
    fi
    if [ -z "$apk" ] && [ -f "$CACHE/ksu-next-manager.apk" ]; then
        apk="$CACHE/ksu-next-manager.apk"; ok "manager from setup-cache"
    fi
    if [ -z "$apk" ]; then
        apk="$CACHE/ksu-next-manager.apk"
        say "downloading KSU-Next manager (STOCK package name — you will have to re-hide it)"
        curl -fL --retry 2 -o "$apk" "$MANAGER_URL" || die "manager download failed"
    fi
    adb install -r "$apk" >/dev/null 2>&1 && ok "manager installed" || bad "manager install failed"

    # --- the four modules (specter deliberately excluded; see header) ---
    local zips=""
    if [ -d "$PAYLOADS" ]; then
        zips=$(ls "$PAYLOADS"/*.zip 2>/dev/null | grep -vi specter)
        [ -n "$zips" ] && ok "modules from payloads ($(echo "$zips" | wc -l | tr -d ' ') zips, specter excluded)"
    fi
    if [ -z "$zips" ]; then
        local i=0
        for url in $MOD_URLS; do
            i=$((i+1)); local z="$CACHE/mod_$i.zip"
            [ -f "$z" ] || curl -fL --retry 2 -o "$z" "$url" || bad "download failed: $url"
            zips="$zips$z\n"
        done
        zips=$(printf "%b" "$zips" | grep .)
    fi

    printf '%s\n' "$zips" | while IFS= read -r z; do
        [ -f "$z" ] || continue
        local b; b=$(basename "$z")
        adb push "$z" /data/local/tmp/ >/dev/null 2>&1
        if adb shell "su -c '$KSUD module install /data/local/tmp/$b'" 2>&1 | grep -qiE "success|installed"; then
            ok "installed $b"
        else
            bad "install unclear: $b"
        fi
        adb shell "su -c 'rm -f /data/local/tmp/$b'" >/dev/null 2>&1
    done

    # Restore the shell-root grant rather than making you re-do it in the UI.
    if [ -f "$CACHE/ksu-allowlist.bin" ]; then
        adb push "$CACHE/ksu-allowlist.bin" /data/local/tmp/al >/dev/null 2>&1
        adb shell "su -c 'cp /data/local/tmp/al /data/adb/ksu/.allowlist && chmod 600 /data/adb/ksu/.allowlist && rm -f /data/local/tmp/al'" >/dev/null 2>&1 \
            && ok "restored KSU allowlist (shell root grant)" || bad "allowlist restore failed"
    fi

    sync_guest
    cold_boot

    if adb shell "su -c id" 2>/dev/null | grep -q 'uid=0'; then
        ok "shell root ACTIVE"
    else
        bad "shell root NOT active"
        echo
        echo "  MANUAL GATE: open the KernelSU-Next manager on the device and"
        echo "  grant root to 'shell', then re-run:  ./scripts/new-avd.sh harden"
        return 1
    fi
}

phase_harden() {
    say "PHASE harden"
    adb shell "su -c id" 2>/dev/null | grep -q 'uid=0' || die "shell root not active — finish the root phase first"
    ( cd "$REPO_ROOT" && ./scripts/install-device-setup.sh ) || die "install-device-setup.sh failed"
    sync_guest
    cold_boot
    ok "hardening installed and cold-booted"
}

phase_verify() {
    say "PHASE verify"
    echo "-- identity (THE gate: must differ from a burned device) --"
    local id
    id=$(adb shell "su -c 'cat /data/data/com.google.android.gms/files/checkin_id_token 2>/dev/null'" 2>/dev/null | tr -d '\r')
    if [ -z "$id" ]; then
        echo "     check-in id: (none yet — sign in, then re-run verify)"
    else
        echo "     check-in id: $id"
        case "$id" in
            4067661520090240516*) bad "SAME id as the burned device — identity did NOT rotate" ;;
            *) ok "identity differs from the known-burned id" ;;
        esac
    fi
    echo "-- hardening --"
    local n
    n=$(adb shell "su -c 'getprop | grep -ic emulator'" 2>/dev/null | tr -d '\r')
    [ "${n:-1}" = "0" ] && ok "no 'emulator' strings in props" || bad "$n props still contain 'emulator'"
    n=$(adb shell "su -c 'getprop | grep -icE \"ranchu|goldfish|qemu\"'" 2>/dev/null | tr -d '\r')
    echo "     ranchu/goldfish/qemu props remaining: ${n:-?} (adb.pubkey is expected)"
    adb shell "su -c 'tail -3 /data/adb/susfs-late.log 2>/dev/null'" 2>/dev/null | sed 's/^/     /'
    echo "-- radio HAL (was crash-looping on the old image) --"
    echo "     init.svc.vendor.radio-ranchu = $(adb shell getprop init.svc.vendor.radio-ranchu 2>/dev/null | tr -d '\r')"
    echo
    ( cd "$REPO_ROOT" && ./scripts/verify-integrity.sh ) || true
    echo
    say "NEXT: sign in to Google on the device, then run ./scripts/verify-integrity.sh --trigger"
    say "      Test BEFORE debloating. Then debloat and test again."
}

case "${1:-all}" in
    create) phase_create ;;
    boot)   phase_boot ;;
    root)   phase_root ;;
    harden) phase_harden ;;
    verify) phase_verify ;;
    all)    phase_create && phase_boot && phase_root && phase_harden && phase_verify ;;
    *)      die "unknown phase '${1}' (create|boot|root|harden|verify|all)" ;;
esac
