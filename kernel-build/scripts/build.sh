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
# build-user@build-host is what real AOSP GKI release kernels report.
#
# The timestamp comes from the pinned kernel tag's own commit date, so it is
# deterministic for a given KERNEL_TAG and still a plausible build date --
# rather than a hardcoded lie that drifts further from the source every release.
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-build-user}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-build-host}"
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
CONFIG_LOCALVERSION="-android16-5-Pixel10Pro"
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

# Build the virtio drivers IN, rather than relying on the system image's
# prebuilt /lib/modules/*.ko.
#
# The comment above says we deliberately leave these as =m so the AVD's
# prebuilt modules load, with Wild's vermagic bypass covering the version
# mismatch. That holds on arm64. It does NOT hold on x86_64, where every
# module is rejected before vermagic is even consulted:
#
#   module virtio_dma_buf: .gnu.linkonce.this_module section size must match
#                          the kernel's built struct module size at run time
#   init: Failed to insmod '/lib/modules/virtio_dma_buf.ko': Exec format error
#   init: partition(s) not found after polling timeout: metadata, super, vbmeta
#   init: Failed to create devices required for first stage mount
#   Kernel panic - not syncing: Attempted to kill init!
#
# That is a struct-size check, not the vermagic check, so the bypass does
# nothing for it. No virtio block driver means no metadata/super/vbmeta, so
# first-stage mount fails and init dies -- then the emulator reboots and does
# it again, which is why adb only ever reports `offline`.
#
# Patching out the size check would be wrong: unlike vermagic it is
# load-bearing, and ignoring it lets the kernel misread the module's own
# struct and corrupt memory.
#
# The old worry about forcing =y was that init's insmod would then fail with
# "Device or resource busy" and panic. The boot log above disproves it: init
# logged the insmod failure, said "LoadWithAliases was unable to load
# virtio_dma_buf", and carried on regardless. It panicked ten seconds later
# for want of block devices, not for the failed insmod. A built-in driver
# whose insmod returns EEXIST lands in exactly that tolerated path, with the
# device actually present.
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_PCI_LEGACY=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_DMA_SHARED_BUFFER=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_INPUT=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_VSOCKETS=y
CONFIG_VIRTIO_VSOCKETS_COMMON=y
CONFIG_VSOCKETS=y
CONFIG_VIRTIO_PMEM=y
CONFIG_FAILOVER=y
CONFIG_NET_FAILOVER=y
CONFIG_HW_RANDOM_VIRTIO=y

# Graphics. The first attempt covered only the block path, which got the guest
# all the way into Android userspace -- and then surfaceflinger SIGABRTed every
# five seconds, 185 times, because virtio_gpu was still a module and still
# rejected. No display driver, no compositor, black screen, and from outside it
# looks identical to not booting at all.
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y

# Match Google's struct module layout, so the AVD's own vendor modules load.
#
# This is the root cause under every rejection so far, not another workaround.
# The x86_64 AVD's graphics stack needs goldfish_address_space (the gfxstream
# ASG device at PCI 607d:f153) and goldfish_sync. Neither exists in AOSP common
# -- drivers/platform/goldfish/Kconfig defines only GOLDFISH_PIPE -- so they can
# only come from the vendor partition, and those .ko files are refused with
#
#   .gnu.linkonce.this_module section size must match the kernel's built
#   struct module size at run time
#
# Google's kernel-ranchu, pulled from /proc/config.gz on a stock boot, is the
# same 6.6.66 we build and sets CONFIG_DEBUG_INFO_BTF=y plus
# CONFIG_DEBUG_INFO_BTF_MODULES=y. Those add a field to struct module. BTF needs
# pahole (PAHOLE_VERSION >= 116); our image had no dwarves package, so the
# option was silently unselectable and olddefconfig dropped it, leaving our
# struct module a field short of every module in the image.
#
# x86_64 ONLY. The arm64 kernel currently loads the AVD's prebuilt modules, so
# changing its struct module layout risks breaking a stack that reaches
# MEETS_STRONG_INTEGRITY today. Do not lift this into the shared block without
# re-measuring arm64.
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_DEBUG_INFO_BTF_MODULES=y
CONFIG_MODULE_SCMVERSION=y

# The emulator's host-guest channels. /dev/goldfish_pipe and goldfish_sync are
# what adb and qemud ride on, so losing them to the same rejection would leave
# a booted guest with no adb -- indistinguishable from not booting.
CONFIG_GOLDFISH=y
CONFIG_GOLDFISH_PIPE=y
# No CONFIG_GOLDFISH_SYNC: the symbol does not exist in this tree. Only
# GOLDFISH_PIPE is in drivers/platform/goldfish/Kconfig; goldfish_sync.ko ships
# in the system image's VENDOR partition (dlkm_loader loads it from
# /vendor/lib/modules) and is not AOSP common source, so it cannot be built in
# from here. It will keep failing to insmod. If the graphics path turns out to
# need it, virtio_gpu is the alternative and is built in above.
EOF
fi

make -j "${JOBS}" olddefconfig

# olddefconfig silently DROPS any symbol whose dependencies are unmet, so an
# appended "CONFIG_X=y" is a request, not a result. Getting that wrong here
# costs a full rebuild plus a boot to discover the identical panic, so check
# what actually landed.
if [[ "${KERNEL_ARCH}" == "x86_64" ]]; then
    # Check EVERY symbol this branch sets, not a hand-picked few. The first
    # version listed five, all block-path, and passed -- while VIRTIO_NET,
    # VIRTIO_CONSOLE, VSOCKETS and the whole graphics stack were quietly absent.
    # A partial check is worse than none: it reads as confirmation.
    _missing=()
    for sym in CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK \
               CONFIG_VIRTIO_DMA_SHARED_BUFFER CONFIG_VIRTIO_NET \
               CONFIG_VIRTIO_CONSOLE CONFIG_VIRTIO_INPUT CONFIG_VIRTIO_PMEM \
               CONFIG_VSOCKETS CONFIG_VIRTIO_VSOCKETS \
               CONFIG_DMABUF_HEAPS CONFIG_DMABUF_HEAPS_SYSTEM \
               CONFIG_DEBUG_INFO_BTF CONFIG_DEBUG_INFO_BTF_MODULES \
               CONFIG_GOLDFISH_PIPE; do
        grep -qx "${sym}=y" .config || _missing+=("$sym")
    done
    if (( ${#_missing[@]} )); then
        echo "ERROR: these did not survive olddefconfig as built-in:" >&2
        for sym in "${_missing[@]}"; do
            printf '       %s -> %s\n' "$sym" "$(grep -E "^(# )?${sym}[ =]" .config || echo 'absent')" >&2
        done
        echo "       Each of these is a driver the prebuilt module cannot supply:" >&2
        echo "       block ones panic init at first-stage mount, graphics ones let" >&2
        echo "       the guest boot and then crash-loop surfaceflinger on a black" >&2
        echo "       screen. Check each symbol's dependencies." >&2
        exit 1
    fi
    echo "==> x86_64 built-in drivers confirmed in .config"
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
