#!/usr/bin/env bash
#
# Download the AOSP Clang toolchain requested in $CLANG_VERSION into
# toolchains/${CLANG_VERSION}. Intended to be skipped when the cache hits.
#
set -euo pipefail

: "${CLANG_VERSION:?CLANG_VERSION must be set}"

declare -A CLANG_URLS=(
  [clang-r584948]="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/b896c53892be0ae507473a9f3dce67907edf4965/clang-r584948.tar.gz"
  [clang-r596125]="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/b896c53892be0ae507473a9f3dce67907edf4965/clang-r596125.tar.gz"
  [clang-r416183b1]="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/2cddc8015b6a61bbcb8bb58e55d67e4e4b4db6d2/clang-r416183b1.tar.gz"
  [clang-r450784d]="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/c9c9d70ad5cb62dd761adccd87c34e8a35846a81/clang-r450784d.tar.gz"
  [clang-r487747c]="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/7154d3eddcb62ff7909a6ae2bf0c03e445e65bc4/clang-r487747c.tar.gz"
  [clang-r536225]="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/96266255abde668f1bf100bf2c47363b96b7a21e/clang-r536225.tar.gz"
  [clang-r547379]="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/9916fb51ccb914d62d35ad9a7b9b21d2ef046928/clang-r547379.tar.gz"
  [clang-r563880c]="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/9916fb51ccb914d62d35ad9a7b9b21d2ef046928/clang-r563880c.tar.gz"
)

URL="${CLANG_URLS[$CLANG_VERSION]:-}"
if [[ -z "$URL" ]]; then
  echo "::error::Unsupported clang version: $CLANG_VERSION"
  exit 1
fi

TARGET_DIR="toolchains/${CLANG_VERSION}"
mkdir -p "$TARGET_DIR"

TMP_TAR="$(mktemp --suffix=.tar.gz)"
trap 'rm -f "$TMP_TAR"' EXIT

curl --retry 5 --retry-delay 3 --retry-all-errors -fL "$URL" -o "$TMP_TAR"
tar -xf "$TMP_TAR" -C "$TARGET_DIR"
test -x "$TARGET_DIR/bin/clang"
"$TARGET_DIR/bin/clang" --version | head -n 1
