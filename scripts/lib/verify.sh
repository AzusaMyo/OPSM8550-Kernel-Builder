#!/usr/bin/env bash
#
# Post-patch/post-build verification helpers. Sourced, not executed.
#

verify_kpm_source_integration() {
  local ksu_kernel_dir="$1"
  local kpm_object

  test -f "${ksu_kernel_dir}/kpm/kpm.c" || {
    echo "::error::SukiSU KPM loader source is missing at ${ksu_kernel_dir}/kpm/kpm.c."
    exit 1
  }
  test -f "${ksu_kernel_dir}/kpm/compact.c" || {
    echo "::error::SukiSU KPM compatibility source is missing at ${ksu_kernel_dir}/kpm/compact.c."
    exit 1
  }
  test -f "${ksu_kernel_dir}/kpm/super_access.c" || {
    echo "::error::SukiSU KPM structure-access source is missing at ${ksu_kernel_dir}/kpm/super_access.c."
    exit 1
  }
  grep -Eq '^[[:space:]]*config KPM$' "${ksu_kernel_dir}/Kconfig" || {
    echo "::error::SukiSU Kconfig does not expose CONFIG_KPM."
    exit 1
  }
  for kpm_object in compact kpm super_access; do
    grep -Fq "obj-\$(CONFIG_KPM) += kpm/${kpm_object}.o" "${ksu_kernel_dir}/Kbuild" || {
      echo "::error::SukiSU Kbuild does not wire kpm/${kpm_object}.o."
      exit 1
    }
  done
  grep -q 'sukisu_handle_kpm' "${ksu_kernel_dir}/kpm/kpm.c" || {
    echo "::error::SukiSU KPM loader does not expose the expected manager handler."
    exit 1
  }
  grep -Fq 'kernelsu-objs += infra/symbol_resolver.o' "${ksu_kernel_dir}/Kbuild" || {
    echo "::error::SukiSU KPM symbol resolver is not linked into kernelsu.o."
    exit 1
  }
  grep -Fq 'find_kernel_symbol_exact' "${ksu_kernel_dir}/infra/symbol_resolver.c" || {
    echo "::error::SukiSU KPM symbol resolver implementation is missing."
    exit 1
  }

  {
    echo "==== KPM SOURCE PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "modules_branch=${MODULES_BRANCH}"
    echo "modules_commit=${MODULES_COMMIT}"
    echo "sukisu_commit=${KSU_COMMIT}"
    grep -nE '^[[:space:]]*config KPM$|^[[:space:]]*select KALLSYMS(_ALL)?$' "${ksu_kernel_dir}/Kconfig" || true
    grep -Fn 'obj-$(CONFIG_KPM)' "${ksu_kernel_dir}/Kbuild" || true
    grep -Fn 'kernelsu-objs += infra/symbol_resolver.o' "${ksu_kernel_dir}/Kbuild" || true
    grep -nE 'sukisu_(handle_kpm|kpm_load_module_path|kpm_unload_module)' "${ksu_kernel_dir}/kpm/kpm.c" | head -n 20 || true
  } | tee kpm-source-proof.txt
}

verify_kpm_binary_presence() {
  local symbol_hits=0
  local object_file="out/${KSU_DRIVER_DIR:?}/kernelsu/kpm/kpm.o"
  local resolver_object="out/${KSU_DRIVER_DIR}/kernelsu/infra/symbol_resolver.o"
  local llvm_nm="${CLANG_ROOT:?}/llvm-nm"

  # The composite kernelsu.o is an LTO intermediate. GNU nm cannot reliably
  # report its LLVM symbols even though the final vmlinux resolves their users.
  # Inspect the defining bitcode object with llvm-nm from the active toolchain.
  if [[ ! -x "$llvm_nm" ]]; then
    echo "::error::AOSP Clang llvm-nm is missing at ${llvm_nm}."
    exit 1
  fi

  if [[ ! -f "$resolver_object" ]] || \
     ! "$llvm_nm" --defined-only "$resolver_object" 2>/dev/null | \
       grep -E '[[:space:]][Tt][[:space:]]+find_kernel_symbol_exact([.$][^[:space:]]*)?$' >/dev/null; then
    echo "::error::CONFIG_KPM=y, but compiled symbol_resolver.o does not define find_kernel_symbol_exact according to llvm-nm."
    exit 1
  fi

  if [[ -f "$object_file" ]]; then
    nm "$object_file" | grep -E 'sukisu_(handle_kpm|kpm_load_module_path|kpm_unload_module)' && symbol_hits=1 || true
  fi
  if [[ -f out/System.map ]]; then
    grep -E 'sukisu_(handle_kpm|kpm_load_module_path|kpm_unload_module)' out/System.map && symbol_hits=1 || true
  fi
  if [[ -f out/vmlinux ]]; then
    nm out/vmlinux | grep -E 'sukisu_(handle_kpm|kpm_load_module_path|kpm_unload_module)' && symbol_hits=1 || true
  fi
  if [[ "$symbol_hits" -eq 0 ]]; then
    echo "::error::CONFIG_KPM=y, but no SukiSU KPM signature was found in the final kernel artifacts."
    exit 1
  fi

  {
    echo "==== KPM BINARY PROOF ===="
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "sukisu_commit=${KSU_COMMIT}"
    echo "resolver_object=${resolver_object}"
    echo "resolver_nm=${llvm_nm}"
    "$llvm_nm" --defined-only "$resolver_object" 2>/dev/null | \
      grep -E 'find_kernel_symbol_exact([.$][^[:space:]]*)?$' | head -n 20 || true
    if [[ -f "$object_file" ]]; then
      nm "$object_file" | grep -E 'sukisu_(handle_kpm|kpm_load_module_path|kpm_unload_module)' | head -n 20 || true
    fi
    if [[ -f out/System.map ]]; then
      grep -E 'sukisu_(handle_kpm|kpm_load_module_path|kpm_unload_module)' out/System.map | head -n 20 || true
    fi
    if [[ -f out/vmlinux ]]; then
      nm out/vmlinux | grep -E 'sukisu_(handle_kpm|kpm_load_module_path|kpm_unload_module)' | head -n 20 || true
    fi
  } | tee kpm-proof.txt
}

verify_susfs_source_integration() {
  local ksu_kernel_dir="$1"
  local runtime_file="${ksu_kernel_dir}/runtime/ksud_integration.c"

  test -f fs/susfs.c || {
    echo "::error::fs/susfs.c is missing after applying susfs patches."
    exit 1
  }

  test -f include/linux/susfs.h || {
    echo "::error::include/linux/susfs.h is missing after applying susfs patches."
    exit 1
  }

  test -f include/linux/susfs_def.h || {
    echo "::error::include/linux/susfs_def.h is missing after applying susfs patches."
    exit 1
  }

  grep -Fq "#define SUSFS_VERSION \"v${SUSFS_VERSION}\"" include/linux/susfs.h || {
    echo "::error::Integrated SUSFS headers do not report expected version v${SUSFS_VERSION}."
    exit 1
  }

  grep -Fq 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || {
    echo "::error::fs/Makefile does not reference susfs.o after applying susfs patches."
    exit 1
  }

  grep -q 'ksu_handle_sys_reboot' kernel/reboot.c || {
    echo "::error::kernel/reboot.c is missing the susfs reboot hook after applying susfs patches."
    exit 1
  }

  grep -R -q 'CMD_SUSFS_SHOW_VERSION' "$ksu_kernel_dir" || {
    echo "::error::KernelSU tree does not expose CMD_SUSFS_SHOW_VERSION, so the manager will not detect susfs."
    exit 1
  }

  if grep -R -q 'ksu_selinux_hide_running' security/selinux; then
    local fake_state_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*struct[[:space:]]+selinux_state[[:space:]]+fake_state([[:space:];=]|$)'
    local running_def_re='^[[:space:]]*(__[A-Za-z0-9_]+[[:space:]]+)*bool[[:space:]]+ksu_selinux_hide_running([[:space:];=]|$)'

    grep -R -Eq "$fake_state_def_re" "$ksu_kernel_dir" || {
      echo "::error::KernelSU tree does not define fake_state required by the susfs SELinux hooks."
      exit 1
    }
    grep -R -Eq "$running_def_re" "$ksu_kernel_dir" || {
      echo "::error::KernelSU tree does not define ksu_selinux_hide_running required by the susfs SELinux hooks."
      exit 1
    }
  fi

  if [[ "$KSU_TYPE" == ReSukiSU* ]]; then
    test -f "$runtime_file" || {
      echo "::error::ReSukiSU runtime file is missing at ${runtime_file}"
      exit 1
    }

    grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_init_rc_hook_enabled\);$' "$runtime_file" || {
      echo "::error::ReSukiSU runtime compat is missing ksu_is_init_rc_hook_enabled, so susfs builds will fail or silently fall back."
      exit 1
    }

    grep -Eq '^[[:space:]]*DEFINE_STATIC_KEY_TRUE\(ksu_is_input_hook_enabled\);$' "$runtime_file" || {
      echo "::error::ReSukiSU runtime compat is missing ksu_is_input_hook_enabled, so susfs builds will fail or silently fall back."
      exit 1
    }

    if ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook ksu_is_init_rc_hook_enabled$' "$runtime_file" && \
       ! grep -Eq '^[[:space:]]*#define ksu_init_rc_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_init_rc_hook_enabled\)\)$' "$runtime_file"; then
      echo "::error::ReSukiSU runtime compat is not pointing init_rc hook to the susfs static key."
      exit 1
    fi

    if ! grep -Eq '^[[:space:]]*#define ksu_input_hook ksu_is_input_hook_enabled$' "$runtime_file" && \
       ! grep -Eq '^[[:space:]]*#define ksu_input_hook_inactive\(\) \(!static_branch_likely\(&ksu_is_input_hook_enabled\)\)$' "$runtime_file"; then
      echo "::error::ReSukiSU runtime compat is not pointing input hook to the susfs static key."
      exit 1
    fi
  fi

  {
    echo "==== SUSFS SOURCE PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "modules_branch=${MODULES_BRANCH}"
    echo "modules_commit=${MODULES_COMMIT}"
    echo "ksu_commit=${KSU_COMMIT}"
    echo "susfs_ref=${SUSFS_REF}"
    echo "susfs_commit=${SUSFS_COMMIT}"
    echo "susfs_version=${SUSFS_VERSION}"
    echo "susfs_min_version=${SUSFS_MIN_VERSION}"
    echo "susfs_patch=${SUSFS_PATCH_FILE}"
    grep -Fn 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' fs/Makefile || true
    grep -n 'ksu_handle_sys_reboot' kernel/reboot.c | head -n 5 || true
    grep -R -n 'CMD_SUSFS_SHOW_VERSION' "$ksu_kernel_dir" | head -n 10 || true
    grep -R -nE 'fake_state|ksu_selinux_hide_running' "$ksu_kernel_dir" | head -n 10 || true
    if [[ -f "$runtime_file" ]]; then
      grep -nE 'ksu_is_init_rc_hook_enabled|ksu_is_input_hook_enabled|ksu_init_rc_hook_key_false|ksu_input_hook_key_false' "$runtime_file" | head -n 20 || true
    fi
  } | tee susfs-source-proof.txt
}

verify_susfs_binary_presence() {
  local symbol_hits=0
  local string_hits=0

  if [[ -f out/fs/susfs.o ]]; then
    nm out/fs/susfs.o | grep -E 'susfs_(init|show_version|get_enabled_features)' && symbol_hits=1 || true
    strings out/fs/susfs.o | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION' && string_hits=1 || true
  fi

  if [[ -f out/System.map ]]; then
    grep -E 'susfs_(init|show_version|get_enabled_features)' out/System.map && symbol_hits=1 || true
  fi

  if [[ -f out/vmlinux ]]; then
    strings out/vmlinux | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION|CONFIG_KSU_SUSFS_SUS_MOUNT' && string_hits=1 || true
  fi

  if [[ "$symbol_hits" -eq 0 && "$string_hits" -eq 0 ]]; then
    echo "::error::susfs config flags were enabled, but no susfs signature was found in the final kernel artifacts."
    exit 1
  fi

  {
    echo "==== SUSFS BINARY PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "modules_branch=${MODULES_BRANCH}"
    echo "modules_commit=${MODULES_COMMIT}"
    echo "ksu_commit=${KSU_COMMIT}"
    echo "susfs_ref=${SUSFS_REF}"
    echo "susfs_commit=${SUSFS_COMMIT}"
    echo "susfs_version=${SUSFS_VERSION}"
    echo "susfs_patch=${SUSFS_PATCH_FILE}"
    if [[ -f out/fs/susfs.o ]]; then
      nm out/fs/susfs.o | grep -E 'susfs_(init|show_version|get_enabled_features)' | head -n 20 || true
      strings out/fs/susfs.o | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION' | head -n 20 || true
    fi
    if [[ -f out/System.map ]]; then
      grep -E 'susfs_(init|show_version|get_enabled_features)' out/System.map | head -n 20 || true
    fi
    if [[ -f out/vmlinux ]]; then
      strings out/vmlinux | grep -E 'susfs is initialized! version:|CMD_SUSFS_SHOW_VERSION|CONFIG_KSU_SUSFS_' | head -n 20 || true
    fi
  } | tee susfs-proof.txt
}

verify_nomount_source_integration() {
  local fs_dir="${NOMOUNT_FS_DIR:?}"

  test -f "$fs_dir/nomount/nomount.c" || {
    echo "::error::NoMount source is missing at $fs_dir/nomount/nomount.c."
    exit 1
  }
  test -f "$fs_dir/nomount/nomount.h" || {
    echo "::error::NoMount header is missing at $fs_dir/nomount/nomount.h."
    exit 1
  }
  grep -Fq 'obj-$(CONFIG_NOMOUNT) += nomount/' "$fs_dir/Makefile" || {
    echo "::error::$fs_dir/Makefile does not reference the NoMount directory."
    exit 1
  }
  grep -Fq "source \"${fs_dir}/nomount/Kconfig\"" "$fs_dir/Kconfig" || {
    echo "::error::$fs_dir/Kconfig does not include the NoMount Kconfig."
    exit 1
  }
  grep -Fq "#define NOMOUNT_VERSION \"${NOMOUNT_VERSION}\"" "$fs_dir/nomount/nomount.h" || {
    echo "::error::Integrated NoMount headers do not report expected version ${NOMOUNT_VERSION}."
    exit 1
  }
}

verify_zeromount_source_integration() {
  test -f fs/zeromount.c || {
    echo "::error::ZeroMount driver source is missing at fs/zeromount.c."
    exit 1
  }
  test -f include/linux/zeromount.h || {
    echo "::error::ZeroMount public header is missing at include/linux/zeromount.h."
    exit 1
  }
  grep -Fq 'obj-$(CONFIG_ZEROMOUNT)' fs/Makefile || {
    echo "::error::fs/Makefile does not wire the ZeroMount object."
    exit 1
  }
  grep -Eq '^[[:space:]]*config ZEROMOUNT$' fs/Kconfig || {
    echo "::error::fs/Kconfig does not expose CONFIG_ZEROMOUNT."
    exit 1
  }
  grep -Fq 'zeromount_getname_hook' fs/namei.c || {
    echo "::error::ZeroMount getname VFS hook is missing from fs/namei.c."
    exit 1
  }
  grep -Fq 'zeromount_inject_dents64' fs/readdir.c || {
    echo "::error::ZeroMount directory-entry hook is missing from fs/readdir.c."
    exit 1
  }

  {
    echo "==== ZEROMOUNT SOURCE PROOF ===="
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "zeromount_commit=${ZEROMOUNT_COMMIT}"
    echo "zeromount_gki_tag=${ZEROMOUNT_GKI_TAG}"
    echo "zeromount_patch_sha256=${ZEROMOUNT_PATCH_SHA256}"
    grep -Fn 'obj-$(CONFIG_ZEROMOUNT)' fs/Makefile
    grep -nE 'config ZEROMOUNT|zeromount_getname_hook|zeromount_inject_dents64' \
      fs/Kconfig fs/namei.c fs/readdir.c | head -n 20
  } | tee zeromount-source-proof.txt
}

verify_zeromount_binary_presence() {
  local symbol_hits=0
  local string_hits=0
  local object_file="out/fs/zeromount.o"

  if [[ -f "$object_file" ]]; then
    nm "$object_file" | grep -E 'zeromount_(init|getname_hook|resolve_path)' && symbol_hits=1 || true
    strings "$object_file" | grep -E 'ZeroMount:|zeromount' && string_hits=1 || true
  fi
  if [[ -f out/System.map ]]; then
    grep -E 'zeromount_(init|getname_hook|resolve_path)' out/System.map && symbol_hits=1 || true
  fi
  if [[ -f out/vmlinux ]]; then
    strings out/vmlinux | grep -E 'ZeroMount:|/dev/zeromount|zeromount' && string_hits=1 || true
  fi
  if [[ "$symbol_hits" -eq 0 && "$string_hits" -eq 0 ]]; then
    echo "::error::CONFIG_ZEROMOUNT=y, but no ZeroMount signature was found in the kernel artifacts."
    exit 1
  fi

  {
    echo "==== ZEROMOUNT BINARY PROOF ===="
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "zeromount_commit=${ZEROMOUNT_COMMIT}"
    echo "zeromount_gki_tag=${ZEROMOUNT_GKI_TAG}"
    if [[ -f "$object_file" ]]; then
      nm "$object_file" | grep -E 'zeromount_(init|getname_hook|resolve_path)' | head -n 20 || true
      strings "$object_file" | grep -E 'ZeroMount:|zeromount' | head -n 20 || true
    fi
  } | tee zeromount-proof.txt
}

verify_nomount_binary_presence() {
  local symbol_hits=0
  local string_hits=0
  local object_file="out/${NOMOUNT_FS_DIR}/nomount/nomount.o"

  if [[ -f "$object_file" ]]; then
    nm "$object_file" | grep -E 'nomount_(init|key_instantiate|hijacked_lookup)' && symbol_hits=1 || true
    strings "$object_file" | grep -E 'NoMount Path Redirection VFS Subsystem|NoMount: ' && string_hits=1 || true
  fi

  if [[ -f out/System.map ]]; then
    grep -E 'nomount_(init|key_instantiate|hijacked_lookup)' out/System.map && symbol_hits=1 || true
  fi
  if [[ -f out/vmlinux ]]; then
    strings out/vmlinux | grep -E 'NoMount Path Redirection VFS Subsystem|NoMount: ' && string_hits=1 || true
  fi
  if [[ "$symbol_hits" -eq 0 && "$string_hits" -eq 0 ]]; then
    echo "::error::CONFIG_NOMOUNT=y, but no NoMount signature was found in the final kernel artifacts."
    exit 1
  fi

  {
    echo "==== NOMOUNT BINARY PROOF ===="
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "nomount_ref=${NOMOUNT_REF}"
    echo "nomount_commit=${NOMOUNT_COMMIT}"
    echo "nomount_version=${NOMOUNT_VERSION}"
    if [[ -f "$object_file" ]]; then
      nm "$object_file" | grep -E 'nomount_(init|key_instantiate|hijacked_lookup)' | head -n 20 || true
      strings "$object_file" | grep -E 'NoMount Path Redirection VFS Subsystem|NoMount: ' | head -n 20 || true
    fi
    if [[ -f out/System.map ]]; then
      grep -E 'nomount_(init|key_instantiate|hijacked_lookup)' out/System.map | head -n 20 || true
    fi
    if [[ -f out/vmlinux ]]; then
      strings out/vmlinux | grep -E 'NoMount Path Redirection VFS Subsystem|NoMount: ' | head -n 20 || true
    fi
  } | tee nomount-proof.txt
}

verify_resukisu_susfs_hook_mode() {
  test -f build.log || {
    echo "::error::build.log is missing, cannot verify ReSukiSU hook mode."
    exit 1
  }

  if grep -Eq 'using KSU_TRACEPOINT_HOOK|using Tracepoint Syscall Redirect Hook' build.log; then
    echo "::error::ReSukiSU fell back to KSU_TRACEPOINT_HOOK, so the manager will not detect susfs inline mode."
    exit 1
  fi

  if grep -Eq 'using KSU_MANUAL_HOOK|using Manual Hook' build.log; then
    echo "::error::ReSukiSU fell back to KSU_MANUAL_HOOK, so this build is not the expected susfs inline mode."
    exit 1
  fi

  grep -Eq 'using SUSFS_INLINE_HOOK|using SuSFS Inline hook' build.log || {
    echo "::error::ReSukiSU did not report SUSFS_INLINE_HOOK in build.log."
    exit 1
  }

  {
    echo "==== RESUKISU SUSFS HOOK PROOF ===="
    echo "kernel_branch=${KERNEL_BRANCH}"
    echo "kernel_commit=${KERNEL_COMMIT}"
    echo "modules_branch=${MODULES_BRANCH}"
    echo "modules_commit=${MODULES_COMMIT}"
    echo "ksu_commit=${KSU_COMMIT}"
    echo "susfs_ref=${SUSFS_REF}"
    echo "susfs_commit=${SUSFS_COMMIT}"
    grep -nE 'using SUSFS_INLINE_HOOK|using SuSFS Inline hook|using KSU_TRACEPOINT_HOOK|using Tracepoint Syscall Redirect Hook|using KSU_MANUAL_HOOK|using Manual Hook' build.log || true
  } | tee susfs-hook-proof.txt
}
