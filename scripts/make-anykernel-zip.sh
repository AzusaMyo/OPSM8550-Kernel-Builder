#!/usr/bin/env bash
#
# Create a device-checked AnyKernel3 package plus release provenance files.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/git-helpers.sh
. "${SCRIPT_DIR}/lib/git-helpers.sh"
# shellcheck source=lib/anykernel-helpers.sh
. "${SCRIPT_DIR}/lib/anykernel-helpers.sh"

: "${SOC:?}"
: "${PROFILE_ID:?}"
: "${TARGET_NAME:?}"
: "${DEVICE_CODENAMES:?}"
: "${DEVICE_NAMES:?}"
: "${SOURCE_NAME:?}"
: "${KERNEL_BRANCH:?}"
: "${MODULES_BRANCH:?}"
: "${KERNEL_COMMIT:?}"
: "${MODULES_COMMIT:?}"
: "${CLANG_VERSION:?}"
: "${KSU_TYPE:?}"
: "${BUILD_TIMESTAMP:?}"
: "${GITHUB_ENV:?}"
: "${GITHUB_OUTPUT:?}"
: "${ANYKERNEL_REPO:?}"
: "${ANYKERNEL_COMMIT:?}"

SUPPORTED_ANDROID_VERSIONS="${SUPPORTED_ANDROID_VERSIONS:-}"
KSU_COMMIT="${KSU_COMMIT:-}"
KSU_REPO="${KSU_REPO:-}"
KSU_REF="${KSU_REF:-}"
SUSFS_REF="${SUSFS_REF:-}"
SUSFS_COMMIT="${SUSFS_COMMIT:-}"
SUSFS_VERSION="${SUSFS_VERSION:-}"
NOMOUNT_REF="${NOMOUNT_REF:-}"
NOMOUNT_COMMIT="${NOMOUNT_COMMIT:-}"
NOMOUNT_VERSION="${NOMOUNT_VERSION:-}"
ZEROMOUNT_REPO="${ZEROMOUNT_REPO:-}"
ZEROMOUNT_COMMIT="${ZEROMOUNT_COMMIT:-}"
ZEROMOUNT_GKI_TAG="${ZEROMOUNT_GKI_TAG:-}"
ZEROMOUNT_PATCH_SHA256="${ZEROMOUNT_PATCH_SHA256:-}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-local/OPSM8550-Kernel-Builder}"
GITHUB_RUN_ID="${GITHUB_RUN_ID:-local}"
GITHUB_SHA="${GITHUB_SHA:-local}"
MAGISK_TOOLS_VERSION="${MAGISK_TOOLS_VERSION:-30.7}"
MAGISK_APK_URL="${MAGISK_APK_URL:-https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk}"
MAGISK_APK_SHA256="${MAGISK_APK_SHA256:-e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5}"
MAGISKBOOT_ARM64_SHA256="${MAGISKBOOT_ARM64_SHA256:-d7440e2cd89899426e809554bf793baef9804ccbe5a52ce34a8b6242725d3c77}"
MAGISK_APK_PATH="${MAGISK_APK_PATH:-}"

SHORT_KERNEL_COMMIT="${KERNEL_COMMIT:0:12}"
ZIP_NAME="${PROFILE_ID}_${KSU_TYPE}_${SHORT_KERNEL_COMMIT}_${BUILD_TIMESTAMP}"
ASSET_DIR="${GITHUB_WORKSPACE:-$(pwd)}/release-assets"
KPM_ENABLED=false
if [[ "$KSU_TYPE" == *KPM* ]]; then
  KPM_ENABLED=true
fi

{
  echo "ZIP_NAME=$ZIP_NAME"
  echo "RELEASE_ASSET_DIR=$ASSET_DIR"
} >> "$GITHUB_ENV"
{
  echo "zip_name=$ZIP_NAME"
  echo "asset_dir=$ASSET_DIR"
} >> "$GITHUB_OUTPUT"

if [[ -d AnyKernel3/.git ]]; then
  echo "[+] Reusing cached AnyKernel3 checkout."
  sanitize_cached_anykernel_checkout AnyKernel3
  (
    cd AnyKernel3
    git remote set-url origin "$ANYKERNEL_REPO"
    git_fetch_retry . --depth=1 --no-tags origin "$ANYKERNEL_COMMIT"
    git checkout -q --force --detach FETCH_HEAD
    git reset --hard -q "$ANYKERNEL_COMMIT"
    git clean -qfdx
  )
else
  rm -rf AnyKernel3
  git init -q AnyKernel3
  git -C AnyKernel3 remote add origin "$ANYKERNEL_REPO"
  git_fetch_retry AnyKernel3 --depth=1 --no-tags origin "$ANYKERNEL_COMMIT"
  git -C AnyKernel3 checkout -q --detach FETCH_HEAD
fi

test "$(git -C AnyKernel3 rev-parse HEAD)" = "$ANYKERNEL_COMMIT"

ANYKERNEL_SCRIPT="AnyKernel3/anykernel.sh"
ANYKERNEL_UPDATE_BINARY="AnyKernel3/META-INF/com/google/android/update-binary"
ANYKERNEL_TEMPLATE="${SCRIPT_DIR}/templates/anykernel.sh"
ANYKERNEL_BUSYBOX_ABI="arm"
ANYKERNEL_BUSYBOX_SHA256=""
install_anykernel_template "$ANYKERNEL_TEMPLATE" "$ANYKERNEL_SCRIPT"
configure_anykernel_properties \
  "$ANYKERNEL_SCRIPT" \
  "OnePlus Kernel (${KSU_TYPE}) for ${TARGET_NAME}" \
  "$DEVICE_NAMES" \
  "$SUPPORTED_ANDROID_VERSIONS"
add_anykernel_devicecheck_diagnostics "$ANYKERNEL_UPDATE_BINARY"
patch_anykernel_app_flash_staging "$ANYKERNEL_UPDATE_BINARY"

if [[ "$KPM_ENABLED" == true ]]; then
  KSU_CHECKOUT_NAME="$(basename "${KSU_REPO%.git}")"
  KSU_ARM64_BUSYBOX="${SOC}/${KSU_CHECKOUT_NAME}/userspace/ksud/bin/aarch64/busybox"
  install_anykernel_arm64_busybox "$KSU_ARM64_BUSYBOX" "AnyKernel3/tools/busybox"
  install_anykernel_arm64_magiskboot \
    "$MAGISK_APK_URL" \
    "$MAGISK_APK_SHA256" \
    "$MAGISKBOOT_ARM64_SHA256" \
    "AnyKernel3/tools/magiskboot" \
    "$MAGISK_APK_PATH"
  prepare_anykernel_arm64_toolset "AnyKernel3/tools"
  ANYKERNEL_BUSYBOX_ABI="arm64"
fi
ANYKERNEL_BUSYBOX_SHA256="$(sha256sum AnyKernel3/tools/busybox | awk '{print $1}')"
ANYKERNEL_MAGISKBOOT_SHA256="$(sha256sum AnyKernel3/tools/magiskboot | awk '{print $1}')"
add_anykernel_preflight_diagnostics \
  "$ANYKERNEL_UPDATE_BINARY" \
  "$ANYKERNEL_BUSYBOX_ABI" \
  "$KPM_ENABLED"

rm -rf "$ASSET_DIR"
mkdir -p "$ASSET_DIR"

jq -n \
  --arg profile_id "$PROFILE_ID" \
  --arg target "$TARGET_NAME" \
  --arg device_codenames "$DEVICE_CODENAMES" \
  --arg accepted_device_ids "$DEVICE_NAMES" \
  --arg android_versions "$SUPPORTED_ANDROID_VERSIONS" \
  --arg soc "$SOC" \
  --arg source "$SOURCE_NAME" \
  --arg branch "$KERNEL_BRANCH" \
  --arg modules_branch "$MODULES_BRANCH" \
  --arg kernel_commit "$KERNEL_COMMIT" \
  --arg modules_commit "$MODULES_COMMIT" \
  --arg clang "$CLANG_VERSION" \
  --arg root_solution "$KSU_TYPE" \
  --argjson kpm_enabled "$KPM_ENABLED" \
  --arg ksu_repo "$KSU_REPO" \
  --arg ksu_ref "$KSU_REF" \
  --arg ksu_commit "$KSU_COMMIT" \
  --arg susfs_ref "$SUSFS_REF" \
  --arg susfs_commit "$SUSFS_COMMIT" \
  --arg susfs_version "$SUSFS_VERSION" \
  --arg nomount_ref "$NOMOUNT_REF" \
  --arg nomount_commit "$NOMOUNT_COMMIT" \
  --arg nomount_version "$NOMOUNT_VERSION" \
  --arg zeromount_repo "$ZEROMOUNT_REPO" \
  --arg zeromount_commit "$ZEROMOUNT_COMMIT" \
  --arg zeromount_gki_tag "$ZEROMOUNT_GKI_TAG" \
  --arg zeromount_patch_sha256 "$ZEROMOUNT_PATCH_SHA256" \
  --arg anykernel_commit "$ANYKERNEL_COMMIT" \
  --arg anykernel_busybox_abi "$ANYKERNEL_BUSYBOX_ABI" \
  --arg anykernel_busybox_sha256 "$ANYKERNEL_BUSYBOX_SHA256" \
  --arg anykernel_magiskboot_version "$MAGISK_TOOLS_VERSION" \
  --arg anykernel_magiskboot_sha256 "$ANYKERNEL_MAGISKBOOT_SHA256" \
  --arg builder_commit "$GITHUB_SHA" \
  --arg run_url "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}" \
  --arg built_at "$BUILD_TIMESTAMP" \
  '{
    profile_id: $profile_id,
    target: $target,
    device_codenames: ($device_codenames | split(" ")),
    accepted_device_ids: ($accepted_device_ids | split(" ")),
    supported_android_versions: $android_versions,
    soc: $soc,
    source: $source,
    branch: $branch,
    modules_branch: $modules_branch,
    kernel_commit: $kernel_commit,
    modules_commit: $modules_commit,
    clang: $clang,
    root_solution: $root_solution,
    kpm_enabled: $kpm_enabled,
    kernelsu_repository: $ksu_repo,
    kernelsu_ref: $ksu_ref,
    kernelsu_commit: $ksu_commit,
    susfs_ref: $susfs_ref,
    susfs_commit: $susfs_commit,
    susfs_version: $susfs_version,
    nomount_ref: $nomount_ref,
    nomount_commit: $nomount_commit,
    nomount_version: $nomount_version,
    zeromount_patch_repository: $zeromount_repo,
    zeromount_patch_commit: $zeromount_commit,
    zeromount_gki_tag: $zeromount_gki_tag,
    zeromount_patch_sha256: $zeromount_patch_sha256,
    anykernel_commit: $anykernel_commit,
    anykernel_busybox_abi: $anykernel_busybox_abi,
    anykernel_busybox_sha256: $anykernel_busybox_sha256,
    anykernel_magiskboot_version: $anykernel_magiskboot_version,
    anykernel_magiskboot_sha256: $anykernel_magiskboot_sha256,
    builder_commit: $builder_commit,
    workflow_run: $run_url,
    built_at_utc: $built_at
  }' > "$ASSET_DIR/build-info.json"

cp "$ASSET_DIR/build-info.json" AnyKernel3/build-info.json
cp "${SOC}/out/arch/arm64/boot/Image" AnyKernel3/Image

(
  cd AnyKernel3
  zip -r9 "${ASSET_DIR}/${ZIP_NAME}.zip" . -x .git/\* .github/\*
)
zip -T "$ASSET_DIR/${ZIP_NAME}.zip" >/dev/null

IMAGE_ASSET="Image-${ZIP_NAME}"
cp "${SOC}/out/arch/arm64/boot/Image" "${ASSET_DIR}/${IMAGE_ASSET}"

SUSFS_NOTE="disabled"
NOMOUNT_NOTE="disabled"
ZEROMOUNT_NOTE="disabled"
if [[ -n "$SUSFS_VERSION" ]]; then
  SUSFS_NOTE="v${SUSFS_VERSION} (${SUSFS_REF}, ${SUSFS_COMMIT})"
fi
if [[ -n "$NOMOUNT_VERSION" ]]; then
  NOMOUNT_NOTE="v${NOMOUNT_VERSION} (${NOMOUNT_REF}, ${NOMOUNT_COMMIT})"
fi
if [[ -n "$ZEROMOUNT_COMMIT" ]]; then
  ZEROMOUNT_NOTE="${ZEROMOUNT_GKI_TAG} (${ZEROMOUNT_COMMIT}, sha256:${ZEROMOUNT_PATCH_SHA256})"
fi

cat > "$ASSET_DIR/release-notes.md" <<EOF_NOTES
## Build profile

- Target: ${TARGET_NAME} (${SOC})
- Device codenames: ${DEVICE_CODENAMES}
- Accepted device IDs: ${DEVICE_NAMES}
- Source: ${SOURCE_NAME}
- Branch: ${KERNEL_BRANCH}
- Kernel commit: \`${KERNEL_COMMIT}\`
- Modules branch: ${MODULES_BRANCH}
- Modules commit: \`${MODULES_COMMIT}\`
- Clang: ${CLANG_VERSION}
- Root solution: ${KSU_TYPE}
- KernelSU source: ${KSU_REPO:-disabled} (${KSU_REF:-none}, ${KSU_COMMIT:-none})
- KPM: ${KPM_ENABLED}
- SUSFS: ${SUSFS_NOTE}
- NoMount: ${NOMOUNT_NOTE}
- ZeroMount: ${ZEROMOUNT_NOTE}
- AnyKernel BusyBox: ${ANYKERNEL_BUSYBOX_ABI} (sha256:${ANYKERNEL_BUSYBOX_SHA256})
- AnyKernel MagiskBoot: v${MAGISK_TOOLS_VERSION} (sha256:${ANYKERNEL_MAGISKBOOT_SHA256})

The flashable ZIP performs a device-codename check before modifying the boot partition.
Only flash it on the listed target devices, and keep a known-good stock boot image available.
See \`build-info.json\` and \`SHA256SUMS\` for provenance and integrity data.
EOF_NOTES

(
  cd "$ASSET_DIR"
  sha256sum "${ZIP_NAME}.zip" "$IMAGE_ASSET" build-info.json > SHA256SUMS
)

test -s "$ASSET_DIR/${ZIP_NAME}.zip"
test -s "$ASSET_DIR/$IMAGE_ASSET"
test -s "$ASSET_DIR/SHA256SUMS"
