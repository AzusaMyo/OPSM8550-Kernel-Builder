#!/usr/bin/env python3
"""Run the real SUSFS command dispatcher and verify the NoMount v23 ABI."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

repo, susfs = map(lambda p: Path(p).resolve(), sys.argv[1:3])
ref, commit = sys.argv[3:5]
scripts = Path(__file__).resolve().parents[1]
helper = scripts / "lib/finasu-integration.sh"
subprocess.run([
    "bash", "-c", '. "$1"; verify_finasu_susfs_inputs "$2/kernel" "$3" "$4" "$5"',
    "finasu-test", str(helper), str(repo), str(susfs), ref, commit,
], check=True)
bad_pin = subprocess.run([
    "bash", "-c", '. "$1"; verify_finasu_susfs_inputs "$2/kernel" "$3" "$4" "$5"',
    "finasu-test", str(helper), str(repo), str(susfs), ref, "0" * 40,
], capture_output=True)
assert bad_pin.returncode != 0

extension = (repo / "kernel/extension/susfs.c").read_text()
dispatcher = extension[extension.index("int ksu_handle_sys_reboot("):]
install = extension[extension.index("static int inline_install_fd("):extension.index("int ksu_handle_sys_reboot(")]
commands = re.findall(r"case (CMD_SUSFS_\w+):\s*(\w+)\(arg\);", dispatcher)
definitions = "\n".join(line for line in (susfs / "kernel_patches/include/linux/susfs_def.h").read_text().splitlines()
                        if re.match(r"#define (CMD_SUSFS_|SUSFS_MAGIC)", line))
magic = "\n".join(line for line in (repo / "kernel/include/uapi/supercall.h").read_text().splitlines()
                  if "static const __u32 KSU_INSTALL_MAGIC" in line)
options = re.findall(r"^config (KSU_SUSFS\w*)", (repo / "kernel/Kconfig").read_text(), re.M)
handlers = {handler: index + 1 for index, handler in enumerate(dict.fromkeys(handler for _, handler in commands))}
mock_handlers = "\n".join(f"static void {handler}(void **arg) {{ receipt = {index}; }}"
                          for handler, index in handlers.items())
checks = "\n".join(f"receipt = 0; assert(ksu_handle_sys_reboot(KSU_INSTALL_MAGIC1, SUSFS_MAGIC, {command}, &arg) == 0); "
                    f"assert(receipt == {handlers[handler]});" for command, handler in commands)
nomount = (repo / "userspace/nomount/kernel/src/nomount.h").read_text()
wire = "\n".join(re.search(rf"struct {name} \{{.*?\}} __attribute__\(\(packed\)\);", nomount, re.S).group()
                 for name in ("nm_payload", "nm_rule_hdr", "nm_del_hdr"))
rust = (repo / "userspace/ksud/src/nomount.rs").read_text()
assert 'NOMOUNT_BASE_VERSION "23"' in nomount
assert "MIN_API_VERSION: u32 = 23" in rust
rule_size = int(re.search(r"RULE_HEADER_SIZE: usize = (\d+)", rust)[1])
delete_size = int(re.search(r"DELETE_HEADER_SIZE: usize = (\d+)", rust)[1])

with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary)
    harness = fixture / "features.c"
    harness.write_text('''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
typedef uint32_t __u32;
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint64_t u64;
#define __user
#define CONFIG_KSU_HOOK_SUSFS_INLINE 1
static unsigned uid, receipt;
static int copy_error, close_count;
struct kuid { unsigned val; };
static struct kuid current_uid(void) { return (struct kuid){ uid }; }
static int ksu_install_fd(void) { return 42; }
static void ksu_close_fd(int fd) { assert(fd == 42); close_count++; }
static int copy_to_user(void *dst, const void *src, unsigned size) {
    if (copy_error) return 1;
    memcpy(dst, src, size); return 0;
}
''' + "\n".join(f"#define CONFIG_{option} 1" for option in options) + "\n" + definitions + "\n"
        + magic + "\n" + mock_handlers + "\n" + install + dispatcher + "\n" + wire + f'''
int main(void) {{
    int fd = 0;
    void *arg = &fd;
    _Static_assert(sizeof(struct nm_rule_hdr) == {rule_size}, "NoMount add/list ABI");
    _Static_assert(sizeof(struct nm_del_hdr) == {delete_size}, "NoMount delete ABI");
    _Static_assert(sizeof(struct nm_payload) == 4096, "NoMount key payload ABI");
    _Static_assert(offsetof(struct nm_rule_hdr, uid) == 4 && offsetof(struct nm_rule_hdr, uid_end) == 8 &&
                   offsetof(struct nm_rule_hdr, deny_start) == 12 && offsetof(struct nm_rule_hdr, deny_end) == 16 &&
                   offsetof(struct nm_rule_hdr, v_len) == 20 && offsetof(struct nm_rule_hdr, r_len) == 22,
                   "NoMount add/list field layout");
    _Static_assert(offsetof(struct nm_del_hdr, uid_end) == 4 && offsetof(struct nm_del_hdr, deny_start) == 8 &&
                   offsetof(struct nm_del_hdr, deny_end) == 12 && offsetof(struct nm_del_hdr, v_len) == 16,
                   "NoMount delete field layout");
    {checks}
    uid = 10000; receipt = 0;
    assert(ksu_handle_sys_reboot(KSU_INSTALL_MAGIC1, SUSFS_MAGIC, CMD_SUSFS_SHOW_VERSION, &arg) == -EINVAL);
    assert(receipt == 0);
    assert(ksu_handle_sys_reboot(0, SUSFS_MAGIC, CMD_SUSFS_SHOW_VERSION, &arg) == -EINVAL);
    uid = 0;
    assert(ksu_handle_sys_reboot(KSU_INSTALL_MAGIC1, SUSFS_MAGIC, 0, &arg) == -EINVAL);
    assert(ksu_handle_sys_reboot(KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, &arg) == 0 && fd == 42);
    copy_error = 1;
    assert(ksu_handle_sys_reboot(KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, &arg) == -EFAULT);
    assert(close_count == 1);
    assert(ksu_handle_sys_reboot(KSU_INSTALL_MAGIC1, KSU_INSTALL_MAGIC2, 0, 0) == -EFAULT);
}}
''')
    binary = fixture / "features"
    subprocess.run([*shlex.split(os.environ.get("CC", "cc")), "-std=gnu11", str(harness), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

    # Wire the real vendored driver into both layouts and check idempotence.
    for layout in ("fs", "common/fs"):
        root = fixture / layout.replace("/", "-")
        fs = root / layout
        fs.mkdir(parents=True)
        (fs / "Kconfig").write_text('menu "Filesystem"\nendmenu\n')
        (fs / "Makefile").write_text("")
        subprocess.run([
            "bash", "-c", '. "$1/lib/kernel-helpers.sh"; . "$1/lib/nomount-setup.sh"; '
            '. "$1/lib/verify.sh"; . "$1/lib/finasu-integration.sh"; '
            'KSU_REPO_DIR="$2"; NOMOUNT_COMMIT="$FINASU_COMMIT"; NOMOUNT_REF="$FINASU_RELEASE:userspace/nomount"; '
            'GITHUB_ENV="$PWD/env"; install_finasu_nomount; verify_nomount_source_integration; '
            'install_finasu_nomount; verify_nomount_source_integration',
            "finasu-test", str(scripts), str(repo),
        ], cwd=root, check=True, stdout=subprocess.DEVNULL)
        assert (fs / "nomount").resolve() == repo / "userspace/nomount/kernel/src"
        assert (fs / "Makefile").read_text().count('obj-$(CONFIG_NOMOUNT) += nomount/') == 1
        assert "nomount_version=23\n" in (root / "nomount-source-proof.txt").read_text()

    header = repo / "userspace/nomount/kernel/src/nomount.h"
    original = header.read_bytes()
    try:
        header.write_bytes(original + b"\n/* unreviewed source drift */\n")
        drift = subprocess.run([
            "bash", "-c", '. "$1/lib/kernel-helpers.sh"; . "$1/lib/nomount-setup.sh"; '
            '. "$1/lib/finasu-integration.sh"; KSU_REPO_DIR="$2"; '
            'NOMOUNT_COMMIT="$FINASU_COMMIT"; NOMOUNT_REF="$FINASU_RELEASE:userspace/nomount"; '
            'GITHUB_ENV="$PWD/env"; install_finasu_nomount',
            "finasu-test", str(scripts), str(repo),
        ], cwd=root, capture_output=True)
        assert drift.returncode != 0, "Unreviewed NoMount source drift was accepted"
    finally:
        header.write_bytes(original)

print(f"PASS: {ref}: SUSFS command routing, root checks, FD cleanup, NoMount v23 ABI and built-in wiring")
