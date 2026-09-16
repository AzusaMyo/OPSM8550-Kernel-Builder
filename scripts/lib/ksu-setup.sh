#!/usr/bin/env bash
#
# KernelSU variant setup helpers. Sourced, not executed.
# Depends on lib/git-helpers.sh and lib/kernel-helpers.sh (insert_line_before_first_match,
# ensure_line_in_file, detect_kernelsu_driver_dir, kernelsu_kconfig_source_path).
#

setup_kernelsu_repo() {
  local owner="$1"
  local repo="$2"
  local requested_ref="$3"
  local allow_fallbacks="${4:-0}"
  local repo_dir="$repo"
  local driver_dir
  local kconfig_source
  local ref
  local cloned=0
  local actual_commit
  local refs_to_try

  driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found in kernel tree"
    exit 1
  }
  kconfig_source="$(kernelsu_kconfig_source_path "$driver_dir")"

  rm -rf "$repo_dir"

  refs_to_try="$requested_ref"
  if [[ "$allow_fallbacks" == "1" ]]; then
    refs_to_try="$refs_to_try dev main"
  fi

  for ref in $refs_to_try; do
    [[ -z "$ref" ]] && continue

    rm -rf "$repo_dir"
    git init -q "$repo_dir"
    git -C "$repo_dir" remote add origin "https://github.com/${owner}/${repo}.git"

    if git_fetch_retry "$repo_dir" --depth=1 --no-tags origin "$ref" && \
       git -C "$repo_dir" checkout -q --detach FETCH_HEAD; then
      actual_commit="$(git -C "$repo_dir" rev-parse HEAD)"
      if [[ "$ref" =~ ^[0-9a-f]{40}$ ]] && [[ "$actual_commit" != "$ref" ]]; then
        echo "::error::${owner}/${repo} checkout '$actual_commit' does not match resolved commit '$ref'."
        rm -rf "$repo_dir"
        continue
      fi
      echo "[+] Cloned ${owner}/${repo} at ${actual_commit} (requested '$ref')."
      cloned=1
      break
    fi

    rm -rf "$repo_dir"
    echo "[!] ${owner}/${repo} branch '$ref' is unavailable, trying next fallback..."
  done

  if [[ "$cloned" -ne 1 ]]; then
    echo "::error::Failed to clone ${owner}/${repo} from https://github.com/${owner}/${repo}.git using refs: $refs_to_try"
    exit 1
  fi

  rm -rf "$driver_dir/kernelsu"
  ln -sfn "$(realpath --relative-to="$driver_dir" "$repo_dir/kernel")" "$driver_dir/kernelsu"

  ensure_line_in_file "$driver_dir/Makefile" 'obj-$(CONFIG_KSU) += kernelsu/'
  insert_line_before_first_match "$driver_dir/Kconfig" "endmenu" "source \"$kconfig_source\""

  KSU_REPO_DIR="$(readlink -f "$repo_dir")"
  export KSU_REPO_DIR
  export KSU_KERNEL_DIR="${KSU_REPO_DIR}/kernel"
  export KSU_DRIVER_DIR="$driver_dir"
}

# Apply the chosen KSU preset from the commit resolved during profile setup.
install_ksu_variant() {
  local ksu_type="$1"

  case "$ksu_type" in
    "None")
      ;;
    "Official-KernelSU")
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for Official KernelSU}"
      setup_kernelsu_repo "tiann" "KernelSU" "$KSU_COMMIT"
      ;;
    "KowSU")
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for KowSU}"
      setup_kernelsu_repo "KOWX712" "KernelSU" "$KSU_COMMIT"
      ;;
    "KernelSU-Next")
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for KernelSU-Next}"
      setup_kernelsu_repo "KernelSU-Next" "KernelSU-Next" "$KSU_COMMIT"
      ;;
    "KernelSU-Next-with-susfs"|"KernelSU-Next-with-susfs-zeromount")
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for KernelSU-Next with SUSFS}"
      setup_kernelsu_repo "pershoot" "KernelSU-Next" "$KSU_COMMIT"
      ;;
    "SukiSU-Ultra-with-KPM"|"SukiSU-Ultra-with-susfs-KPM"|"SukiSU-Ultra-with-susfs-nomount-KPM"|"SukiSU-Ultra-with-susfs-zeromount-KPM")
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for SukiSU Ultra}"
      setup_kernelsu_repo "SukiSU-Ultra" "SukiSU-Ultra" "$KSU_COMMIT"
      ;;
    "ReSukiSU"|"ReSukiSU-with-susfs"|"ReSukiSU-with-susfs-nomount"|"ReSukiSU-with-susfs-zeromount")
      : "${KSU_COMMIT:?KSU_COMMIT must be resolved for ReSukiSU}"
      setup_kernelsu_repo "ReSukiSU" "ReSukiSU" "$KSU_COMMIT"
      ;;
    *)
      echo "::error::Unsupported ksu_type: $ksu_type"
      exit 1
      ;;
  esac
}
