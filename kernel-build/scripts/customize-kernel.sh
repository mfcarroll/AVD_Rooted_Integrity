#!/bin/bash
# Inject anti-emulator modifications directly into the kernel source files
# instead of using diff/patch hunks (which break every time AOSP cherry-picks
# something into the branch). Each section is idempotent: if our marker
# comment is already present, the edit is skipped.
#
# Modifications:
#   1. kernel/module/procfs.c -- filter goldfish/qemu/virtio entries from
#      /proc/modules
#   2. arch/arm64/kernel/cpuinfo.c -- (arm64 only) print Tensor-G5-shaped CPU
#      implementer (0x41) and parts (Cortex-X4 / A720 / A520). There is no
#      x86_64 equivalent: MIDR is an ARM register, and on x86_64 /proc/cpuinfo
#      is spoofed at runtime via SUSFS open_redirect onto avd-fake/cpuinfo.
#   3. drivers/base/devtmpfs.c -- suppress devtmpfs nodes for
#      goldfish_* / qemu_* / ranchu_* names

set -euo pipefail

KERNEL_DIR="${1:?need path to kernel source tree}"
KERNEL_ARCH="${KERNEL_ARCH:-arm64}"
cd "${KERNEL_DIR}"

MARKER='AVD_SPOOF_INJECTED'

# ============================================================================
# 1. /proc/modules filter
# ============================================================================
f=kernel/module/procfs.c
if grep -q "${MARKER}" "$f"; then
    echo "  - ${f}: already injected"
else
    echo "  - ${f}: injecting /proc/modules blocklist"
    python3 - "$f" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()

block = r'''
/* AVD_SPOOF_INJECTED: hide emulator-fingerprint modules from /proc/modules */
/*
 * PREFIXES, not an exact list. The original was strcmp against a fixed set and
 * it hid nothing that was actually loaded: measured on a running AVD 2026-09-25,
 * /proc/modules showed virtual_cpufreq, virtio_media, vexpress_sysreg,
 * v4l2loopback, usbip_core and vhci_hcd — not one of them was in the list, while
 * most of the names that were (virtio_gpu, goldfish_fb, ...) are not loaded on
 * this image at all. An enumerable list of emulator modules is a losing game;
 * the families are stable, the members are not.
 */
static const char * const avd_hidden_module_prefixes[] = {
	"goldfish", "qemu", "ranchu", "virtio", "virt_",
	"vexpress", "usbip", "vhci", "v4l2loopback",
	"virtual_cpufreq", "mac80211_hwsim",
	NULL,
};
static bool avd_module_hidden(const char *name)
{
	int i;
	for (i = 0; avd_hidden_module_prefixes[i]; i++)
		if (!strncmp(name, avd_hidden_module_prefixes[i],
			     strlen(avd_hidden_module_prefixes[i])))
			return true;
	return false;
}
'''

# Insert block right before the m_show function definition.
m = re.search(r'^static int m_show\(struct seq_file \*m, void \*p\)\s*\{', src, re.M)
assert m, "m_show not found in " + path
src = src[:m.start()] + block + '\n' + src[m.start():]

# Inside m_show, add an early return if the module name is hidden.
# Look for the first statement after the opening brace of m_show.
m2 = re.search(
    r'(static int m_show\(struct seq_file \*m, void \*p\)\s*\{\s*\n'
    r'\tstruct module \*mod[^;]*;\s*\n[^\n]*\n)',
    src
)
assert m2, "couldn't locate body of m_show"
inject = '\n\tif (avd_module_hidden(mod->name))\n\t\treturn 0;\n'
src = src[:m2.end()] + inject + src[m2.end():]

open(path, 'w').write(src)
PY
fi

# ============================================================================
# 2. /proc/cpuinfo spoof (arm64 builds only)
# ============================================================================
if [[ "${KERNEL_ARCH}" == "arm64" ]]; then
f=arch/arm64/kernel/cpuinfo.c
if grep -q "${MARKER}" "$f"; then
    echo "  - ${f}: already injected"
else
    echo "  - ${f}: injecting Tensor-G5 MIDR spoof"
    python3 - "$f" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()

# Define the spoof helpers as a static block before c_show.
helper = r'''
/* AVD_SPOOF_INJECTED: Tensor G5 layout (cpu0 X4, cpu1-3 A720, cpu4-7 A520) */
struct avd_midr_entry { u8 variant; u8 implementer; u16 part; u8 revision; };
static const struct avd_midr_entry avd_midr_table[] = {
	{ 0x9, 0x41, 0xd4d, 0x1 },
	{ 0x9, 0x41, 0xd41, 0x1 },
	{ 0x9, 0x41, 0xd41, 0x1 },
	{ 0x9, 0x41, 0xd41, 0x1 },
	{ 0x9, 0x41, 0xd80, 0x1 },
	{ 0x9, 0x41, 0xd80, 0x1 },
	{ 0x9, 0x41, 0xd80, 0x1 },
	{ 0x9, 0x41, 0xd80, 0x1 },
};
static u32 avd_spoofed_midr(int cpu)
{
	const struct avd_midr_entry *e =
		&avd_midr_table[cpu < 0 || cpu >= (int)ARRAY_SIZE(avd_midr_table) ? 0 : cpu];
	return ((u32)e->implementer << 24)
	     | ((u32)(e->variant & 0xf) << 20)
	     | (0xfu << 16)
	     | ((u32)(e->part & 0xfff) << 4)
	     | (e->revision & 0xf);
}
'''

m = re.search(r'^static int c_show\(struct seq_file \*m, void \*v\)\s*\{', src, re.M)
assert m, "c_show not found"
src = src[:m.start()] + helper + '\n' + src[m.start():]

# Replace every MIDR_*(midr) with the spoofed equivalent. The variable `i` is
# the per-cpu index already in scope in c_show (for_each_online_cpu(i)).
src = re.sub(r'MIDR_IMPLEMENTOR\(midr\)', 'MIDR_IMPLEMENTOR(avd_spoofed_midr(i))', src)
src = re.sub(r'MIDR_VARIANT\(midr\)',      'MIDR_VARIANT(avd_spoofed_midr(i))',     src)
src = re.sub(r'MIDR_PARTNUM\(midr\)',      'MIDR_PARTNUM(avd_spoofed_midr(i))',     src)
src = re.sub(r'MIDR_REVISION\(midr\)',     'MIDR_REVISION(avd_spoofed_midr(i))',    src)
# midr and the cpuinfo pointer that fed it are both unused now; strip them
# (otherwise -Werror=unused-variable blocks the build).
src = re.sub(r'^\s*u32\s+midr\s*=\s*cpuinfo->reg_midr\s*;\s*\n', '\n', src, flags=re.M)
src = re.sub(r'^\s*struct\s+cpuinfo_arm64\s*\*\s*cpuinfo\s*=\s*[^;]+;\s*\n', '\n', src, flags=re.M)

open(path, 'w').write(src)
PY
fi
else
    echo "  - /proc/cpuinfo: no kernel-level spoof on ${KERNEL_ARCH} (SUSFS open_redirect serves avd-fake/cpuinfo at runtime)"
fi

# ============================================================================
# 3. devtmpfs node suppression -- DISABLED
# ============================================================================
# Kernel-level suppression of goldfish_*/qemu_*/ranchu_* /dev nodes breaks
# the AVD bringup: /dev/goldfish_pipe and /dev/goldfish_sync are the only
# host-guest channels init relies on. Hiding them here gives a stuck-at-init
# boot. The right tool is SUSFS sus_path applied at runtime against the same
# names, which our 02-avd-deeper-spoof.sh on-device script already handles.
echo "  - drivers/base/devtmpfs.c: SKIPPED (would break AVD init)"

# ============================================================================
# 4. scripts/mkcompile_h -- honour KBUILD_COMPILER_STRING
# ============================================================================
# LINUX_COMPILER is baked from "${CC_VERSION}, ${LD_VERSION}", which on this
# build image reads "Ubuntu clang version 18.1.3 (1ubuntu1), Ubuntu LLD 18.1.3".
# That string is in /proc/version, which any app can read, and it says
# "self-built kernel" as plainly as anything could.
#
# It cannot be fixed from userspace: a bind mount over /proc/version is
# access-checked against the source inode's SELinux label, and nothing reachable
# from /data/adb is readable by an app. So fix it where it is generated.
#
# build.sh exports KBUILD_COMPILER_STRING. If this patch has not been applied the
# variable is simply ignored, so the failure mode is the old string rather than a
# broken build.
f=scripts/mkcompile_h
if grep -q "KBUILD_COMPILER_STRING" "$f"; then
    echo "  - ${f}: already injected"
else
    echo "  - ${f}: honouring KBUILD_COMPILER_STRING"
    python3 - "$f" <<'PY2'
import sys
path = sys.argv[1]
src = open(path).read()
old = '#define LINUX_COMPILER\t\t"${CC_VERSION}, ${LD_VERSION}"'
assert old in src, "mkcompile_h layout changed — LINUX_COMPILER line not found"
new = ('if test -n "$KBUILD_COMPILER_STRING"; then\n'
       '\tLINUX_COMPILER_STR="$KBUILD_COMPILER_STRING"\n'
       'else\n'
       '\tLINUX_COMPILER_STR="${CC_VERSION}, ${LD_VERSION}"\n'
       'fi\n\n')
# insert the selection just before the cat heredoc that emits the defines
src = src.replace('cat <<EOF', new + 'cat <<EOF', 1)
src = src.replace(old, '#define LINUX_COMPILER\t\t"${LINUX_COMPILER_STR}"')
open(path, 'w').write(src)
print("    injected")
PY2
fi

# ============================================================================
# 5. arch/x86/kernel/cpu/proc.c -- drop the "hypervisor" CPU flag
# ============================================================================
# x86_64 has no MIDR to rewrite, so section 2's arm64 approach does not apply.
# The one unambiguous tell in an x86 /proc/cpuinfo is the `hypervisor` flag: the
# CPU sets it when running under virtualisation and no physical phone has it.
# Everything else on this guest (a real Intel model name, real cache sizes) is
# plausible as-is.
#
# The previous plan was to spoof the whole file at runtime via SUSFS
# open_redirect onto avd-fake/cpuinfo. That never worked — measured 2026-09-25,
# it returns EACCES to apps because the redirect target is under /data/adb.
f=arch/x86/kernel/cpu/proc.c
if [ ! -f "$f" ]; then
    echo "  - ${f}: absent (not an x86 tree) — skipped"
elif grep -q "${MARKER}" "$f"; then
    echo "  - ${f}: already injected"
else
    echo "  - ${f}: hiding the hypervisor flag"
    python3 - "$f" <<'PY2'
import sys, re
path = sys.argv[1]
src = open(path).read()
# show_cpuinfo prints each set flag from x86_cap_flags[]; skip the one that
# announces virtualisation.
# The loop is BRACELESS:
#     for (i = 0; i < 32*NCAPINTS; i++)
#             if (cpu_has(c, i) && x86_cap_flags[i] != NULL)
#                     seq_printf(m, " %s", x86_cap_flags[i]);
# so inserting a statement before the `if` silently moves the printf OUT of the
# loop, where it runs once with i == 32*NCAPINTS — a compiling, out-of-bounds
# read. Replace the whole construct with a braced body instead. Caught by
# reading the patched output; the compiler would not have complained.
needle = ('\tfor (i = 0; i < 32*NCAPINTS; i++)\n'
          '\t\tif (cpu_has(c, i) && x86_cap_flags[i] != NULL)\n'
          '\t\t\tseq_printf(m, " %s", x86_cap_flags[i]);\n')
assert needle in src, "proc.c layout changed — braceless flag loop not found"
src = src.replace(needle,
    '\tfor (i = 0; i < 32*NCAPINTS; i++) {\n'
    '\t\t/* ' + 'AVD_SPOOF_INJECTED' + ': never advertise virtualisation */\n'
    '\t\tif (x86_cap_flags[i] && !strcmp(x86_cap_flags[i], "hypervisor"))\n'
    '\t\t\tcontinue;\n'
    '\t\tif (cpu_has(c, i) && x86_cap_flags[i] != NULL)\n'
    '\t\t\tseq_printf(m, " %s", x86_cap_flags[i]);\n'
    '\t}\n', 1)
open(path, 'w').write(src)
print("    injected")
PY2
fi

# ============================================================================
# 6. scripts/setlocalversion -- drop the trailing "+"
# ============================================================================
# With CONFIG_LOCALVERSION_AUTO=n, scm_version takes its --short path and emits
# "+" whenever it cannot resolve the checkout to an exact tag. We clone with
# --branch <tag> into a detached HEAD and then patch the tree, so that lookup
# fails and every build came out as "...-ab13070261+".
#
# No Google release kernel carries a "+" — it means "built from a tree that is
# not exactly a release". It is a small tell in a string any app can read, and
# now that /proc/version is no longer spoofed at runtime it is the real one.
#
# .scmversion does NOT work here: 6.6's setlocalversion does not consult it.
# Tried first, measured, no effect.
f=scripts/setlocalversion
if grep -q "${MARKER}" "$f"; then
    echo "  - ${f}: already injected"
else
    echo "  - ${f}: suppressing the dirty-tree \"+\""
    python3 - "$f" <<'PY2'
import sys
path = sys.argv[1]
src = open(path).read()
needle = '\t\tif $short; then\n\t\t\techo "+"\n\t\t\treturn\n\t\tfi\n'
assert needle in src, "setlocalversion layout changed — short path not found"
src = src.replace(needle,
    '\t\tif $short; then\n'
    '\t\t\t# ' + 'AVD_SPOOF_INJECTED' + ': a release kernel has no "+"\n'
    '\t\t\techo ""\n'
    '\t\t\treturn\n'
    '\t\tfi\n', 1)
open(path, 'w').write(src)
print("    injected")
PY2
fi

echo "==> kernel customization complete"
