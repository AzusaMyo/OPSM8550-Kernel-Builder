#!/usr/bin/env bash
#
# Safe AnyKernel3 property editing helpers.
#

sanitize_cached_anykernel_checkout() {
  local repo_dir="$1"

  test -d "${repo_dir}/.git" || {
    echo "::error::Cached AnyKernel3 checkout is not a Git repository: ${repo_dir}"
    return 1
  }

  # The cache is saved after packaging, when tracked files such as
  # anykernel.sh have already been customized. Restore the cached checkout to
  # its recorded commit before fetching/checking out the pinned revision.
  git -C "$repo_dir" reset --hard -q HEAD
  git -C "$repo_dir" clean -qfdx

  if [[ -n "$(git -C "$repo_dir" status --porcelain)" ]]; then
    echo "::error::Could not sanitize the cached AnyKernel3 checkout."
    return 1
  fi
}

replace_file_preserving_mode() {
  local replacement="$1"
  local destination="$2"

  # AnyKernel executes both anykernel.sh and update-binary.  mktemp creates
  # replacements as 0600, so retain the upstream executable mode before the
  # replacement.  A root-side extractor followed by an app-side repackager
  # otherwise leaves the app unable to read these files.
  chmod --reference="$destination" "$replacement" || {
    rm -f "$replacement"
    echo "::error::Could not preserve permissions for $destination"
    return 1
  }
  mv "$replacement" "$destination"
}

install_anykernel_template() {
  local template="$1"
  local destination="$2"
  local tmp_file

  test -f "$template" || {
    echo "::error::AnyKernel device template is missing: $template"
    return 1
  }
  test -f "$destination" || {
    echo "::error::AnyKernel destination script is missing: $destination"
    return 1
  }

  tmp_file="$(mktemp)"
  cp "$template" "$tmp_file"
  replace_file_preserving_mode "$tmp_file" "$destination"

  grep -Fxq 'BLOCK=boot;' "$destination" || {
    echo "::error::AnyKernel template does not target the boot partition."
    return 1
  }
  grep -Fxq 'IS_SLOT_DEVICE=1;' "$destination" || {
    echo "::error::AnyKernel template does not require A/B slot detection."
    return 1
  }
  grep -Fxq 'split_boot;' "$destination" || {
    echo "::error::AnyKernel template does not split the existing boot image."
    return 1
  }
  grep -Fxq 'flash_boot;' "$destination" || {
    echo "::error::AnyKernel template does not flash the rebuilt boot image."
    return 1
  }
  if grep -Eq '^[[:space:]]*(dump_boot|write_boot);' "$destination"; then
    echo "::error::AnyKernel template must not unpack a possibly absent boot ramdisk."
    return 1
  fi
  if grep -Eq 'omap_hsmmc|maguro|toro|tuna' "$destination"; then
    echo "::error::AnyKernel template still contains upstream example-device settings."
    return 1
  fi
}

set_ak_property() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    index($0, key "=") == 1 {
      print key "=" value
      found = 1
      next
    }
    { print }
    END { if (!found) exit 1 }
  ' "$file" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "::error::AnyKernel3 property '$key' was not found in $file"
    return 1
  }
  replace_file_preserving_mode "$tmp_file" "$file"
}

configure_anykernel_properties() {
  local file="$1"
  local kernel_string="$2"
  local device_names="$3"
  local android_versions="$4"
  local index
  local device_value
  local device_name
  local devices=()

  read -r -a devices <<< "$device_names"
  [[ "${#devices[@]}" -gt 0 ]] || {
    echo "::error::At least one AnyKernel3 device codename is required."
    return 1
  }
  [[ "${#devices[@]}" -le 5 ]] || {
    echo "::error::AnyKernel3 helper currently supports at most five device codenames."
    return 1
  }

  set_ak_property "$file" kernel.string "$kernel_string"
  set_ak_property "$file" do.devicecheck 1
  set_ak_property "$file" supported.versions "$android_versions"

  for index in 1 2 3 4 5; do
    device_value="${devices[$((index - 1))]:-}"
    set_ak_property "$file" "device.name${index}" "$device_value"
  done

  grep -q '^do.devicecheck=1$' "$file"
  for device_name in "${devices[@]}"; do
    grep -q "^device.name[1-5]=${device_name}$" "$file"
  done
}

add_anykernel_devicecheck_diagnostics() {
  local file="$1"
  local tmp_file
  local abort_line='    abort " " "Unsupported device. Aborting...";'

  grep -Fq 'Detected device IDs:' "$file" && return 0
  tmp_file="$(mktemp)"
  awk -v abort_line="$abort_line" '
    $0 == abort_line {
      print "    ui_print \"Detected device IDs:\";"
      print "    ui_print \"  ro.product.device=$device\";"
      print "    ui_print \"  ro.build.product=$product\";"
      print "    ui_print \"  ro.product.vendor.device=$vendordevice\";"
      print "    ui_print \"  ro.vendor.product.device=$vendorproduct\";"
      inserted = 1
    }
    { print }
    END { if (!inserted) exit 1 }
  ' "$file" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "::error::Could not add AnyKernel device-check diagnostics to $file"
    return 1
  }
  replace_file_preserving_mode "$tmp_file" "$file"
  grep -Fq 'ro.product.device=$device' "$file"
}

patch_anykernel_app_flash_staging() {
  local file="$1"
  local tmp_file
  local akhome_line='[ "$AKHOME" ] || export AKHOME=$POSTINSTALL/tmp/anykernel;'

  if grep -Fq 'export AKHOME=/data/local/tmp/anykernel-$$;' "$file"; then
    return 0
  fi

  tmp_file="$(mktemp)"
  awk -v akhome_line="$akhome_line" '
    $0 == akhome_line {
      print "case \"${AKHOME:-}:$POSTINSTALL\" in"
      print "  /data/user/*:*|/data/data/*:*|*:/data/user/*|*:/data/data/*)"
      print "    # Android app-private data may be writable but non-executable to the"
      print "    # root shell used by manager flashers. Stage the complete installer"
      print "    # in the shell-owned executable temporary directory before unzip."
      print "    export AKHOME=/data/local/tmp/anykernel-$$;"
      print "    ;;"
      print "  *)"
      print "    [ \"$AKHOME\" ] || export AKHOME=$POSTINSTALL/tmp/anykernel;"
      print "    ;;"
      print "esac;"
      staged = 1
      next
    }
    { print }
    END { if (!staged) exit 1 }
  ' "$file" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "::error::Could not add Android app-flasher staging compatibility to $file"
    return 1
  }

  replace_file_preserving_mode "$tmp_file" "$file"
  grep -Fq 'export AKHOME=/data/local/tmp/anykernel-$$;' "$file"
}

install_anykernel_arm64_binary() {
  local source="$1"
  local destination="$2"
  local label="$3"
  local elf_header

  test -s "$source" || {
    echo "::error::The arm64 $label is missing: $source"
    return 1
  }

  elf_header="$(readelf -h "$source")" || {
    echo "::error::Could not inspect the arm64 $label: $source"
    return 1
  }
  grep -Eq 'Class:[[:space:]]+ELF64' <<< "$elf_header" || {
    echo "::error::$label is not a 64-bit ELF: $source"
    return 1
  }
  grep -Eq 'Machine:[[:space:]]+AArch64' <<< "$elf_header" || {
    echo "::error::$label is not built for AArch64: $source"
    return 1
  }

  install -m 0755 "$source" "$destination"
  test -x "$destination"
}

install_anykernel_arm64_busybox() {
  install_anykernel_arm64_binary "$1" "$2" BusyBox
}

install_anykernel_arm64_magiskboot() {
  local apk_url="$1"
  local expected_apk_sha256="$2"
  local expected_magiskboot_sha256="$3"
  local destination="$4"
  local local_apk="${5:-}"

  (
    set -e
    local temp_dir
    local apk_file
    local magiskboot_file

    temp_dir="$(mktemp -d)"
    trap 'rm -rf "$temp_dir"' EXIT
    apk_file="$temp_dir/Magisk.apk"
    magiskboot_file="$temp_dir/magiskboot"

    if [[ -n "$local_apk" ]]; then
      cp "$local_apk" "$apk_file"
    else
      curl --retry 5 --retry-delay 3 --retry-all-errors -fL "$apk_url" -o "$apk_file"
    fi
    printf '%s  %s\n' "$expected_apk_sha256" "$apk_file" | sha256sum --check --status || {
      echo "::error::Magisk APK checksum verification failed."
      return 1
    }
    unzip -p "$apk_file" lib/arm64-v8a/libmagiskboot.so > "$magiskboot_file"
    printf '%s  %s\n' "$expected_magiskboot_sha256" "$magiskboot_file" | sha256sum --check --status || {
      echo "::error::arm64 MagiskBoot checksum verification failed."
      return 1
    }
    install_anykernel_arm64_binary "$magiskboot_file" "$destination" MagiskBoot
  )
}

prepare_anykernel_arm64_toolset() {
  local tools_dir="$1"
  local file
  local elf_header

  # This package only modifies boot. These optional AnyKernel tools target
  # other partition types and the canonical checkout currently ships ARM32
  # builds that cannot execute on arm64-only SoCs.
  rm -f \
    "$tools_dir/fec" \
    "$tools_dir/httools_static" \
    "$tools_dir/lptools_static" \
    "$tools_dir/magiskpolicy" \
    "$tools_dir/snapshotupdater_static"

  for file in "$tools_dir"/*; do
    [[ -f "$file" ]] || continue
    if elf_header="$(readelf -h "$file" 2>/dev/null)"; then
      grep -Eq 'Class:[[:space:]]+ELF64' <<< "$elf_header" || {
        echo "::error::AnyKernel contains a non-ELF64 runtime tool: $file"
        return 1
      }
      grep -Eq 'Machine:[[:space:]]+AArch64' <<< "$elf_header" || {
        echo "::error::AnyKernel contains a non-AArch64 runtime tool: $file"
        return 1
      }
    fi
  done
}

add_anykernel_preflight_diagnostics() {
  local file="$1"
  local busybox_abi="$2"
  local remove_injected_mkbootfs="${3:-false}"
  local tmp_file
  local setup_line='setup_bb;'
  local path_line='OLD_PATH="$PATH";'

  if grep -Fq 'AnyKernel work directory: $AKHOME' "$file" && \
     grep -Fq "Bundled BusyBox ABI: $busybox_abi" "$file" && \
     grep -Fq "Bundled MagiskBoot ABI: $busybox_abi" "$file" && \
     { [[ "$remove_injected_mkbootfs" != true ]] || grep -Fq 'Removing incompatible app-injected mkbootfs' "$file"; }; then
    return 0
  fi

  tmp_file="$(mktemp)"
  awk \
    -v setup_line="$setup_line" \
    -v path_line="$path_line" \
    -v busybox_abi="$busybox_abi" \
    -v remove_injected_mkbootfs="$remove_injected_mkbootfs" '
    $0 == setup_line {
      print "ui_print \"AnyKernel work directory: $AKHOME\";"
      print "ui_print \"Device primary ABI: $(getprop ro.product.cpu.abi 2>/dev/null)\";"
      print "ui_print \"Bundled BusyBox ABI: " busybox_abi "\";"
      print "ui_print \"Bundled MagiskBoot ABI: " busybox_abi "\";"
      print
      diagnosed = 1
      next
    }
    $0 == path_line && remove_injected_mkbootfs == "true" {
      print "if [ -f \"$AKHOME/tools/mkbootfs\" ]; then"
      print "  ui_print \"Removing incompatible app-injected mkbootfs\";"
      print "  \"$AKHOME/tools/busybox\" rm -f \"$AKHOME/tools/mkbootfs\";"
      print "fi;"
      removed = 1
    }
    { print }
    END {
      if (!diagnosed || (remove_injected_mkbootfs == "true" && !removed)) exit 1
    }
  ' "$file" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "::error::Could not add AnyKernel preflight diagnostics to $file"
    return 1
  }

  replace_file_preserving_mode "$tmp_file" "$file"
  grep -Fq 'AnyKernel work directory: $AKHOME' "$file"
  grep -Fq "Bundled BusyBox ABI: $busybox_abi" "$file"
  grep -Fq "Bundled MagiskBoot ABI: $busybox_abi" "$file"
  [[ "$remove_injected_mkbootfs" != true ]] || \
    grep -Fq 'Removing incompatible app-injected mkbootfs' "$file"
}
