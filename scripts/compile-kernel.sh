#!/usr/bin/env bash
#
# Apply the selected integrations, generate config, and optionally build Image.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-helpers.sh
. "${SCRIPT_DIR}/lib/git-helpers.sh"
# shellcheck source=lib/kernel-helpers.sh
. "${SCRIPT_DIR}/lib/kernel-helpers.sh"
# shellcheck source=lib/ksu-setup.sh
. "${SCRIPT_DIR}/lib/ksu-setup.sh"
# shellcheck source=lib/susfs-apply.sh
. "${SCRIPT_DIR}/lib/susfs-apply.sh"
# shellcheck source=lib/nomount-setup.sh
. "${SCRIPT_DIR}/lib/nomount-setup.sh"
# shellcheck source=lib/zeromount-setup.sh
. "${SCRIPT_DIR}/lib/zeromount-setup.sh"
# shellcheck source=lib/verify.sh
. "${SCRIPT_DIR}/lib/verify.sh"

: "${GITHUB_WORKSPACE:?}"
: "${GITHUB_STEP_SUMMARY:?}"
: "${CLANG_VERSION:?}"
: "${SOC:?}"
: "${BUILD_CONFIGS:?}"
: "${KERNEL_MAKE_FLAGS:=}"
: "${SOURCE_LAYOUT:?}"
: "${OFFICIAL_BUILD_TARGET:?}"
: "${KSU_TYPE:?}"
: "${KERNEL_BRANCH:?}"
: "${KERNEL_COMMIT:?}"
: "${BUILD_MODE:?}"
: "${ROM_GKI_MODULE_COMPAT:=0}"

BUILD_STARTED_AT="$(date +%s)"
CONFIG_SECONDS=0
COMPILE_SECONDS=0
BUILD_PHASE="setup"

publish_performance_summary() {
  local status="$?"
  local finished_at
  local elapsed

  trap - EXIT
  if [[ -n "${BUILD_RESOURCE_MONITOR_PID:-}" ]]; then
    kill "$BUILD_RESOURCE_MONITOR_PID" 2>/dev/null || true
    wait "$BUILD_RESOURCE_MONITOR_PID" 2>/dev/null || true
  fi
  finished_at="$(date +%s)"
  elapsed=$((finished_at - BUILD_STARTED_AT))

  {
    echo "### Build performance"
    echo "- Result: $([[ "$status" -eq 0 ]] && echo success || echo failure)"
    echo "- Last phase: $BUILD_PHASE"
    echo "- Config/patch time: ${CONFIG_SECONDS}s"
    echo "- Compile time: ${COMPILE_SECONDS}s"
    echo "- Script total: ${elapsed}s"
    if command -v ccache >/dev/null 2>&1; then
      echo
      echo '```text'
      ccache --show-stats || true
      echo '```'
    fi
  } >> "$GITHUB_STEP_SUMMARY"

  exit "$status"
}
trap publish_performance_summary EXIT

CLANG_ROOT="${GITHUB_WORKSPACE}/toolchains/${CLANG_VERSION}/bin"
if [[ "$BUILD_MODE" == 'Patch/config validation only' && ! -x "${CLANG_ROOT}/clang" ]]; then
  # Validation workflows install the distribution LLVM toolchain instead of
  # downloading AOSP Clang. Keep symbol verification on that same toolchain.
  CLANG_ROOT="$(dirname "$(command -v clang)")"
  test -x "${CLANG_ROOT}/ld.lld"
  test -x "${CLANG_ROOT}/llvm-nm"
fi
export PATH="${CLANG_ROOT}:${PATH}"
export ARCH=arm64
export SUBARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CCACHE_DIR="${GITHUB_WORKSPACE}/.ccache"
export CCACHE_BASEDIR="${GITHUB_WORKSPACE}"
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
export CCACHE_COMPRESS=true
export CCACHE_COMPRESSLEVEL=6
export CCACHE_MAXSIZE=3G
mkdir -p "${CCACHE_DIR}"

cd "${SOC}"

SOURCE_DATE_EPOCH="$(git show -s --format=%ct "$KERNEL_COMMIT")"
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP="$(date -u -d "@${SOURCE_DATE_EPOCH}" '+%Y-%m-%d %H:%M:%S UTC')"
export KBUILD_BUILD_USER=opskernel
export KBUILD_BUILD_HOST=github-actions

# Command-line assignments take precedence over Kbuild's own CC/HOSTCC values.
# Exporting CC alone is not sufficient when LLVM=1 because the kernel Makefile
# assigns CC=clang internally.
MAKE_ARGS=(
  O=out
  LLVM=1
  LLVM_IAS=1
  "CC=ccache clang"
  "CXX=ccache clang++"
  "HOSTCC=ccache clang"
  "HOSTCXX=ccache clang++"
)
if [[ -n "$KERNEL_MAKE_FLAGS" ]]; then
  read -r -a KERNEL_MAKE_FLAG_ARRAY <<< "$KERNEL_MAKE_FLAGS"
  for make_flag in "${KERNEL_MAKE_FLAG_ARRAY[@]}"; do
    if [[ ! "$make_flag" =~ ^CONFIG_[A-Z0-9_]+=(y|m|n)$ ]]; then
      echo "::error::Invalid device kernel make flag: $make_flag"
      exit 1
    fi
  done
  MAKE_ARGS+=("${KERNEL_MAKE_FLAG_ARRAY[@]}")
  echo "[config] Device make flags: ${KERNEL_MAKE_FLAG_ARRAY[*]}"
fi

ccache --zero-stats || true
CONFIG_STARTED_AT="$(date +%s)"
BUILD_PHASE="source integration"

EXTRACT_CERT_SOURCE="$(detect_extract_cert_source)" || {
  echo '::error::Kernel certificate host-tool source was not found.'
  exit 1
}
repair_extract_cert_key_pass_guard "$EXTRACT_CERT_SOURCE"
install_ksu_variant "${KSU_TYPE}"

if [[ "$KSU_TYPE" == *KPM* ]]; then
  verify_kpm_source_integration "${KSU_KERNEL_DIR}"
fi

if [[ "$KSU_TYPE" == *susfs* ]]; then
  : "${SUSFS_REF:?}"
  : "${SUSFS_COMMIT:?}"
  : "${SUSFS_PATCH_FILE:?}"
  apply_susfs_full "$SUSFS_REF" "$SUSFS_COMMIT" "$SUSFS_PATCH_FILE"
  verify_susfs_source_integration "${KSU_KERNEL_DIR}"
fi

if [[ "$KSU_TYPE" == *zeromount* ]]; then
  : "${ZEROMOUNT_REPO:?}"
  : "${ZEROMOUNT_COMMIT:?}"
  : "${ZEROMOUNT_GKI_TAG:?}"
  install_zeromount "$ZEROMOUNT_REPO" "$ZEROMOUNT_COMMIT" "$ZEROMOUNT_GKI_TAG"
  verify_zeromount_source_integration
fi

if [[ "$KSU_TYPE" == *nomount* ]]; then
  : "${NOMOUNT_REPO:?}"
  : "${NOMOUNT_REF:?}"
  : "${NOMOUNT_COMMIT:?}"
  install_nomount "$NOMOUNT_REPO" "$NOMOUNT_REF" "$NOMOUNT_COMMIT"
  verify_nomount_source_integration
fi

# Match the ROM kernel's CONFIG_LOCALVERSION_AUTO result without inheriting the
# intentionally dirty integration worktree. Vendor modules include this release
# string in vermagic and fail during early boot when the source identity is lost.
write_kernel_scmversion "$KERNEL_COMMIT"

ACTIVE_BUILD_CONFIGS="${BUILD_CONFIGS}"
if [[ "$SOURCE_LAYOUT" == "oneplus-official" ]]; then
  ACTIVE_BUILD_CONFIGS="vendor/${OFFICIAL_BUILD_TARGET}_GKI.config"
fi
read -r -a ACTIVE_CONFIG_ARRAY <<< "$ACTIVE_BUILD_CONFIGS"

BUILD_PHASE="config generation"
apply_variant_configs arch/arm64/configs/gki_defconfig
apply_rom_gki_module_compat_config arch/arm64/configs/gki_defconfig
make "${MAKE_ARGS[@]}" gki_defconfig "${ACTIVE_CONFIG_ARRAY[@]}"
apply_variant_configs out/.config
apply_rom_gki_module_compat_config out/.config
make "${MAKE_ARGS[@]}" olddefconfig

require_config_enabled  out/.config CONFIG_MODULES
require_config_enabled  out/.config CONFIG_MODULE_UNLOAD
require_config_enabled  out/.config CONFIG_MODVERSIONS
if [[ "$ROM_GKI_MODULE_COMPAT" == 1 ]]; then
  require_config_enabled out/.config CONFIG_MODULE_SIG
  require_config_disabled out/.config CONFIG_MODULE_SIG_FORCE
  require_config_disabled out/.config CONFIG_MODULE_SIG_PROTECT
  grep -Fqx '# CONFIG_MODULE_SIG_PROTECT is not set' out/.config || {
    echo "::error::ROM GKI module compatibility did not survive olddefconfig."
    exit 1
  }
fi

if [[ "$KSU_TYPE" != "None" ]]; then
  require_config_enabled out/.config CONFIG_KSU
fi
if [[ "$KSU_TYPE" == *susfs* ]]; then
  require_config_enabled  out/.config CONFIG_KSU_SUSFS
  require_config_enabled  out/.config CONFIG_KSU_SUSFS_SUS_MAP
  require_config_enabled  out/.config CONFIG_KSU_SUSFS_OPEN_REDIRECT
  require_config_disabled out/.config CONFIG_KSU_MANUAL_HOOK
  if [[ "$KSU_TYPE" == SukiSU-Ultra-with-susfs* ]]; then
    require_config_enabled out/.config CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
  else
    require_config_disabled out/.config CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
  fi
fi
if [[ "$KSU_TYPE" == *nomount* ]]; then
  require_config_enabled out/.config CONFIG_KEYS
  require_config_enabled out/.config CONFIG_NOMOUNT
fi
if [[ "$KSU_TYPE" == *zeromount* ]]; then
  require_config_enabled out/.config CONFIG_ZEROMOUNT
fi
if [[ "$KSU_TYPE" == *KPM* ]]; then
  require_config_enabled out/.config CONFIG_KPM
  require_config_enabled out/.config CONFIG_KALLSYMS
  require_config_enabled out/.config CONFIG_KALLSYMS_ALL
fi

CONFIG_SECONDS=$(($(date +%s) - CONFIG_STARTED_AT))

if [[ "$BUILD_MODE" == "Patch/config validation only" ]]; then
  BUILD_PHASE="host-tool smoke compile"
  COMPILE_STARTED_AT="$(date +%s)"
  # Use the owning Kbuild target so extract-cert is compiled with HOSTCC and
  # linked with libcrypto, rather than treated as an arm64 kernel object.
  EXTRACT_CERT_TARGET='certs/'
  [[ "$EXTRACT_CERT_SOURCE" != scripts/* ]] || EXTRACT_CERT_TARGET=scripts
  if ! make "${MAKE_ARGS[@]}" "$EXTRACT_CERT_TARGET" || \
     [[ ! -x "out/${EXTRACT_CERT_SOURCE%.c}" ]]; then
    COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))
    echo "::error::Kernel certificate host-tool smoke compile failed."
    exit 1
  fi
  COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))

  SMOKE_TARGETS=()
  if [[ "$KSU_TYPE" == *susfs* ]]; then
    SMOKE_TARGETS+=(
      fs/susfs.o
      fs/namespace.o
      fs/proc/task_mmu.o
      kernel/reboot.o
      "${KSU_DRIVER_DIR}/kernelsu/"
    )
  fi
  if [[ "$KSU_TYPE" == *nomount* ]]; then
    SMOKE_TARGETS+=("${NOMOUNT_FS_DIR}/nomount/nomount.o")
  fi
  if [[ "$KSU_TYPE" == *zeromount* ]]; then
    SMOKE_TARGETS+=(
      fs/zeromount.o
      fs/namei.o
      fs/readdir.o
      fs/d_path.o
      fs/stat.o
      fs/statfs.o
      fs/xattr.o
      fs/proc/base.o
    )
  fi
  if [[ "$KSU_TYPE" == *KPM* ]]; then
    if [[ "$KSU_TYPE" != *susfs* ]]; then
      SMOKE_TARGETS+=("${KSU_DRIVER_DIR}/kernelsu/")
    fi
    # Building the KernelSU directory includes all CONFIG_KPM objects as well
    # as its SUSFS compatibility sources and symbol resolver.
  fi

  if [[ "${#SMOKE_TARGETS[@]}" -gt 0 ]]; then
    BUILD_PHASE="integration object smoke compile"
    COMPILE_STARTED_AT="$(date +%s)"
    # A partial driver build does not visit the directories that generate
    # compile.h and the SELinux flask/permission headers used by KernelSU.
    if ! make -j"$(nproc)" "${MAKE_ARGS[@]}" init/ security/selinux/; then
      COMPILE_SECONDS=$((COMPILE_SECONDS + $(date +%s) - COMPILE_STARTED_AT))
      echo '::error::KernelSU generated-header preparation failed.'
      exit 1
    fi
    if ! make -j"$(nproc)" "${MAKE_ARGS[@]}" "${SMOKE_TARGETS[@]}" 2>&1 | tee integration-smoke.log; then
      COMPILE_SECONDS=$((COMPILE_SECONDS + $(date +%s) - COMPILE_STARTED_AT))
      echo "::error::SUSFS/NoMount/ZeroMount/KPM integration object smoke compile failed."
      exit 1
    fi
    COMPILE_SECONDS=$((COMPILE_SECONDS + $(date +%s) - COMPILE_STARTED_AT))
    if [[ "$KSU_TYPE" == *susfs* ]]; then
      verify_susfs_binary_presence
    fi
    if [[ "$KSU_TYPE" == *nomount* ]]; then
      verify_nomount_binary_presence
    fi
    if [[ "$KSU_TYPE" == *zeromount* ]]; then
      verify_zeromount_binary_presence
    fi
    if [[ "$KSU_TYPE" == *KPM* ]]; then
      verify_kpm_binary_presence
    fi
  fi

  BUILD_PHASE="validation complete"
  echo "[+] Source integration, config validation, and integration object smoke compile completed."
  exit 0
fi

BUILD_PHASE="kernel compilation"
COMPILE_STARTED_AT="$(date +%s)"
(
  while true; do
    {
      echo "==== BUILD RESOURCES $(date -u +'%Y-%m-%d %H:%M:%S UTC') ===="
      free -h
      df -h .
      ps -C ld.lld -o pid,rss,vsz,pcpu,etime,comm || true
    } | tee -a build-resources.log
    sleep 30
  done
) &
BUILD_RESOURCE_MONITOR_PID=$!
if ! make -j"$(nproc)" "${MAKE_ARGS[@]}" Image 2>&1 | tee build.log; then
  COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))
  ccache --show-stats || true
  echo "==== BUILD ERROR SUMMARY ===="
  grep -nE ' error:|undefined reference|No rule to make target|fatal error:' build.log | tail -n 50 || true
  echo "==== BUILD FAILED (last 200 lines) ===="
  tail -n 200 build.log || true
  exit 1
fi
kill "$BUILD_RESOURCE_MONITOR_PID" 2>/dev/null || true
wait "$BUILD_RESOURCE_MONITOR_PID" 2>/dev/null || true
BUILD_RESOURCE_MONITOR_PID=''
COMPILE_SECONDS=$(($(date +%s) - COMPILE_STARTED_AT))

BUILD_PHASE="post-build verification"
KERNEL_RELEASE="$(make -s "${MAKE_ARGS[@]}" kernelrelease)"
verify_kernel_release_identity "$KERNEL_RELEASE" "$KERNEL_COMMIT"
if ! strings out/arch/arm64/boot/Image | grep -F "Linux version ${KERNEL_RELEASE} " >/dev/null; then
  echo "::error::Built Image banner does not contain the verified kernel release: ${KERNEL_RELEASE}"
  exit 1
fi
echo "[+] Kernel release identity verified: ${KERNEL_RELEASE}"
if [[ "$KSU_TYPE" == *susfs* ]]; then
  echo "==== SUSFS CONFIG SNAPSHOT ===="
  grep -E '^CONFIG_KSU_SUSFS|^CONFIG_KSU_MANUAL_HOOK|^CONFIG_TMPFS_XATTR=|^CONFIG_NOMOUNT=' out/.config || true
  if [[ "$KSU_TYPE" == ReSukiSU* ]]; then
    verify_resukisu_susfs_hook_mode
  fi
  verify_susfs_binary_presence
fi
if [[ "$KSU_TYPE" == *nomount* ]]; then
  verify_nomount_binary_presence
fi
if [[ "$KSU_TYPE" == *zeromount* ]]; then
  echo "==== ZEROMOUNT CONFIG SNAPSHOT ===="
  grep -E '^CONFIG_ZEROMOUNT=|^CONFIG_KSU_SUSFS=' out/.config || true
  verify_zeromount_binary_presence
fi
if [[ "$KSU_TYPE" == *KPM* ]]; then
  echo "==== KPM CONFIG SNAPSHOT ===="
  grep -E '^CONFIG_KPM=|^CONFIG_KALLSYMS(_ALL)?=' out/.config || true
  verify_kpm_binary_presence
fi

ccache --show-stats || true
test -f out/arch/arm64/boot/Image
BUILD_PHASE="build complete"
