#!/usr/bin/env bash
# Prove select-arches.sh classifies real paths the way the comments claim.
#
# Run it after adding, moving or renaming anything under kernel-build/ — the
# classifier reads paths, so a rename is exactly what silently turns an
# arch-specific file into a shared one, or worse, the other way round:
#
#   ./.github/scripts/select-arches.test.sh
#
# It builds a throwaway repo in a temp dir and never touches this one.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/select-arches.sh"
BOTH='["arm64","x86_64"]'
REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT

(
    cd "$REPO"
    git init -q .
    git config user.email ci@test
    git config user.name ci
    # The repo this runs from may sign commits; a throwaway repo has no key.
    git config commit.gpgsign false
    mkdir -p kernel-build/scripts
    echo base > kernel-build/scripts/build.sh
    git add -A && git commit -qm base
) || { echo "SETUP FAILED"; exit 1; }

BASE=$(git -C "$REPO" rev-parse HEAD) || exit 1
fails=0

check() {
    local name=$1 want=$2; shift 2
    git -C "$REPO" reset -q --hard "$BASE"
    local f
    for f in "$@"; do
        mkdir -p "$REPO/$(dirname "$f")"
        echo change >> "$REPO/$f"
    done
    git -C "$REPO" add -A
    git -C "$REPO" commit -qm "$name" || { echo "SETUP FAILED: $name"; exit 1; }

    local head out got
    head=$(git -C "$REPO" rev-parse HEAD)
    [[ "$head" != "$BASE" ]] || { echo "SETUP FAILED: no commit for $name"; exit 1; }

    out=$(cd "$REPO" && WANT= BEFORE="$BASE" AFTER="$head" bash "$SCRIPT")
    got=$(sed -n 's/^arches=//p' <<< "$out")
    if [[ "$got" == "$want" ]]; then
        printf 'ok    %-30s %s\n' "$name" "$got"
    else
        printf 'FAIL  %-30s got=%s want=%s\n' "$name" "$got" "$want"
        fails=$((fails + 1))
    fi
}

env_check() {
    local name=$1 want=$2 w=$3 b=$4
    local got
    got=$(cd "$REPO" && WANT="$w" BEFORE="$b" AFTER=HEAD bash "$SCRIPT" | sed -n 's/^arches=//p')
    if [[ "$got" == "$want" ]]; then
        printf 'ok    %-30s %s\n' "$name" "$got"
    else
        printf 'FAIL  %-30s got=%s want=%s\n' "$name" "$got" "$want"
        fails=$((fails + 1))
    fi
}

# --- narrowing: only an arch name in the path earns it ----------------------
check "x86 config only"        '["x86_64"]' kernel-build/configs/x86_64-ranchu.config
check "x86 patch only"         '["x86_64"]' kernel-build/patches/x86_64/03-new.patch
check "x86 ksu fixups"         '["x86_64"]' kernel-build/scripts/fix-ksu-x86_64.sh
check "x86 config + README"    '["x86_64"]' kernel-build/configs/x86_64-ranchu.config kernel-build/README.md
check "arm64 config (task 6)"  '["arm64"]'  kernel-build/configs/arm64-ranchu.config
check "both arches named"      "$BOTH"      kernel-build/configs/x86_64-ranchu.config kernel-build/patches/arm64/01.patch

# --- a shared input always builds both --------------------------------------
check "build.sh"               "$BOTH" kernel-build/scripts/build.sh
check "Dockerfile"             "$BOTH" kernel-build/Dockerfile
check "arch-env.sh"            "$BOTH" kernel-build/scripts/arch-env.sh
check "apply-patches.sh"       "$BOTH" kernel-build/scripts/apply-patches.sh
check "x86 config + build.sh"  "$BOTH" kernel-build/configs/x86_64-ranchu.config kernel-build/scripts/build.sh
check "the workflow"           "$BOTH" .github/workflows/kernel.yml
check "the selector"           "$BOTH" .github/scripts/select-arches.sh

# --- nothing attributable falls back to both --------------------------------
check "README only"            "$BOTH" kernel-build/README.md
check "unrelated file"         "$BOTH" docs/CI.md

# --- manual dispatch wins, degenerate ranges fall back ----------------------
env_check "dispatch arm64"     '["arm64"]'  arm64  "$BASE"
env_check "dispatch x86_64"    '["x86_64"]' x86_64 "$BASE"
env_check "dispatch both"      "$BOTH"      both   "$BASE"
env_check "new branch"         "$BOTH"      ""     0000000000000000000000000000000000000000
env_check "before is gone"     "$BOTH"      ""     deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
env_check "before is empty"    "$BOTH"      ""     ""

if (( fails )); then
    echo "=== $fails failed ==="
    exit 1
fi
echo "=== all passed ==="
