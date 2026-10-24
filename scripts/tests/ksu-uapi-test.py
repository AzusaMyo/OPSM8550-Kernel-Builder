#!/usr/bin/env python3
"""Execute the patched upstream handlers with host mocks, using their real C source."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
header = (repo / 'uapi/supercall.h').read_text()
dispatch = (repo / 'kernel/supercall/dispatch.c').read_text()
version = int(re.search(r'KERNEL_SU_UAPI_VERSION = (\d+);', header)[1])


def function(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def run(source, *flags):
    with tempfile.TemporaryDirectory() as temp:
        path = Path(temp) / 'test.c'
        path.write_text(source)
        binary = Path(temp) / 'test'
        subprocess.run([os.environ.get('CC', 'cc'), '-std=gnu11', '-Wno-int-conversion',
                        '-Wno-incompatible-pointer-types', *flags, str(path), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


preamble = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
typedef uint32_t u32;
typedef uint64_t u64;
#define __user
#define __nocfi
#define __init
#define pr_info(...) ((void)0)
#define pr_err(...) ((void)0)
#define pr_warn(...) ((void)0)
#define copy_from_user(d,s,n) ((s) ? (memcpy(d,s,n),0) : 1)
'''
events = []
for name in ('POST_FS_DATA', 'BOOT_COMPLETED', 'MODULE_MOUNTED', 'SERVICES'):
    value = re.search(r'EVENT_' + name + r'[, =]+(\d+)', header)[1]
    events.append(f'#define EVENT_{name} {value}\n')
run(preamble + ''.join(events) + f'\n#define MONITOR_EXPECTED {int("susfs_start_sdcard_monitor_fn();" in dispatch)}\n' + r'''
#define CONFIG_KSU_SUSFS 1
struct ksu_report_event_cmd { u32 event; };
static bool ksu_late_loaded;
static int post_count, boot_count, module_count, monitor_count;
static void on_post_fs_data(void) { post_count++; }
static void on_boot_completed(void) { boot_count++; }
static void on_module_mounted(void) { module_count++; }
static void susfs_start_sdcard_monitor_fn(void) { monitor_count++; }
''' + function(dispatch, 'static int do_report_event(') + r'''
int main(void) {
    struct ksu_report_event_cmd cmd = { EVENT_SERVICES };
    assert(do_report_event(NULL) == -EFAULT);
    assert(do_report_event(&cmd) == 1);
    assert(do_report_event(&cmd) == 0);
    cmd.event = EVENT_POST_FS_DATA;
    assert(do_report_event(&cmd) == 0 && post_count == 1);
    cmd.event = EVENT_SERVICES;
    assert(do_report_event(&cmd) == 1);
    assert(do_report_event(&cmd) == 0);
    cmd.event = EVENT_POST_FS_DATA;
    assert(do_report_event(&cmd) == 0 && post_count == 1);
    cmd.event = EVENT_SERVICES;
    assert(do_report_event(&cmd) == 1);
    cmd.event = EVENT_MODULE_MOUNTED;
    assert(do_report_event(&cmd) == 0 && module_count == 1);
    cmd.event = EVENT_BOOT_COMPLETED;
    assert(do_report_event(&cmd) == 0 && boot_count == 1 && monitor_count == MONITOR_EXPECTED);
    assert(do_report_event(&cmd) == 0 && boot_count == 1 && monitor_count == MONITOR_EXPECTED);
}
''')
print(f'PASS: UAPI {version} service start/skip, soft reboot reset, and SUSFS boot callbacks')
if version != 6:
    sys.exit(0)

assert re.search(r'\.cmd = KSU_IOCTL_EXTENSION,.*?\.handler = do_extension,\s*\.perm_check = manager_or_root', dispatch, re.S)
assert '.cmd = KSU_IOCTL_KPM,' in dispatch  # Older managers still work.
extension_abi = header[header.index('enum ksu_extension_id {'):header.index('struct ksu_set_spoof_version_cmd {')]
extension_ioctl = re.search(r'static const __u32 KSU_IOCTL_EXTENSION =\s*[^;]+;', header)[0]
for kpm, susfs in ((0, 0), (1, 0), (0, 1), (1, 1)):
    run(preamble + r'''
#include <stddef.h>
#define __u32 u32
#define __u64 u64
#define _IOC_READ 2U
#define _IOC_WRITE 1U
#define _IOC(d,t,n,s) (((d)<<30)|((s)<<16)|((t)<<8)|(n))
#define KSU_FEATURE_FLAG_SUPPORTED 1U
static bool fail_output;
#define copy_to_user(d,s,n) ((d) && !fail_output ? (memcpy(d,s,n),0) : 1)
static void *last_kpm_arg;
static int do_kpm(void *arg) { last_kpm_arg = arg; return arg ? 37 : -EFAULT; }
''' + extension_abi + extension_ioctl + function(dispatch, 'static int do_extension(') + r'''
int main(void) {
    _Static_assert(sizeof(struct ksu_extension_cmd) == 32, "extension wire size");
    _Static_assert(offsetof(struct ksu_extension_cmd, user_ptr) == 24, "pointer offset");
    assert(KSU_IOCTL_EXTENSION == 0xc0204b2cU);
    assert(do_extension(NULL) == -EFAULT);
    struct ksu_extension_cmd cmd = {0};
    for (u32 id = 0; id < KSU_EXTENSION_MAX; id++) {
        cmd = (struct ksu_extension_cmd){id, KSU_EXTENSION_GET, 255, 99, 99, 0};
        bool supported = (id == KSU_EXTENSION_KPM && EXPECT_KPM) ||
                         (id == KSU_EXTENSION_SUSFS && EXPECT_SUSFS);
        assert(do_extension(&cmd) == (supported ? 0 : -EOPNOTSUPP));
        if (supported) {
            assert(cmd.supported == 1 && cmd.reserved == 0);
            assert(cmd.value == (id == KSU_EXTENSION_KPM ? 1 : 0));
            fail_output = true;
            assert(do_extension(&cmd) == -EFAULT);
            fail_output = false;
        }
        cmd.op = KSU_EXTENSION_SET; assert(do_extension(&cmd) == -EOPNOTSUPP);
        cmd.op = KSU_EXTENSION_WIPE; assert(do_extension(&cmd) == -EOPNOTSUPP);
        cmd.op = 99; assert(do_extension(&cmd) == -EINVAL);
        int payload;
        cmd.op = KSU_EXTENSION_IO; cmd.user_ptr = (u64)(uintptr_t)&payload;
        if (id == KSU_EXTENSION_KPM && EXPECT_KPM) {
            assert(do_extension(&cmd) == 37 && last_kpm_arg == &payload);
            cmd.user_ptr = 0; assert(do_extension(&cmd) == -EFAULT);
        } else {
            assert(do_extension(&cmd) == -EOPNOTSUPP);
        }
    }
    cmd.id = KSU_EXTENSION_MAX; assert(do_extension(&cmd) == -EINVAL);
    cmd.id = UINT32_MAX; assert(do_extension(&cmd) == -EINVAL);
}
''', f'-DEXPECT_KPM={kpm}', f'-DEXPECT_SUSFS={susfs}',
        *(['-DCONFIG_KPM=1'] if kpm else []), *(['-DCONFIG_KSU_SUSFS=1'] if susfs else []))
    print(f'PASS: extension ABI, GET availability, KPM IO routing, errors; KPM={kpm}, SUSFS={susfs}')

assert re.search(r'\.cmd = KSU_IOCTL_LOOKUP_SYMBOLS,.*?\.handler = do_lookup_symbols,\s*\.perm_check = only_root', dispatch, re.S)
assert not re.search(r'cmd.flags\s*\|=\s*KSU_GET_INFO_FLAG_PREINIT', dispatch)
runtime = (repo / 'kernel/runtime/ksud_integration.c').read_text()
assert runtime.index('filp_open(MODULE_RC_PATH_VOLD') < runtime.index('filp_open(MODULE_RC_PATH_WATCHDOG')
resolver = (repo / 'kernel/infra/symbol_resolver.c').read_text()
resolver = re.sub(r'^#include .*\n', '', resolver, flags=re.M)
lookup_cmd = header[header.index('struct ksu_lookup_symbols_cmd {'):]
lookup_cmd = lookup_cmd[:lookup_cmd.index('};') + 2]
lookup_max = re.search(r'KSU_LOOKUP_SYMBOLS_MAX = (\d+)', header)[1]
mocks = r'''
#define KERNEL_VERSION(a,b,c) (((a)<<16)+((b)<<8)+(c))
#define LINUX_VERSION_CODE KERNEL_VERSION(TEST_MAJOR,TEST_MINOR,0)
#define KSYM_NAME_LEN 128
#define KSYM_SYMBOL_LEN 256
#define GFP_KERNEL 0
#define likely(x) (x)
#define unlikely(x) (x)
#define current NULL
#define cond_resched() ((void)0)
#define kzalloc(n,g) calloc(1,n)
#define kvmalloc_array(n,s,g) calloc(n,s)
#define kvcalloc(n,s,g) calloc(n,s)
#define kvfree(p) free(p)
#define kfree(p) free(p)
#define __aligned_u64 u64
#define __u32 u32
#define get_user(v,p) ((p) ? ((v)=*(p),0) : 1)
#define put_user(v,p) ((p) ? (*(p)=(v),0) : 1)
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((intptr_t)(p))
static char *strndup_user(const char *p, size_t max) {
    if (!p) return (char *)(intptr_t)-EFAULT;
    size_t n = strnlen(p,max);
    if (n == max) return (char *)(intptr_t)-EINVAL;
    return strdup(p);
}
static bool interrupted;
static bool fatal_signal_pending(void *task) { return interrupted; }
static void sort(void *b, size_t n, size_t s, int (*cmp)(const void*,const void*), void *swap) {
    qsort(b,n,s,cmp);
}
struct module { int unused; };
static struct module module;
struct symbol { const char *name; unsigned long addr; bool mod; };
static struct symbol symbols[] = {
    {"alpha",0x100,false}, {"alpha.llvm.123",0x110,false},
    {"beta.llvm.42",0x200,false}, {"gamma$123",0x300,false},
    {"module_only",0x400,true}
};
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6,6,0)
static int kallsyms_on_each_symbol(int (*cb)(void*,const char*,unsigned long), void *data) {
    for (unsigned i=0; i<4; i++) { int r=cb(data,symbols[i].name,symbols[i].addr); if(r) return r; }
    return 0;
}
#else
static int kallsyms_on_each_symbol(int (*cb)(void*,const char*,struct module*,unsigned long), void *data) {
    for (unsigned i=0; i<5; i++) { int r=cb(data,symbols[i].name,symbols[i].mod?&module:NULL,symbols[i].addr); if(r) return r; }
    return 0;
}
#endif
static int kallsyms_on_each_match_symbol(int (*cb)(void*,unsigned long), const char *name, void *data) {
    for (unsigned i=0; i<4; i++) if (!strcmp(name,symbols[i].name)) { int r=cb(data,symbols[i].addr); if(r) return r; }
    return 0;
}
static unsigned long kallsyms_lookup_name(const char *name) {
    if(!strcmp(name,"kallsyms_on_each_symbol")) return (unsigned long)kallsyms_on_each_symbol;
    if(!strcmp(name,"kallsyms_on_each_match_symbol")) return (unsigned long)kallsyms_on_each_match_symbol;
    for (unsigned i=0; i<5; i++) if(!strcmp(name,symbols[i].name)) return symbols[i].addr;
    return 0;
}
static void kallsyms_lookup(unsigned long addr, void *size, void *offset, char **mod, char *buf) {
    *mod = addr == 0x400 ? "test_module" : NULL;
}
'''
main = r'''
int main(void) {
    const char *names[] = {"alpha","beta","gamma","alpha","missing","module_only",NULL};
    unsigned long addrs[7];
    ksu_init_symbol_resolver();
    assert(ksu_lookup_kernel_symbols(names,addrs,7) == 4);
    assert(addrs[0]==0x100 && addrs[1]==0x200 && addrs[2]==0x300 && addrs[3]==0x100);
    assert(addrs[4]==0 && addrs[5]==0 && addrs[6]==0);
    interrupted = true;
    assert(ksu_lookup_kernel_symbols(names,addrs,7) == -EINTR);
    interrupted = false;
    u64 user_names[] = {(u64)(uintptr_t)"alpha",(u64)(uintptr_t)"missing",(u64)(uintptr_t)"beta"};
    u64 user_addrs[3] = {99,99,99};
    struct ksu_lookup_symbols_cmd cmd = {(u64)(uintptr_t)user_names,(u64)(uintptr_t)user_addrs,3,0};
    assert(do_lookup_symbols(&cmd) == 2);
    assert(user_addrs[0]==0x100 && user_addrs[1]==0 && user_addrs[2]==0x200);
    assert(do_lookup_symbols(NULL) == -EFAULT);
    cmd.flags=1; assert(do_lookup_symbols(&cmd) == -EINVAL); cmd.flags=0;
    cmd.count=0; assert(do_lookup_symbols(&cmd) == -EINVAL);
    cmd.count=1025; assert(do_lookup_symbols(&cmd) == -EINVAL); cmd.count=3;
    cmd.names=0; assert(do_lookup_symbols(&cmd) == -EFAULT); cmd.names=(u64)(uintptr_t)user_names;
    cmd.addrs=0; assert(do_lookup_symbols(&cmd) == -EFAULT);
}
'''
for major, minor in ((5,10),(5,15),(6,1),(6,6)):
    run(preamble + mocks + resolver + lookup_cmd + f'\n#define KSU_LOOKUP_SYMBOLS_MAX {lookup_max}\n'
        + function(dispatch, 'static int do_lookup_symbols(') + main,
        f'-DTEST_MAJOR={major}',f'-DTEST_MINOR={minor}')
    print(f'PASS: UAPI 6 lookup on {major}.{minor}, suffixes, duplicates, missing/module symbols, interruption, ioctl validation')
print('PASS: symbol lookup is root-only, module rc prefers vold, preinit stays unadvertised')
