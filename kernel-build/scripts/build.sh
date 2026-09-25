#!/bin/bash
# Build the AOSP common-android15-6.6 kernel with our patches applied.
#
#   ./scripts/build.sh              # arm64 (default) -> out/Image, out/Image.gz
#   ./scripts/build.sh --arch x86_64  #              -> out/bzImage
#
# Re-run safe: incremental builds work via ccache.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${ROOT}/sources/kernel"

. "${ROOT}/scripts/arch-env.sh"
arch_parse "$@"

MARKER="${KERNEL_DIR}/$(arch_marker_file)"
if [[ ! -f "${MARKER}" ]]; then
    echo "ERROR: patches not yet applied. Run scripts/apply-patches.sh first." >&2
    exit 1
fi

# The marker carries the arch the tree was patched for. Refuse a mismatch
# instead of producing a kernel that boots but has no working root.
patched_arch="$(cat "${MARKER}" 2>/dev/null || true)"
patched_arch="${patched_arch:-arm64}"   # markers written before this check
if [[ "${patched_arch}" != "${KERNEL_ARCH}" ]]; then
    cat >&2 <<EOF
ERROR: source tree is patched for '${patched_arch}' but you asked for '${KERNEL_ARCH}'.
       The arches apply different patch sets, so this would silently build a
       kernel missing its arch-specific fixes. Re-patch first:
           ./scripts/apply-patches.sh --arch ${KERNEL_ARCH}
EOF
    exit 1
fi

cd "${KERNEL_DIR}"

# With LLVM=1 LLVM_IAS=1 the kernel uses clang for compilation, integrated
# assembler, ld.lld for linking, llvm-objcopy. CROSS_COMPILE is still set so
# helpers that shell out to ${CROSS_COMPILE}gcc find the right gcc.
export ARCH="${KBUILD_ARCH}"
export CROSS_COMPILE="${KBUILD_CROSS}"
export LLVM=1
export LLVM_IAS=1
# ccache wraps via /usr/lib/ccache symlinks already on PATH
export CC=clang
export HOSTCC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip

# Pin the identity stamped into the kernel banner.
#
# Two reasons. Reproducibility: without these the banner carries the build host
# and wall-clock time, so two CI runs of the SAME commit produce different bytes
# and the images cannot be compared. Measured: two runs of one commit differed
# by ~40 KB after gzip amplified the change.
#
# And disclosure: the default reads `root@<docker-container-id>`, e.g.
# root@29806e91e7ad. This kernel is the centrepiece of an anti-detection stack;
# announcing that it was built as root inside a container works against that.
# android-build@abfarm-2003 is what real AOSP GKI release kernels report.
#
# Not cosmetic. /proc/version is readable by any app, and the previous value said
# "(build-user@build-host) ... Ubuntu clang version 18.1.3" — a self-built kernel
# announced in one line. Userspace could not fix it: a bind mount over
# /proc/version is access-checked against the SOURCE inode's SELinux label, and
# nothing reachable from /data/adb is readable by an app. Fixing the banner here
# removes the need for that spoof entirely.
#
# The timestamp comes from the pinned kernel tag's own commit date, so it is
# deterministic for a given KERNEL_TAG and still a plausible build date --
# rather than a hardcoded lie that drifts further from the source every release.
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-android-build}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-abfarm-2003}"
if [[ -z "${KBUILD_BUILD_TIMESTAMP:-}" ]]; then
    # format-local + TZ=UTC so the stamp does not depend on the builder's
    # timezone, and UTC is spelled literally: git's %Z renders empty here, which
    # left a double space where the zone belongs.
    KBUILD_BUILD_TIMESTAMP=$(TZ=UTC git -C "${KERNEL_DIR}" log -1 \
        --format=%cd --date=format-local:'%a %b %e %T UTC %Y' 2>/dev/null || true)
    # A source tree with no git metadata must not silently fall back to "now" --
    # that is exactly the non-determinism this block exists to remove.
    if [[ -z "${KBUILD_BUILD_TIMESTAMP}" ]]; then
        echo "ERROR: cannot derive a deterministic build timestamp from ${KERNEL_DIR}." >&2
        echo "       Set KBUILD_BUILD_TIMESTAMP explicitly to build anyway." >&2
        exit 1
    fi
    export KBUILD_BUILD_TIMESTAMP
fi
# The compiler string is the other half of the giveaway. mkcompile_h builds
# LINUX_COMPILER from "${CC_VERSION}, ${LD_VERSION}", which here is Ubuntu clang.
# customize-kernel.sh patches that script to honour this variable; without the
# patch it is ignored, so an unpatched tree degrades to the old string rather
# than failing to build.
export KBUILD_COMPILER_STRING="${KBUILD_COMPILER_STRING:-Android (12027248, +pgo, +bolt, +lto, +mlgo, based on r522817b) clang version 18.0.3 (https://android.googlesource.com/toolchain/llvm-project 5f78b6f0b58c5734b16dd92dbab2bfa19e9c5e3a), LLD 18.0.3}"

echo "==> banner identity: ${KBUILD_BUILD_USER}@${KBUILD_BUILD_HOST}, ${KBUILD_BUILD_TIMESTAMP}"

JOBS="${JOBS:-$(nproc)}"

echo "==> Building for ${KERNEL_ARCH} (ARCH=${ARCH}, CROSS_COMPILE=${CROSS_COMPILE})"

# x86_64 starts from Google's OWN kernel-ranchu config, not gki_defconfig.
#
# The AVD's graphics stack lives in VENDOR modules -- goldfish_address_space,
# goldfish_sync, virtio-gpu -- loaded from /vendor/lib/modules. Google's config
# does not even set CONFIG_GOLDFISH, and has VIRTIO_BLK=m: those modules are
# built separately against that exact kernel, so they carry its struct module
# layout and refuse to load into anything else:
#
#   .gnu.linkonce.this_module section size must match the kernel's built
#   struct module size at run time
#
# Chasing that field by field did not converge. BTF was one difference and
# fixing it changed nothing; struct module has a dozen conditional fields and we
# were guessing at them one build at a time.
#
# configs/x86_64-ranchu.config is that kernel's own config, taken from
# /proc/config.gz on a stock boot of the same android-36 x86_64 image. Same
# 6.6.66 we build. Starting from it makes ABI agreement the default rather than
# something to be reverse-engineered, and our KSU/SUSFS options are appended on
# top -- none of them add fields to struct module.
echo "==> defconfig"
if [[ "${KERNEL_ARCH}" == "x86_64" ]]; then
    _ref="${ROOT}/configs/x86_64-ranchu.config"
    [[ -f "$_ref" ]] || { echo "ERROR: missing ${_ref}" >&2; exit 1; }
    echo "    base: configs/x86_64-ranchu.config (Google's kernel-ranchu)"
    cp "$_ref" .config
else
    make -j "${JOBS}" gki_defconfig
fi

# Append config overrides:
#  - KernelSU + every SUSFS feature
#  - LSM stack without baseband_guard (the Wild kernel added it; AOSP common
#    doesn't ship it, so we just guarantee the value we want)
#  - LOCALVERSION/host so the kernel banner doesn't say "android15-6.6-Wild"
cat >> .config <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,selinux,smack,tomoyo,apparmor,bpf"
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_DEFAULT_HOSTNAME="localhost"
# ARM64 ONLY: we do NOT force virtio_*/goldfish_*/dmabuf/binder/drm to =y. The
# defconfig leaves them as =m to match the AVD's prebuilt /lib/modules/*.ko,
# and Wild's vermagic-bypass hack (applied earlier in apply-patches.sh) lets
# those .ko files load despite version mismatch. Forcing them =y would cause
# init's insmod calls to fail with "Device or resource busy" -> kernel panic.
#
# x86_64 is the opposite and forces them =y -- see the block further down.
# There the prebuilt modules are rejected outright on a struct-size check the
# vermagic bypass does not cover, so leaving them as =m means no block devices
# and a boot loop.
EOF

# LOCALVERSION NAMES NO DEVICE, deliberately. Appended here rather than inside
# the quoted heredoc above so the sha can be interpolated.
#
# It was "-android16-5-Pixel10Pro". Once /proc/version reports this string for
# real rather than through a spoof, a device name in it has to agree with what
# the PIF profile claims — and that profile claims a Pixel 9 Pro Fold, which runs
# a 6.1 kernel, not 6.6.66. Rather than couple the two and let them drift (they
# already did: uname, /proc/version and the profile told three different
# stories), the kernel identifies itself as generic Google GKI and cannot
# contradict any device.
#
# -g<sha> is this tree's real HEAD, a genuine android.googlesource.com commit.
# -ab<n> is a plausible Android build number: arbitrary, and only has to look
# like one.
KERNEL_SCM_SHA=$(git -C "${KERNEL_DIR}" rev-parse --short=12 HEAD 2>/dev/null || echo 000000000000)
echo "CONFIG_LOCALVERSION=\"-android16-5-g${KERNEL_SCM_SHA}-ab13070261\"" >> .config
echo "==> localversion: -android16-5-g${KERNEL_SCM_SHA}-ab13070261"

# ARM64: keep BTF OFF, explicitly.
#
# gki_defconfig asks for CONFIG_DEBUG_INFO_BTF=y, but this image had no pahole
# until the x86_64 work added dwarves, so the option was silently unselectable
# and every arm64 kernel built here so far -- including the one in
# payloads/kernel/ that reaches MEETS_STRONG_INTEGRITY -- was built WITHOUT it.
#
# Adding dwarves to the shared image therefore changed arm64 too, unasked: the
# artifact grew 12.8MB -> 14.8MB and resolve_btfids ran. BTF adds a field to
# struct module, and whether the AVD's prebuilt modules load depends on that
# layout matching. Flipping it silently on the stack that works is exactly the
# wrong trade.
#
# So pin it off here and keep CI reproducing the validated kernel. Turning it on
# for arm64 may well be an improvement -- it is what Google ships -- but that is
# a deliberate experiment that has to end in a re-measured integrity verdict,
# not a side effect of an x86_64 fix.
if [[ "${KERNEL_ARCH}" == "arm64" ]]; then
    cat >> .config <<'EOF'
# CONFIG_DEBUG_INFO_BTF is not set
# CONFIG_DEBUG_INFO_BTF_MODULES is not set
EOF
fi

# x86_64 hooks KSU through the indirect syscall table, which the 6.6 syscall
# hardening replaces with direct branches. patches/x86_64/ restores an indirect
# path behind X86_FEATURE_INDIRECT_SAFE, selected at runtime with
# `syscall_hardening=off` on the kernel cmdline (start_avd.sh passes it).
# Do NOT also enable CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER -- pick one method.
if [[ "${KERNEL_ARCH}" == "x86_64" ]]; then
    cat >> .config <<'EOF'
# CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER is not set
EOF
fi

# Nothing is forced built-in here, deliberately.
#
# Earlier revisions built virtio and goldfish drivers in to work around the
# struct module mismatch. Basing this config on Google's kernel-ranchu removed
# that mismatch, and the built-ins then became the problem: the vendor
# goldfish_pipe.ko could not load because our AOSP-common one already held the
# device --
#
#   Failed to insmod '/vendor/lib/modules/goldfish_pipe.ko': Device or resource busy
#
# -- and goldfish_address_space is built against the VENDOR goldfish_pipe, not
# ours. Google's config sets no CONFIG_GOLDFISH at all and ships virtio as
# modules; the vendor DLKMs are meant to be the whole story.
#
# So match that and let them load. If a driver is missing, the fix is to find
# out why its module was rejected, not to build a different version of it in
# alongside.


make -j "${JOBS}" olddefconfig

# olddefconfig silently DROPS any symbol whose dependencies are unmet, so an
# appended "CONFIG_X=y" is a request, not a result. Getting that wrong here
# costs a full rebuild plus a boot to discover the identical panic, so check
# what actually landed.
if [[ "${KERNEL_ARCH}" == "x86_64" ]]; then
    # What matters now is ABI agreement with the vendor modules, not which
    # drivers are built in. Check the options that change struct module layout
    # and are the reason those modules load at all.
    _missing=()
    # NOT CONFIG_MODULE_SCMVERSION, though Google's config sets it: the symbol
    # is defined in no Kconfig in this tree, and struct module carries
    # `const char *scmversion` UNCONDITIONALLY (include/linux/module.h:422, no
    # ifdef). It controls whether a build stamp is populated, not the layout --
    # which is why the modules already loaded without it.
    for sym in CONFIG_DEBUG_INFO_BTF CONFIG_DEBUG_INFO_BTF_MODULES \
               CONFIG_MODULE_UNLOAD \
               CONFIG_KSU CONFIG_KSU_SUSFS; do
        grep -qx "${sym}=y" .config || _missing+=("$sym")
    done
    if (( ${#_missing[@]} )); then
        echo "ERROR: these are not =y in the x86_64 .config:" >&2
        for sym in "${_missing[@]}"; do
            printf '       %s -> %s\n' "$sym" "$(grep -E "^(# )?${sym}[ =]" .config || echo 'absent')" >&2
        done
        echo "       The BTF and MODULE_* ones change struct module layout; losing" >&2
        echo "       them means the AVD's vendor modules stop loading and the guest" >&2
        echo "       boots to a black screen with surfaceflinger crash-looping." >&2
        exit 1
    fi
    # And the inverse: building goldfish in shadows the vendor module, which is
    # what goldfish_address_space is actually linked against.
    if grep -qx 'CONFIG_GOLDFISH_PIPE=y' .config; then
        echo "ERROR: goldfish_pipe is built in." >&2
        echo "       The vendor goldfish_pipe.ko then fails with 'Device or resource" >&2
        echo "       busy' and goldfish_address_space, which is built against IT," >&2
        echo "       gets the wrong driver. Google's config sets no CONFIG_GOLDFISH." >&2
        exit 1
    fi
    echo "==> x86_64 module ABI options confirmed (BTF on, goldfish not built in)"
fi

# The mirror of the above: arm64 must NOT have BTF, or it is no longer the
# kernel that was validated at 3/3.
if [[ "${KERNEL_ARCH}" == "arm64" ]]; then
    if grep -qx 'CONFIG_DEBUG_INFO_BTF=y' .config; then
        echo "ERROR: BTF is enabled on arm64." >&2
        echo "       That changes struct module, which is what decides whether the" >&2
        echo "       AVD's prebuilt modules load. The validated arm64 kernel has it" >&2
        echo "       off. If enabling it is intended, re-measure integrity first." >&2
        exit 1
    fi
    echo "==> arm64 BTF confirmed off (matches the validated kernel)"
fi

BOOT_DIR="$(arch_boot_dir)"

echo "==> Build (parallel jobs=${JOBS}, targets: ${KBUILD_TARGETS[*]})"
time make -j "${JOBS}" "${KBUILD_TARGETS[@]}"

echo
echo "==> Build complete"
for img in "${KBUILD_OUTPUTS[@]}"; do
    ls -la "${BOOT_DIR}/${img}" | sed 's|^|    |'
done

# Copy the kernel image out of the named-volume source tree into the host-
# bind-mounted /work/out/ so the host can find it. Do this BEFORE the banner-
# print pipeline below -- grep -m1 closes its stdin which gives `strings`
# SIGPIPE, which with pipefail set would abort the script right before we
# copied the output. Copy first, then the banner is decorative.
#
# Output names are distinct per arch (Image/Image.gz vs bzImage), so both
# arches can coexist in out/ without clobbering each other.
OUTDIR="${ROOT}/out"
mkdir -p "${OUTDIR}"
for img in "${KBUILD_OUTPUTS[@]}"; do
    cp -fv "${BOOT_DIR}/${img}" "${OUTDIR}/${img}"
done
echo
echo "==> Kernel images copied to host at: kernel-build/out/"

echo
echo "Kernel build version banner:"
( strings "${BOOT_DIR}/${KBUILD_OUTPUTS[0]}" || true ) | grep -m1 "Linux version" | sed 's|^|    |' || true
