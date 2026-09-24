# Build environment for AOSP common-android15-6.6 kernel with KSU-Next + SUSFS
# + custom anti-emulator patches. Uses Ubuntu 24.04's native clang-18, which
# matches the AOSP prebuilt clang-r522817's version and works natively on
# Apple Silicon (no Rosetta needed).
#
# Both target arches are CROSS-compiled, so this one image builds either and
# the host architecture does not matter. Both toolchains are installed.
#
# To use:
#   docker build -t kbuild .
#   docker run --rm -v "$PWD":/work -w /work kbuild ./scripts/build-all.sh
#   docker run --rm -v "$PWD":/work -w /work kbuild ./scripts/build-all.sh --arch x86_64

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# Build deps for the AOSP common-android kernel.
# Ubuntu 24.04 has clang-18 in its main repo. The Android Common Kernel for
# 6.6 builds cleanly with clang-18 (the official prebuilts/clang/host/linux-x86
# tag clang-r522817 IS clang-18.0.x).
#
# dwarves provides pahole, which CONFIG_DEBUG_INFO_BTF requires
# (PAHOLE_VERSION >= 116). Without it that option is silently unselectable, BTF
# is dropped, and struct module loses a field -- which is precisely why the
# AVD's prebuilt x86_64 modules refuse to load into our kernel.
#
# When CC=clang LLVM=1 LLVM_IAS=1, the kernel uses clang for compilation,
# integrated assembler, ld.lld for linking, llvm-objcopy etc. We still need
# binutils-<target>-linux-gnu for a couple of helpers (mkimage, objtool, etc).
# Retry the whole update+install cycle.
#
# Ubuntu publishes a security update, drops the superseded .deb from the pool,
# and any index fetched moments earlier now points at a file that 404s:
#
#   E: Failed to fetch .../libexpat1_2.6.1-2ubuntu0.6_amd64.deb  404  Not Found
#
# It is a race against the archive, not a problem with this image, and it takes
# out every build until someone re-runs. Re-running `apt-get update` picks up
# the new index, so retry rather than pin: pinning would just move the failure
# to whenever that pin goes stale.
RUN for attempt in 1 2 3; do \
        apt-get update -o Acquire::Retries=5 \
     && apt-get install -y --no-install-recommends -o Acquire::Retries=5 \
        ca-certificates curl wget git xz-utils unzip \
        build-essential bc bison flex \
        libssl-dev openssl libelf-dev \
        kmod cpio rsync \
        python3 python3-pip \
        device-tree-compiler \
        zstd lz4 \
        ccache \
        dwarves \
        clang lld llvm llvm-dev \
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
        gcc-x86-64-linux-gnu binutils-x86-64-linux-gnu \
     && break; \
        echo "apt attempt ${attempt} failed; refreshing the index and retrying"; \
        sleep 15; \
        [ "${attempt}" = 3 ] && exit 1; \
    done \
    && rm -rf /var/lib/apt/lists/* \
    && clang --version \
    && ld.lld --version

# Configure git for in-container operations (patches use git apply)
RUN git config --global user.email "kbuild@local" \
 && git config --global user.name "kbuild" \
 && git config --global init.defaultBranch main \
 && git config --global advice.detachedHead false

# Use ccache to speed up rebuild iterations
ENV CCACHE_DIR=/work/.ccache
ENV PATH="/usr/lib/ccache:${PATH}"

WORKDIR /work
