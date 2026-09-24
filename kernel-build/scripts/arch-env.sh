#!/bin/bash
# Sourced by apply-patches.sh / build.sh / build-all.sh. Single source of truth
# for everything that differs between the arm64 and x86_64 builds.
#
# The build was arm64-only until 2026-09-23. It is a CROSS-compile in both
# cases (clang + LLVM_IAS, CROSS_COMPILE only for the few helpers that shell
# out to ${CROSS_COMPILE}gcc), so the host architecture is irrelevant and one
# container image builds either target.
#
# Note there is NO Bazel in this build -- it is plain `make`. Forks that sed
# `kernel_aarch64_dist` -> `kernel_x86_64_dist` are editing a string that does
# not appear in these scripts.
#
# Usage:
#     . "${ROOT}/scripts/arch-env.sh"
#     arch_parse "$@"

# arm64 is the default: it is the validated configuration that reaches
# MEETS_STRONG_INTEGRITY, and every x86_64-specific step below is gated so that
# an arm64 build behaves exactly as it did before parameterisation.
arch_parse() {
    KERNEL_ARCH="${KERNEL_ARCH:-arm64}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --arch) KERNEL_ARCH="${2:?--arch needs a value}"; shift 2 ;;
            --arch=*) KERNEL_ARCH="${1#*=}"; shift ;;
            *) echo "unknown argument: $1" >&2; return 2 ;;
        esac
    done

    case "${KERNEL_ARCH}" in
        arm64)
            KBUILD_ARCH=arm64
            # Directory under arch/ holding the sources. For arm64 it matches
            # ARCH; for x86_64 it does not (see below).
            KBUILD_SRCARCH=arm64
            KBUILD_CROSS=aarch64-linux-gnu-
            KBUILD_TARGETS=(Image Image.gz)
            KBUILD_OUTPUTS=(Image Image.gz)
            ;;
        x86_64)
            KBUILD_ARCH=x86_64
            # The kernel's top-level Makefile maps ARCH=x86_64 to SRCARCH=x86,
            # so the build lands in arch/x86/boot -- NOT arch/x86_64/boot.
            # boot_dir() below probes both rather than trusting either.
            KBUILD_SRCARCH=x86
            KBUILD_CROSS=x86_64-linux-gnu-
            KBUILD_TARGETS=(bzImage)
            KBUILD_OUTPUTS=(bzImage)
            ;;
        *)
            echo "ERROR: unsupported --arch '${KERNEL_ARCH}' (want arm64 or x86_64)" >&2
            return 2
            ;;
    esac
    export KERNEL_ARCH KBUILD_ARCH KBUILD_SRCARCH KBUILD_CROSS
}

# Resolve the boot output directory inside a patched kernel tree. Probes the
# mapped SRCARCH path first, then the raw ARCH path, rather than hardcoding a
# guess -- a wrong path here fails late, under `set -e`, after a 20-minute build.
arch_boot_dir() {
    local d
    for d in "arch/${KBUILD_SRCARCH}/boot" "arch/${KBUILD_ARCH}/boot"; do
        [[ -d "$d" ]] && { printf '%s' "$d"; return 0; }
    done
    echo "ERROR: no boot output dir for ARCH=${KBUILD_ARCH} (tried arch/${KBUILD_SRCARCH}/boot, arch/${KBUILD_ARCH}/boot)" >&2
    return 1
}

# The patch-state marker records WHICH arch the tree was patched for. Building
# x86_64 against an arm64-patched tree would silently omit the syscall-hardening
# bypass: the kernel compiles and boots, and KSU simply never gets root. Cheap
# check, expensive failure.
arch_marker_file() { printf '%s' ".avd-patches-applied"; }
