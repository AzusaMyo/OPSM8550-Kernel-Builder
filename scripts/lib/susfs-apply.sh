#!/usr/bin/env bash
#
# susfs patching helpers and the end-to-end apply routine. Sourced, not
# executed. Depends on lib/git-helpers.sh and lib/kernel-helpers.sh.
#

version_is_at_least() {
  local actual="$1"
  local minimum="$2"
  [[ "$(printf '%s\n' "$minimum" "$actual" | sort -V | head -n 1)" == "$minimum" ]]
}

is_sukisu_susfs_variant() {
  case "${KSU_TYPE:-}" in
    SukiSU-Ultra-with-susfs-KPM|SukiSU-Ultra-with-susfs-nomount-KPM) return 0 ;;
    *) return 1 ;;
  esac
}

apply_susfs_task_mmu_fix() {
  local file="fs/proc/task_mmu.c"
  local block

  if grep -q 'susfs_def.h' "$file"; then
    echo "[+] task_mmu.c already includes susfs_def.h."
    return 0
  fi

  block=$'#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n#include <linux/susfs_def.h>\n#endif // #if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\n'

  if insert_block_before_first_match "$file" '#include <asm/elf.h>' "$block" 'susfs_def.h'; then
    echo "[+] Applied fallback susfs include fix to task_mmu.c."
    return 0
  fi

  echo "[-] Could not find a stable insertion point in $file."
  return 1
}

apply_susfs_namespace_fix() {
  local file="fs/namespace.c"
  local block

  if grep -q '^#include <linux/susfs_def.h>$' "$file" && \
     grep -q '^extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;$' "$file" && \
     grep -q '^#define CL_COPY_MNT_NS ' "$file"; then
    echo "[+] namespace.c already contains the susfs mount declarations."
    return 0
  fi

  if grep -qE '^#include <linux/susfs_def.h>$|^extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;$|^#define CL_COPY_MNT_NS ' "$file"; then
    echo "[-] Refusing to modify a partially applied susfs declaration block in $file."
    return 1
  fi

  block=$'#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n\n#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n\n#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n'

  if insert_block_before_first_match "$file" '/* Maximum number of mounts in a mount namespace */' "$block" 'extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;'; then
    echo "[+] Applied fallback susfs declaration fix to namespace.c."
    return 0
  fi

  echo "[-] Could not find a stable insertion point in $file."
  return 1
}

resolve_known_susfs_rejects() {
  local reject
  local unknown=0
  local reject_files=()

  mapfile -t reject_files < <(find . -name '*.rej' -print | sort)
  [[ "${#reject_files[@]}" -gt 0 ]] || return 1

  for reject in "${reject_files[@]}"; do
    case "$reject" in
      ./fs/proc/task_mmu.c.rej)
        grep -q 'susfs_def.h' "$reject" && apply_susfs_task_mmu_fix || unknown=1
        ;;
      ./fs/namespace.c.rej)
        grep -q 'susfs_def.h' "$reject" && apply_susfs_namespace_fix || unknown=1
        ;;
      *)
        unknown=1
        ;;
    esac
  done

  [[ "$unknown" -eq 0 ]] || return 1
  rm -f "${reject_files[@]}"
  echo "[+] Resolved ${#reject_files[@]} known susfs include/declaration drift reject(s)."
}

patch_susfs_kernelsu_layout() {
  local file="fs/susfs.c"
  local driver_dir
  local target_include

  [[ -f "$file" ]] || return 0

  driver_dir="$(detect_kernelsu_driver_dir)" || return 0
  target_include="../${driver_dir}/kernelsu/hook/core_hook.h"

  if [[ -f "${driver_dir}/kernelsu/hook/core_hook.h" ]] && [[ ! -f "${driver_dir}/kernelsu/core_hook.h" ]]; then
    sed -i "s|\"\\.\\./drivers/kernelsu/core_hook.h\"|\"${target_include}\"|" "$file"
    echo "[+] Patched susfs core_hook include for nested KernelSU layout."
  fi
}

resolve_known_sukisu_susfs_rejects() {
  local ksu_repo_dir="$1"
  local ksu_dir="$2"
  local init_file="${ksu_dir}/core/init.c"
  local kernel_umount_file="${ksu_dir}/feature/kernel_umount.c"
  local allowlist_file="${ksu_dir}/policy/allowlist.c"
  local kbuild_file="${ksu_dir}/Kbuild"
  local symbol_resolver_file="${ksu_dir}/infra/symbol_resolver.c"
  local core_compat_patch
  local policy_compat_patch
  local reject
  local relative_reject
  local has_policy_drift=0
  local reject_files=()
  local reject_relatives=()

  is_sukisu_susfs_variant || return 1

  mapfile -t reject_files < <(find "$ksu_repo_dir" -name '*.rej' -print | sort)
  for reject in "${reject_files[@]}"; do
    relative_reject="$(realpath --relative-to="$ksu_repo_dir" "$reject")"
    reject_relatives+=("$relative_reject")
  done

  case "${#reject_relatives[@]}" in
    1)
      [[ "${reject_relatives[0]}" == "kernel/core/init.c.rej" ]] || return 1
      ;;
    3)
      [[ "${reject_relatives[0]}" == "kernel/core/init.c.rej" ]] || return 1
      [[ "${reject_relatives[1]}" == "kernel/feature/kernel_umount.c.rej" ]] || return 1
      [[ "${reject_relatives[2]}" == "kernel/policy/allowlist.c.rej" ]] || return 1
      has_policy_drift=1
      ;;
    *)
      return 1
      ;;
  esac

  grep -q 'ksu_init_symbol_resolver' "${ksu_repo_dir}/kernel/core/init.c.rej" || return 1
  grep -q 'ksu_syscall_hook_manager_init' "${ksu_repo_dir}/kernel/core/init.c.rej" || return 1

  if [[ "$has_policy_drift" -eq 1 ]]; then
    grep -Fq 'Webview zygote forked from zygote: zygote -> webview_zygote' \
      "${ksu_repo_dir}/kernel/feature/kernel_umount.c.rej" || return 1
    grep -Fq 'ksu_uid_should_umount(new_uid)' \
      "${ksu_repo_dir}/kernel/feature/kernel_umount.c.rej" || return 1
    grep -Fq 'ksu_get_manager_appid() == uid % PER_USER_RANGE' \
      "${ksu_repo_dir}/kernel/policy/allowlist.c.rej" || return 1
  fi

  test -f "$init_file" || return 1
  grep -Fq '#include "feature/uts_spoof.h"' "$init_file" || return 1
  grep -Fq 'if (spoof_release || spoof_version)' "$init_file" || return 1
  grep -Fq '#include <linux/susfs.h>' "$init_file" || return 1
  grep -Fq 'ksu_init_symbol_resolver();' "$init_file" || return 1
  grep -Fq 'ksu_syscall_hook_manager_init();' "$init_file" || return 1

  test -f "$kbuild_file" || return 1
  test -f "$symbol_resolver_file" || return 1
  grep -Fq 'unsigned long __nocfi find_kernel_symbol_exact' "$symbol_resolver_file" || return 1
  grep -Fq 'obj-$(CONFIG_KPM) += kpm/compact.o' "$kbuild_file" || return 1
  if grep -Fq 'kernelsu-objs += infra/symbol_resolver.o' "$kbuild_file"; then
    return 1
  fi

  core_compat_patch="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../patches/sukisu-susfs-core-init-compat.patch"
  test -f "$core_compat_patch" || return 1

  if [[ "$has_policy_drift" -eq 1 ]]; then
    test -f "$kernel_umount_file" || return 1
    test -f "$allowlist_file" || return 1
    grep -Fq 'webview_zygote (controlled by feature policy)' "$kernel_umount_file" || return 1
    grep -Fq 'ksu_uid_should_umount(new_uid)' "$kernel_umount_file" || return 1
    grep -Fq 'ksu_get_manager_appid() == uid % PER_USER_RANGE' "$allowlist_file" || return 1
    grep -Fq 'if (unlikely(uid == WEBVIEW_ZYGOTE_UID))' "$allowlist_file" || return 1

    policy_compat_patch="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../patches/sukisu-susfs-policy-compat.patch"
    test -f "$policy_compat_patch" || return 1
  fi

  (
    cd "$ksu_repo_dir" || exit 1
    patch --batch --forward -p1 < "$core_compat_patch"
    if [[ "$has_policy_drift" -eq 1 ]]; then
      patch --batch --forward -p1 < "$policy_compat_patch"
    fi
  ) || return 1

  grep -Fq '#include "feature/uts_spoof.h"' "$init_file" || return 1
  grep -Fq 'ksu_spoof_version(spoof_release, spoof_version);' "$init_file" || return 1
  grep -Fq 'susfs_init();' "$init_file" || return 1
  grep -Fq 'ksu_setuid_hook_init();' "$init_file" || return 1
  grep -Fq 'ksu_sucompat_init();' "$init_file" || return 1
  grep -Fq '#include "infra/symbol_resolver.h"' "$init_file" || return 1
  grep -Fq 'ksu_init_symbol_resolver();' "$init_file" || return 1
  grep -Fq 'kernelsu-objs += infra/symbol_resolver.o' "$kbuild_file" || return 1

  if grep -Eq 'ksu_(late_loaded|bundled)|ksu_syscall_hook_(init|manager_init)|ksu_lsm_hook_init' "$init_file"; then
    return 1
  fi

  if [[ "$has_policy_drift" -eq 1 ]]; then
    if grep -Eq 'ksu_uid_should_umount\(new_uid\)|is_zygote_child = is_zygote' "$kernel_umount_file"; then
      return 1
    fi
    if grep -Fq 'ksu_get_manager_appid() == uid % PER_USER_RANGE' "$allowlist_file"; then
      return 1
    fi
    grep -Fq 'if (unlikely(uid == WEBVIEW_ZYGOTE_UID))' "$allowlist_file" || return 1
    grep -Fq 'return ksu_webview_zygote_umount_enabled;' "$allowlist_file" || return 1
  fi

  rm -f "${reject_files[@]}"
  echo "[+] Resolved recognized SukiSU Ultra UTS-spoof/KPM resolver/policy drift in the SUSFS patch."
}

patch_kernelsu_for_susfs() {
  local ksu_repo_dir="$1"
  local ksu_dir="$2"
  local patch_file="${ksu_repo_dir}/10_enable_susfs_for_ksu.patch"
  local kconfig_file="${ksu_dir}/Kconfig"

  test -f "$kconfig_file" || {
    echo "::error::KernelSU Kconfig not found at $kconfig_file"
    exit 1
  }

  if grep -q 'KSU_SUSFS' "$kconfig_file"; then
    echo "[+] KernelSU tree already contains KSU_SUSFS entries."
    return 0
  fi

  test -f "$patch_file" || {
    echo "::error::Missing KernelSU susfs patch at $patch_file"
    exit 1
  }

  if ! (
    cd "$ksu_repo_dir"
    patch --batch --forward -p1 < "$(basename "$patch_file")"
  ); then
    echo "[!] KernelSU SUSFS patch reported conflicts, checking recognized SukiSU Ultra drift..."
    if ! resolve_known_sukisu_susfs_rejects "$ksu_repo_dir" "$ksu_dir"; then
      echo "::error::Failed to apply KernelSU susfs patch in $ksu_repo_dir"
      find "$ksu_repo_dir" -name '*.rej' -print -exec sh -c 'echo "---- $1 ----"; cat "$1"' _ {} \;
      exit 1
    fi
  fi

  if find "$ksu_repo_dir" -name '*.rej' -print -quit | grep -q .; then
    echo "::error::KernelSU susfs integration left unresolved reject files in $ksu_repo_dir"
    find "$ksu_repo_dir" -name '*.rej' -print
    exit 1
  fi

  grep -q 'KSU_SUSFS' "$kconfig_file" || {
    echo "::error::KernelSU susfs patch applied but KSU_SUSFS is still missing from $kconfig_file"
    exit 1
  }
}

patch_resukisu_susfs_runtime_compat() {
  local ksu_kernel_dir="$1"
  local runtime_file="${ksu_kernel_dir}/runtime/ksud_integration.c"

  [[ -f "$runtime_file" ]] || return 0
  grep -q 'CONFIG_KSU_SUSFS' "$runtime_file" || return 0

  if grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file" && \
     grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
    echo "[+] ReSukiSU runtime already contains native susfs hook support."
    return 0
  fi

  sed -i \
    -e 's/^extern struct static_key_false ksu_init_rc_hook_key_false;$/extern struct static_key_true ksu_is_init_rc_hook_enabled;/' \
    -e 's/^extern struct static_key_false ksu_input_hook_key_false;$/extern struct static_key_true ksu_is_input_hook_enabled;/' \
    -e 's/^#define ksu_init_rc_hook ksu_init_rc_hook_key_false$/#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled/' \
    -e 's/^#define ksu_input_hook ksu_input_hook_key_false$/#define ksu_input_hook ksu_is_input_hook_enabled/' \
    "$runtime_file"

  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "#define ksu_init_rc_hook_key_false ksu_is_init_rc_hook_enabled"
  insert_line_before_first_match "$runtime_file" "// use define to avoid ifdef" "#define ksu_input_hook_key_false ksu_is_input_hook_enabled"

  grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" || {
    echo "::error::Failed to inject ksu_is_init_rc_hook_enabled compatibility into ${runtime_file}"
    exit 1
  }

  grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" || {
    echo "::error::Failed to inject ksu_is_input_hook_enabled compatibility into ${runtime_file}"
    exit 1
  }

  if ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled$' "$runtime_file" && \
     ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file"; then
    echo "::error::Failed to retarget init_rc hook to the susfs static key in ${runtime_file}"
    exit 1
  fi

  if ! grep -Eq '^[[:space:]]*#define ksu_input_hook ksu_is_input_hook_enabled$' "$runtime_file" && \
     ! grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
    echo "::error::Failed to retarget input hook to the susfs static key in ${runtime_file}"
    exit 1
  fi
}

patch_susfs_selinux_hide_compat() {
  local ksu_kernel_dir="$1"
  local kbuild_file="${ksu_kernel_dir}/Kbuild"
  [[ -f "$kbuild_file" ]] || kbuild_file="${ksu_kernel_dir}/Makefile"
  local compat_dir="${ksu_kernel_dir}/compat"
  local compat_file="${compat_dir}/susfs_selinux_hide_compat.c"
  local compat_obj_line='kernelsu-objs += compat/susfs_selinux_hide_compat.o'
  local fake_state_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*struct[[:space:]]+selinux_state[[:space:]]+fake_state([[:space:];=]|$)'
  local running_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*bool[[:space:]]+ksu_selinux_hide_running([[:space:];=]|$)'

  if grep -R --exclude='susfs_selinux_hide_compat.c' -Eq "$fake_state_def_re" "$ksu_kernel_dir" && \
     grep -R --exclude='susfs_selinux_hide_compat.c' -Eq "$running_def_re" "$ksu_kernel_dir"; then
    if [[ -f "$kbuild_file" ]]; then
      sed -i "\|^${compat_obj_line}$|d" "$kbuild_file"
    fi
    rm -f "$compat_file"
    echo "[+] KernelSU tree already exports susfs SELinux hide compatibility symbols."
    return 0
  fi

  test -f "$kbuild_file" || {
    echo "::error::KernelSU Kbuild not found at $kbuild_file"
    exit 1
  }

  mkdir -p "$compat_dir"
  cat > "$compat_file" <<'EOF_COMPAT'
#include <linux/cache.h>
#include <linux/types.h>
#include "security.h"

#ifdef CONFIG_KSU_SUSFS
struct selinux_state fake_state;
bool ksu_selinux_hide_running __read_mostly = false;
#endif
EOF_COMPAT

  ensure_line_in_file "$kbuild_file" "$compat_obj_line"
  echo "[+] Added susfs SELinux hide compatibility symbols for this KernelSU tree."
}

# Full susfs apply flow: clone susfs, copy patches, patch KernelSU tree,
# apply the kernel-side patch with drift recovery.
apply_susfs_full() {
  local susfs_ref="$1"
  local susfs_commit="$2"
  local susfs_patch_file="$3"
  local ksu_driver_dir ksu_kernel_dir ksu_repo_dir

  : "${SUSFS_REPO:?SUSFS_REPO must be resolved before applying susfs}"

  ksu_driver_dir="$(detect_kernelsu_driver_dir)" || {
    echo "::error::drivers directory not found before applying susfs"
    exit 1
  }
  ksu_kernel_dir="$(readlink -f "${ksu_driver_dir}/kernelsu")"
  ksu_repo_dir="$(dirname "${ksu_kernel_dir}")"

  rm -rf susfs
  git init -q susfs
  git -C susfs remote add origin "$SUSFS_REPO"
  git_fetch_retry susfs --depth=1 --no-tags origin "$susfs_commit"
  git -C susfs checkout -q --detach FETCH_HEAD
  test "$(git -C susfs rev-parse HEAD)" = "$susfs_commit" || {
    echo "::error::susfs checkout does not match resolved commit $susfs_commit ($susfs_ref)."
    exit 1
  }

  : "${SUSFS_MIN_VERSION:?SUSFS_MIN_VERSION must be resolved before applying SUSFS}"
  SUSFS_VERSION="$(sed -nE 's/^#define SUSFS_VERSION "v?([^"]+)"/\1/p' \
    susfs/kernel_patches/include/linux/susfs.h | head -n 1)"
  if [[ -z "$SUSFS_VERSION" ]]; then
    echo "::error::Could not detect the SUSFS version at $susfs_commit."
    exit 1
  fi
  if ! version_is_at_least "$SUSFS_VERSION" "$SUSFS_MIN_VERSION"; then
    echo "::error::SUSFS v${SUSFS_VERSION} is older than required v${SUSFS_MIN_VERSION}."
    exit 1
  fi
  export SUSFS_VERSION
  echo "SUSFS_VERSION=$SUSFS_VERSION" >> "$GITHUB_ENV"
  echo "[+] Using SUSFS v${SUSFS_VERSION} from $susfs_commit ($susfs_ref)."

  (
    cd susfs || exit 1
    cp "./kernel_patches/${susfs_patch_file}" ..
    cp ./kernel_patches/fs/* ../fs/
    cp ./kernel_patches/include/linux/* ../include/linux/
  )

  cp ./susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch "${ksu_repo_dir}/"
  mkdir -p "${ksu_kernel_dir}/include/linux"
  cp ./susfs/kernel_patches/include/linux/* "${ksu_kernel_dir}/include/linux/"
  patch_kernelsu_for_susfs "${ksu_repo_dir}" "${ksu_kernel_dir}"
  if [[ "$KSU_TYPE" == ReSukiSU* ]]; then
    patch_resukisu_susfs_runtime_compat "${ksu_kernel_dir}"
  fi
  patch_susfs_selinux_hide_compat "${ksu_kernel_dir}"

  test -f include/linux/susfs_def.h || {
    echo "::error::susfs_def.h was not copied into include/linux from $susfs_ref"
    find include/linux -maxdepth 1 -type f -name 'susfs*' -print || true
    exit 1
  }

  test -f "${ksu_kernel_dir}/include/linux/susfs_def.h" || {
    echo "::error::susfs_def.h was not copied into ${ksu_kernel_dir}/include/linux from $susfs_ref"
    find "${ksu_kernel_dir}/include/linux" -maxdepth 1 -type f -name 'susfs*' -print || true
    exit 1
  }

  if ! patch -p1 < "${susfs_patch_file}"; then
    echo "[!] susfs patch reported conflicts, checking for known vendor include drift..."

    if ! resolve_known_susfs_rejects; then
      echo "==== PATCH FAILED ===="
      echo "==== REJECT FILES ===="
      find . -name "*.rej" -print -exec sh -c 'echo "---- $1 ----"; cat "$1"' _ {} \;
      exit 1
    fi
  fi

  patch_susfs_kernelsu_layout

  # Export for downstream verification
  export KSU_KERNEL_DIR="$ksu_kernel_dir"
  export KSU_REPO_DIR="$ksu_repo_dir"
}
