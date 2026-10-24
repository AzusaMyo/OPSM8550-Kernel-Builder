#!/usr/bin/env bash
# CONFIG_KPM supplies hook stubs; KernelPatch must populate the final Image.

KPM_PATCH_VERSION=0.13.9
KPM_TOOLS_SHA256=6b5122046848865b1f68c04a45e34bbed81c9b535a42646a3ea423ce38a93aeb
KPM_PAYLOAD_SHA256=396a20777668e85d674a23dd3945815f285332b5358be0bfc97297935e2d130b

verify_kpm_image_patch() {
  local image="$1" proof="$2" image_sha
  image_sha="$(sha256sum "$image" | awk '{print $1}')" || return 1
  if [[ ! -s "$proof" ]] ||
     ! grep -Fxq 'patched=true' "$proof" ||
     ! grep -Fxq "patch_version=$KPM_PATCH_VERSION" "$proof" ||
     ! grep -Fxq "tools_sha256=$KPM_TOOLS_SHA256" "$proof" ||
     ! grep -Fxq "payload_sha256=$KPM_PAYLOAD_SHA256" "$proof" ||
     ! grep -Fxq "image_sha256=$image_sha" "$proof"; then
    echo '::error::KPM Image patch proof is missing or does not match the packaged Image.'
    return 1
  fi
}

patch_kpm_image() (
  set -euo pipefail
  local image="$1" proof="$2" stage asset expected actual
  local base="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/$KPM_PATCH_VERSION"
  image="$(realpath "$image")" || exit 1
  proof="$(realpath -m "$proof")" || exit 1
  stage="$(mktemp -d "$(dirname "$image")/.kpm-patch.XXXXXX")" || exit 1
  trap 'rm -rf "$stage"' EXIT
  for asset in kptools-linux kpimg; do
    curl --retry 5 --retry-delay 3 --retry-all-errors -fLSs "$base/$asset" -o "$stage/$asset" || exit 1
    if [[ "$asset" == kptools-linux ]]; then
      expected="$KPM_TOOLS_SHA256"
    else
      expected="$KPM_PAYLOAD_SHA256"
    fi
    actual="$(sha256sum "$stage/$asset" | awk '{print $1}')" || exit 1
    if [[ "$actual" != "$expected" ]]; then
      echo "::error::KPM $asset checksum mismatch."
      exit 1
    fi
  done
  chmod 755 "$stage/kptools-linux"
  # Same invocation as upstream patch_linux, with explicit files and status.
  "$stage/kptools-linux" -p -s 123 -i "$image" -k "$stage/kpimg" -o "$stage/Image" > "$stage/patch.log" 2>&1 || {
    cat "$stage/patch.log"
    exit 1
  }
  test -s "$stage/Image" || { echo '::error::KPM patcher did not produce Image.'; exit 1; }
  if cmp -s "$image" "$stage/Image"; then
    echo '::error::KPM patcher did not change Image.'
    exit 1
  fi
  "$stage/kptools-linux" -l -i "$stage/Image" > "$stage/inspect.txt" || exit 1
  if ! grep -Fxq 'patched=true' "$stage/inspect.txt"; then
    echo '::error::KPM patcher output is not a patched kernel Image.'
    exit 1
  fi
  {
    echo "patch_version=$KPM_PATCH_VERSION"
    echo "tools_sha256=$KPM_TOOLS_SHA256"
    echo "payload_sha256=$KPM_PAYLOAD_SHA256"
    echo "input_sha256=$(sha256sum "$image" | awk '{print $1}')"
    echo "image_sha256=$(sha256sum "$stage/Image" | awk '{print $1}')"
    cat "$stage/inspect.txt"
  } > "$stage/proof.txt"
  mv "$stage/Image" "$image" || exit 1
  mv "$stage/proof.txt" "$proof" || exit 1
  verify_kpm_image_patch "$image" "$proof" || exit 1
  echo "[+] KPM $KPM_PATCH_VERSION injected and verified in final Image."
)
