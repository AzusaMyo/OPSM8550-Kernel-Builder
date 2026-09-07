#!/usr/bin/env bash
#
# Pure build-profile mappings shared by the resolver and its offline tests.
# This file performs no network or filesystem operations.
#
# Functions intentionally populate globals consumed by the sourcing script.
# shellcheck disable=SC2034

list_build_profiles() {
  printf '%s\n' \
    "SM7550 | OnePlus Nord CE4 | development" \
    "SM7550 | OnePlus Nord CE4 | crDroid (recommended for crDroid)" \
    "SM8450 | OnePlus 10 Pro | OnePlus official" \
    "SM8450 | OnePlus 10T / Ace Pro | LineageOS community" \
    "SM8550 | OnePlus 11 | OnePlus official" \
    "SM8550 | OnePlus 11 | LunarisOS" \
    "SM8550 | OnePlus 11 / 12R | LineageOS (recommended)" \
    "SM8550 | OnePlus 11 / 12R | crDroid" \
    "SM8550 | OnePlus 12R | development" \
    "SM8650 | OnePlus 12 | OnePlus official" \
    "SM8650 | OnePlus 12 | LineageOS (recommended)" \
    "SM8650 | OnePlus 12 | crDroid"
}

resolve_build_profile() {
  local profile="$1"

  # Most profiles use the conventional android_kernel_* repository names and
  # the same branch for the kernel and modules. Source-specific profiles can
  # override those defaults without complicating the common resolver path.
  KERNEL_REPO_OVERRIDE=""
  MODULES_REPO_OVERRIDE=""
  MODULES_BRANCH_OVERRIDE=""
  KERNEL_MAKE_FLAGS=""

  case "$profile" in
    "SM7550 | OnePlus Nord CE4 | development")
      PROFILE_ID="sm7550-oneplus-nord-ce4-dev"
      SOC="sm7550"
      TARGET_NAME="OnePlus Nord CE4"
      DEVICE_CODENAMES="benz"
      DEVICE_NAMES="benz OP5D3FL1 CPH2613"
      KERNEL_SOURCE="OnePlus-Nord-CE4-development"
      SOURCE_LAYOUT="community-flat"
      KERNEL_MAKE_FLAGS="CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_BENZ_DTB=y"
      ;;
    "SM7550 | OnePlus Nord CE4 | crDroid (recommended for crDroid)")
      PROFILE_ID="sm7550-oneplus-nord-ce4-crdroid"
      SOC="sm7550"
      TARGET_NAME="OnePlus Nord CE4"
      DEVICE_CODENAMES="benz"
      DEVICE_NAMES="benz OP5D3FL1 CPH2613"
      KERNEL_SOURCE="crdroidandroid"
      SOURCE_LAYOUT="community-flat"
      # Keep parity with crDroid's benz BoardConfig.mk. These are make
      # command-line assignments, not ordinary defconfig fragments.
      KERNEL_MAKE_FLAGS="CONFIG_OPLUS_DEVICE_DTBS=y CONFIG_BENZ_DTB=y"
      ;;
    "SM8450 | OnePlus 10 Pro | OnePlus official")
      PROFILE_ID="sm8450-oneplus10pro-official"
      SOC="sm8450"
      TARGET_NAME="OnePlus 10 Pro"
      DEVICE_CODENAMES="negroni"
      DEVICE_NAMES="negroni OP516EL1 OP516FL1"
      KERNEL_SOURCE="OnePlusOSS"
      SOURCE_LAYOUT="oneplus-official"
      ;;
    "SM8450 | OnePlus 10T / Ace Pro | LineageOS community")
      PROFILE_ID="sm8450-oneplus10t-lineage"
      SOC="sm8450"
      TARGET_NAME="OnePlus 10T / Ace Pro"
      DEVICE_CODENAMES="ovaltine"
      DEVICE_NAMES="ovaltine OP5551L1 OP5552L1"
      KERNEL_SOURCE="lineage-ovaltine-dev"
      SOURCE_LAYOUT="community-flat"
      ;;
    "SM8550 | OnePlus 11 | OnePlus official")
      PROFILE_ID="sm8550-oneplus11-official"
      SOC="sm8550"
      TARGET_NAME="OnePlus 11"
      DEVICE_CODENAMES="salami"
      DEVICE_NAMES="salami OP591BL1 OP594DL1"
      KERNEL_SOURCE="OnePlusOSS"
      SOURCE_LAYOUT="oneplus-official"
      ;;
    "SM8550 | OnePlus 11 | LunarisOS")
      PROFILE_ID="sm8550-oneplus11-lunarisos"
      SOC="sm8550"
      TARGET_NAME="OnePlus 11"
      DEVICE_CODENAMES="salami"
      DEVICE_NAMES="salami OP591BL1 OP594DL1"
      KERNEL_SOURCE="LunarisOS"
      SOURCE_LAYOUT="community-flat"
      KERNEL_REPO_OVERRIDE="https://github.com/osm1019/kernel_oneplus_sm8550.git"
      MODULES_REPO_OVERRIDE="https://github.com/osm1019/android_kernel_oneplus_sm8550-modules.git"
      MODULES_BRANCH_OVERRIDE="los"
      ;;
    "SM8550 | OnePlus 11 / 12R | LineageOS (recommended)")
      PROFILE_ID="sm8550-oneplus11-12r-lineage"
      SOC="sm8550"
      TARGET_NAME="OnePlus 11 / 12R"
      DEVICE_CODENAMES="salami aston"
      DEVICE_NAMES="salami OP591BL1 OP594DL1 aston OP5D35L1"
      KERNEL_SOURCE="LineageOS"
      SOURCE_LAYOUT="community-flat"
      ;;
    "SM8550 | OnePlus 11 / 12R | crDroid")
      PROFILE_ID="sm8550-oneplus11-12r-crdroid"
      SOC="sm8550"
      TARGET_NAME="OnePlus 11 / 12R"
      DEVICE_CODENAMES="salami aston"
      DEVICE_NAMES="salami OP591BL1 OP594DL1 aston OP5D35L1"
      KERNEL_SOURCE="crdroidandroid"
      SOURCE_LAYOUT="community-flat"
      ;;
    "SM8550 | OnePlus 12R | development")
      PROFILE_ID="sm8550-oneplus12r-dev"
      SOC="sm8550"
      TARGET_NAME="OnePlus 12R"
      DEVICE_CODENAMES="aston"
      DEVICE_NAMES="aston OP5D35L1"
      KERNEL_SOURCE="OnePlus12R-development"
      SOURCE_LAYOUT="community-flat"
      ;;
    "SM8650 | OnePlus 12 | OnePlus official")
      PROFILE_ID="sm8650-oneplus12-official"
      SOC="sm8650"
      TARGET_NAME="OnePlus 12"
      DEVICE_CODENAMES="waffle"
      DEVICE_NAMES="waffle OP5929L1 OP595DL1"
      KERNEL_SOURCE="OnePlusOSS"
      SOURCE_LAYOUT="oneplus-official"
      ;;
    "SM8650 | OnePlus 12 | LineageOS (recommended)")
      PROFILE_ID="sm8650-oneplus12-lineage"
      SOC="sm8650"
      TARGET_NAME="OnePlus 12"
      DEVICE_CODENAMES="waffle"
      DEVICE_NAMES="waffle OP5929L1 OP595DL1"
      KERNEL_SOURCE="LineageOS"
      SOURCE_LAYOUT="community-flat"
      ;;
    "SM8650 | OnePlus 12 | crDroid")
      PROFILE_ID="sm8650-oneplus12-crdroid"
      SOC="sm8650"
      TARGET_NAME="OnePlus 12"
      DEVICE_CODENAMES="waffle"
      DEVICE_NAMES="waffle OP5929L1 OP595DL1"
      KERNEL_SOURCE="crdroidandroid"
      SOURCE_LAYOUT="community-flat"
      ;;
    *)
      echo "::error::Unknown build profile: $profile"
      return 1
      ;;
  esac

  UPSTREAM_SOC="$SOC"
  if [[ "$SOC" == "sm7550" ]]; then
    # Both supported CE4 sources intentionally carry their SM7550/crow
    # support in sm8550-named kernel and modules repositories.
    UPSTREAM_SOC="sm8550"
  fi

  case "$SOC" in
    sm7550)
      PLATFORM_SLUG="7gen3"
      PLATFORM_NAME="Snapdragon 7 Gen 3"
      BUILD_CONFIGS="vendor/kalama_GKI.config vendor/oplus/kalama_GKI.config vendor/debugfs.config"
      OFFICIAL_BUILD_TARGET="kalama"
      OFFICIAL_GKI_FRAGMENT="arch/arm64/configs/vendor/kalama_GKI.config"
      ;;
    sm8450)
      PLATFORM_SLUG="8gen1"
      PLATFORM_NAME="Snapdragon 8 Gen 1"
      BUILD_CONFIGS="vendor/waipio_GKI.config vendor/oplus/waipio_GKI.config vendor/debugfs.config"
      OFFICIAL_BUILD_TARGET="waipio"
      OFFICIAL_GKI_FRAGMENT="arch/arm64/configs/vendor/waipio_GKI.config"
      ;;
    sm8550)
      PLATFORM_SLUG="8gen2"
      PLATFORM_NAME="Snapdragon 8 Gen 2"
      BUILD_CONFIGS="vendor/kalama_GKI.config vendor/oplus/kalama_GKI.config vendor/debugfs.config"
      OFFICIAL_BUILD_TARGET="kalama"
      OFFICIAL_GKI_FRAGMENT="arch/arm64/configs/vendor/kalama_GKI.config"
      ;;
    sm8650)
      PLATFORM_SLUG="8gen3"
      PLATFORM_NAME="Snapdragon 8 Gen 3"
      BUILD_CONFIGS="vendor/pineapple_GKI.config vendor/oplus/pineapple_GKI.config"
      OFFICIAL_BUILD_TARGET="pineapple"
      OFFICIAL_GKI_FRAGMENT="arch/arm64/configs/vendor/pineapple_GKI.config"
      ;;
  esac

  case "$KERNEL_SOURCE" in
    OnePlusOSS)
      SOURCE_NAME="OnePlus official source"
      SOURCE_SLUG="oneplus-official"
      ;;
    LineageOS)
      SOURCE_NAME="LineageOS"
      SOURCE_SLUG="lineageos"
      ;;
    LunarisOS)
      SOURCE_NAME="LunarisOS (OnePlus 11)"
      SOURCE_SLUG="lunarisos"
      ;;
    lineage-ovaltine-dev)
      SOURCE_NAME="LineageOS community (ovaltine)"
      SOURCE_SLUG="lineage-community"
      ;;
    crdroidandroid)
      SOURCE_NAME="crDroid"
      SOURCE_SLUG="crdroid"
      ;;
    OnePlus12R-development)
      SOURCE_NAME="OnePlus 12R development"
      SOURCE_SLUG="oneplus12r-dev"
      ;;
    OnePlus-Nord-CE4-development)
      SOURCE_NAME="OnePlus Nord CE4 development"
      SOURCE_SLUG="oneplus-nord-ce4-dev"
      ;;
  esac
}

resolve_root_solution() {
  case "$1" in
    "No root changes") KSU_TYPE="None" ;;
    "Official KernelSU") KSU_TYPE="Official-KernelSU" ;;
    "KernelSU-Next") KSU_TYPE="KernelSU-Next" ;;
    "KernelSU-Next + SUSFS") KSU_TYPE="KernelSU-Next-with-susfs" ;;
    "KowSU") KSU_TYPE="KowSU" ;;
    "SukiSU Ultra + KPM (experimental)") KSU_TYPE="SukiSU-Ultra-with-KPM" ;;
    "SukiSU Ultra + SUSFS + KPM (experimental)") KSU_TYPE="SukiSU-Ultra-with-susfs-KPM" ;;
    "SukiSU Ultra + SUSFS + NoMount + KPM (experimental)") KSU_TYPE="SukiSU-Ultra-with-susfs-nomount-KPM" ;;
    "ReSukiSU") KSU_TYPE="ReSukiSU" ;;
    "ReSukiSU + susfs") KSU_TYPE="ReSukiSU-with-susfs" ;;
    "ReSukiSU + SUSFS + NoMount (experimental)") KSU_TYPE="ReSukiSU-with-susfs-nomount" ;;
    *)
      echo "::error::Unsupported root solution: $1"
      return 1
      ;;
  esac
}

resolve_clang_version() {
  local choice="$1"
  local branch="$2"

  case "$choice" in
    "Recommended (auto-select based on branch)")
      case "$branch" in
        main|master|android-mainline*) CLANG_VERSION="clang-r596125" ;;
        lineage-19.1*|oneplus/*_s_12.1*|oneplus/*_s_12.0*) CLANG_VERSION="clang-r416183b1" ;;
        lineage-20*|thirteen*|android13*|13.*|oneplus/*_t_13*|oneplus_*_t_13*) CLANG_VERSION="clang-r450784d" ;;
        lineage-21*|fourteen*|android14*|14.*|oneplus/*_u_14*|oneplus_*_u_14*) CLANG_VERSION="clang-r487747c" ;;
        lineage-22*|fifteen*|android15*|15.*|oneplus/*_v_15*|oneplus_*_v_15*) CLANG_VERSION="clang-r536225" ;;
        lineage-23.0*) CLANG_VERSION="clang-r547379" ;;
        16.0|lineage-23*|sixteen*|android16*|16.*|oneplus/*_b_16*|oneplus_*_b_16*) CLANG_VERSION="clang-r563880c" ;;
        *)
          CLANG_VERSION="clang-r563880c"
          echo "::warning::Could not confidently infer clang for '$branch'; using $CLANG_VERSION."
          ;;
      esac
      ;;
    "clang-r596125 (Clang 22.0.2 / current AOSP mainline era)") CLANG_VERSION="clang-r596125" ;;
    "clang-r563880c (Android 16 / LineageOS 23.2+ era)") CLANG_VERSION="clang-r563880c" ;;
    "clang-r547379 (Android 16 / LineageOS 23.0 era)") CLANG_VERSION="clang-r547379" ;;
    "clang-r536225 (Android 15 / LineageOS 22.2 era)") CLANG_VERSION="clang-r536225" ;;
    "clang-r487747c (Android 14 / LineageOS 21 era)") CLANG_VERSION="clang-r487747c" ;;
    "clang-r450784d (Android 13 / LineageOS 20 era)") CLANG_VERSION="clang-r450784d" ;;
    "clang-r416183b1 (Android 12 / LineageOS 19.1 era)") CLANG_VERSION="clang-r416183b1" ;;
    *)
      echo "::error::Unknown clang choice: $choice"
      return 1
      ;;
  esac
}

resolve_susfs_settings() {
  local soc="$1"
  local branch="$2"

  case "$soc" in
    sm7550)
      SUSFS_REF="gki-android14-5.15"
      ;;
    sm8450)
      SUSFS_REF="gki-android13-5.10"
      ;;
    sm8550)
      case "$branch" in
        lineage-20*|thirteen*|android13*|13.*|oneplus/*_t_13*|oneplus_*_t_13*)
          SUSFS_REF="gki-android13-5.15"
          ;;
        *)
          SUSFS_REF="gki-android14-5.15"
          ;;
      esac
      ;;
    sm8650)
      SUSFS_REF="gki-android14-6.1"
      ;;
    *)
      echo "::error::No susfs mapping is configured for platform $soc"
      return 1
      ;;
  esac

  SUSFS_PATCH_FILE="50_add_susfs_in_${SUSFS_REF}.patch"
}

sukisu_compatible_susfs_commit() {
  local susfs_ref="$1"

  # SUSFS commits after these pins target the newer upstream KernelSU su-session
  # fd ABI (ksu_install_su_fd), which SukiSU Ultra does not provide.  Keep each
  # kernel branch on the identical v2.3.0 KernelSU patch that still matches
  # SukiSU's hook implementation.
  case "$susfs_ref" in
    gki-android13-5.10) echo "ed3d6d9c9a2652e1c70f153f5358701e996d646c" ;;
    gki-android13-5.15) echo "bca0d2333c1a7d717e7278b019d7af7ba1d16005" ;;
    gki-android14-5.15) echo "d54b51724afa912c4c99bb99731354ce934d1889" ;;
    gki-android14-6.1) echo "4fc9c1898ea66f51847cdbc0d1473ea4ef525a70" ;;
    *)
      echo "::error::No SukiSU-compatible SUSFS commit is pinned for $susfs_ref" >&2
      return 1
      ;;
  esac
}

infer_android_versions() {
  local branch="$1"

  case "$branch" in
    lineage-19.1*|oneplus/*_s_12*|oneplus_*_s_12*) SUPPORTED_ANDROID_VERSIONS="12" ;;
    lineage-20*|thirteen*|android13*|13.*|oneplus/*_t_13*|oneplus_*_t_13*) SUPPORTED_ANDROID_VERSIONS="13" ;;
    lineage-21*|fourteen*|android14*|14.*|oneplus/*_u_14*|oneplus_*_u_14*) SUPPORTED_ANDROID_VERSIONS="14" ;;
    lineage-22*|fifteen*|android15*|15.*|oneplus/*_v_15*|oneplus_*_v_15*) SUPPORTED_ANDROID_VERSIONS="15" ;;
    16.0|lineage-23*|sixteen*|android16*|16.*|oneplus/*_b_16*|oneplus_*_b_16*) SUPPORTED_ANDROID_VERSIONS="16" ;;
    *) SUPPORTED_ANDROID_VERSIONS="" ;;
  esac
}
