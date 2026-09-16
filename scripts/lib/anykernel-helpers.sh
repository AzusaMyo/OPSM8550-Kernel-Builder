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
  grep -Fxq 'dump_boot;' "$destination" || {
    echo "::error::AnyKernel template does not unpack the existing boot image."
    return 1
  }
  grep -Fxq 'write_boot;' "$destination" || {
    echo "::error::AnyKernel template does not write the rebuilt boot image."
    return 1
  }
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

install_anykernel_arm64_busybox() {
  local source="$1"
  local destination="$2"
  local elf_header

  test -s "$source" || {
    echo "::error::The KernelSU arm64 BusyBox is missing: $source"
    return 1
  }

  elf_header="$(readelf -h "$source")" || {
    echo "::error::Could not inspect the KernelSU BusyBox: $source"
    return 1
  }
  grep -Eq 'Class:[[:space:]]+ELF64' <<< "$elf_header" || {
    echo "::error::KernelSU BusyBox is not a 64-bit ELF: $source"
    return 1
  }
  grep -Eq 'Machine:[[:space:]]+AArch64' <<< "$elf_header" || {
    echo "::error::KernelSU BusyBox is not built for AArch64: $source"
    return 1
  }

  install -m 0755 "$source" "$destination"
  test -x "$destination"
}

add_anykernel_preflight_diagnostics() {
  local file="$1"
  local busybox_abi="$2"
  local tmp_file
  local setup_line='setup_bb;'

  if grep -Fq 'AnyKernel work directory: $AKHOME' "$file" && \
     grep -Fq "Bundled BusyBox ABI: $busybox_abi" "$file"; then
    return 0
  fi

  tmp_file="$(mktemp)"
  awk -v setup_line="$setup_line" -v busybox_abi="$busybox_abi" '
    $0 == setup_line {
      print "ui_print \"AnyKernel work directory: $AKHOME\";"
      print "ui_print \"Device primary ABI: $(getprop ro.product.cpu.abi 2>/dev/null)\";"
      print "ui_print \"Bundled BusyBox ABI: " busybox_abi "\";"
      print
      diagnosed = 1
      next
    }
    { print }
    END {
      if (!diagnosed) exit 1
    }
  ' "$file" > "$tmp_file" || {
    rm -f "$tmp_file"
    echo "::error::Could not add AnyKernel preflight diagnostics to $file"
    return 1
  }

  replace_file_preserving_mode "$tmp_file" "$file"
  grep -Fq 'AnyKernel work directory: $AKHOME' "$file"
  grep -Fq "Bundled BusyBox ABI: $busybox_abi" "$file"
}
