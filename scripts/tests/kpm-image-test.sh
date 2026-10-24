#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/kpm-image.sh
. "$SCRIPT_DIR/../lib/kpm-image.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/assets"
export KPM_TEST_ASSETS="$fixture/assets"
cat > "$fixture/assets/kptools-linux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mode="$1"
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) image="$2" ;;
    -o) output="$2" ;;
    -s|-k) ;;
    *) exit 9 ;;
  esac
  shift 2
done
case "$mode" in
  -p)
    [[ "${KPM_TEST_MODE:-}" != failure ]] || exit 7
    [[ "${KPM_TEST_MODE:-}" != missing ]] || exit 0
    cp "$image" "$output"
    [[ "${KPM_TEST_MODE:-}" == unchanged ]] || echo payload >> "$output"
    ;;
  -l)
    [[ "${KPM_TEST_MODE:-}" != unpatched ]] || { echo patched=false; exit 0; }
    echo patched=true
    ;;
esac
EOF
cat > "$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    https://*) asset="${1##*/}" ;;
    -o) output="$2"; shift ;;
  esac
  shift
done
cp "$KPM_TEST_ASSETS/$asset" "$output"
[[ "${KPM_TEST_MODE:-}" != corrupt ]] || echo corrupt >> "$output"
EOF
chmod +x "$fixture/bin/curl" "$fixture/assets/kptools-linux"
echo payload > "$fixture/assets/kpimg"
# Fixtures exercise real digest checks without downloading executable tools.
KPM_TOOLS_SHA256="$(sha256sum "$fixture/assets/kptools-linux" | awk '{print $1}')"
KPM_PAYLOAD_SHA256="$(sha256sum "$fixture/assets/kpimg" | awk '{print $1}')"
export PATH="$fixture/bin:$PATH"
for mode in failure missing unchanged unpatched corrupt; do
  echo original > "$fixture/Image"
  rm -f "$fixture/proof.txt"
  if KPM_TEST_MODE="$mode" patch_kpm_image "$fixture/Image" "$fixture/proof.txt" > "$fixture/log" 2>&1; then
    echo "FAIL: KPM patch accepted $mode output"
    exit 1
  fi
  [[ "$(cat "$fixture/Image")" == original && ! -e "$fixture/proof.txt" ]]
done
echo original > "$fixture/Image"
patch_kpm_image "$fixture/Image" "$fixture/proof.txt"
verify_kpm_image_patch "$fixture/Image" "$fixture/proof.txt"
if verify_kpm_image_patch "$fixture/Image" "$fixture/missing-proof" >/dev/null; then
  echo 'FAIL: package gate accepted missing KPM proof'
  exit 1
fi
echo tampered >> "$fixture/Image"
if verify_kpm_image_patch "$fixture/Image" "$fixture/proof.txt" >/dev/null; then
  echo 'FAIL: package gate accepted an Image changed after verification'
  exit 1
fi
echo 'PASS: KPM download integrity, patch failures, atomic replacement, inspection, and package hash gate'
