# Custom kernel build for AVD anti-detection

A reproducible Docker build of AOSP `common-android15-6.6` with KernelSU-Next,
SUSFS, and in-tree anti-emulator source customizations that hide the bulk of
QEMU/goldfish/ranchu fingerprints from userspace.

## What this gives you

| Layer | What |
|---|---|
| AOSP common-android15-6.6 | The kernel matching the AVD's existing 6.6.x |
| KernelSU-Next | Same root framework the KSU app talks to |
| SUSFS (gki-android15-6.6) | SUSFS features, at the version that supports `uid_scheme` on `add_open_redirect` |
| Module vermagic bypass | Lets the AVD's prebuilt `.ko` files load despite the rebuilt kernel's vermagic — without it, mediaswcodec's driver chain never comes up and the apex SIGABRTs |
| `CONFIG_LSM` without `baseband_guard` | The LSM stack we want; AOSP common doesn't ship baseband_guard |
| `/proc/modules` filter | goldfish_*, virtio_*, mac80211_hwsim hidden from the module list |
| `/proc/cpuinfo` spoof | Reports a Tensor-class layout (implementer `0x41`, Cortex-X4/A720/A520 part IDs) |
| Kernel banner | `LOCALVERSION` says `Pixel10Pro`, not `Wild`/`ranchu` |

These customizations are injected **directly into the kernel source** by
`scripts/customize-kernel.sh` (Python edits guarded by an `AVD_SPOOF_INJECTED`
marker), not as `diff`/`patch` hunks — patch hunks break every time AOSP
cherry-picks something onto the branch, so source injection is more robust.

## What it does *not* fix

These need a different surface than the kernel:

- **`/dev/goldfish_*` device nodes.** Kernel-level suppression breaks AVD init
  (`/dev/goldfish_pipe` and `_sync` are the host↔guest channels init relies on).
  The on-device SUSFS `sus_path` / `add_open_redirect` approach handles the
  detectable surfaces (`/proc/*`) at runtime instead — see `../device/`.
- **Sensor vendor names** ("Goldfish 3-axis Accelerometer | The Android Open
  Source Project"). The sensor HAL lives in `vendor.img`. This is a known,
  unaddressed gap in this repo — it is not required for the Play Integrity
  verdict, only for evading deeper gms.unstable hardware-shape heuristics.
- **The attestation verdict itself.** `MEETS_STRONG_INTEGRITY` does *not* come
  from the kernel — it comes from TEESimulator forging a complete keybox-rooted
  attestation chain in GENERATE mode (see `../docs/INTEGRITY_CHAIN.md`). The
  kernel's job is only to keep emulator tells out of `/proc` so the rest of the
  chain holds; with that plus your own keybox, the verdict reaches **strong**
  integrity — no StrongBox hardware needed.

## Build it

### Time and disk

- ~3 GB of kernel source downloaded on first run
- ~3 GB of clang toolchain in the Docker image
- ~5–25 min to build, depending on cores + ccache state
- Total disk: ~10 GB inside the build dir

### Steps

```bash
cd kernel-build

# 1. Build the Docker image (one-time; reused on rebuild)
docker build -t kbuild .

# 2. Sync sources, apply patches, build kernel.
#    sources/ MUST live in a named volume, not a host bind mount — see below.
docker run --rm \
    -v "$PWD":/work \
    -v kbuild-sources:/work/sources \
    -w /work kbuild ./scripts/build-all.sh
```

Output (copied to the host bind mount): `out/Image` and `out/Image.gz`.

### Target architecture

Every script takes `--arch arm64` (the default) or `--arch x86_64`:

```bash
docker run --rm -v "$PWD":/work -v kbuild-sources:/work/sources \
    -w /work kbuild ./scripts/build-all.sh --arch x86_64
```

| | `arm64` | `x86_64` |
|---|---|---|
| ARCH / CROSS_COMPILE | `arm64` / `aarch64-linux-gnu-` | `x86_64` / `x86_64-linux-gnu-` |
| kernel source dir | `arch/arm64` | `arch/x86` (the Makefile maps it) |
| make target → output | `Image Image.gz` → `out/Image.gz` | `bzImage` → `out/bzImage` |
| extra patches | none | `patches/x86_64/`, `scripts/fix-ksu-x86_64.sh` |
| `/proc/cpuinfo` spoof | in-kernel MIDR rewrite | SUSFS `open_redirect` at runtime |

Both are **cross-compiles** — the host architecture is irrelevant and one
container image builds either. The output filenames differ, so both arches can
sit in `out/` at once.

`.avd-patches-applied` records which arch the source tree was patched for, and
`build.sh` refuses to build the other one against it. The arches apply different
patch sets, and the failure mode without that check is silent: an x86_64 kernel
built from an arm64-patched tree compiles and boots, and KSU simply never gets
root. Switch arch by re-running `apply-patches.sh --arch <a>` first.

#### Why x86_64 needs extra patches

Kernel 6.6 hardens the x86_64 syscall path by replacing the indirect branch with
a series of direct branches, which blocks KernelSU's syscall-table hooking.
`patches/x86_64/` carries two upstream-derived patches that reinstate an
indirect path behind `X86_FEATURE_INDIRECT_SAFE` and let it be selected from the
kernel cmdline, so booting with `syscall_hardening=off` re-enables it.

Do **not** combine that with `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER` — they are
two solutions to the same problem and `build.sh` explicitly disables the latter.

`scripts/fix-ksu-x86_64.sh` then repairs the compile errors the Wild
KSU↔SUSFS integration patch leaves on x86_64 (it is written against arm64): a
missing `linux/compat.h`, dropped `strncpy_from_user` return checks, an
arm64-only `TIF_SECCOMP` test and a dropped `linux/kallsyms.h`.

> The x86_64 work is adapted from the
> [jdw1023](https://github.com/jdw1023/AVD_Rooted_Integrity) fork, which
> switched this build to x86_64 outright; here it is parameterised so both
> arches build from one set of scripts.

> **Why the `kbuild-sources` named volume is required.** The AOSP kernel tree
> contains files that differ only in case (e.g.
> `…+pooncelock+poonceLock+….litmus` vs `…+pooncelock+pooncelock+….litmus`).
> On macOS (case-insensitive APFS) those collide, so a host bind mount of
> `sources/` makes `git reset --hard` fail with *"unable to create file … File
> exists"* and the build never starts. A Docker **named volume** lives on
> Docker's case-sensitive Linux filesystem, so the checkout succeeds. `out/`
> stays on the host bind mount (just two files, no collision) so you can grab
> `Image.gz`. On a case-sensitive Linux host you can drop the named volume, but
> it's harmless to keep.

### Per-step (useful when iterating)

```bash
V="-v $PWD:/work -v kbuild-sources:/work/sources -w /work"
docker run --rm $V kbuild ./scripts/fetch-sources.sh
docker run --rm $V kbuild ./scripts/apply-patches.sh --arch arm64
docker run --rm $V kbuild ./scripts/build.sh         --arch arm64
```

Sources are arch-independent, so `fetch-sources.sh` takes no `--arch`.

### Reset the source tree if patches fail to apply

Run inside the container (the tree lives in the named volume, not on the host):

```bash
docker run --rm -v "$PWD":/work -v kbuild-sources:/work/sources -w /work kbuild \
    bash -c 'rm -f sources/kernel/.avd-patches-applied && \
             cd sources/kernel && git reset --hard && git clean -fdx'
```

To wipe sources entirely and re-fetch: `docker volume rm kbuild-sources`.

## Boot the AVD with the new kernel

Use the repo-root launcher (uses your host Android SDK):

```bash
../scripts/start_avd.sh
# or override the AVD name / kernel:
AVD=Pixel_9_Pro_XL KERNEL="$PWD/out/Image.gz" ../scripts/start_avd.sh
```

It passes `-kernel out/Image.gz -no-snapshot-load -no-snapshot-save` to the
emulator. The AVD's system/vendor/userdata stay exactly as they were — only the
kernel changes.

## What to verify after boot

```bash
# 1. /proc/modules doesn't list goldfish/hwsim/virtio
adb shell 'su -c "grep -iE \"goldfish|hwsim|virtio\" /proc/modules | wc -l"'   # → 0

# 2. /proc/cpuinfo shows implementer 0x41
adb shell 'su -c "grep -m1 implementer /proc/cpuinfo"'                          # → 0x41

# 3. KSU is active
adb shell 'su -c "zcat /proc/config.gz | grep -E \"CONFIG_KSU=|CONFIG_KSU_SUSFS=\""'

# 4. ReZygisk healthy
adb shell 'su -c "grep description /data/adb/modules/rezygisk/module.prop"'
```

## How the scripts pin versions

`scripts/fetch-sources.sh` pins exact tags/commits so the build is reproducible:

| Source | Pin |
|---|---|
| AOSP common kernel | tag `android15-6.6-2025-02_r19` (matches the AVD's 6.6.66 vintage; branch HEAD is far ahead and Android 16 userspace SIGABRTs against it) |
| KernelSU-Next | commit `5a4a71874caa…` (the exact commit Wild Kernels uses) |
| SUSFS | branch `gki-android15-6.6`, commit `2df41de78902…` |
| Wild kernel_patches | HEAD — only their KSU↔SUSFS integration patch is used, which disables the aggressive syscall hooks that crash Android 16's mediaswcodec |

## Troubleshooting

**`fetch-sources.sh` is slow on AOSP gerrit.** Expected; the clone is
single-shot and cached. Subsequent runs skip.

**Source customization didn't apply.** `customize-kernel.sh` is idempotent and
guarded by an `AVD_SPOOF_INJECTED` marker comment. If a customization is
missing, AOSP moved the function it anchors on (e.g. `m_show` in
`kernel/module/procfs.c`, `c_show` in `arch/arm64/kernel/cpuinfo.c` on arm64). The
Python `assert`s will fail loudly pointing at the function that moved; adjust
the anchor regex in `customize-kernel.sh` to match the new context.

**Build fails with `<asm/...>: No such file or directory`.** clang's
`--target=aarch64-linux-gnu` isn't finding the sysroot. Inside the container,
confirm `clang --target=aarch64-linux-gnu --print-search-dirs`.

**AVD won't boot the new kernel.** Look at `../avd-boot.log` — a panic in init
usually means a driver we depend on got disabled. `build.sh` deliberately keeps
`CONFIG_GOLDFISH_*`/`CONFIG_VIRTIO_*` as `=m` (not forced `=y`) so init's insmod
calls still succeed; don't change that.

**KSU shows "not installed" after boot.** `CONFIG_KSU` didn't land. Confirm
with `zcat /proc/config.gz | grep KSU`. If empty, re-run `apply-patches.sh` with
`bash -x` to see where KSU-Next integration failed.
