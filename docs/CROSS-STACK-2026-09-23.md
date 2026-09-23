# Cross-stack comparison — 2026-09-23

Two independent stacks target the same goal on the same machine. One reaches
**BASIC + DEVICE**, the other **DEVICE only**. This is what differs, measured
rather than assumed, and what to try here as a result.

- **Stack A** — `avd-cloud-portable`, Magisk. **`MEETS_BASIC_INTEGRITY` +
  `MEETS_DEVICE_INTEGRITY`.**
- **Stack B** — this repo, KernelSU-Next + SUSFS. **`MEETS_DEVICE_INTEGRITY` only.**

## The headline finding: stack A does not spoof global props at all

Read live off a booted stack-A clone (`wa-meeting`, cut from the sealed
`WA_Base`), while it was passing BASIC + DEVICE:

```
ro.build.fingerprint            google/sdk_gphone64_arm64/emu64a:13/TE1A.240213.009/12342917:user/release-keys
ro.product.model                sdk_gphone64_arm64
ro.build.characteristics        emulator
ro.serialno                     EMULATOR36X6X11X0
ro.build.version.security_patch 2024-03-01
ro.boot.verifiedbootstate       (empty)
```

Every one of those is a blatant emulator tell, left completely untouched — the
literal strings `sdk_gphone64_arm64`, `emulator` and `EMULATOR…`, a
two-and-a-half-year-old patch level, and no verified-boot state at all. **That
configuration passes BASIC and DEVICE.**

This repo rewrites all of them globally, every boot, via `resetprop` in
`post-fs-data.d/01-avd-prop-spoof.sh` — and does not reach BASIC.

So the entire global prop layer here is, at minimum, **not necessary** for
BASIC + DEVICE. Stack A demonstrates the spoof only has to exist inside the
processes GMS actually runs: Zygisk injects it per-process, DenyList + Shamiko
hide root from those same processes, and the system underneath stays honestly an
emulator. Nothing has to agree with anything, because there is only one layer.

That reframes `docs/FINDINGS-2026-09-22.md`. This repo's own measurements already
recorded that fixing `ro.serialno`, `ro.build.characteristics`,
`ro.build.description` and `ro.build.flavor` **did not move the verdict**. Stack A
explains why: those props are not what is being read. Meanwhile maintaining three
layers that must agree is exactly the cross-layer inconsistency this repo
identifies as the mechanism behind `CANNOT_ATTEST_IDS`.

## Full delta

| | Stack A (BASIC+DEVICE) | Stack B / here (DEVICE only) |
|---|---|---|
| Root | Magisk 30.6 core / 30.7 app | KernelSU-Next (custom kernel) |
| Hiding | Zygisk Next 1.5.0 + Shamiko 1.2.5 + DenyList (4 entries) | SUSFS (kernel) |
| **PIF module** | **Integrity Box v42** | **PlayIntegrityFork v18** |
| Keystore | Tricky Store v1.4.1 | TEESimulator v3.2 |
| Hook manager | LSPosed v1.9.2 (7024) | Vector v2.0 / ReZygisk v1.0.0 |
| **Global prop spoof** | **none** | **extensive (`01-avd-prop-spoof.sh`)** |
| Android | 13 / API 33, patch 2024-03-01 | 16 / API 36 |
| Profile | `comet` — Pixel 9 Pro Fold | `tokay` — Pixel 9 |
| `spoofSignature` | **1** | 0 |
| `spoofProvider` | 0 | **1** |
| `spoofPixel` | **1** | (key absent in PIF v18) |
| `spoofApps` | 0 | (key absent in PIF v18) |

Stack A's working profile, verbatim:

```
MANUFACTURER=Google
MODEL=Pixel 9 Pro Fold
FINGERPRINT=google/comet_beta/comet:CANARY/ZP11.260821.010/16290768:user/release-keys
BRAND=google
PRODUCT=comet_beta
DEVICE=comet
RELEASE=CANARY
ID=ZP11.260821.010
INCREMENTAL=16290768
TYPE=user
TAGS=release-keys
SECURITY_PATCH=2026-09-05
DEVICE_INITIAL_SDK_INT=32

*.build.id=ZP11.260821.010
*.security_patch=2026-09-05
*api_level=32

verboseLogs=0
spoofApps=0
spoofBuild=1
spoofProps=1
spoofProvider=0
spoofSignature=1
spoofVendingFinger=1
spoofVendingSdk=0
spoofPixel=1

# Released On: 2026-09-16
# Estimated Expiry: 2026-10-28
```

Note the build ID and incremental (`ZP11.260821.010` / `16290768`) are **identical**
to this repo's current profile. Only the device differs (`comet` vs `tokay`) —
so the profile *generation* is not the difference between the two stacks.

## Experiments, in order of expected value

### 1. Swap PlayIntegrityFork v18 → Integrity Box v42  ← strongest lead

This is the one variable already **proven** to gate BASIC. On stack A, Integrity
Box **v36 failed BASIC and v42 passed it** — measured directly, twice, with
sign-out/sign-in confirming the flip. In this repo the PIF module was **never
varied**: v18 was constant across every single test on 2026-09-22, so it is an
untested confound sitting exactly where the failure is.

It is close to a drop-in:

- Integrity Box uses module id **`playintegrityfix`** — the same id, and therefore
  the same `/data/adb/modules/playintegrityfix/custom.pif.prop` path that
  `scripts/install-device-setup.sh` already writes to. No plumbing change.
- Its `customize.sh` resolves resetprop from **`/data/adb/ksu/bin/resetprop`** as
  well as the Magisk path, so it is KernelSU-aware by design.
- Zip: `avd-cloud-portable/payloads/modules/Integrity-Box-v42.zip`.

Caveat: it is a Zygisk module, so it rides on ReZygisk here rather than Zygisk
Next. That is the main transplant risk.

### 2. Adopt stack A's profile and spoof flags verbatim

Independent of (1), and free. Three flags differ, and this repo has the
*opposite* value on two of them: `spoofSignature` 0→**1**, `spoofProvider` 1→**0**.
`spoofPixel` / `spoofApps` only exist under Integrity Box, so this pairs
naturally with (1).

### 3. A/B the global prop layer off

Stack A proves it is unnecessary; this repo's own notes record it as
verdict-neutral. Disable `01-avd-prop-spoof.sh` (and `04`/`11` prop sweeps) and
cold boot. If the verdict is unchanged, delete an entire class of
must-stay-consistent state. If it improves, the layer was actively harmful.
Cheap, reversible, and it removes a confound from every future test.

### 4. Only then, the system image

Stack A is API 33 with a 2024-03-01 patch level; here it is API 36. Worth
testing last — it is the most expensive change and the least evidenced.

## RESULTS — experiments 1 and 2 ran the same night

**Both failed to move the verdict.** Recording this because a negative result on
the strongest lead is worth more than the hypothesis was.

Applied to `Pixel_9_Fresh` (KernelSU-Next + SUSFS + ReZygisk + TEESimulator):

1. **PlayIntegrityFork v18 → Integrity Box v42.** Installed via
   `ksud module install`. It is genuinely a drop-in — same module id, and its
   installer even fetched its own keybox (5815 bytes, the same size as the one
   stack A runs).
2. **tokay → stack A's comet profile, verbatim**, including the inverted flags
   (`spoofProvider` 1→0, `spoofSignature` 0→1, `spoofPixel=1`). Confirmed
   propagated globally after a cold boot:
   `ro.build.fingerprint = google/comet_beta/comet:CANARY/…`, model
   `Pixel 9 Pro Fold`.

The module was verifiably live, so this is a valid test, not a silent no-op —
`PIF/Native` logged its own rewrites:

```
D PIF/Native: [ro.product.first_api_level]: 36 -> 32
D PIF/Native: [ro.vendor.api_level]: 202504 -> 32
```

Verdict afterwards — **identical to before the swap**:

```json
"deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY"],
"appRecognitionVerdict":    "PLAY_RECOGNIZED",
"appLicensingVerdict":      "UNLICENSED",
"playProtectVerdict":       "UNEVALUATED",
"deviceAttributes":         { "sdkVersion": 36 }
```

**So the PIF module was not the gate here**, and the v36→v42 effect measured on
stack A does not transfer. Cross-stack transplant of the module + profile is
ruled out as the explanation for the BASIC gap.

### A third thing tried, also negative

`/system/bin/su` is present on this stack, **world-readable and
world-executable**, at a completely standard path — `stat()`-able by any app with
no root at all. On a real device it does not exist. `/debug_ramdisk` is present
too. And `device/data_adb/susfs4ksu/sus_path.txt` is **empty** — nothing but the
upstream template comments — so SUSFS's path-hiding is compiled into the kernel
with zero rules loaded. `02-avd-deeper-spoof.sh` only ever hides `/dev/qemu_pipe`
style nodes.

That looked like a strong candidate, because it explains the exact shape of the
anomaly: DEVICE passes (the forged attestation says "a real certified comet")
while BASIC fails (runtime tamper checks see `su` in the open). Applying
`ksu_susfs add_sus_path /system/bin/su` live did **not** change the verdict.

Caveat worth keeping: GMS was already running when the rule was applied, and
SUSFS exempts root-granted processes, so this is weaker evidence than 1 and 2.
It is worth one more attempt persisted into `sus_path.txt` across a cold boot
before being written off. The empty `sus_path.txt` is a real gap regardless of
whether it is *this* gap.

### What that leaves

The module, the profile, and the most obvious root tell are all eliminated. The
remaining differences between the two stacks are structural:

| | stack A (BASIC+DEVICE) | here (DEVICE only) |
|---|---|---|
| SDK | **33** | **36** — and reported raw to Google in `deviceAttributes` |
| root | Magisk | KernelSU-Next |
| hiding | Zygisk Next + Shamiko + DenyList | SUSFS + ReZygisk |
| keystore | Tricky Store v1.4.1 | TEESimulator v3.2 |

`deviceAttributes.sdkVersion: 36` is notable: Integrity Box spoofs
`first_api_level` to 32, but Google is still told 36, so that attribute is read
from the real runtime and cannot be reached from the module layer. Stack A
reports 33. Of the four, the **SDK / system image** is now the best-evidenced
remaining candidate and the cheapest of the structural changes to test — the
others mean rebuilding the stack on a different root framework.

Experiment 3 from the list below (dropping the global prop layer) is still
untested and still cheap.

## What this does not explain

Stack A has never reached STRONG either. Nothing here is a lead on STRONG; the
target of these experiments is **BASIC**, which is the gap between the two stacks.
