#!/usr/bin/env python3
"""Reproduce the default-key rejection and test the upstream trusted-key matcher.

The public certificate fixture comes from the APK v2 signing block of the
official FinaSU_v1.2.1_33074-release.apk, whose release SHA-256 is
785c1cef104b76d50c2f35c8169abad7e18033554ae56bf46f74bff44024ebd0.
No private key or signature-check bypass is used.
"""
import hashlib
import os
from pathlib import Path
import shlex
import ssl
import subprocess
import sys
import tempfile

test_dir = Path(__file__).resolve().parent
source = Path(sys.argv[1]).resolve()
helper = test_dir.parent / "lib" / "finasu-manager.sh"
cert = ssl.PEM_cert_to_DER_cert((test_dir / "fixtures/finasu-v1.2.1-cert.pem").read_text())
cert_hash = hashlib.sha256(cert).hexdigest()
args = subprocess.check_output([
    "bash", "-c", '. "$1"; KSU_TYPE=FinaSU; MAKE_ARGS=(); '
    'configure_finasu_manager >/dev/null; printf "%s\\n" "${MAKE_ARGS[@]}"',
    "finasu-test", str(helper),
], text=True).splitlines()
unchanged = subprocess.check_output([
    "bash", "-c", '. "$1"; KSU_TYPE=Official-KernelSU; MAKE_ARGS=(O=out); '
    'configure_finasu_manager; printf "%s\\n" "${MAKE_ARGS[@]}"',
    "finasu-test", str(helper),
], text=True)
assert unchanged == "O=out\n"

apk_sign = (source / "manager/apk_sign.c").read_text()
table = apk_sign[apk_sign.index("typedef struct {"):apk_sign.index("struct sdesc {")]
matcher = apk_sign[apk_sign.index("    int i;\n    for (i = 0; i < ARRAY_SIZE(apk_sign_keys);"):]
matcher = matcher[:matcher.index("\n}\n")]

with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary)
    cacheflush = fixture / "arch/arm64/include/asm/cacheflush.h"
    cacheflush.parent.mkdir(parents=True)
    cacheflush.write_text("")
    # Keep Kbuild's version detection outside the real checkout so the test
    # never triggers its automatic git fetch --unshallow side effect.
    (fixture / "Kbuild").write_text((source / "Kbuild").read_text())
    makefile = fixture / "Makefile"
    makefile.write_text(f"""srctree := {fixture}
objtree := {fixture}
src := {source}
CONFIG_KSU := y
CONFIG_ARM64 := y
CONFIG_KSU_DYNAMIC_MANAGER := y
include {fixture / 'Kbuild'}
print:
\t@printf '%s\\n' 'FLAGS=$(ccflags-y)'
""")
    for corrected in (False, True):
        output = subprocess.check_output([
            "make", "-s", "--no-print-directory", "-f", str(makefile), "print",
            *(args if corrected else []),
        ], cwd=fixture, text=True)
        flags = shlex.split(next(line[6:] for line in output.splitlines() if line.startswith("FLAGS=")))
        definitions = [flag for flag in flags if flag.startswith((
            "-DEXPECTED_", "-DFINASU_TRUSTED_", "-DSECOND_SIGNATURE_RELEASE="))]
        if corrected:
            assert "-DSECOND_SIGNATURE_RELEASE=1" in definitions
        harness = fixture / "matcher.c"
        harness.write_text("""
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define CONFIG_KSU_DYNAMIC_MANAGER 1
#define APK_SIGN_FLAG_TRUSTED 1U
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define strscpy(dst, src, size) snprintf(dst, size, "%s", src)
struct apk_sign_match {
    int index; bool trusted, preset, dynamic; unsigned size;
    const char *name; char hash[65];
};
static bool ksu_dynamic_manager_is_trusted_sign(unsigned size, const char *hash) { return false; }
""" + table + "\nstatic bool match_signature(unsigned certificate_size, const char *hash_str, "
            "struct apk_sign_match *match) {\n" + matcher + "\n}\n" + f"""
int main(void) {{
    struct apk_sign_match match = {{0}};
    bool matched = match_signature({len(cert)}, "{cert_hash}", &match);
    assert(matched == {int(corrected)});
    if (matched) {{
        assert(match.trusted && !match.preset && !match.dynamic);
        assert(strcmp(match.name, "FinaSU") == 0);
    }}
    assert(!match_signature({len(cert) + 1}, "{cert_hash}", &match));
    assert(!match_signature({len(cert)}, "{'0' * 64}", &match));
    assert(match_signature(0x033b, "c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6", &match));
    assert(match.trusted == {int(not corrected)});
    assert(match.preset == {int(corrected)});
    return 0;
}}
""")
        binary = fixture / "matcher"
        subprocess.run([*shlex.split(os.environ.get("CC", "cc")), "-std=gnu11", *definitions,
                        str(harness), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)

    # The artifact gate must reject a kernel containing only the old key.
    image, proof = fixture / "Image", fixture / "proof.txt"
    for corrected in (False, True):
        image.write_bytes(b"\0" + (cert_hash if corrected else "c371061b19d8c7d7d6133c6a9bafe198fa944e50c1b31c9d8daa8d7f1fc2d2d6").encode() + b"\0")
        result = subprocess.run([
            "bash", "-c", '. "$1"; verify_finasu_manager_binary "$2" "$3"',
            "finasu-test", str(helper), str(image), str(proof),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        assert (result.returncode == 0) == corrected
    assert cert_hash in proof.read_text()

print("PASS: upstream default-key rejection, FinaSU release trust, preset isolation, and Image certificate gate")
