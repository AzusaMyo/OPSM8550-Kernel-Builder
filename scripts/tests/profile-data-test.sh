#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/profile-data.sh
. "${SCRIPT_DIR}/../lib/profile-data.sh"
# shellcheck source=../lib/anykernel-helpers.sh
. "${SCRIPT_DIR}/../lib/anykernel-helpers.sh"
# shellcheck source=../lib/nomount-setup.sh
. "${SCRIPT_DIR}/../lib/nomount-setup.sh"
# shellcheck source=../lib/susfs-apply.sh
. "${SCRIPT_DIR}/../lib/susfs-apply.sh"
# shellcheck source=../lib/kernel-helpers.sh
. "${SCRIPT_DIR}/../lib/kernel-helpers.sh"
# shellcheck source=../lib/verify.sh
. "${SCRIPT_DIR}/../lib/verify.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

profiles=()
mapfile -t profiles < <(list_build_profiles)
assert_eq "12" "${#profiles[@]}" "profile count"

WORKFLOW_FILE="${SCRIPT_DIR}/../../.github/workflows/build.yml"
UPSTREAM_HEALTH_WORKFLOW="${SCRIPT_DIR}/../../.github/workflows/upstream-health.yml"
COMPILE_SCRIPT="${SCRIPT_DIR}/../compile-kernel.sh"
RESOLVER_SCRIPT="${SCRIPT_DIR}/../resolve-profile.sh"
KSU_SETUP_SCRIPT="${SCRIPT_DIR}/../lib/ksu-setup.sh"
SUSFS_APPLY_SCRIPT="${SCRIPT_DIR}/../lib/susfs-apply.sh"
SUKISU_SUSFS_COMPAT_PATCH="${SCRIPT_DIR}/../patches/sukisu-susfs-core-init-compat.patch"
SUKISU_SUSFS_POLICY_COMPAT_PATCH="${SCRIPT_DIR}/../patches/sukisu-susfs-policy-compat.patch"
for profile in "${profiles[@]}"; do
  grep -Fq -- "- ${profile}" "$WORKFLOW_FILE" \
    || fail "workflow is missing profile option: $profile"
done
kernel_branch_input="$(sed -n '/^      kernel_branch:/,/^      clang_choice:/p' "$WORKFLOW_FILE")"
grep -Fq 'type: choice' <<< "$kernel_branch_input" \
  || fail "manual kernel branch input must be a choice"
grep -Fq -- '- "16.0"' <<< "$kernel_branch_input" \
  || fail "manual kernel branch choices must include crDroid 16.0"
grep -Fq '"CC=ccache clang"' "$COMPILE_SCRIPT" \
  || fail "compile script is not passing ccache on the make command line"
grep -Fq 'KBUILD_BUILD_TIMESTAMP=' "$COMPILE_SCRIPT" \
  || fail "compile script is missing deterministic Kbuild metadata"
if grep -Fq 'CCACHE_PREFIX' "$WORKFLOW_FILE"; then
  fail "workflow must not export ccache's reserved CCACHE_PREFIX variable"
fi
grep -Fq 'CCACHE_KEY_PREFIX' "$WORKFLOW_FILE" \
  || fail "workflow is missing the cache-key-only ccache prefix"
grep -Fq 'RELEASE_TAG="kernel-build-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"' "$WORKFLOW_FILE" \
  || fail "release workflow is missing its immutable tag reservation"
grep -Fq 'if ! EXISTING_SHA="$(gh api' "$WORKFLOW_FILE" \
  || fail "release tag lookup must distinguish a missing tag from an existing SHA"
grep -Fq 'gh release create "$RELEASE_TAG"' "$WORKFLOW_FILE" \
  || fail "release workflow must publish the pre-reserved tag"
grep -Fq 'gh api "repos/${GH_REPO}/git/refs/tags/${RELEASE_TAG}" --method DELETE' "$WORKFLOW_FILE" \
  || fail "release workflow must clean up a reserved tag after a failed build"
grep -Eq '^[[:space:]]+lld \\' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health workflow is missing the LLVM linker"
grep -Eq '^[[:space:]]+llvm \\' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health workflow is missing the LLVM binutils"
grep -Fq 'MODULES_CLONE_DIR="${UPSTREAM_SOC}-modules"' "$RESOLVER_SCRIPT" \
  || fail "community module checkout must preserve the upstream repository stem"
grep -Fq 'clone_repo "$MODULES_REPO" "$MODULES_BRANCH"' "${SCRIPT_DIR}/../clone-sources.sh" \
  || fail "modules checkout must use its independently resolved branch"
grep -Fq 'MAKE_ARGS+=("${KERNEL_MAKE_FLAG_ARRAY[@]}")' "$COMPILE_SCRIPT" \
  || fail "compile script must pass profile-specific flags to every make invocation"
grep -Fq 'make "${MAKE_ARGS[@]}" certs/extract-cert' "$COMPILE_SCRIPT" \
  || fail "validation mode must smoke-compile the kernel certificate host tool"
grep -Fq 'profile: SM8650 | OnePlus 12 | crDroid' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health must exercise the crDroid SM8650 certificate compatibility path"

expected_socs=(sm7550 sm7550 sm8450 sm8450 sm8550 sm8550 sm8550 sm8550 sm8550 sm8650 sm8650 sm8650)
expected_upstream_socs=(sm8550 sm8550 sm8450 sm8450 sm8550 sm8550 sm8550 sm8550 sm8550 sm8650 sm8650 sm8650)
expected_codenames=(benz benz negroni ovaltine salami salami "salami aston" "salami aston" aston waffle waffle waffle)
expected_devices=("benz OP5D3FL1 CPH2613" "benz OP5D3FL1 CPH2613" "negroni OP516EL1 OP516FL1" "ovaltine OP5551L1 OP5552L1" "salami OP591BL1 OP594DL1" "salami OP591BL1 OP594DL1" "salami OP591BL1 OP594DL1 aston OP5D35L1" "salami OP591BL1 OP594DL1 aston OP5D35L1" "aston OP5D35L1" "waffle OP5929L1 OP595DL1" "waffle OP5929L1 OP595DL1" "waffle OP5929L1 OP595DL1")

for i in "${!profiles[@]}"; do
  resolve_build_profile "${profiles[$i]}"
  assert_eq "${expected_socs[$i]}" "$SOC" "${profiles[$i]} SoC"
  assert_eq "${expected_upstream_socs[$i]}" "$UPSTREAM_SOC" "${profiles[$i]} upstream SoC"
  assert_eq "${expected_codenames[$i]}" "$DEVICE_CODENAMES" "${profiles[$i]} codenames"
  assert_eq "${expected_devices[$i]}" "$DEVICE_NAMES" "${profiles[$i]} devices"
  [[ -n "$PROFILE_ID" && -n "$BUILD_CONFIGS" && -n "$SOURCE_SLUG" ]] \
    || fail "${profiles[$i]} did not resolve all required metadata"
done

resolve_build_profile "SM7550 | OnePlus Nord CE4 | development"
assert_eq "CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_BENZ_DTB=y" "$KERNEL_MAKE_FLAGS" "Nord CE4 development make flags"
resolve_build_profile "SM7550 | OnePlus Nord CE4 | crDroid (recommended for crDroid)"
assert_eq "crdroidandroid" "$KERNEL_SOURCE" "Nord CE4 crDroid kernel source"
assert_eq "sm8550" "$UPSTREAM_SOC" "Nord CE4 crDroid upstream repository SoC"
assert_eq "CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_BENZ_DTB=y" "$KERNEL_MAKE_FLAGS" "Nord CE4 crDroid make flags"

resolve_build_profile "SM8550 | OnePlus 11 | LunarisOS"
assert_eq "https://github.com/osm1019/kernel_oneplus_sm8550.git" "$KERNEL_REPO_OVERRIDE" "LunarisOS kernel repository"
assert_eq "https://github.com/osm1019/android_kernel_oneplus_sm8550-modules.git" "$MODULES_REPO_OVERRIDE" "LunarisOS modules repository"
assert_eq "los" "$MODULES_BRANCH_OVERRIDE" "LunarisOS modules branch"
assert_eq "lunarisos" "$SOURCE_SLUG" "LunarisOS source slug"

resolve_root_solution "ReSukiSU + susfs"
assert_eq "ReSukiSU-with-susfs" "$KSU_TYPE" "root mapping"
resolve_root_solution "KernelSU-Next + SUSFS"
assert_eq "KernelSU-Next-with-susfs" "$KSU_TYPE" "KernelSU-Next SUSFS root mapping"
resolve_root_solution "ReSukiSU + SUSFS + NoMount (experimental)"
assert_eq "ReSukiSU-with-susfs-nomount" "$KSU_TYPE" "NoMount root mapping"
resolve_root_solution "SukiSU Ultra + KPM (experimental)"
assert_eq "SukiSU-Ultra-with-KPM" "$KSU_TYPE" "KPM root mapping"
resolve_root_solution "SukiSU Ultra + SUSFS + KPM (experimental)"
assert_eq "SukiSU-Ultra-with-susfs-KPM" "$KSU_TYPE" "SukiSU SUSFS/KPM root mapping"
resolve_root_solution "SukiSU Ultra + SUSFS + NoMount + KPM (experimental)"
assert_eq "SukiSU-Ultra-with-susfs-nomount-KPM" "$KSU_TYPE" "SukiSU SUSFS/NoMount/KPM root mapping"
grep -Fq -- '- ReSukiSU + SUSFS + NoMount (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the NoMount root option"
grep -Fq -- '- KernelSU-Next + SUSFS' "$WORKFLOW_FILE" \
  || fail "workflow is missing the KernelSU-Next SUSFS root option"
grep -Fq 'KSU_REPO="https://github.com/pershoot/KernelSU-Next.git"' "$RESOLVER_SCRIPT" \
  || fail "KernelSU-Next SUSFS must resolve the compatible dev-susfs fork"
grep -Fq 'KSU_REF="dev-susfs"' "$RESOLVER_SCRIPT" \
  || fail "KernelSU-Next SUSFS must resolve the dev-susfs branch"
grep -Fq -- '- SukiSU Ultra + KPM (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the KPM root option"
grep -Fq -- '- SukiSU Ultra + SUSFS + KPM (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the combined SukiSU SUSFS/KPM root option"
grep -Fq -- '- SukiSU Ultra + SUSFS + NoMount + KPM (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the combined SukiSU SUSFS/NoMount/KPM root option"
grep -Fq -- '- SukiSU Ultra + SUSFS + NoMount + KPM (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing the combined SukiSU SUSFS/NoMount/KPM preset"
grep -Fq 'SukiSU-Ultra-with-KPM|SukiSU-Ultra-with-susfs-KPM|SukiSU-Ultra-with-susfs-nomount-KPM)' "$RESOLVER_SCRIPT" \
  || fail "resolver does not route all SukiSU presets to SukiSU Ultra"
grep -Fq 'SUSFS_COMMIT="$(sukisu_compatible_susfs_commit "$SUSFS_REF")"' "$RESOLVER_SCRIPT" \
  || fail "resolver does not use the SukiSU-compatible SUSFS commit map"
grep -Fq '"SukiSU-Ultra-with-KPM"|"SukiSU-Ultra-with-susfs-KPM"|"SukiSU-Ultra-with-susfs-nomount-KPM")' "$KSU_SETUP_SCRIPT" \
  || fail "KernelSU setup does not install SukiSU Ultra for all combined presets"
grep -Fq 'resolve_known_sukisu_susfs_rejects' "$SUSFS_APPLY_SCRIPT" \
  || fail "SUSFS integration is missing the guarded SukiSU drift resolver"
KSU_TYPE="SukiSU-Ultra-with-susfs-KPM"
is_sukisu_susfs_variant || fail "SukiSU SUSFS/KPM preset must allow guarded SUSFS drift repair"
KSU_TYPE="SukiSU-Ultra-with-susfs-nomount-KPM"
is_sukisu_susfs_variant || fail "SukiSU SUSFS/NoMount/KPM preset must allow guarded SUSFS drift repair"
KSU_TYPE="SukiSU-Ultra-with-KPM"
if is_sukisu_susfs_variant; then
  fail "SukiSU KPM-only preset must not enter SUSFS drift repair"
fi
test -f "$SUKISU_SUSFS_COMPAT_PATCH" \
  || fail "SUSFS integration is missing the guarded SukiSU compatibility patch"
grep -Fq 'kernelsu-objs += infra/symbol_resolver.o' "$SUKISU_SUSFS_COMPAT_PATCH" \
  || fail "SukiSU SUSFS/KPM compatibility patch does not restore the symbol resolver object"
grep -Fq 'ksu_init_symbol_resolver();' "$SUKISU_SUSFS_COMPAT_PATCH" \
  && fail "SukiSU SUSFS/KPM compatibility patch must preserve, not duplicate, resolver initialization"
test -f "$SUKISU_SUSFS_POLICY_COMPAT_PATCH" \
  || fail "SUSFS integration is missing the guarded SukiSU policy compatibility patch"
grep -Fq 'webview_zygote (controlled by feature policy)' "$SUKISU_SUSFS_POLICY_COMPAT_PATCH" \
  || fail "SukiSU policy compatibility patch does not resolve kernel umount drift"
grep -Fq 'ksu_get_manager_appid() == uid % PER_USER_RANGE' "$SUKISU_SUSFS_POLICY_COMPAT_PATCH" \
  || fail "SukiSU policy compatibility patch does not resolve allowlist drift"
grep -Fq 'kernel/feature/kernel_umount.c.rej' "$SUSFS_APPLY_SCRIPT" \
  || fail "SukiSU drift resolver does not guard the kernel umount reject"
grep -Fq 'kernel/policy/allowlist.c.rej' "$SUSFS_APPLY_SCRIPT" \
  || fail "SukiSU drift resolver does not guard the allowlist reject"
grep -Fq 'SukiSU KPM symbol resolver is not linked into kernelsu.o.' "${SCRIPT_DIR}/../lib/verify.sh" \
  || fail "KPM source verification does not check symbol resolver linkage"
grep -Fq '"${KSU_DRIVER_DIR}/kernelsu/kernelsu.o"' "$COMPILE_SCRIPT" \
  || fail "KPM smoke compilation does not build the composite KernelSU object"
grep -Fq 'out/${KSU_DRIVER_DIR}/kernelsu/infra/symbol_resolver.o' "${SCRIPT_DIR}/../lib/verify.sh" \
  || fail "KPM binary verification does not inspect the compiled symbol resolver object"
grep -Fq 'local llvm_nm="${CLANG_ROOT:?}/llvm-nm"' "${SCRIPT_DIR}/../lib/verify.sh" \
  || fail "KPM binary verification does not use the active LTO-aware LLVM symbol tool"
grep -Fq 'toolchains/${CLANG_VERSION}/bin/llvm-nm' "$WORKFLOW_FILE" \
  || fail "workflow does not validate the KPM symbol inspection tool"
grep -Fq 'compiled symbol_resolver.o does not define find_kernel_symbol_exact' "${SCRIPT_DIR}/../lib/verify.sh" \
  || fail "KPM binary verification does not require a defined symbol resolver"
grep -Fq 'CONFIG_KPM CONFIG_KALLSYMS CONFIG_KALLSYMS_ALL' "${SCRIPT_DIR}/../lib/kernel-helpers.sh" \
  || fail "KPM preset is missing required config values"

resolve_clang_version "Recommended (auto-select based on branch)" "lineage-23.2"
assert_eq "clang-r563880c" "$CLANG_VERSION" "LineageOS 23.2 clang"
resolve_clang_version "Recommended (auto-select based on branch)" "main"
assert_eq "clang-r596125" "$CLANG_VERSION" "mainline clang"

resolve_susfs_settings sm8550 lineage-20.0
assert_eq "gki-android13-5.15" "$SUSFS_REF" "Android 13 susfs"
resolve_susfs_settings sm8550 lineage-23.2
assert_eq "gki-android14-5.15" "$SUSFS_REF" "Android 16 susfs"
resolve_susfs_settings sm7550 lineage-23.0
assert_eq "gki-android14-5.15" "$SUSFS_REF" "Nord CE4 susfs"
assert_eq "ed3d6d9c9a2652e1c70f153f5358701e996d646c" \
  "$(sukisu_compatible_susfs_commit gki-android13-5.10)" "SukiSU Android 13 5.10 SUSFS pin"
assert_eq "bca0d2333c1a7d717e7278b019d7af7ba1d16005" \
  "$(sukisu_compatible_susfs_commit gki-android13-5.15)" "SukiSU Android 13 5.15 SUSFS pin"
assert_eq "d54b51724afa912c4c99bb99731354ce934d1889" \
  "$(sukisu_compatible_susfs_commit gki-android14-5.15)" "SukiSU Android 14 5.15 SUSFS pin"
assert_eq "4fc9c1898ea66f51847cdbc0d1473ea4ef525a70" \
  "$(sukisu_compatible_susfs_commit gki-android14-6.1)" "SukiSU Android 14 6.1 SUSFS pin"
if sukisu_compatible_susfs_commit unsupported >/dev/null 2>&1; then
  fail "unknown SukiSU SUSFS branches must not silently fall back to HEAD"
fi
version_is_at_least 2.2.0 2.2.0 || fail "SUSFS minimum version equality"
version_is_at_least 2.3.0 2.2.0 || fail "SUSFS newer version acceptance"
if version_is_at_least 2.1.9 2.2.0; then
  fail "SUSFS old version rejection"
fi

infer_android_versions oneplus/sm8550_v_15.0.0_oneplus11
assert_eq "15" "$SUPPORTED_ANDROID_VERSIONS" "OnePlus Android 15 detection"
infer_android_versions sixteen-qpr2
assert_eq "16" "$SUPPORTED_ANDROID_VERSIONS" "Android 16 development detection"

ANYKERNEL_FIXTURE="$(mktemp)"
UPDATE_BINARY_FIXTURE="$(mktemp)"
KPM_CONFIG_FIXTURE="$(mktemp)"
KPM_VERIFY_FIXTURE="$(mktemp -d)"
NOMOUNT_FIXTURE_DIR="$(mktemp -d)"
EXTRACT_CERT_FIXTURE_DIR="$(mktemp -d)"
trap 'rm -f "$ANYKERNEL_FIXTURE" "$UPDATE_BINARY_FIXTURE" "$KPM_CONFIG_FIXTURE"; rm -rf "$KPM_VERIFY_FIXTURE" "$NOMOUNT_FIXTURE_DIR" "$EXTRACT_CERT_FIXTURE_DIR"' EXIT

cat > "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" <<'EOF'
#include <openssl/engine.h>
#ifdef USE_PKCS11_ENGINE
static const char *key_pass;
#endif
int main(void)
{
#ifndef OPENSSL_IS_BORINGSSL
#ifdef USE_PKCS11_ENGINE
	key_pass = getenv("KBUILD_SIGN_PIN");
#endif
	if (key_pass)
		ENGINE_ctrl_cmd_string(e, "PIN", key_pass, 0);
}
EOF
repair_extract_cert_key_pass_guard "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" >/dev/null
if grep -Fq '#ifdef USE_PKCS11_ENGINE' "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c"; then
  fail "extract-cert compatibility repair left the broken key_pass guards in place"
fi
assert_eq "1" "$(grep -Fc 'static const char *key_pass;' "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c")" \
  "extract-cert key_pass declaration"
assert_eq "1" "$(grep -Fc 'key_pass = getenv("KBUILD_SIGN_PIN");' "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c")" \
  "extract-cert key_pass assignment"
EXTRACT_CERT_REPAIRED_HASH="$(sha256sum "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" | cut -d' ' -f1)"
repair_extract_cert_key_pass_guard "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" >/dev/null
assert_eq "$EXTRACT_CERT_REPAIRED_HASH" \
  "$(sha256sum "$EXTRACT_CERT_FIXTURE_DIR/extract-cert.c" | cut -d' ' -f1)" \
  "extract-cert repair idempotence"

cat > "$EXTRACT_CERT_FIXTURE_DIR/provider-extract-cert.c" <<'EOF'
#define USE_PKCS11_PROVIDER
#ifndef OPENSSL_IS_BORINGSSL
#ifdef USE_PKCS11_ENGINE
static const char *key_pass;
#endif
#ifdef USE_PKCS11_ENGINE
	key_pass = getenv("KBUILD_SIGN_PIN");
#endif
ENGINE_ctrl_cmd_string(e, "PIN", key_pass, 0);
EOF
EXTRACT_CERT_PROVIDER_HASH="$(sha256sum "$EXTRACT_CERT_FIXTURE_DIR/provider-extract-cert.c" | cut -d' ' -f1)"
repair_extract_cert_key_pass_guard "$EXTRACT_CERT_FIXTURE_DIR/provider-extract-cert.c" >/dev/null
assert_eq "$EXTRACT_CERT_PROVIDER_HASH" \
  "$(sha256sum "$EXTRACT_CERT_FIXTURE_DIR/provider-extract-cert.c" | cut -d' ' -f1)" \
  "provider-aware extract-cert source preservation"

mkdir -p \
  "$KPM_VERIFY_FIXTURE/out/drivers/kernelsu/infra" \
  "$KPM_VERIFY_FIXTURE/toolchain"
: > "$KPM_VERIFY_FIXTURE/out/drivers/kernelsu/infra/symbol_resolver.o"
printf '%s\n' '0000000000001000 T sukisu_handle_kpm' > "$KPM_VERIFY_FIXTURE/out/System.map"
cat > "$KPM_VERIFY_FIXTURE/toolchain/llvm-nm" <<'EOF'
#!/usr/bin/env bash
[[ "${*: -1}" == */infra/symbol_resolver.o ]] || exit 1
printf '%s\n' '0000000000000000 T find_kernel_symbol_exact'
EOF
chmod +x "$KPM_VERIFY_FIXTURE/toolchain/llvm-nm"
(
  cd "$KPM_VERIFY_FIXTURE"
  export KSU_DRIVER_DIR=drivers
  export CLANG_ROOT="$KPM_VERIFY_FIXTURE/toolchain"
  export KERNEL_COMMIT=test-kernel
  export KSU_COMMIT=test-sukisu
  verify_kpm_binary_presence >/dev/null
  grep -Fq 'T find_kernel_symbol_exact' kpm-proof.txt \
    || fail "KPM proof does not record the leaf resolver definition"
)

KSU_TYPE="SukiSU-Ultra-with-susfs-nomount-KPM"
apply_variant_configs "$KPM_CONFIG_FIXTURE"
grep -q '^CONFIG_KPM=y$' "$KPM_CONFIG_FIXTURE" || fail "KPM config"
grep -q '^CONFIG_KALLSYMS=y$' "$KPM_CONFIG_FIXTURE" || fail "KPM kallsyms config"
grep -q '^CONFIG_KALLSYMS_ALL=y$' "$KPM_CONFIG_FIXTURE" || fail "KPM kallsyms-all config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$KPM_CONFIG_FIXTURE" || fail "combined preset SUSFS config"
grep -q '^CONFIG_KSU_SUSFS_SUS_MAP=y$' "$KPM_CONFIG_FIXTURE" || fail "combined preset SUSFS map config"
grep -q '^CONFIG_KSU_SUSFS_OPEN_REDIRECT=y$' "$KPM_CONFIG_FIXTURE" || fail "combined preset SUSFS redirect config"
grep -q '^CONFIG_KEYS=y$' "$KPM_CONFIG_FIXTURE" || fail "combined preset NoMount key config"
grep -q '^CONFIG_NOMOUNT=y$' "$KPM_CONFIG_FIXTURE" || fail "combined preset NoMount config"

printf '%s\n' \
  'kernel.string=placeholder' \
  'do.devicecheck=0' \
  'device.name1=' \
  'device.name2=' \
  'device.name3=' \
  'device.name4=' \
  'device.name5=' \
  'supported.versions=' > "$ANYKERNEL_FIXTURE"
chmod 755 "$ANYKERNEL_FIXTURE"
configure_anykernel_properties "$ANYKERNEL_FIXTURE" "Test Kernel" "salami OP591BL1 OP594DL1 aston OP5D35L1" "16"
assert_eq "755" "$(stat -c '%a' "$ANYKERNEL_FIXTURE")" "AnyKernel script permissions"
grep -q '^kernel.string=Test Kernel$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel string"
grep -q '^do.devicecheck=1$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel device check"
grep -q '^device.name1=salami$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel salami mapping"
grep -q '^device.name2=OP591BL1$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel stock ID mapping"
grep -q '^device.name4=aston$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel aston mapping"
grep -q '^device.name5=OP5D35L1$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel 12R stock ID mapping"
grep -q '^supported.versions=16$' "$ANYKERNEL_FIXTURE" || fail "AnyKernel Android mapping"

for i in "${!profiles[@]}"; do
  resolve_build_profile "${profiles[$i]}"
  configure_anykernel_properties \
    "$ANYKERNEL_FIXTURE" \
    "${PROFILE_ID} test kernel" \
    "$DEVICE_NAMES" \
    "16"
  for device_name in $DEVICE_NAMES; do
    grep -q "^device.name[1-5]=${device_name}$" "$ANYKERNEL_FIXTURE" \
      || fail "${profiles[$i]} did not inject device ID: $device_name"
  done
done

printf '%s\n' \
  '  if [ ! "$match" ]; then' \
  '    abort " " "Unsupported device. Aborting...";' \
  '  fi;' > "$UPDATE_BINARY_FIXTURE"
chmod 755 "$UPDATE_BINARY_FIXTURE"
add_anykernel_devicecheck_diagnostics "$UPDATE_BINARY_FIXTURE"
assert_eq "755" "$(stat -c '%a' "$UPDATE_BINARY_FIXTURE")" "update-binary permissions"
grep -Fq 'ro.product.device=$device' "$UPDATE_BINARY_FIXTURE" \
  || fail "AnyKernel device diagnostics"

printf '%s\n' 'menu "one"' endmenu 'menu "two"' endmenu > "$NOMOUNT_FIXTURE_DIR/Kconfig"
insert_line_before_last_match \
  "$NOMOUNT_FIXTURE_DIR/Kconfig" \
  endmenu \
  'source "fs/nomount/Kconfig"'
assert_eq "4" "$(grep -nF 'source "fs/nomount/Kconfig"' "$NOMOUNT_FIXTURE_DIR/Kconfig" | cut -d: -f1)" \
  "NoMount Kconfig insertion"

echo "PASS: profiles, source compatibility, KPM, SUSFS floor, NoMount integration, and AnyKernel protection"
