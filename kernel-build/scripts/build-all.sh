#!/bin/bash
# One-shot entry point: fetch -> patch -> build.
# Intended to be the Docker container's default invocation.
#
#   ./scripts/build-all.sh                  # arm64 (default)
#   ./scripts/build-all.sh --arch x86_64
#
# Sources are arch-independent and shared between both builds; only the patch
# and build steps take the arch.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

. "${ROOT}/scripts/arch-env.sh"
arch_parse "$@"

bash "${ROOT}/scripts/fetch-sources.sh"
bash "${ROOT}/scripts/apply-patches.sh" --arch "${KERNEL_ARCH}"
bash "${ROOT}/scripts/build.sh"         --arch "${KERNEL_ARCH}"
