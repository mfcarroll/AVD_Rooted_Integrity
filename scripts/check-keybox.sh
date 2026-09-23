#!/usr/bin/env bash
# Validate a keybox against Google's live attestation revocation list.
#
# WHY THIS EXISTS: tools that fetch keyboxes do not reliably check revocation.
# Specter (dpejoh/specter), for example, checks only the FIRST certificate's
# serial, and on 2026-09-22 it printed BOTH of these for the same keybox:
#     Warning: Keybox is revoked by Google (installing anyway)
#     Keybox is not revoked
# ...and installed a KEY_COMPROMISE-revoked keybox anyway. A keybox can carry
# several certificates and more than one key block; ANY revoked certificate in
# the chain poisons it. This checks every certificate.
#
# It also reports whether an RSA key block is present alongside the ECDSA one,
# since some attestation paths use it and keyboxes vary.
#
# Usage:
#   ./scripts/check-keybox.sh                      # checks device/data_adb/tricky_store/keybox.xml
#   ./scripts/check-keybox.sh path/to/keybox.xml
#   ./scripts/check-keybox.sh --device             # pulls the live one off the AVD
#
# Exit: 0 = clean, 1 = revoked or unreadable.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRL_URL="https://android.googleapis.com/attestation/status"
KEYBOX="$REPO_ROOT/device/data_adb/tricky_store/keybox.xml"
TMPDIR="${TMPDIR:-/tmp}"
PULLED=""

case "${1:-}" in
  --device)
    command -v adb >/dev/null 2>&1 || { echo "ERROR: adb not on PATH" >&2; exit 1; }
    PULLED="$TMPDIR/keybox_device_$$.xml"
    adb shell "su -c 'cp /data/adb/tricky_store/keybox.xml /data/local/tmp/_kb_$$.xml; chmod 644 /data/local/tmp/_kb_$$.xml'" >/dev/null 2>&1
    adb pull "/data/local/tmp/_kb_$$.xml" "$PULLED" >/dev/null 2>&1 || { echo "ERROR: could not pull keybox from device" >&2; exit 1; }
    adb shell "su -c 'rm -f /data/local/tmp/_kb_$$.xml'" >/dev/null 2>&1
    KEYBOX="$PULLED"
    ;;
  "") ;;
  *) KEYBOX="$1" ;;
esac

[ -f "$KEYBOX" ] || { echo "ERROR: keybox not found: $KEYBOX" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl not on PATH" >&2; exit 1; }

CRL="$TMPDIR/att_status_$$.json"
trap 'rm -f "$CRL" "${PULLED:-}" 2>/dev/null' EXIT

echo "keybox: $KEYBOX"
curl -fsS --max-time 45 -H "Cache-Control: no-cache" "${CRL_URL}?ts=$(date +%s)" -o "$CRL" \
  || { echo "ERROR: could not fetch Google's revocation list" >&2; exit 1; }

KEYBOX="$KEYBOX" CRL="$CRL" python3 - <<'PY'
import json, os, re, subprocess, sys

xml = open(os.environ["KEYBOX"], encoding="utf-8", errors="replace").read()
crl = json.load(open(os.environ["CRL"]))
entries = {k.lower().lstrip("0"): v for k, v in crl.get("entries", {}).items()}

dev   = re.search(r'DeviceID="([^"]*)"', xml)
algos = sorted({a.lower() for a in re.findall(r'<Key algorithm="([^"]+)"', xml)})
certs = re.findall(r'<Certificate format="pem">(.*?)</Certificate>', xml, re.S)

print(f"  DeviceID   : {dev.group(1) if dev else '(none)'}")
print(f"  key blocks : {len(algos)} ({', '.join(algos) or 'none'})")
print(f"  certs      : {len(certs)}")
print(f"  CRL entries: {len(entries)}\n")

revoked, seen = [], set()
for pem_raw in certs:
    pem = "\n".join(l.strip() for l in pem_raw.strip().splitlines() if l.strip())
    r = subprocess.run(["openssl", "x509", "-noout", "-serial", "-subject", "-enddate"],
                       input=pem, capture_output=True, text=True, timeout=20)
    if r.returncode:
        print("  ! unparseable certificate"); continue
    m = re.search(r"serial=([0-9A-Fa-f]+)", r.stdout)
    if not m:
        continue
    hx = m.group(1).lower().lstrip("0")
    if hx in seen:
        continue
    seen.add(hx)
    dec = str(int(m.group(1), 16))
    hit = entries.get(hx) or entries.get(dec)
    subj = re.search(r"subject=(.*)", r.stdout)
    exp  = re.search(r"notAfter=(.*)", r.stdout)
    if hit:
        revoked.append((hx, hit))
        print(f"  *** REVOKED {hx}")
        print(f"      {hit}")
    else:
        print(f"  ok  {hx[:32]:34s} {(subj.group(1).strip()[:44] if subj else '')}")
    if exp:
        print(f"      expires {exp.group(1).strip()}")

print()
if revoked:
    print("RESULT: REVOKED — do not use this keybox.")
    sys.exit(1)
if not any("rsa" in a for a in algos):
    print("RESULT: not revoked (ECDSA only — no RSA key block).")
else:
    print("RESULT: not revoked (ECDSA + RSA key blocks present).")
PY
