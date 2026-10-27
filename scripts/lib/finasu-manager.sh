#!/usr/bin/env bash
# FinaSU release-manager identity. Sourced, not executed.
# The public X.509 certificate was extracted from the APK v2 signing block of
# https://github.com/LyraVoid/FinaSU/releases/download/v1.2.1/FinaSU_v1.2.1_33074-release.apk
# APK SHA-256: 785c1cef104b76d50c2f35c8169abad7e18033554ae56bf46f74bff44024ebd0
# Keep these pinned to a verified release; never trust an arbitrary installed APK.
FINASU_MANAGER_CERT_SIZE=0x02cc
FINASU_MANAGER_CERT_SHA256=2d89b50aaf1db013c2b6738f973f48b62ea21a3a8d7216bfec3521065d448458

configure_finasu_manager() {
  [[ "$KSU_TYPE" == FinaSU ]] || return 0

  # Mirror upstream's release workflow. Kbuild selects slot 2 as the trusted
  # FinaSU identity only when it is explicitly marked as a release key.
  MAKE_ARGS+=(
    "KSU_EXPECTED_SIZE2=$FINASU_MANAGER_CERT_SIZE"
    "KSU_EXPECTED_HASH2=$FINASU_MANAGER_CERT_SHA256"
    KSU_SECOND_SIGNATURE_RELEASE=1
  )
  echo "[config] FinaSU release manager certificate: $FINASU_MANAGER_CERT_SHA256 ($FINASU_MANAGER_CERT_SIZE bytes)"
}

verify_finasu_manager_binary() {
  local image="$1"
  local proof="$2"

  if ! strings "$image" | grep -Fx "$FINASU_MANAGER_CERT_SHA256" >/dev/null; then
    echo "::error::FinaSU release manager certificate is missing from $image."
    return 1
  fi
  {
    echo "manager_package=me.yuki.fina"
    echo "manager_reference_release=v1.2.1"
    echo "manager_certificate_size=$FINASU_MANAGER_CERT_SIZE"
    echo "manager_certificate_sha256=$FINASU_MANAGER_CERT_SHA256"
    echo "image_sha256=$(sha256sum "$image" | awk '{print $1}')"
  } > "$proof"
  echo '[+] FinaSU release manager certificate verified in final Image.'
}
