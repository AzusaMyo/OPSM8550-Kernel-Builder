#!/usr/bin/env bash
#
# Safe AnyKernel3 property editing helpers.
#

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
