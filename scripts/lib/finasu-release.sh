#!/usr/bin/env bash
# Reviewed upstream release pair. Update source, APK digest and tests together.
# Variables are consumed by the scripts sourcing this metadata file.
# shellcheck disable=SC2034
FINASU_RELEASE=v1.6.5
FINASU_COMMIT=f96445f966a2c3f4c1257938acf0449757be8a04
FINASU_NOMOUNT_API=23
FINASU_MANAGER_APK=FinaSU_v1.6.5_33213-release.apk
FINASU_MANAGER_URL="https://github.com/LyraVoid/FinaSU/releases/download/$FINASU_RELEASE/$FINASU_MANAGER_APK"
FINASU_MANAGER_APK_SHA256=96acc60da221fba5e8cb906a9e72fc03479eab7603acd005a2f110fedcb19f81
# Extracted from the verified APK v2 signing block; unchanged since v1.2.1.
FINASU_MANAGER_CERT_SIZE=0x02cc
FINASU_MANAGER_CERT_SHA256=2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458

# These v2.4.0 snapshots match the pinned FinaSU command dispatcher.
finasu_susfs_commit() {
  case "$1" in
    gki-android13-5.10) echo 1bea9e8fb4a64920f068e5da43f9751dfe601199 ;;
    gki-android13-5.15) echo fe943d15ec6a1891f7a360bf210589bdffe4e318 ;;
    gki-android14-5.15) echo 10751e3c83f6e63f886cd2af937fd0a34463824b ;;
    gki-android14-6.1) echo 69b8e734920b8f9ed885ab8d112969719698e242 ;;
    *) echo "::error::No FinaSU-compatible SUSFS revision for $1" >&2; return 1 ;;
  esac
}
