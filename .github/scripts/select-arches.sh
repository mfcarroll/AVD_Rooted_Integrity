#!/usr/bin/env bash
# Decide which arches a push actually needs to build.
#
# A two-arch kernel build is 25-75 runner-minutes, and most commits can only
# affect one arch. This narrows the build matrix to the arches a change can
# reach.
#
# THE RULE THAT KEEPS IT SAFE: narrowing requires positive evidence. The only
# evidence accepted is an arch name in the path -- patches/<arch>/,
# configs/<arch>-*.config, scripts/*-<arch>.sh. Anything else that is a build
# input (a shared script, the Dockerfile, the workflow) builds both, as does any
# range this cannot diff. A wrong "both" costs minutes. A wrong "one arch"
# publishes a kernel nobody compiled, which is the failure mode that hides until
# a device fails to boot.
#
# apply-patches.sh:65 reads patches/<arch>/ and nothing else, so an arch patch
# directory genuinely cannot affect the other arch.
#
# Env in:  WANT (workflow_dispatch choice, empty on push), BEFORE, AFTER
# Std out: arches=<json array>  and  why=<one line>, for $GITHUB_OUTPUT.

set -euo pipefail

ZERO=0000000000000000000000000000000000000000
BOTH='["arm64","x86_64"]'

decide() {
    printf 'arches=%s\n' "$1"
    printf 'why=%s\n' "$2"
    exit 0
}

want="${WANT:-}"
before="${BEFORE:-}"
after="${AFTER:-HEAD}"

# An explicit manual choice always wins, including "build both anyway".
case "$want" in
    arm64|x86_64) decide "[\"$want\"]" "workflow_dispatch selected ${want}" ;;
    both)         decide "$BOTH"       "workflow_dispatch selected both" ;;
esac

# A range we cannot diff: a new branch (before is all zeros), or history that
# was rewritten out from under us so the old tip is gone.
if [[ -z "$before" || "$before" == "$ZERO" ]] \
   || ! git cat-file -e "${before}^{commit}" 2>/dev/null; then
    decide "$BOTH" "no diffable range (new branch or rewritten history)"
fi

changed=$(git diff --name-only "$before" "$after")
[[ -n "$changed" ]] || decide "$BOTH" "empty diff for ${before:0:7}..${after:0:7}"

want_arm64=false
want_x86=false
shared=false

while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
        # Docs never change a kernel. The workflow's own path filter already
        # drops a docs-only push; this is for a mixed one.
        *.md) ;;
        *x86_64*|*x86-64*) want_x86=true ;;
        *arm64*|*aarch64*) want_arm64=true ;;
        kernel-build/*|.github/workflows/kernel.yml|.github/scripts/select-arches.sh)
            shared=true ;;
        # Anything else is not a build input at all -- it cannot have triggered
        # this workflow on its own, and it says nothing about which arch to build.
        *) ;;
    esac
done <<< "$changed"

if $shared; then
    decide "$BOTH" "a shared build input changed"
fi

sel=()
names=()
if $want_arm64; then sel+=('"arm64"');  names+=(arm64);  fi
if $want_x86;   then sel+=('"x86_64"'); names+=(x86_64); fi

# Reachable when a push touches only docs plus files outside kernel-build/.
if [[ ${#sel[@]} -eq 0 ]]; then
    decide "$BOTH" "no change attributable to an arch"
fi

printf -v joined '%s,' "${sel[@]}"
printf -v listed '%s and ' "${names[@]}"
decide "[${joined%,}]" "only ${listed% and } inputs changed"
