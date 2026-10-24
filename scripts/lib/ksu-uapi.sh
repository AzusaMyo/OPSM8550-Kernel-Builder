#!/usr/bin/env bash
# Backport manager-facing interfaces without replacing the tested SUSFS hooks.

apply_ksu_uapi_backports() {
  local patch_name expected_commit expected_uapi patch_file
  local repo_dir="${KSU_REPO_DIR:-}"
  local uapi_header dispatch_file

  case "$KSU_TYPE" in
    BakaSU-with-susfs|BakaSU-with-susfs-nomount|BakaSU-with-susfs-zeromount)
      patch_name=bakasu-susfs-uapi5.patch
      expected_commit=fa8311f632a215b5381ec644627c6198d1e8a13e
      expected_uapi=5
      ;;
    SukiSU-Ultra-with-susfs-KPM|SukiSU-Ultra-with-susfs-nomount-KPM|SukiSU-Ultra-with-susfs-zeromount-KPM)
      patch_name=sukisu-susfs-uapi6.patch
      expected_commit=7fbbb1f12e2410b69c8ebf958be84f165b8d0c93
      expected_uapi=6
      ;;
    *) return 0 ;;
  esac

  if [[ -z "$repo_dir" || "$(git -C "$repo_dir" rev-parse HEAD)" != "$expected_commit" ]]; then
    echo "::error::UAPI backport requires the tested $KSU_TYPE driver at $expected_commit."
    return 1
  fi
  patch_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../patches/$patch_name"
  if git -C "$repo_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "[+] $patch_name is already applied."
  else
    git -C "$repo_dir" apply --check "$patch_file" || return 1
    git -C "$repo_dir" apply "$patch_file" || return 1
  fi

  uapi_header="$repo_dir/uapi/supercall.h"
  dispatch_file="$repo_dir/kernel/supercall/dispatch.c"
  grep -Eq "KERNEL_SU_UAPI_VERSION = ${expected_uapi};" "$uapi_header" || return 1
  grep -Fq 'case EVENT_SERVICES:' "$dispatch_file" || return 1
  if [[ "$expected_uapi" == 6 ]]; then
    grep -Fq '.handler = do_extension,' "$dispatch_file" || return 1
    grep -Fq "_IOC(_IOC_READ | _IOC_WRITE, 'K', 300, sizeof(struct ksu_extension_cmd))" "$uapi_header" || return 1
    grep -Fq '.handler = do_lookup_symbols,' "$dispatch_file" || return 1
    grep -Fq 'int __nocfi ksu_lookup_kernel_symbols(' "$repo_dir/kernel/infra/symbol_resolver.c" || return 1
    grep -Fq '"/metadata/vold/ksu/modules.rc"' "$repo_dir/kernel/runtime/ksud_integration.c" || return 1
    if grep -Eq 'cmd.flags[[:space:]]*\|=[[:space:]]*KSU_GET_INFO_FLAG_PREINIT' "$dispatch_file"; then
      echo '::error::The SUSFS UAPI backport must not advertise an unavailable preinit runner.'
      return 1
    fi
  fi
  KSU_UAPI_VERSION="$expected_uapi"
  KSU_UAPI_PATCH_SHA256="$(sha256sum "$patch_file" | awk '{print $1}')"
  export KSU_UAPI_VERSION KSU_UAPI_PATCH_SHA256
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf 'KSU_UAPI_VERSION=%s\nKSU_UAPI_PATCH_SHA256=%s\n' \
      "$KSU_UAPI_VERSION" "$KSU_UAPI_PATCH_SHA256" >> "$GITHUB_ENV"
  fi
  echo "[+] $KSU_TYPE supports manager UAPI $KSU_UAPI_VERSION ($patch_name)."
}
