# The installer attribution bug — 2026-09-23

**A Play Integrity verdict is only meaningful if the app asking for it was
installed with Play attribution.** Without it Google does not merely flag the
app — it withholds the *device* verdict too, and does so silently.

This single fact explains the original report that started all of this ("it
worked this morning, then it didn't"), and it invalidates most of the verdicts
recorded on 2026-09-22.

## The measurement

One device (`Pixel_9_Fresh`), one account, one identity, **the same four APK
files** — `base.apk` + three `split_config.*`, verified **byte-for-byte
identical** (sha256, all four) between the Play copy and the repo copy. Same
signing certificate (`F5UrXPhnBbreh3Q_WjMe_kyYK_tNoNL9XXC_wjXPeeM`), same
`versionCode=22`. Toggled back and forth in minutes:

| install | `installerPackageName` | `deviceRecognitionVerdict` |
|---|---|---|
| `adb install-multiple …` | `null` | `[MEETS_DEVICE_INTEGRITY]` |
| installed from the Play Store | `com.android.vending` | `[BASIC, DEVICE, STRONG]` |
| `adb install-multiple -i com.android.vending …` | `com.android.vending` | `[BASIC, DEVICE, STRONG]` |

Full field-by-field difference:

| field | no attribution | attributed to Play |
|---|---|---|
| `deviceRecognitionVerdict` | `[MEETS_DEVICE_INTEGRITY]` | `[MEETS_BASIC_INTEGRITY, MEETS_DEVICE_INTEGRITY, MEETS_STRONG_INTEGRITY]` |
| `appLicensingVerdict` | `UNLICENSED` | `LICENSED` |
| `playProtectVerdict` | `UNEVALUATED` | `NO_ISSUES` |
| `recentDeviceActivity` | `UNEVALUATED` | `LEVEL_1` |
| `appAccessRiskVerdict` | `{}` | `{ appsDetected: [KNOWN_INSTALLED, UNKNOWN_INSTALLED] }` |
| `appRecognitionVerdict` | `PLAY_RECOGNIZED` | `PLAY_RECOGNIZED` (unchanged) |

## What the mechanism is — and is not

- **Not the binary.** All four APKs are byte-identical; `appRecognitionVerdict`
  was already `PLAY_RECOGNIZED` in both cases, i.e. Google always recognised the
  code as genuine.
- **Not account entitlement.** After installing from Play (so the account
  demonstrably owns the app *on this device*), uninstalling and re-sideloading
  plainly returned immediately to `UNLICENSED` / `[DEVICE]`. Ownership does not
  survive the reinstall.
- **Not server-side verification.** This was the natural hypothesis — that Google
  tracks whether this device ever installed this app from Play. **It does not.**
  Sideloading the repo's own APKs with `-i com.android.vending` is accepted and
  yields three green. The claim is taken at face value.
- **It is the local `installerPackageName` string**, and nothing else.

The important and non-obvious part is the *blast radius*: `appLicensingVerdict`
is an account-level field about app ownership, so it would be reasonable to
assume it cannot affect `deviceRecognitionVerdict`. It does. An unattributed
install suppresses BASIC and STRONG and blanks three environment fields, which
looks exactly like a device that fails integrity rather than an app that was
installed oddly.

## Consequences for this repo

1. **`MEETS_STRONG_INTEGRITY` is achievable.** The README's downgrade to
   `MEETS_DEVICE_INTEGRITY` has been reverted.
2. **`docs/FINDINGS-2026-09-22.md` is unreliable.** Its verdicts were all read
   through a mis-attributed checker. In particular the headline conclusion —
   that the April profile "died" during 2026-09-22 — was a controlled A/B whose
   *absolute* readings were depressed across the board. The A/B may still be
   valid in relative terms (one checker throughout), but "the profile stopped
   being accepted by Google" is no longer supported.
3. **The original mystery is solved.** The morning's three green and the
   evening's all-red were the same stack. What changed was the rebuild, which
   reinstalled the checker with a plain `adb install-multiple`.
4. Every install path in both repos now passes `-i com.android.vending`.

## Rule

> Never install an app whose Play Integrity verdict you intend to read — or that
> reads its own — without `-i com.android.vending`.

This applies to WhatsApp in `avd-cloud-portable` just as much as to the checker:
it calls the Play Integrity API itself, so an unattributed install degrades what
it sees about the device.
