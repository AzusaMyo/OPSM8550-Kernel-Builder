#!/usr/bin/env bash
#
# Shared helper functions used by the kernel build pipeline.
# This file is sourced, not executed.
#

# ---- Small utilities ---------------------------------------------------------

ensure_line_in_file() {
  local file="$1"
  local line="$2"
  grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
}

insert_line_before_first_match() {
  local file="$1"
  local match_line="$2"
  local insert_line="$3"
  local tmp_file

  grep -qxF "$insert_line" "$file" && return 0

  tmp_file="$(mktemp)"
  awk -v match_line="$match_line" -v insert_line="$insert_line" '
    !inserted && $0 == match_line {
      print insert_line
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        print insert_line
      }
    }
  ' "$file" > "$tmp_file"
  mv "$tmp_file" "$file"
}

insert_block_before_first_match() {
  local file="$1"
  local match_line="$2"
  local block="$3"
  local marker="$4"
  local tmp_file

  grep -Fq "$marker" "$file" && return 0

  tmp_file="$(mktemp)"
  awk -v match_line="$match_line" -v block="$block" '
    !inserted && $0 == match_line {
      print block
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        exit 1
      }
    }
  ' "$file" > "$tmp_file" || {
    rm -f "$tmp_file"
    return 1
  }
  mv "$tmp_file" "$file"
}

detect_kernelsu_driver_dir() {
  if test -d "common/drivers"; then
    echo "common/drivers"
  elif test -d "drivers"; then
    echo "drivers"
  else
    return 1
  fi
}

# Repair a stable-backport merge regression where key_pass was guarded as if
# the OpenSSL provider implementation were present, while the older ENGINE
# implementation still referenced it unconditionally. Keep this deliberately
# pattern-gated so newer extract-cert implementations remain untouched.
repair_extract_cert_key_pass_guard() {
  local source_file="${1:-certs/extract-cert.c}"
  local tmp_file

  [[ -f "$source_file" ]] || return 0
  grep -Fq 'ENGINE_ctrl_cmd_string(e, "PIN", key_pass, 0)' "$source_file" || return 0
  grep -Fq '#ifdef USE_PKCS11_ENGINE' "$source_file" || return 0
  grep -Fq '#ifndef OPENSSL_IS_BORINGSSL' "$source_file" || return 0

  # Provider-aware versions legitimately scope key_pass to the ENGINE path.
  if grep -Fq 'USE_PKCS11_PROVIDER' "$source_file"; then
    return 0
  fi

  tmp_file="$(mktemp)"
  if ! awk '
    $0 == "#ifdef USE_PKCS11_ENGINE" {
      if ((getline guarded_line) <= 0 || (getline endif_line) <= 0) {
        exit 1
      }
      if (endif_line == "#endif" &&
          (guarded_line == "static const char *key_pass;" ||
           guarded_line ~ /^[[:space:]]*key_pass = getenv\("KBUILD_SIGN_PIN"\);$/)) {
        print guarded_line
        repaired++
        next
      }
      print $0
      print guarded_line
      print endif_line
      next
    }
    { print }
    END {
      if (repaired != 2) {
        exit 1
      }
    }
  ' "$source_file" > "$tmp_file"; then
    rm -f "$tmp_file"
    echo "::error::Recognized the extract-cert key_pass regression, but its guarded blocks did not match the expected form."
    return 1
  fi

  chmod --reference="$source_file" "$tmp_file"
  mv "$tmp_file" "$source_file"

  if [[ "$(grep -Fc 'static const char *key_pass;' "$source_file")" -ne 1 ]] ||
     [[ "$(grep -Fc 'key_pass = getenv("KBUILD_SIGN_PIN");' "$source_file")" -ne 1 ]]; then
    echo "::error::extract-cert key_pass compatibility repair did not produce the expected source."
    return 1
  fi

  echo "[+] Repaired the legacy extract-cert key_pass guard regression."
}

kernelsu_kconfig_source_path() {
  local driver_dir="$1"
  echo "${driver_dir}/kernelsu/Kconfig"
}

# ---- defconfig / .config manipulation ---------------------------------------

set_config_value() {
  local config_file="$1"
  local key="$2"
  local value="$3"

  if [[ "$value" == "n" ]]; then
    if grep -q "^${key}=" "$config_file"; then
      sed -i "s|^${key}=.*|# ${key} is not set|" "$config_file"
    elif grep -q "^# ${key} is not set$" "$config_file"; then
      :
    else
      echo "# ${key} is not set" >> "$config_file"
    fi
  else
    if grep -q "^${key}=" "$config_file"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$config_file"
    elif grep -q "^# ${key} is not set$" "$config_file"; then
      sed -i "s|^# ${key} is not set$|${key}=${value}|" "$config_file"
    else
      echo "${key}=${value}" >> "$config_file"
    fi
  fi
}

enable_config_values() {
  local config_file="$1"
  shift
  local key
  for key in "$@"; do
    set_config_value "$config_file" "$key" y
  done
}

disable_config_values() {
  local config_file="$1"
  shift
  local key
  for key in "$@"; do
    set_config_value "$config_file" "$key" n
  done
}

enable_susfs_configs() {
  local config_file="$1"
  enable_config_values "$config_file" \
    CONFIG_KSU_SUSFS \
    CONFIG_KSU_SUSFS_SUS_PATH \
    CONFIG_KSU_SUSFS_SUS_MOUNT \
    CONFIG_KSU_SUSFS_SUS_KSTAT \
    CONFIG_KSU_SUSFS_SUS_MAP \
    CONFIG_KSU_SUSFS_SPOOF_UNAME \
    CONFIG_KSU_SUSFS_ENABLE_LOG \
    CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    CONFIG_KSU_SUSFS_OPEN_REDIRECT
  disable_config_values "$config_file" \
    CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS
}

enable_ksu_common_configs() {
  local config_file="$1"
  enable_config_values "$config_file" CONFIG_TMPFS_XATTR
}

apply_variant_configs() {
  local config_file="$1"

  if [[ "$KSU_TYPE" == *susfs* ]]; then
    enable_susfs_configs "$config_file"
  fi

  if [[ "$KSU_TYPE" != "None" ]]; then
    enable_ksu_common_configs "$config_file"
  fi

  if [[ "$KSU_TYPE" == *nomount* ]]; then
    enable_config_values "$config_file" CONFIG_KEYS CONFIG_NOMOUNT
  fi

  if [[ "$KSU_TYPE" == *KPM* ]]; then
    enable_config_values "$config_file" CONFIG_KPM CONFIG_KALLSYMS CONFIG_KALLSYMS_ALL
  fi

}

require_config_enabled() {
  local config_file="$1"
  local key="$2"

  if ! grep -q "^${key}=y$" "$config_file"; then
    echo "::error::Expected ${key}=y in ${config_file}, but it was not enabled."
    grep -n "${key}" "$config_file" || true
    exit 1
  fi
}

require_config_disabled() {
  local config_file="$1"
  local key="$2"

  if grep -q "^${key}=y$" "$config_file"; then
    echo "::error::Expected ${key} to stay disabled in ${config_file}, but it is enabled."
    grep -n "${key}" "$config_file" || true
    exit 1
  fi
}
