#!/usr/bin/env bash
# Run the real FinaSU signature matcher with our actual Kbuild arguments.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
commit=be19eb90b9c7b96f265c86b733aa0640a2839bdb
for source_file in Kbuild manager/apk_sign.c; do
  mkdir -p "$fixture/$(dirname "$source_file")"
  curl --retry 3 --retry-all-errors -fLSs \
    "https://raw.githubusercontent.com/LyraVoid/FinaSU/$commit/kernel/$source_file" \
    -o "$fixture/$source_file"
done
python3 "$SCRIPT_DIR/finasu-manager-test.py" "$fixture"
