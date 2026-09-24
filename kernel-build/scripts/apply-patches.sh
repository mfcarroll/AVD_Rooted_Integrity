#!/bin/bash
# Apply, in order matching Wild Kernels' build pipeline exactly:
#   1. Reset kernel tree
#   2. Arch-specific pre-KSU patches (patches/<arch>/; x86_64 only today)
#   3. KernelSU-Next setup (drops drivers/kernelsu into the tree)
#   4. Wild's KSU<->SUSFS integration patch (disables syscall hooks that
#      crash Android 16 mediaswcodec)
#   4b. Arch-specific KSU compile fixes (x86_64 only)
#   5. Copy SUSFS source files into kernel tree
#   6. Sublevel-specific pre-SUSFS sed fixes
#   7. Apply SUSFS kernel patch (|| true; sublevel fixes may already absorb)
#   8. Revert the pre-SUSFS sed fixes
#   9. Module-version bypass hack
#  10. Our anti-emulator source customizations
#
#   ./scripts/apply-patches.sh [--arch arm64|x86_64]    (default arm64)
#
# Steps 2 and 4b are no-ops on arm64, so an arm64 run is byte-for-byte what it
# was before the build became arch-parameterised.
#
# After this, the kernel source tree is ready for build.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${ROOT}/sources/kernel"
KSU_DIR="${ROOT}/sources/kernelsu"
SUSFS_DIR="${ROOT}/sources/susfs"
WILD_DIR="${ROOT}/sources/wild-patches"

. "${ROOT}/scripts/arch-env.sh"
arch_parse "$@"

if [[ ! -d "${KERNEL_DIR}" ]]; then
    echo "ERROR: ${KERNEL_DIR} not found. Run scripts/fetch-sources.sh first." >&2
    exit 1
fi

echo "==> Patching for ${KERNEL_ARCH}"

# ----------------------------------------------------------------------------
# 1. Reset kernel tree
# ----------------------------------------------------------------------------
echo "==> Resetting kernel tree to clean state"
( cd "${KERNEL_DIR}" \
    && git reset --hard HEAD >/dev/null \
    && git clean -fdx >/dev/null )

cd "${KERNEL_DIR}"
SUBLEVEL=$(grep -m1 '^SUBLEVEL' Makefile | awk '{print $3}')
echo "==> Kernel sublevel: ${SUBLEVEL}"

# ----------------------------------------------------------------------------
# 2. Arch-specific pre-KSU patches
#
# x86_64: the 6.6 syscall hardening converts the syscall indirect branch into a
# series of direct branches, which blocks KSU's syscall-table hooking. The two
# patches here are upstream-derived: Josh Poimboeuf's "only harden syscalls when
# needed" (adds X86_FEATURE_INDIRECT_SAFE) plus hmtheboy154's change letting it
# be selected from the kernel cmdline, so `syscall_hardening=off` re-enables the
# indirect table at boot. start_avd.sh passes that parameter.
#
# arm64 has no patches/arm64/ directory and this loop does nothing.
# ----------------------------------------------------------------------------
ARCH_PATCH_DIR="${ROOT}/patches/${KERNEL_ARCH}"
if compgen -G "${ARCH_PATCH_DIR}/*.patch" >/dev/null; then
    echo "==> Applying ${KERNEL_ARCH} pre-KSU patches"
    for p in "${ARCH_PATCH_DIR}"/*.patch; do
        echo "  - ${p##*/}"
        patch -p1 -F 3 -N --no-backup-if-mismatch \
            -r "/tmp/arch-${KERNEL_ARCH}.rej" -i "$p"
    done
else
    echo "==> No ${KERNEL_ARCH} pre-KSU patches (patches/${KERNEL_ARCH}/ absent or empty)"
fi

# ----------------------------------------------------------------------------
# 3. KernelSU-Next
# setup.sh ignores any pre-existing KSU_DIR and clones fresh into
# $(pwd)/KernelSU-Next (= ${KERNEL_DIR}/KernelSU-Next). We pass the pinned
# commit so it checks that one out instead of "latest tagged release".
# ----------------------------------------------------------------------------
KSU_COMMIT="5a4a71874caaad06aa126f761c93391de1d32361"
echo "==> Integrating KernelSU-Next @ ${KSU_COMMIT:0:12}"
bash "${KSU_DIR}/kernel/setup.sh" "${KSU_COMMIT}"

# ----------------------------------------------------------------------------
# 4. Wild's KSU<->SUSFS integration patch
# This patch disables KSU-Next's aggressive syscall hooks (lsm_hook,
# syscall_event_bridge, tp_marker, <arch>/syscall_hook, etc.) that crash
# mediaswcodec on Android 16. Keeps only the setuid hook + extras.
# ----------------------------------------------------------------------------
WILD_KSU_PATCH="${WILD_DIR}/wild/ksun-5a4a718-susfs-f7ae19ef-gki-android14-6.1.patch"
if [[ ! -f "${WILD_KSU_PATCH}" ]]; then
    echo "ERROR: ${WILD_KSU_PATCH} missing -- re-run fetch-sources.sh" >&2
    exit 1
fi
echo "==> Applying Wild KSU<->SUSFS integration patch"
( cd drivers/kernelsu && patch -p2 -F 3 -N --no-backup-if-mismatch \
    -r /tmp/wild-ksu.rej -i "${WILD_KSU_PATCH}" )

# ----------------------------------------------------------------------------
# 4b. Arch-specific KSU compile fixes.
# The Wild patch is written against arm64; on x86_64 it leaves KSU with a
# missing compat.h include, unchecked strncpy_from_user returns, an arm64-only
# TIF_SECCOMP test and a dropped kallsyms.h. All are compile failures, not
# silent ones. No equivalent is needed on arm64.
# ----------------------------------------------------------------------------
if [[ "${KERNEL_ARCH}" == "x86_64" ]]; then
    echo "==> Fixing x86_64 KernelSU compile issues"
    bash "${ROOT}/scripts/fix-ksu-x86_64.sh" "${KERNEL_DIR}"
fi

# ----------------------------------------------------------------------------
# 5. Stage SUSFS source files
# ----------------------------------------------------------------------------
echo "==> Staging SUSFS files into kernel tree"
cp -v "${SUSFS_DIR}/kernel_patches/fs/"*.c                fs/
cp -v "${SUSFS_DIR}/kernel_patches/include/linux/"*.h     include/linux/

# ----------------------------------------------------------------------------
# 6. Pre-SUSFS sed fixes (Wild's "Fake Patches" for android15-6.6)
# These add temporary #include directives so the SUSFS kernel patch's
# context lines match across sublevels.
# ----------------------------------------------------------------------------
echo "==> Pre-SUSFS sublevel-specific fixes"
if [ "${SUBLEVEL}" -le 92 ] 2>/dev/null; then
    echo "  - sublevel<=92: add dma-buf.h to fs/proc/base.c"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
fi
if [ "${SUBLEVEL}" -le 57 ] 2>/dev/null; then
    echo "  - sublevel<=57: add zswap.h to mm/memory.c"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
fi
# kernel-fixes: sublevel<=58 needs <trace/hooks/fs.h> in fs/namespace.c
if [ "${SUBLEVEL}" -le 58 ] 2>/dev/null; then
    if ! grep -qxF '#include <trace/hooks/fs.h>' fs/namespace.c; then
        echo "  - sublevel<=58: add <trace/hooks/fs.h> to fs/namespace.c"
        sed -i '/^#include <trace\/hooks\/blk.h>$/a #include <trace\/hooks\/fs.h>' fs/namespace.c
    fi
fi

# ----------------------------------------------------------------------------
# 7. Apply SUSFS kernel patch
# ----------------------------------------------------------------------------
SUSFS_KERNEL_PATCH=$(ls "${SUSFS_DIR}/kernel_patches"/*.patch 2>/dev/null | head -1)
if [[ -z "${SUSFS_KERNEL_PATCH}" ]]; then
    echo "ERROR: no .patch file in ${SUSFS_DIR}/kernel_patches/" >&2
    exit 1
fi
echo "==> Applying SUSFS kernel patch: ${SUSFS_KERNEL_PATCH##*/}"
patch -p1 -F 3 -N --no-backup-if-mismatch -r /tmp/susfs.rej \
    -i "${SUSFS_KERNEL_PATCH}" || true

# ----------------------------------------------------------------------------
# 8. Revert the pre-SUSFS sed fixes (Wild does this too)
# ----------------------------------------------------------------------------
echo "==> Reverting pre-SUSFS sed fixes"
if [ "${SUBLEVEL}" -le 92 ] 2>/dev/null; then
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
fi
if [ "${SUBLEVEL}" -le 57 ] 2>/dev/null; then
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
fi

# ----------------------------------------------------------------------------
# 9. Module-version bypass hack (Wild's "Bypass" variant).
# Forces kernel/module/version.c::check_version to return 1 instead of 0 on
# vermagic mismatch -- so the AVD's pre-built .ko files (which carry the
# original kernel's vermagic) actually load. Without this, mediaswcodec's
# dependency chain (drm/audio/etc. modules) never comes up and the apex
# SIGABRTs. This is what the "Bypass-AnyKernel3" variant does.
# ----------------------------------------------------------------------------
echo "==> Applying module vermagic bypass hack"
sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' \
    kernel/module/version.c
if grep -A 5 "bad_version:" kernel/module/version.c | grep -q "return 1;"; then
    echo "  - bypass hack applied to kernel/module/version.c"
else
    echo "ERROR: bypass hack didn't apply" >&2
    grep -A 10 "bad_version:" kernel/module/version.c
    exit 1
fi

# Wipe the GKI protected-exports list. Otherwise modules like
# virtio_pci_modern_dev.ko fail to load with "exports protected symbol".
echo "==> Emptying GKI protected-exports list"
if ls android/abi_gki_protected_exports_* >/dev/null 2>&1; then
    for f in android/abi_gki_protected_exports_*; do
        : > "$f"
        echo "  - emptied $f"
    done
fi

# ----------------------------------------------------------------------------
# 10. Our anti-emulator source customizations
# ----------------------------------------------------------------------------
echo "==> Customizing kernel source for AVD anti-detection"
KERNEL_ARCH="${KERNEL_ARCH}" bash "${ROOT}/scripts/customize-kernel.sh" "${KERNEL_DIR}"

# Record WHICH arch this tree is patched for; build.sh refuses a mismatch.
printf '%s' "${KERNEL_ARCH}" > "${KERNEL_DIR}/$(arch_marker_file)"
echo
echo "==> All patches applied successfully (${KERNEL_ARCH})."
echo "    Next: scripts/build.sh --arch ${KERNEL_ARCH}"
