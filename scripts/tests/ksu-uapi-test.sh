#!/usr/bin/env bash
# Network integration test: compose real pinned drivers, SUSFS, and UAPI patches.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/susfs-apply.sh
. "$SCRIPT_DIR/../lib/susfs-apply.sh"
# shellcheck source=../lib/ksu-uapi.sh
. "$SCRIPT_DIR/../lib/ksu-uapi.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

fetch_source() {
  local source="$1" commit="$2" destination="$3"
  shift 3
  git init -q "$destination"
  git -C "$destination" remote add origin "$source"
  git -C "$destination" sparse-checkout set "$@"
  git -C "$destination" fetch -q --depth=1 --filter=blob:none origin "$commit"
  git -C "$destination" checkout -q --detach FETCH_HEAD
}

fetch_source "${UAPI_TEST_SUSFS_SOURCE:-https://gitlab.com/simonpunk/susfs4ksu.git}" \
  aab99ba7693d94489fd32f1cc4c9d58396fffeee "$fixture/susfs" kernel_patches
for variant in BakaSU SukiSU; do
  if [[ "$variant" == BakaSU ]]; then
    source="${UAPI_TEST_BAKASU_SOURCE:-https://github.com/Baka-SU/BakaSU.git}"
    commit=fa8311f632a215b5381ec644627c6198d1e8a13e
    KSU_TYPE=BakaSU-with-susfs-zeromount
    expected=5
  else
    source="${UAPI_TEST_SUKISU_SOURCE:-https://github.com/SukiSU-Ultra/SukiSU-Ultra.git}"
    commit=7fbbb1f12e2410b69c8ebf958be84f165b8d0c93
    KSU_TYPE=SukiSU-Ultra-with-susfs-nomount-KPM
    expected=6
  fi
  KSU_REPO_DIR="$fixture/$variant"
  fetch_source "$source" "$commit" "$KSU_REPO_DIR" kernel uapi
  cp "$fixture/susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" "$KSU_REPO_DIR/"
  mkdir -p "$KSU_REPO_DIR/kernel/include/linux"
  cp "$fixture/susfs/kernel_patches/include/linux/"* "$KSU_REPO_DIR/kernel/include/linux/"
  patch_kernelsu_for_susfs "$KSU_REPO_DIR" "$KSU_REPO_DIR/kernel"
  if [[ "$variant" == BakaSU ]]; then
    patch_bakasu_susfs_runtime_compat "$KSU_REPO_DIR/kernel"
  fi
  patch_susfs_selinux_hide_compat "$KSU_REPO_DIR/kernel"
  GITHUB_ENV="$fixture/env"
  apply_ksu_uapi_backports
  [[ "$KSU_UAPI_VERSION" == "$expected" ]]
  [[ "$KSU_UAPI_PATCH_SHA256" =~ ^[0-9a-f]{64}$ ]]
  grep -Fxq "KSU_UAPI_VERSION=$expected" "$GITHUB_ENV"
  before="$(git -C "$KSU_REPO_DIR" diff | sha256sum)"
  apply_ksu_uapi_backports
  [[ "$before" == "$(git -C "$KSU_REPO_DIR" diff | sha256sum)" ]]
  python3 "$SCRIPT_DIR/ksu-uapi-test.py" "$KSU_REPO_DIR"
  # Unknown source drift must not be accepted as an already-applied patch.
  printf '\n// unknown drift\n' >> "$KSU_REPO_DIR/kernel/supercall/dispatch.c"
  # Alter patched code itself so the reverse-check also detects the drift.
  sed -i 's/case EVENT_SERVICES:/case EVENT_SERVICES + 99:/' "$KSU_REPO_DIR/kernel/supercall/dispatch.c"
  if apply_ksu_uapi_backports > "$fixture/drift.log" 2>&1; then
    echo "::error::UAPI backport accepted unknown handler drift."
    exit 1
  fi
  # The backport must not touch unrelated root presets.
  KSU_TYPE=Official-KernelSU apply_ksu_uapi_backports
  echo "PASS: $variant SUSFS composition, idempotence, provenance, and drift rejection"
done
