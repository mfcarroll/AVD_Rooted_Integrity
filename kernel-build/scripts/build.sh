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

JOBS="${JOBS:-$(nproc)}"

echo "==> Building for ${KERNEL_ARCH} (ARCH=${ARCH}, CROSS_COMPILE=${CROSS_COMPILE})"

echo "==> defconfig"
make -j "${JOBS}" gki_defconfig

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
# We do NOT force virtio_*/goldfish_*/dmabuf/binder/drm to =y. The defconfig
# leaves them as =m to match the AVD's prebuilt /lib/modules/*.ko, and Wild's
# vermagic-bypass hack (applied earlier in apply-patches.sh) lets those .ko
# files load despite version mismatch. Forcing them =y would cause init's
# insmod calls to fail with "Device or resource busy" -> kernel panic.
EOF

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

make -j "${JOBS}" olddefconfig

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
