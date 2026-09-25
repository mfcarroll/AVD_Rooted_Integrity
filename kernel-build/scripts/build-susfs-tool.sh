#!/bin/bash
# Build ksu_susfs, SUSFS's userspace configurator, for every ABI we target.
#
# WHY THIS EXISTS. ksu_module_susfs ships tools/ksu_susfs_arm64 and nothing else,
# and its customize.sh installs that file unconditionally. On an x86_64 guest the
# result is an AArch64 binary at /data/adb/ksu/bin/ksu_susfs that cannot execute,
# so every SUSFS rule silently goes unregistered while the module still reports
# success. The kernel half is fine and unaffected -- verified on the x86_64 base:
# `ksud susfs support` says Supported, v2.1.0, variant GKI, with
# CONFIG_KSU_SUSFS_OPEN_REDIRECT, _SUS_MOUNT, _SUS_MAP and _SPOOF_UNAME all
# compiled in. Only the tool that talks to it was missing.
#
# WHY BUILD RATHER THAN DOWNLOAD. ksu_susfs and the kernel share a command ABI,
# and our kernel is patched from a pinned SUSFS commit. A binary from anywhere
# else is a guess at that ABI, and a mismatch fails the way this project keeps
# getting caught -- quietly. Building from the same tree makes agreement
# structural rather than hopeful.
#
# Upstream ships arm64 only because build_ksu_susfs_tool.sh copies exactly one
# path out of libs/. The code is not arch-specific; jni/Application.mk just says
# APP_ABI := arm64-v8a. Adding x86_64 to that line produces both.
#
#   ./scripts/build-susfs-tool.sh                 # both ABIs
#   NDK_HOME=/path/to/ndk ./scripts/build-susfs-tool.sh
#
# Outputs: out/susfs-tools/<abi>/ksu_susfs
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/sources/susfs"
OUT="${ROOT}/out/susfs-tools"

# Pinned. The NDK is published for linux-x86_64 only -- there is no linux-aarch64
# build -- so this cannot run on an Apple Silicon host without emulation. CI runs
# on x86_64 runners, which is where it is meant to happen.
NDK_VERSION="r27c"
NDK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
NDK_SHA256="59c2f6dc96743b5daf5d1626684640b20a6bd2b1d85b13156b90333741bad5cc"
NDK_CACHE="${NDK_CACHE:-${ROOT}/.ndk}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# ---- source -----------------------------------------------------------------
# Reuse sources/susfs when the kernel build has already populated it. Otherwise
# clone just that one tree: fetch-sources.sh also pulls the ~3 GB AOSP common
# kernel, which this tool does not need and CI should not pay for.
#
# The pin is READ FROM fetch-sources.sh rather than repeated here. The whole
# point of building this ourselves is that the tool and the kernel come from the
# same SUSFS commit; two copies of that constant would eventually disagree, and
# the symptom would be a command-ABI mismatch that fails silently.
pin() { grep -m1 "^$1=" "${ROOT}/scripts/fetch-sources.sh" | cut -d'"' -f2; }
SUSFS_URL="$(pin SUSFS_URL)"
SUSFS_BRANCH="$(pin SUSFS_BRANCH)"
SUSFS_COMMIT="$(pin SUSFS_COMMIT)"
[ -n "${SUSFS_URL}" ] && [ -n "${SUSFS_COMMIT}" ] \
    || die "could not read the SUSFS pin out of scripts/fetch-sources.sh"

if [ ! -d "${SRC}/.git" ]; then
    say "Cloning SUSFS ${SUSFS_BRANCH} @ ${SUSFS_COMMIT:0:12}"
    mkdir -p "$(dirname "${SRC}")"
    git clone --quiet --branch "${SUSFS_BRANCH}" "${SUSFS_URL}" "${SRC}"
fi
( cd "${SRC}" && git fetch --quiet origin "${SUSFS_BRANCH}" 2>/dev/null || true
  git -C "${SRC}" checkout --quiet "${SUSFS_COMMIT}" )
have=$(git -C "${SRC}" rev-parse HEAD)
[ "${have}" = "${SUSFS_COMMIT}" ] \
    || die "susfs is at ${have}, expected the pinned ${SUSFS_COMMIT}"
say "SUSFS at ${SUSFS_COMMIT:0:12} (pinned by fetch-sources.sh)"

[ -d "${SRC}/ksu_susfs/jni" ] || die "no ksu_susfs/jni in ${SRC} — upstream layout changed"

# ---- toolchain -------------------------------------------------------------
if [ -z "${NDK_HOME:-}" ]; then
    NDK_HOME="${NDK_CACHE}/android-ndk-${NDK_VERSION}"
    if [ ! -x "${NDK_HOME}/ndk-build" ]; then
        case "$(uname -m)" in
            x86_64|amd64) ;;
            *) die "the Android NDK is published for linux-x86_64 only, and this host is $(uname -m).
  Build this in CI, or set NDK_HOME to an NDK that runs here." ;;
        esac
        mkdir -p "${NDK_CACHE}"
        zip="${NDK_CACHE}/ndk.zip"
        sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$1" | awk '{print $1}'; }

        # Reuse an already-downloaded archive if it verifies. 664 MB is worth not
        # fetching twice, and it lets this be tested without the download.
        if [ -f "${zip}" ] && [ "$(sha_of "${zip}")" = "${NDK_SHA256}" ]; then
            say "Using cached NDK archive"
        else
            say "Fetching Android NDK ${NDK_VERSION} (~664 MB)"
            curl -fsSL -o "${zip}" "${NDK_URL}"
        fi

        # Verify before unpacking, always. This is a binary toolchain from the
        # network that will compile something we ship onto a device.
        actual=$(sha_of "${zip}")
        [ "${actual}" = "${NDK_SHA256}" ] || die "NDK checksum mismatch
  expected ${NDK_SHA256}
  actual   ${actual}
  Refusing to unpack an unverified toolchain."
        say "NDK archive verified"
        # -o: the archive has duplicate entries, and without it unzip stops on an
        # interactive "replace?" prompt that never gets an answer in CI.
        unzip -qo "${zip}" -d "${NDK_CACHE}"
        rm -f "${zip}"
    fi
fi
[ -x "${NDK_HOME}/ndk-build" ] || die "no ndk-build at ${NDK_HOME}"
export PATH="${NDK_HOME}:${PATH}"
say "Using NDK at ${NDK_HOME}"

# ---- widen APP_ABI ---------------------------------------------------------
# A guarded sed rather than a patch file: this is one line in a fetched tree that
# fetch-sources.sh resets, so it must be re-applied on every build, and a patch
# that fails to apply cleanly after an upstream bump would be a worse failure
# than an assertion here. Verify both before and after.
APP_MK="${SRC}/ksu_susfs/jni/Application.mk"
WANT_ABIS="arm64-v8a x86_64"
grep -q '^APP_ABI *:=' "${APP_MK}" || die "no APP_ABI line in ${APP_MK} — upstream layout changed"
sed -i.bak "s|^APP_ABI *:=.*|APP_ABI := ${WANT_ABIS}|" "${APP_MK}"
rm -f "${APP_MK}.bak"
grep -q "^APP_ABI := ${WANT_ABIS}\$" "${APP_MK}" \
    || die "failed to set APP_ABI in ${APP_MK}"

# Drop the GNU build-id so the output is byte-reproducible.
#
# Measured: a local build and the CI build of the same commit differed in
# EXACTLY 20 contiguous bytes at offset 873 — a SHA-1 build-id, derived from
# build inputs including paths, which differ between a container at
# /work/kernel-build and a runner at /home/runner/work/... Everything else was
# identical.
#
# It matters because this binary gets promoted into payloads/ and shipped onto a
# device. Without this, nobody can verify CI's artefact by rebuilding it; with
# it, anyone with the pinned source and NDK gets the same bytes. The kernel build
# pins its banner identity for the same reason.
grep -q '^APP_LDFLAGS' "${APP_MK}" \
    || printf 'APP_LDFLAGS := -Wl,--build-id=none\n' >> "${APP_MK}"
say "APP_ABI := ${WANT_ABIS}, build-id disabled for reproducibility"

# ---- build -----------------------------------------------------------------
say "Building ksu_susfs"
( cd "${SRC}/ksu_susfs" && rm -rf libs obj && ndk-build )

rm -rf "${OUT}"
mkdir -p "${OUT}"
for abi in ${WANT_ABIS}; do
    bin="${SRC}/ksu_susfs/libs/${abi}/ksu_susfs"
    [ -s "${bin}" ] || die "ndk-build produced no binary for ${abi}"
    mkdir -p "${OUT}/${abi}"
    cp -f "${bin}" "${OUT}/${abi}/ksu_susfs"
done

# ---- verify ----------------------------------------------------------------
# Machine type, not just "a file exists". An ELF for the wrong arch is exactly
# the bug this script fixes, so it must not be possible to ship one from here.
say "Verifying"
for abi in ${WANT_ABIS}; do
    f="${OUT}/${abi}/ksu_susfs"
    case "${abi}" in
        arm64-v8a) want=183 ;;   # EM_AARCH64 = 0xB7
        x86_64)    want=62  ;;   # EM_X86_64  = 0x3E
    esac
    got=$(od -An -tu2 -j18 -N2 --endian=little "${f}" 2>/dev/null | tr -d ' ' \
       || od -An -tu2 -j18 -N2 "${f}" | tr -d ' ')
    [ "${got}" = "${want}" ] \
        || die "${abi}: e_machine is ${got}, expected ${want} — wrong architecture"
    printf '    %-12s %8s bytes  e_machine=%s  ok\n' "${abi}" "$(wc -c <"${f}" | tr -d ' ')" "${got}"
done

# The arm64 output should behave like the binary the module ships, which is the
# only independent correctness check available: same commit, same compiler
# family. Sizes will differ (different NDK), so compare behaviour, not bytes.
say "Done — ${OUT}"
ls -l "${OUT}"/*/ksu_susfs
