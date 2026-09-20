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
grep -Fq 'patch_anykernel_app_flash_staging "$ANYKERNEL_UPDATE_BINARY"' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must move app-triggered flashes out of app-private data"
grep -Fq 'install_anykernel_arm64_busybox "$KSU_ARM64_BUSYBOX" "AnyKernel3/tools/busybox"' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "KPM packaging must replace AnyKernel's legacy ARM BusyBox"
grep -Fq 'install_anykernel_arm64_magiskboot \' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "KPM packaging must replace AnyKernel's legacy ARM MagiskBoot"
grep -Fq 'prepare_anykernel_arm64_toolset "AnyKernel3/tools"' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "KPM packaging must reject remaining non-AArch64 runtime tools"
grep -Fq 'add_anykernel_preflight_diagnostics \' "$ANYKERNEL_PACKAGE_SCRIPT" \
  || fail "AnyKernel packaging must report the device and BusyBox ABIs"
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
resolve_root_solution "KernelSU-Next + SUSFS + NoMount (experimental)"
assert_eq "KernelSU-Next-with-susfs-nomount" "$KSU_TYPE" "KernelSU-Next NoMount root mapping"
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
grep -Fq -- '- KernelSU-Next + SUSFS + NoMount (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the KernelSU-Next NoMount root option"
grep -Fq -- '- Build all 3 featured SUSFS variants (batch)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the three-variant batch root option"
grep -Fq -- '- Build all 3 ZeroMount variants (batch)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the three-variant ZeroMount batch option"
grep -Fq 'name: Build ${{ matrix.root_solution }}' "$WORKFLOW_FILE" \
  || fail "workflow build job does not use the root-solution matrix"
grep -Fq '"SukiSU Ultra + SUSFS + NoMount + KPM (experimental)","ReSukiSU + SUSFS + NoMount (experimental)","KernelSU-Next + SUSFS + NoMount (experimental)"' "$WORKFLOW_FILE" \
  || fail "workflow featured SUSFS batch matrix does not contain all three NoMount variants"
grep -Fq '"SukiSU Ultra + SUSFS + ZeroMount + KPM (experimental)","ReSukiSU + SUSFS + ZeroMount (experimental)","KernelSU-Next + SUSFS + ZeroMount (experimental)"' "$WORKFLOW_FILE" \
  || fail "workflow batch matrix does not contain the three ZeroMount variants"
grep -Fq 'ARTIFACT_NAME="kernel-package-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${KSU_TYPE}"' "$WORKFLOW_FILE" \
  || fail "workflow package artifact names must be unique across the batch matrix"
grep -Fq 'KSU_REPO="https://github.com/pershoot/KernelSU-Next.git"' "$RESOLVER_SCRIPT" \
  || fail "KernelSU-Next SUSFS must resolve the compatible dev-susfs fork"
grep -Fq 'KSU_REF="dev-susfs"' "$RESOLVER_SCRIPT" \
  || fail "KernelSU-Next SUSFS must resolve the dev-susfs branch"
grep -Fq 'KernelSU-Next-with-susfs|KernelSU-Next-with-susfs-nomount|KernelSU-Next-with-susfs-zeromount)' "$RESOLVER_SCRIPT" \
  || fail "resolver does not route the KernelSU-Next NoMount preset to the SUSFS-compatible fork"
grep -Fq '"KernelSU-Next-with-susfs"|"KernelSU-Next-with-susfs-nomount"|"KernelSU-Next-with-susfs-zeromount")' "$KSU_SETUP_SCRIPT" \
  || fail "KernelSU setup does not install the SUSFS-compatible fork for the NoMount preset"
grep -Fq -- '- SukiSU Ultra + KPM (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the KPM root option"
grep -Fq -- '- SukiSU Ultra + SUSFS + KPM (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the combined SukiSU SUSFS/KPM root option"
grep -Fq -- '- SukiSU Ultra + SUSFS + NoMount + KPM (experimental)' "$WORKFLOW_FILE" \
  || fail "workflow is missing the combined SukiSU SUSFS/NoMount/KPM root option"
grep -Fq -- '- SukiSU Ultra + SUSFS + NoMount + KPM (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing the combined SukiSU SUSFS/NoMount/KPM preset"
grep -Fq -- '- KernelSU-Next + SUSFS + NoMount (experimental)' "$UPSTREAM_HEALTH_WORKFLOW" \
  || fail "upstream health is missing KernelSU-Next NoMount"
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
APP_STAGING_FIXTURE="$(mktemp)"
KPM_CONFIG_FIXTURE="$(mktemp)"
KSUN_NOMOUNT_CONFIG_FIXTURE="$(mktemp)"
ZEROMOUNT_CONFIG_FIXTURE="$(mktemp)"
ZEROMOUNT_FIXTURE_DIR="$(mktemp -d)"
MODULE_CONFIG_FIXTURE="$(mktemp)"
SCMVERSION_FIXTURE="$(mktemp)"
KPM_VERIFY_FIXTURE="$(mktemp -d)"
NOMOUNT_FIXTURE_DIR="$(mktemp -d)"
EXTRACT_CERT_FIXTURE_DIR="$(mktemp -d)"
ANYKERNEL_CACHE_FIXTURE_DIR="$(mktemp -d)"
ANYKERNEL_PACKAGE_FIXTURE_DIR="$(mktemp -d)"
ANYKERNEL_SLOT_FIXTURE_DIR="$(mktemp -d)"
SUSFS_VENDOR_FIXTURE_DIR="$(mktemp -d)"
trap 'rm -f "$ANYKERNEL_FIXTURE" "$UPDATE_BINARY_FIXTURE" "$APP_STAGING_FIXTURE" "$KPM_CONFIG_FIXTURE" "$KSUN_NOMOUNT_CONFIG_FIXTURE" "$ZEROMOUNT_CONFIG_FIXTURE" "$MODULE_CONFIG_FIXTURE" "$SCMVERSION_FIXTURE"; rm -rf "$KPM_VERIFY_FIXTURE" "$NOMOUNT_FIXTURE_DIR" "$ZEROMOUNT_FIXTURE_DIR" "$EXTRACT_CERT_FIXTURE_DIR" "$ANYKERNEL_CACHE_FIXTURE_DIR" "$ANYKERNEL_PACKAGE_FIXTURE_DIR" "$ANYKERNEL_SLOT_FIXTURE_DIR" "$SUSFS_VENDOR_FIXTURE_DIR"' EXIT

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
grep -Fxq 'SLOT_SELECT=active;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not pin flashing to the active slot"
grep -Fxq 'PATCH_VBMETA_FLAG=0;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not preserve the boot vbmeta flag"
grep -Fxq 'NO_MAGISK_CHECK=1;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not skip unnecessary Magisk ramdisk handling"
grep -Fxq 'NO_VBMETA_PARTITION_PATCH=1;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not protect the standalone vbmeta partition"
grep -Fq 'Active-slot boot target verification failed' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not verify the resolved active-slot boot target"
grep -Fxq 'split_boot;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not support ramdiskless boot images"
grep -Fxq 'flash_boot;' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not preserve a ramdiskless boot layout"
if grep -Eq '^[[:space:]]*(dump_boot|write_boot);' "$ANYKERNEL_TEMPLATE_FIXTURE"; then
  fail "AnyKernel device template still requires a boot ramdisk"
fi
grep -Fq 'Stage 1/3: dumping and splitting boot image' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not report the dump stage"
grep -Fq 'Stage 3/3: rebuilding and flashing boot image' "$ANYKERNEL_TEMPLATE_FIXTURE" \
  || fail "AnyKernel device template does not report the flash stage"
if grep -Eq 'omap_hsmmc|maguro|toro|tuna' "$ANYKERNEL_TEMPLATE_FIXTURE"; then
  fail "AnyKernel device template retained an upstream example-device setting"
fi

mkdir -p "$ANYKERNEL_SLOT_FIXTURE_DIR/tools"
cp "$ANYKERNEL_TEMPLATE_FIXTURE" "$ANYKERNEL_SLOT_FIXTURE_DIR/anykernel.sh"
cat > "$ANYKERNEL_SLOT_FIXTURE_DIR/tools/ak3-core.sh" <<'EOF'
ui_print() { :; }
abort() {
  printf '%s\n' "$*"
  exit 97
}
SLOT="${TEST_RESOLVED_SLOT:?}"
BLOCK="${TEST_RESOLVED_BLOCK:?}"
split_boot() { printf '%s\n' split >> "$TEST_TRACE"; }
flash_boot() { printf '%s\n' flash >> "$TEST_TRACE"; }
EOF
SLOT_TRACE="$ANYKERNEL_SLOT_FIXTURE_DIR/trace"
(
  cd "$ANYKERNEL_SLOT_FIXTURE_DIR"
  TEST_RESOLVED_SLOT=_a \
    TEST_RESOLVED_BLOCK=/dev/block/by-name/boot_a \
    TEST_TRACE="$SLOT_TRACE" \
    sh anykernel.sh
)
assert_eq $'split\nflash' "$(cat "$SLOT_TRACE")" \
  "AnyKernel verified active-slot flash path"
rm -f "$SLOT_TRACE"
if (
  cd "$ANYKERNEL_SLOT_FIXTURE_DIR"
  TEST_RESOLVED_SLOT=_a \
    TEST_RESOLVED_BLOCK=/dev/block/by-name/boot_b \
    TEST_TRACE="$SLOT_TRACE" \
    sh anykernel.sh >/dev/null 2>&1
); then
  fail "AnyKernel accepted an inactive-slot boot target"
fi
test ! -e "$SLOT_TRACE" \
  || fail "AnyKernel started modifying boot before rejecting an inactive-slot target"
rm -f "$ANYKERNEL_TEMPLATE_FIXTURE"

printf '%s\n' \
  '[ "$AKHOME" ] || export AKHOME=$POSTINSTALL/tmp/anykernel;' \
  'printf "%s\n" "$AKHOME"' \
  > "$APP_STAGING_FIXTURE"
chmod 755 "$APP_STAGING_FIXTURE"
patch_anykernel_app_flash_staging "$APP_STAGING_FIXTURE"
sh -n "$APP_STAGING_FIXTURE" \
  || fail "AnyKernel app-flasher staging produced invalid shell syntax"
APP_PRIVATE_AKHOME="$(
  AKHOME=/data/user/0/com.sukisu.ultra/files/tmp/anykernel \
    POSTINSTALL=/data/user/0/com.sukisu.ultra/files \
    sh "$APP_STAGING_FIXTURE"
)"
[[ "$APP_PRIVATE_AKHOME" == /data/local/tmp/anykernel-* ]] \
  || fail "AnyKernel did not replace an app-private AKHOME: $APP_PRIVATE_AKHOME"
APP_PRIVATE_POSTINSTALL="$(
  AKHOME='' \
    POSTINSTALL=/data/user/0/com.sukisu.ultra/files \
    sh "$APP_STAGING_FIXTURE"
)"
[[ "$APP_PRIVATE_POSTINSTALL" == /data/local/tmp/anykernel-* ]] \
  || fail "AnyKernel did not replace an app-private POSTINSTALL: $APP_PRIVATE_POSTINSTALL"
RECOVERY_AKHOME="$(AKHOME='' POSTINSTALL=/postinstall sh "$APP_STAGING_FIXTURE")"
assert_eq "/postinstall/tmp/anykernel" "$RECOVERY_AKHOME" \
  "AnyKernel recovery staging path"
APP_STAGING_HASH="$(sha256sum "$APP_STAGING_FIXTURE" | cut -d' ' -f1)"
patch_anykernel_app_flash_staging "$APP_STAGING_FIXTURE"
assert_eq "$APP_STAGING_HASH" \
  "$(sha256sum "$APP_STAGING_FIXTURE" | cut -d' ' -f1)" \
  "AnyKernel app-flasher staging idempotence"

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

KSU_TYPE="KernelSU-Next-with-susfs-nomount"
apply_variant_configs "$KSUN_NOMOUNT_CONFIG_FIXTURE"
grep -q '^CONFIG_KSU_SUSFS=y$' "$KSUN_NOMOUNT_CONFIG_FIXTURE" || fail "KernelSU-Next NoMount SUSFS config"
grep -q '^CONFIG_KEYS=y$' "$KSUN_NOMOUNT_CONFIG_FIXTURE" || fail "KernelSU-Next NoMount key config"
grep -q '^CONFIG_NOMOUNT=y$' "$KSUN_NOMOUNT_CONFIG_FIXTURE" || fail "KernelSU-Next NoMount config"
if grep -q '^CONFIG_ZEROMOUNT=y$' "$KSUN_NOMOUNT_CONFIG_FIXTURE"; then
  fail "KernelSU-Next NoMount preset must not enable ZeroMount"
fi

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
MODULE_CONFIG_HASH="$(sha256sum "$MODULE_CONFIG_FIXTURE" | cut -d' ' -f1)"
MODULE_ABI_PATTERN='^(CONFIG|# CONFIG)_(MODULES|MODULE_UNLOAD|MODVERSIONS|MODULE_FORCE_LOAD|ARCH_INLINE_SPIN_LOCK|ARCH_INLINE_SPIN_UNLOCK|INLINE_SPIN_LOCK|UNINLINE_SPIN_UNLOCK|TRIM_UNUSED_KSYMS|KASAN|KASAN_GENERIC|KASAN_SW_TAGS|KASAN_HW_TAGS)'
MODULE_ABI_SNAPSHOT="$(grep -E "$MODULE_ABI_PATTERN" "$MODULE_CONFIG_FIXTURE")"
KSU_TYPE="None"
apply_variant_configs "$MODULE_CONFIG_FIXTURE"
assert_eq "$MODULE_CONFIG_HASH" \
  "$(sha256sum "$MODULE_CONFIG_FIXTURE" | cut -d' ' -f1)" \
  "no-root preset must preserve vendor ABI-sensitive configs byte for byte"
KSU_TYPE="SukiSU-Ultra-with-susfs-nomount-KPM"
apply_variant_configs "$MODULE_CONFIG_FIXTURE"
assert_eq "$MODULE_ABI_SNAPSHOT" \
  "$(grep -E "$MODULE_ABI_PATTERN" "$MODULE_CONFIG_FIXTURE")" \
  "root presets must preserve vendor ABI-sensitive configs"
grep -Fq 'write_kernel_scmversion "$KERNEL_COMMIT"' "$COMPILE_SCRIPT" \
  || fail "full builds do not pin the ROM-compatible kernel release suffix"
if grep -Fq 'touch .scmversion' "$COMPILE_SCRIPT"; then
  fail "full builds still erase the kernel source identity from vermagic"
fi
write_kernel_scmversion \
  0123456789abcdef0123456789abcdef01234567 \
  "$SCMVERSION_FIXTURE"
assert_eq '-g0123456789ab' "$(cat "$SCMVERSION_FIXTURE")" \
  "kernel source identity suffix"
verify_kernel_release_identity \
  '5.15.211-g0123456789ab' \
  0123456789abcdef0123456789abcdef01234567
if verify_kernel_release_identity \
  '5.15.211' \
  0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  fail "kernel release verification accepted a missing source identity"
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
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8550/out/arch/arm64/boot" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8550/SukiSU-Ultra/userspace/ksud/bin/aarch64" \
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
  '[ "$AKHOME" ] || export AKHOME=$POSTINSTALL/tmp/anykernel;' \
  '  if [ ! "$match" ]; then' \
  '    abort " " "Unsupported device. Aborting...";' \
  '  fi;' \
  'setup_bb;' \
  'if [ $? != 0 ]; then exit 1; fi;' \
  'OLD_PATH="$PATH";' \
  > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/META-INF/com/google/android/update-binary"
printf '%s\n' upstream-arm-busybox > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/busybox"
printf '%s\n' upstream-arm-magiskboot > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/magiskboot"
for optional_tool in fec httools_static lptools_static magiskpolicy snapshotupdater_static; do
  printf '%s\n' upstream-arm-optional > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/$optional_tool"
done
chmod 755 \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/anykernel.sh" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/META-INF/com/google/android/update-binary" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/busybox" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/source/tools/magiskboot"
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
printf '%s\n' sukisu-arm64-busybox > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8550/SukiSU-Ultra/userspace/ksud/bin/aarch64/busybox"
printf '%s\n' magisk-arm64-magiskboot > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a/libmagiskboot.so"
(
  cd "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk"
  zip -q "$ANYKERNEL_PACKAGE_FIXTURE_DIR/Magisk.apk" lib/arm64-v8a/libmagiskboot.so
)
cat > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{}'
EOF
cat > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/zip" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' zip-fixture > "$2"
EOF
cat > "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/readelf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '  Class:                             ELF64'
printf '%s\n' '  Machine:                           AArch64'
EOF
chmod +x \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/jq" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/zip" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/bin/readelf" \
  "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/sm8550/SukiSU-Ultra/userspace/ksud/bin/aarch64/busybox"

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
    KSU_TYPE=SukiSU-Ultra-with-susfs-nomount-KPM \
    KSU_REPO=https://github.com/SukiSU-Ultra/SukiSU-Ultra.git \
    KSU_COMMIT=3333333333333333333333333333333333333333 \
    SUSFS_REF=test \
    SUSFS_COMMIT=4444444444444444444444444444444444444444 \
    SUSFS_VERSION=2.3.0 \
    BUILD_TIMESTAMP="$package_timestamp" \
    GITHUB_WORKSPACE="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work" \
    GITHUB_ENV="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/github-env" \
    GITHUB_OUTPUT="$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/github-output" \
    MAGISK_APK_PATH="$ANYKERNEL_PACKAGE_FIXTURE_DIR/Magisk.apk" \
    MAGISK_APK_SHA256="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/Magisk.apk" | cut -d' ' -f1)" \
    MAGISKBOOT_ARM64_SHA256="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/magisk-apk/lib/arm64-v8a/libmagiskboot.so" | cut -d' ' -f1)" \
    ANYKERNEL_REPO="$ANYKERNEL_PACKAGE_FIXTURE_DIR/source" \
    ANYKERNEL_COMMIT="$ANYKERNEL_PACKAGE_COMMIT" \
    bash "$ANYKERNEL_PACKAGE_SCRIPT" >/dev/null
  )
  test -s "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/release-assets/test-profile_SukiSU-Ultra-with-susfs-nomount-KPM_111111111111_${package_timestamp}.zip" \
    || fail "AnyKernel packaging did not produce the flashable archive"
  test -s "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/release-assets/SHA256SUMS" \
    || fail "AnyKernel packaging did not produce checksums"
  grep -Fxq 'split_boot;' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
    || fail "AnyKernel package does not split ramdiskless boot images"
  grep -Fxq 'flash_boot;' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
    || fail "AnyKernel package does not flash ramdiskless boot images"
  grep -Fxq 'SLOT_SELECT=active;' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
    || fail "AnyKernel package does not force active-slot flashing"
  grep -Fq 'Active-slot boot target verification failed' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh" \
    || fail "AnyKernel package does not verify the resolved active-slot boot target"
  if grep -Eq '^[[:space:]]*(dump_boot|write_boot);' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/anykernel.sh"; then
    fail "AnyKernel package still attempts to unpack a boot ramdisk"
  fi
  assert_eq "sukisu-arm64-busybox" \
    "$(cat "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/tools/busybox")" \
    "KPM AnyKernel arm64 BusyBox replacement"
  assert_eq "755" \
    "$(stat -c '%a' "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/tools/busybox")" \
    "KPM AnyKernel arm64 BusyBox permissions"
  assert_eq "magisk-arm64-magiskboot" \
    "$(cat "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/tools/magiskboot")" \
    "KPM AnyKernel arm64 MagiskBoot replacement"
  assert_eq "755" \
    "$(stat -c '%a' "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/tools/magiskboot")" \
    "KPM AnyKernel arm64 MagiskBoot permissions"
  for optional_tool in fec httools_static lptools_static magiskpolicy snapshotupdater_static; do
    test ! -e "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/tools/$optional_tool" \
      || fail "KPM AnyKernel retained incompatible optional tool: $optional_tool"
  done
  grep -Fq 'export AKHOME=/data/local/tmp/anykernel-$$;' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel package does not stage app-triggered flashes in executable temporary storage"
  grep -Fq 'AnyKernel work directory: $AKHOME' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel package does not report its effective staging directory"
  grep -Fq 'Bundled BusyBox ABI: arm64' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "KPM AnyKernel package does not report its arm64 BusyBox"
  grep -Fq 'Bundled MagiskBoot ABI: arm64' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "KPM AnyKernel package does not report its arm64 MagiskBoot"
  grep -Fq 'Removing incompatible app-injected mkbootfs' \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "KPM AnyKernel package does not remove the manager's ARM32 mkbootfs"
  sh -n "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" \
    || fail "AnyKernel preflight diagnostics produced invalid shell syntax"
  PREFLIGHT_UPDATER_HASH="$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" | cut -d' ' -f1)"
  patch_anykernel_app_flash_staging \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary"
  add_anykernel_preflight_diagnostics \
    "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" arm64 true
  assert_eq "$PREFLIGHT_UPDATER_HASH" \
    "$(sha256sum "$ANYKERNEL_PACKAGE_FIXTURE_DIR/work/AnyKernel3/META-INF/com/google/android/update-binary" | cut -d' ' -f1)" \
    "AnyKernel preflight diagnostics idempotence"
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
