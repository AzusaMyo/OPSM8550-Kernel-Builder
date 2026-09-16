#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/profile-data.sh
. "${SCRIPT_DIR}/../lib/profile-data.sh"
# shellcheck source=../lib/anykernel-helpers.sh
. "${SCRIPT_DIR}/../lib/anykernel-helpers.sh"
# shellcheck source=../lib/nomount-setup.sh
. "${SCRIPT_DIR}/../lib/nomount-setup.sh"
# shellcheck source=../lib/zeromount-setup.sh
. "${SCRIPT_DIR}/../lib/zeromount-setup.sh"
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
ANYKERNEL_PACKAGE_SCRIPT="${SCRIPT_DIR}/../make-anykernel-zip.sh"
ANYKERNEL_TEMPLATE="${SCRIPT_DIR}/../templates/anykernel.sh"
RESOLVER_SCRIPT="${SCRIPT_DIR}/../resolve-profile.sh"
KSU_SETUP_SCRIPT="${SCRIPT_DIR}/../lib/ksu-setup.sh"
GIT_HELPERS_SCRIPT="${SCRIPT_DIR}/../lib/git-helpers.sh"
SUSFS_APPLY_SCRIPT="${SCRIPT_DIR}/../lib/susfs-apply.sh"
ZEROMOUNT_SETUP_SCRIPT="${SCRIPT_DIR}/../lib/zeromount-setup.sh"
SUKISU_SUSFS_COMPAT_PATCH="${SCRIPT_DIR}/../patches/sukisu-susfs-core-init-compat.patch"
SUKISU_SUSFS_POLICY_COMPAT_PATCH="${SCRIPT_DIR}/../patches/sukisu-susfs-policy-compat.patch"
sh -n "$ANYKERNEL_TEMPLATE" || fail "AnyKernel device template has invalid shell syntax"
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
grep -Fq 'local max_attempts=5' "$GIT_HELPERS_SCRIPT" \
  || fail "git network helpers must tolerate a longer transient outage"
grep -Fq 'GIT_TERMINAL_PROMPT=0 git ls-remote' "$GIT_HELPERS_SCRIPT" \
  || fail "git ref lookup must not wait for credentials in CI"
grep -Fq 'GIT_TERMINAL_PROMPT=0 git -C "$repo_dir" fetch' "$GIT_HELPERS_SCRIPT" \
  || fail "git fetch must not wait for credentials in CI"
grep -Fq 'ANYKERNEL_REPO="https://github.com/osm0sis/AnyKernel3.git"' "$RESOLVER_SCRIPT" \
  || fail "resolver must use the canonical live AnyKernel3 repository"
grep -Fq 'ANYKERNEL_COMMIT="020dfeccf9d7e962a48400fc94d3e451df92eead"' "$RESOLVER_SCRIPT" \
  || fail "resolver must pin the tested AnyKernel3 revision"
grep -Fq 'sanitize_cached_anykernel_checkout AnyKernel3' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must sanitize a restored checkout"
grep -Fq 'install_anykernel_template "$ANYKERNEL_TEMPLATE" "$ANYKERNEL_SCRIPT"' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must install the device-specific flash template"
grep -Fq 'git checkout -q --force --detach FETCH_HEAD' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must force the pinned detached checkout"
if grep -Fq 'Kernel-SU/AnyKernel3.git' "$RESOLVER_SCRIPT"; then
  fail "resolver still references the removed Kernel-SU AnyKernel3 fork"
fi
grep -Fq 'profile: SM8650 | OnePlus 12 | crDroid' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health must exercise the crDroid SM8650 certificate compatibility path"
grep -Fq 'integration: SukiSU Ultra + SUSFS + NoMount + KPM (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health must exercise the featured KPM integration"
awk '
  /integration: SukiSU Ultra \+ SUSFS \+ NoMount \+ KPM \(experimental\)/ { kpm = 1; next }
  kpm && /profile: SM8650 \| OnePlus 12 \| crDroid/ { found = 1; exit }
  kpm && /integration:/ { kpm = 0 }
  END { exit !found }
' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health must exercise KPM on the crDroid OnePlus 12 source"

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
resolve_root_solution "KernelSU-Next + SUSFS + ZeroMount (experimental)"
assert_eq "KernelSU-Next-with-susfs-zeromount" "$KSU_TYPE" "KernelSU-Next ZeroMount root mapping"
resolve_root_solution "ReSukiSU + SUSFS + NoMount (experimental)"
assert_eq "ReSukiSU-with-susfs-nomount" "$KSU_TYPE" "NoMount root mapping"
resolve_root_solution "SukiSU Ultra + KPM (experimental)"
assert_eq "SukiSU-Ultra-with-KPM" "$KSU_TYPE" "KPM root mapping"
resolve_root_solution "SukiSU Ultra + SUSFS + KPM (experimental)"
assert_eq "SukiSU-Ultra-with-susfs-KPM" "$KSU_TYPE" "SukiSU SUSFS/KPM root mapping"
resolve_root_solution "SukiSU Ultra + SUSFS + NoMount + KPM (experimental)"
assert_eq "SukiSU-Ultra-with-susfs-nomount-KPM" "$KSU_TYPE" "SukiSU SUSFS/NoMount/KPM root mapping"
resolve_root_solution "SukiSU Ultra + SUSFS + ZeroMount + KPM (experimental)"
assert_eq "SukiSU-Ultra-with-susfs-zeromount-KPM" "$KSU_TYPE" "SukiSU SUSFS/ZeroMount/KPM root mapping"
resolve_root_solution "ReSukiSU + SUSFS + ZeroMount (experimental)"
assert_eq "ReSukiSU-with-susfs-zeromount" "$KSU_TYPE" "ReSukiSU ZeroMount root mapping"
grep -Fq -- '- ReSukiSU + SUSFS + NoMount (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the NoMount root option"
grep -Fq -- '- KernelSU-Next + SUSFS' "$WORKFLOW_FILE" \
  || fail "workflow is missing the KernelSU-Next SUSFS root option"
grep -Fq -- '- Build all 3 featured SUSFS variants (batch)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the three-variant batch root option"
grep -Fq -- '- Build all 3 ZeroMount variants (batch)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the three-variant ZeroMount batch option"
grep -Fq 'name: Build ${{ matrix.root_solution }}' "$WORKFLOW_FILE" \
  || fail "workflow build job does not use the root-solution matrix"
grep -Fq '"SukiSU Ultra + SUSFS + NoMount + KPM (experimental)","ReSukiSU + SUSFS + NoMount (experimental)","KernelSU-Next + SUSFS"' "$WORKFLOW_FILE" \
  || fail "workflow original batch matrix changed unexpectedly"
grep -Fq '"SukiSU Ultra + SUSFS + ZeroMount + KPM (experimental)","ReSukiSU + SUSFS + ZeroMount (experimental)","KernelSU-Next + SUSFS + ZeroMount (experimental)"' "$WORKFLOW_FILE" \
  || fail "workflow batch matrix does not contain the three ZeroMount variants"
grep -Fq 'ARTIFACT_NAME="kernel-package-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${KSU_TYPE}"' "$WORKFLOW_FILE" \
  || fail "workflow package artifact names must be unique across the batch matrix"
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
grep -Fq -- '- integration: KernelSU-Next + SUSFS + ZeroMount (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing KernelSU-Next ZeroMount"
grep -Fq -- '- integration: ReSukiSU + SUSFS + ZeroMount (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing ReSukiSU ZeroMount"
grep -Fq -- '- SukiSU Ultra + SUSFS + ZeroMount + KPM (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing SukiSU ZeroMount"
grep -Fq 'SukiSU-Ultra-with-KPM|SukiSU-Ultra-with-susfs-KPM|SukiSU-Ultra-with-susfs-nomount-KPM|SukiSU-Ultra-with-susfs-zeromount-KPM)' "$RESOLVER_SCRIPT" \
  || fail "resolver does not route all SukiSU presets to SukiSU Ultra"
grep -Fq 'SUSFS_COMMIT="$(sukisu_compatible_susfs_commit "$SUSFS_REF")"' "$RESOLVER_SCRIPT" \
  || fail "resolver does not use the SukiSU-compatible SUSFS commit map"
grep -Fq '"SukiSU-Ultra-with-KPM"|"SukiSU-Ultra-with-susfs-KPM"|"SukiSU-Ultra-with-susfs-nomount-KPM"|"SukiSU-Ultra-with-susfs-zeromount-KPM")' "$KSU_SETUP_SCRIPT" \
  || fail "KernelSU setup does not install SukiSU Ultra for all combined presets"
grep -Fq 'ZEROMOUNT_COMMIT="2978dcad87dc7055e2e4596c603313c553a9a4b4"' "$RESOLVER_SCRIPT" \
  || fail "ZeroMount patch source is not pinned to the tested commit"
for zeromount_tag in android13-5.10 android13-5.15 android14-5.15 android14-6.1; do
  [[ "$(zeromount_patch_sha256 "$zeromount_tag")" =~ ^[0-9a-f]{64}$ ]] \
    || fail "ZeroMount checksum mapping is missing for $zeromount_tag"
done
grep -Fq 'patch --dry-run --batch --forward --fuzz=3 -p1' "$ZEROMOUNT_SETUP_SCRIPT" \
  || fail "ZeroMount integration must validate the whole patch before applying it"
grep -Fq 'resolve_known_sukisu_susfs_rejects' "$SUSFS_APPLY_SCRIPT" \
  || fail "SUSFS integration is missing the guarded SukiSU drift resolver"
KSU_TYPE="SukiSU-Ultra-with-susfs-KPM"
is_sukisu_susfs_variant || fail "SukiSU SUSFS/KPM preset must allow guarded SUSFS drift repair"
KSU_TYPE="SukiSU-Ultra-with-susfs-nomount-KPM"
is_sukisu_susfs_variant || fail "SukiSU SUSFS/NoMount/KPM preset must allow guarded SUSFS drift repair"
KSU_TYPE="SukiSU-Ultra-with-susfs-zeromount-KPM"
is_sukisu_susfs_variant || fail "SukiSU SUSFS/ZeroMount/KPM preset must allow guarded SUSFS drift repair"
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
grep -Fq -- '-    ksu_late_loaded = (current->pid != 1);' "$SUKISU_SUSFS_COMPAT_PATCH" \
  || fail "SukiSU SUSFS/KPM compatibility patch does not remove stale late-load initialization"
grep -Fq -- '-bool ksu_bundled = false;' "$SUKISU_SUSFS_COMPAT_PATCH" \
  || fail "SukiSU SUSFS/KPM compatibility patch does not remove stale bundled state"
grep -Fq "ksu_(late_loaded|bundled)" "$SUSFS_APPLY_SCRIPT" \
  || fail "SukiSU SUSFS drift resolver does not reject stale late-load state"
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
assert_eq "2c774fdb4f0aaa743598c1bec787f6c935574ed1" \
  "$(sukisu_compatible_susfs_commit gki-android13-5.10)" "SukiSU Android 13 5.10 SUSFS pin"
assert_eq "7af04b08f86a5f811cbea28805f96d52368e005f" \
  "$(sukisu_compatible_susfs_commit gki-android13-5.15)" "SukiSU Android 13 5.15 SUSFS pin"
assert_eq "aab99ba7693d94489fd32f1cc4c9d58396fffeee" \
  "$(sukisu_compatible_susfs_commit gki-android14-5.15)" "SukiSU Android 14 5.15 SUSFS pin"
assert_eq "6c2b5042ec656cd3ce9ad352a1e226e2e9e26779" \
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
ZEROMOUNT_CONFIG_FIXTURE="$(mktemp)"
ZEROMOUNT_FIXTURE_DIR="$(mktemp -d)"
MODULE_CONFIG_FIXTURE="$(mktemp)"
SPINLOCK_KCONFIG_FIXTURE="$(mktemp)"
KPM_VERIFY_FIXTURE="$(mktemp -d)"
NOMOUNT_FIXTURE_DIR="$(mktemp -d)"
EXTRACT_CERT_FIXTURE_DIR="$(mktemp -d)"
ANYKERNEL_CACHE_FIXTURE_DIR="$(mktemp -d)"
ANYKERNEL_PACKAGE_FIXTURE_DIR="$(mktemp -d)"
SUSFS_VENDOR_FIXTURE_DIR="$(mktemp -d)"
trap 'rm -f "$ANYKERNEL_FIXTURE" "$UPDATE_BINARY_FIXTURE" "$KPM_CONFIG_FIXTURE" "$ZEROMOUNT_CONFIG_FIXTURE" "$MODULE_CONFIG_FIXTURE" "$SPINLOCK_KCONFIG_FIXTURE"; rm -rf "$KPM_VERIFY_FIXTURE" "$NOMOUNT_FIXTURE_DIR" "$ZEROMOUNT_FIXTURE_DIR" "$EXTRACT_CERT_FIXTURE_DIR" "$ANYKERNEL_CACHE_FIXTURE_DIR" "$ANYKERNEL_PACKAGE_FIXTURE_DIR" "$SUSFS_VENDOR_FIXTURE_DIR"' EXIT

mkdir -p "$ZEROMOUNT_FIXTURE_DIR/fs"
cat > "$ZEROMOUNT_FIXTURE_DIR/fs/stat.c" <<'EOF'
static int vfs_statx(int dfd, const char __user *filename, int flags,
		     struct kstat *stat, u32 request_mask)
{
	int error;
#ifdef CONFIG_KSU_SUSFS
#ifdef CONFIG_ZEROMOUNT
	if (filename)
		return zeromount_stat_hook(dfd, filename, stat, request_mask, flags);
#endif

	struct filename *fname = NULL;
#endif
	return error;
}
EOF
repair_zeromount_stat_declaration "$ZEROMOUNT_FIXTURE_DIR/fs/stat.c" >/dev/null
ZEROMOUNT_DECLARATION_LINE="$(grep -nF $'\tstruct filename *fname = NULL;' "$ZEROMOUNT_FIXTURE_DIR/fs/stat.c" | cut -d: -f1)"
ZEROMOUNT_HOOK_LINE="$(sed -n '/^static int vfs_statx(/,$p' "$ZEROMOUNT_FIXTURE_DIR/fs/stat.c" | grep -n -m1 '^#ifdef CONFIG_ZEROMOUNT$' | cut -d: -f1)"
(( ZEROMOUNT_DECLARATION_LINE < ZEROMOUNT_HOOK_LINE )) \
  || fail "ZeroMount compatibility repair did not move the declaration before executable code"
ZEROMOUNT_REPAIRED_HASH="$(sha256sum "$ZEROMOUNT_FIXTURE_DIR/fs/stat.c" | cut -d' ' -f1)"
repair_zeromount_stat_declaration "$ZEROMOUNT_FIXTURE_DIR/fs/stat.c" >/dev/null
assert_eq \
  "$ZEROMOUNT_REPAIRED_HASH" \
  "$(sha256sum "$ZEROMOUNT_FIXTURE_DIR/fs/stat.c" | cut -d' ' -f1)" \
  "ZeroMount declaration repair idempotence"
cat > "$ZEROMOUNT_FIXTURE_DIR/fs/stat-6.1.c" <<'EOF'
static int vfs_statx(int dfd, struct filename *filename, int flags,
		     struct kstat *stat, u32 request_mask)
{
	int error;
#ifdef CONFIG_ZEROMOUNT
	if (filename)
		return zeromount_stat_hook(dfd, filename, stat, request_mask, flags);
#endif
	return error;
}
EOF
ZEROMOUNT_61_HASH="$(sha256sum "$ZEROMOUNT_FIXTURE_DIR/fs/stat-6.1.c" | cut -d' ' -f1)"
repair_zeromount_stat_declaration "$ZEROMOUNT_FIXTURE_DIR/fs/stat-6.1.c" >/dev/null
assert_eq \
  "$ZEROMOUNT_61_HASH" \
  "$(sha256sum "$ZEROMOUNT_FIXTURE_DIR/fs/stat-6.1.c" | cut -d' ' -f1)" \
  "ZeroMount 6.1 declaration-free compatibility"

mkdir -p "$SUSFS_VENDOR_FIXTURE_DIR/fs"
cat > "$SUSFS_VENDOR_FIXTURE_DIR/fs/namespace.c" <<'EOF'
#include <linux/mnt_idmapping.h>

#include "pnode.h"
#include "internal.h"

/* Maximum number of mounts in a mount namespace */
EOF
cat > "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c" <<'EOF'
#include <linux/fs_context.h>
#include <uapi/linux/mount.h>
#include "internal.h"

static int thaw_super_locked(struct super_block *sb);
EOF
cat > "$SUSFS_VENDOR_FIXTURE_DIR/fs/namespace.c.rej" <<'EOF'
+#include <linux/susfs_def.h>
+extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;
EOF
cat > "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c.rej" <<'EOF'
+#include <linux/susfs_def.h>
+extern bool susfs_is_current_ksu_domain(void);
EOF
(
  cd "$SUSFS_VENDOR_FIXTURE_DIR"
  resolve_known_susfs_rejects >/dev/null
)
test ! -e "$SUSFS_VENDOR_FIXTURE_DIR/fs/namespace.c.rej" \
  || fail "SM8650 SUSFS recovery left the namespace reject in place"
test ! -e "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c.rej" \
  || fail "SM8650 SUSFS recovery left the superblock reject in place"
grep -Fq '#include <linux/susfs_def.h>' "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c" \
  || fail "SM8650 SUSFS recovery did not add the superblock header"
grep -Fq 'extern bool susfs_is_current_ksu_domain(void);' "$SUSFS_VENDOR_FIXTURE_DIR/fs/super.c" \
  || fail "SM8650 SUSFS recovery did not add the superblock domain declaration"

ANYKERNEL_TEMPLATE_FIXTURE="$(mktemp)"
printf '%s\n' placeholder > "$ANYKERNEL_TEMPLATE_FIXTURE"
chmod 755 "$ANYKERNEL_TEMPLATE_FIXTURE"
install_anykernel_template "$ANYKERNEL_TEMPLATE" "$ANYKERNEL_TEMPLATE_FIXTURE"
grep -Fxq 'BLOCK=boot;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not target boot by partition name"
grep -Fxq 'IS_SLOT_DEVICE=1;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not enable A/B slot detection"
if grep -Eq 'omap_hsmmc|maguro|toro|tuna' "$ANYKERNEL_TEMPLATE_FIXTURE"; then
  fail "AnyKernel device template retained an upstream example-device setting"
fi
rm -f "$ANYKERNEL_TEMPLATE_FIXTURE"

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
printf '%s\n' \
  'CONFIG_MODULES=y' \
  'CONFIG_MODULE_UNLOAD=y' \
  'CONFIG_MODVERSIONS=y' \
  'CONFIG_MODULE_FORCE_LOAD=y' \
  'CONFIG_KASAN=y' \
  'CONFIG_KASAN_HW_TAGS=y' \
  '# CONFIG_TRIM_UNUSED_KSYMS is not set' \
  > "$KPM_VERIFY_FIXTURE/out/.config"
cat > "$KPM_VERIFY_FIXTURE/toolchain/llvm-nm" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  */infra/symbol_resolver.o)
    printf '%s\n' '0000000000000000 T find_kernel_symbol_exact'
    ;;
  out/vmlinux)
    printf '%s\n' \
      '0000000000001000 r __ksymtab__raw_spin_lock' \
      '0000000000001004 r __ksymtab__raw_spin_unlock' \
      '0000000000001008 r __ksymtab_kasan_flag_enabled'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$KPM_VERIFY_FIXTURE/toolchain/llvm-nm"
(
  cd "$KPM_VERIFY_FIXTURE"
  export KSU_DRIVER_DIR=drivers
  export CLANG_ROOT="$KPM_VERIFY_FIXTURE/toolchain"
  export KERNEL_BRANCH=test-branch
  export KERNEL_COMMIT=test-kernel
  export KSU_COMMIT=test-sukisu
  verify_kpm_binary_presence >/dev/null
  grep -Fq 'T find_kernel_symbol_exact' kpm-proof.txt \
    || fail "KPM proof does not record the leaf resolver definition"
  printf '%s\n' \
    '0x11111111 module_layout vmlinux EXPORT_SYMBOL' \
    '0x22222222 _raw_spin_lock vmlinux EXPORT_SYMBOL' \
    '0x33333333 _raw_spin_unlock vmlinux EXPORT_SYMBOL' \
    '0x44444444 kasan_flag_enabled vmlinux EXPORT_SYMBOL' \
    > out/vmlinux.symvers
  verify_external_module_exports >/dev/null
  grep -Fq 'kasan_flag_enabled' external-module-proof.txt \
    || fail "external module proof does not record the required exports"
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

KSU_TYPE="SukiSU-Ultra-with-susfs-zeromount-KPM"
apply_variant_configs "$ZEROMOUNT_CONFIG_FIXTURE"
grep -q '^CONFIG_ZEROMOUNT=y$' "$ZEROMOUNT_CONFIG_FIXTURE" || fail "combined preset ZeroMount config"
grep -q '^CONFIG_KSU_SUSFS=y$' "$ZEROMOUNT_CONFIG_FIXTURE" || fail "ZeroMount preset SUSFS config"
grep -q '^CONFIG_KPM=y$' "$ZEROMOUNT_CONFIG_FIXTURE" || fail "ZeroMount preset KPM config"
if grep -q '^CONFIG_NOMOUNT=y$' "$ZEROMOUNT_CONFIG_FIXTURE"; then
  fail "ZeroMount preset must not enable NoMount"
fi

cat > "$MODULE_CONFIG_FIXTURE" <<'EOF'
CONFIG_MODULES=y
# CONFIG_MODULE_UNLOAD is not set
# CONFIG_MODVERSIONS is not set
# CONFIG_MODULE_FORCE_LOAD is not set
CONFIG_ARCH_INLINE_SPIN_LOCK=y
CONFIG_ARCH_INLINE_SPIN_UNLOCK=y
CONFIG_INLINE_SPIN_LOCK=y
# CONFIG_UNINLINE_SPIN_UNLOCK is not set
CONFIG_TRIM_UNUSED_KSYMS=y
# CONFIG_KASAN is not set
CONFIG_KASAN_GENERIC=y
CONFIG_KASAN_SW_TAGS=y
# CONFIG_KASAN_HW_TAGS is not set
EOF
KSU_TYPE="None"
apply_variant_configs "$MODULE_CONFIG_FIXTURE"
for module_config in \
  CONFIG_MODULES \
  CONFIG_MODULE_UNLOAD \
  CONFIG_MODVERSIONS \
  CONFIG_MODULE_FORCE_LOAD \
  CONFIG_UNINLINE_SPIN_UNLOCK \
  CONFIG_KASAN \
  CONFIG_KASAN_HW_TAGS; do
  grep -q "^${module_config}=y$" "$MODULE_CONFIG_FIXTURE" \
    || fail "external module compatibility config ${module_config}"
done
grep -q '^# CONFIG_TRIM_UNUSED_KSYMS is not set$' "$MODULE_CONFIG_FIXTURE" \
  || fail "external module exports must not be trimmed"
for inline_config in \
  CONFIG_ARCH_INLINE_SPIN_LOCK \
  CONFIG_ARCH_INLINE_SPIN_UNLOCK \
  CONFIG_INLINE_SPIN_LOCK; do
  grep -q "^# ${inline_config} is not set$" "$MODULE_CONFIG_FIXTURE" \
    || fail "external module compatibility must disable ${inline_config}"
done
grep -q '^# CONFIG_KASAN_GENERIC is not set$' "$MODULE_CONFIG_FIXTURE" \
  || fail "generic KASAN must not override hardware-tag KASAN"
grep -q '^# CONFIG_KASAN_SW_TAGS is not set$' "$MODULE_CONFIG_FIXTURE" \
  || fail "software-tag KASAN must not override hardware-tag KASAN"
grep -Fq 'verify_external_module_exports' "$COMPILE_SCRIPT" \
  || fail "full builds do not verify external module exports"
grep -Fq 'enable_external_module_spinlock_exports arch/arm64/Kconfig' "$COMPILE_SCRIPT" \
  || fail "builds do not make the raw spin functions exportable"

cat > "$SPINLOCK_KCONFIG_FIXTURE" <<'EOF'
config ARM64
	bool "ARM64"
	select ARCH_INLINE_SPIN_LOCK
	select ARCH_INLINE_SPIN_LOCK_BH
	select ARCH_INLINE_SPIN_UNLOCK
	select ARCH_INLINE_SPIN_UNLOCK_BH
EOF
enable_external_module_spinlock_exports "$SPINLOCK_KCONFIG_FIXTURE" >/dev/null
enable_external_module_spinlock_exports "$SPINLOCK_KCONFIG_FIXTURE" >/dev/null
grep -Fq 'select ARCH_INLINE_SPIN_LOCK_BH' "$SPINLOCK_KCONFIG_FIXTURE" \
  || fail "spinlock compatibility patch must preserve the BH inline selection"
grep -Fq 'select ARCH_INLINE_SPIN_UNLOCK_BH' "$SPINLOCK_KCONFIG_FIXTURE" \
  || fail "spinlock compatibility patch must preserve the unlock-BH inline selection"
grep -Eq '^[[:space:]]*select UNINLINE_SPIN_UNLOCK[[:space:]]*$' "$SPINLOCK_KCONFIG_FIXTURE" \
  || fail "spinlock compatibility patch must select the out-of-line unlock"
if grep -Eq '^[[:space:]]*select ARCH_INLINE_SPIN_(LOCK|UNLOCK)[[:space:]]*$' "$SPINLOCK_KCONFIG_FIXTURE"; then
  fail "spinlock compatibility patch did not disable the plain inline selections"
fi

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

git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" init -q
git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" config user.name fixture
git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" config user.email fixture@example.invalid
printf '%s\n' 'kernel.string=upstream' > "$ANYKERNEL_CACHE_FIXTURE_DIR/anykernel.sh"
git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" add anykernel.sh
git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" commit -qm fixture
printf '%s\n' 'kernel.string=modified-by-prior-matrix-job' > "$ANYKERNEL_CACHE_FIXTURE_DIR/anykernel.sh"
printf '%s\n' stale > "$ANYKERNEL_CACHE_FIXTURE_DIR/Image"
sanitize_cached_anykernel_checkout "$ANYKERNEL_CACHE_FIXTURE_DIR"
grep -q '^kernel.string=upstream$' "$ANYKERNEL_CACHE_FIXTURE_DIR/anykernel.sh" \
  || fail "cached AnyKernel sanitation did not restore tracked files"
test ! -e "$ANYKERNEL_CACHE_FIXTURE_DIR/Image" \
  || fail "cached AnyKernel sanitation did not remove generated files"
test -z "$(git -C "$ANYKERNEL_CACHE_FIXTURE_DIR" status --porcelain)" \
  || fail "cached AnyKernel sanitation left a dirty checkout"

mkdir -p \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/META-INF/com/google/android" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8550/out/arch/arm64/boot" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin"
printf '%s\n' \
  'kernel.string=placeholder' \
  'do.devicecheck=0' \
  'device.name1=' \
  'device.name2=' \
  'device.name3=' \
  'device.name4=' \
  'device.name5=' \
  'supported.versions=' \
  > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/anykernel.sh"
printf '%s\n' \
  '  if [ ! "$match" ]; then' \
  '    abort " " "Unsupported device. Aborting...";' \
  '  fi;' \
  > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/META-INF/com/google/android/update-binary"
chmod 755 \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/anykernel.sh" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/META-INF/com/google/android/update-binary"
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" init -q
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" config user.name fixture
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" config user.email fixture@example.invalid
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" add .
git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" commit -qm fixture
ANYKERNEL_PACKAGE_COMMIT="$(git -C "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" rev-parse HEAD)"
git clone -q "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3"
printf '%s\n' 'kernel.string=dirty-cache' > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh"
printf '%s\n' stale > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/Image"
printf '%s\n' image > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8550/out/arch/arm64/boot/Image"
cat > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{}'
EOF
cat > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/zip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' zip-fixture > "$2"
EOF
chmod +x "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/jq" "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/zip"

for package_timestamp in 20260101_000000 20260101_000001; do
  (
    cd "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work"
    PATH="$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin:$PATH" \
    SOC=sm8550 \
    PROFILE_ID=test-profile \
    TARGET_NAME='Test target' \
    DEVICE_CODENAMES='salami aston' \
    DEVICE_NAMES='salami aston' \
    SUPPORTED_ANDROID_VERSIONS=16 \
    SOURCE_NAME=test \
    KERNEL_BRANCH=test \
    MODULES_BRANCH=test \
    KERNEL_COMMIT=1111111111111111111111111111111111111111 \
    MODULES_COMMIT=2222222222222222222222222222222222222222 \
    CLANG_VERSION=test-clang \
    KSU_TYPE=KernelSU-Next-with-susfs \
    KSU_COMMIT=3333333333333333333333333333333333333333 \
    SUSFS_REF=test \
    SUSFS_COMMIT=4444444444444444444444444444444444444444 \
    SUSFS_VERSION=2.3.0 \
    BUILD_TIMESTAMP="$package_timestamp" \
    GITHUB_WORKSPACE="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work" \
    GITHUB_ENV="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/github-env" \
    GITHUB_OUTPUT="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/github-output" \
    ANYKERNEL_REPO="$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" \
    ANYKERNEL_COMMIT="$ANYKERNEL_PACKAGE_COMMIT" \
    bash "$ANYKERNEL_PACKAGE_SCRIPT" >/dev/null
  )
  test -s "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/release-assets/test-profile_KernelSU-Next-with-susfs_111111111111_${package_timestamp}.zip" \
    || fail "AnyKernel packaging did not produce the flashable archive"
  test -s "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/release-assets/SHA256SUMS" \
    || fail "AnyKernel packaging did not produce checksums"
done

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

echo "PASS: profiles, source compatibility, KPM, SUSFS floor, NoMount/ZeroMount integration, and AnyKernel protection"
