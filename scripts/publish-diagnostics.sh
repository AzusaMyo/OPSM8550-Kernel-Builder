#!/usr/bin/env bash
#
# Emit build diagnostics into the GitHub Actions job summary.
#
# Required env:
#   SOC
#   KSU_TYPE
#   KERNEL_BRANCH
#   MODULES_BRANCH
#   KERNEL_COMMIT
#   MODULES_COMMIT
#   GITHUB_STEP_SUMMARY
#
# Optional env:
#   SUSFS_REF
#
set -euo pipefail

: "${SOC:?}"
: "${KSU_TYPE:?}"
: "${KERNEL_BRANCH:?}"
: "${MODULES_BRANCH:?}"
: "${GITHUB_STEP_SUMMARY:?}"

append_file_block() {
  local label="$1"
  local path="$2"

  [[ -f "$path" ]] || return 0

  echo "#### $label"
  echo '```text'
  cat "$path"
  echo '```'
  echo
}

{
  echo "### Build diagnostics"
  echo
  echo "- Root solution: ${KSU_TYPE}"
  echo "- Target: ${TARGET_NAME:-unknown}"
  echo "- Device codenames: ${DEVICE_CODENAMES:-unknown}"
  echo "- Accepted device IDs: ${DEVICE_NAMES:-unknown}"
  echo "- Branch: ${KERNEL_BRANCH}"
  echo "- Kernel commit: \`${KERNEL_COMMIT}\`"
  echo "- Modules branch: ${MODULES_BRANCH}"
  echo "- Modules commit: \`${MODULES_COMMIT}\`"
  if [[ -n "${KSU_COMMIT:-}" ]]; then
    echo "- KernelSU repository: ${KSU_REPO:-unknown}"
    echo "- KernelSU ref: ${KSU_REF:-unknown}"
    echo "- KernelSU commit: \`${KSU_COMMIT}\`"
  fi
  if [[ -n "${SUSFS_REF:-}" ]]; then
    echo "- susfs ref: ${SUSFS_REF}"
    echo "- susfs commit: \`${SUSFS_COMMIT}\`"
    echo "- susfs version: v${SUSFS_VERSION:-unknown}"
  fi
  if [[ -n "${NOMOUNT_REF:-}" ]]; then
    echo "- NoMount ref: ${NOMOUNT_REF}"
    echo "- NoMount commit: \`${NOMOUNT_COMMIT}\`"
    echo "- NoMount version: v${NOMOUNT_VERSION:-unknown}"
  fi
  if [[ -n "${ZEROMOUNT_COMMIT:-}" ]]; then
    echo "- ZeroMount GKI target: ${ZEROMOUNT_GKI_TAG:-unknown}"
    echo "- ZeroMount patch commit: \`${ZEROMOUNT_COMMIT}\`"
    echo "- ZeroMount patch SHA-256: ${ZEROMOUNT_PATCH_SHA256:-unknown}"
  fi
  echo

  if [[ -f "${SOC}/out/.config" ]]; then
    echo '#### .config snapshot'
    echo '```text'
    grep -E '^CONFIG_(MODULES|MODULE_UNLOAD|MODVERSIONS|MODULE_FORCE_LOAD|UNINLINE_SPIN_UNLOCK|KASAN|KASAN_HW_TAGS)=|^# CONFIG_(TRIM_UNUSED_KSYMS|ARCH_INLINE_SPIN_LOCK|ARCH_INLINE_SPIN_UNLOCK|INLINE_SPIN_LOCK|KASAN_GENERIC|KASAN_SW_TAGS) is not set$|^CONFIG_KSU=|^CONFIG_KSU_SUSFS|^CONFIG_KSU_MANUAL_HOOK|^CONFIG_NOMOUNT=|^CONFIG_ZEROMOUNT=|^CONFIG_KPM=|^CONFIG_KALLSYMS(_ALL)?=' "${SOC}/out/.config" || true
    echo '```'
    echo
  fi

  append_file_block "susfs-source-proof.txt" "${SOC}/susfs-source-proof.txt"
  append_file_block "susfs-hook-proof.txt"   "${SOC}/susfs-hook-proof.txt"
  append_file_block "susfs-proof.txt"        "${SOC}/susfs-proof.txt"
  append_file_block "nomount-source-proof.txt" "${SOC}/nomount-source-proof.txt"
  append_file_block "nomount-proof.txt"        "${SOC}/nomount-proof.txt"
  append_file_block "zeromount-source-proof.txt" "${SOC}/zeromount-source-proof.txt"
  append_file_block "zeromount-proof.txt"        "${SOC}/zeromount-proof.txt"
  append_file_block "kpm-source-proof.txt"     "${SOC}/kpm-source-proof.txt"
  append_file_block "kpm-proof.txt"            "${SOC}/kpm-proof.txt"
  append_file_block "external-module-proof.txt" "${SOC}/external-module-proof.txt"
} >> "$GITHUB_STEP_SUMMARY"
