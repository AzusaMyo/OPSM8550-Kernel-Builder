#!/usr/bin/env bash
#
# ZeroMount VFS driver integration helpers. Sourced, not executed.
# Depends on lib/git-helpers.sh and an already-applied SUSFS integration.
#

zeromount_patch_sha256() {
  case "$1" in
    android13-5.10) echo "8c732bed88c2a4edb705aed8d4078f082c864003f5768cb1e89e4e34ac2a30ad" ;;
    android13-5.15) echo "ff80cb950813c1e763cb588eb2d88ed9fcb6abccb6238dc50be1072b89f65d77" ;;
    android14-5.15) echo "0eb3fb10de60dfad83f8304b531eaf52649322043782e9fcdcacf5fc46419179" ;;
    android14-6.1)  echo "5ee951743cfff33951b6b9ceef3dd8f97d34610311c689bf32095bdec2023e72" ;;
    *)
      echo "::error::No ZeroMount patch checksum is pinned for $1" >&2
      return 1
      ;;
  esac
}

install_zeromount() {
  local repo="$1"
  local commit="$2"
  local gki_tag="$3"
  local repo_dir="ZeroMount-patches"
  local patch_file
  local expected_sha
  local actual_sha

  case "$gki_tag" in
    android13-5.10|android13-5.15|android14-5.15|android14-6.1) ;;
    *)
      echo "::error::Unsupported ZeroMount GKI target: $gki_tag"
      exit 1
      ;;
  esac

  rm -rf "$repo_dir"
  git init -q "$repo_dir"
  git -C "$repo_dir" remote add origin "$repo"
  git_fetch_retry "$repo_dir" --depth=1 --no-tags origin "$commit"
  git -C "$repo_dir" checkout -q --detach FETCH_HEAD
  test "$(git -C "$repo_dir" rev-parse HEAD)" = "$commit" || {
    echo "::error::ZeroMount patch checkout does not match resolved commit $commit."
    exit 1
  }

  patch_file="${repo_dir}/${gki_tag}/SukiSU-Ultra/patches/60_zeromount-${gki_tag}.patch"
  test -s "$patch_file" || {
    echo "::error::ZeroMount patch is missing at $patch_file."
    exit 1
  }

  expected_sha="$(zeromount_patch_sha256 "$gki_tag")"
  actual_sha="$(sha256sum "$patch_file" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    echo "::error::ZeroMount patch checksum mismatch for $gki_tag: expected $expected_sha, got $actual_sha."
    exit 1
  fi

  # Check the whole vendor-tree application before changing files so ordinary
  # context drift fails before the real patch pass starts.
  if ! patch --dry-run --batch --forward --fuzz=3 -p1 < "$patch_file"; then
    echo "::error::ZeroMount $gki_tag patch is incompatible with this kernel/SUSFS tree."
    exit 1
  fi
  patch --batch --forward --fuzz=3 -p1 < "$patch_file"

  if find . -type f -name '*.rej' -print -quit | grep -q .; then
    echo "::error::ZeroMount integration left patch reject files."
    find . -type f -name '*.rej' -print
    exit 1
  fi

  ZEROMOUNT_GKI_TAG="$gki_tag"
  ZEROMOUNT_PATCH_FILE="$patch_file"
  ZEROMOUNT_PATCH_SHA256="$actual_sha"
  export ZEROMOUNT_GKI_TAG ZEROMOUNT_PATCH_FILE ZEROMOUNT_PATCH_SHA256
  {
    echo "ZEROMOUNT_GKI_TAG=$ZEROMOUNT_GKI_TAG"
    echo "ZEROMOUNT_PATCH_FILE=$ZEROMOUNT_PATCH_FILE"
    echo "ZEROMOUNT_PATCH_SHA256=$ZEROMOUNT_PATCH_SHA256"
  } >> "$GITHUB_ENV"

  echo "[+] Integrated ZeroMount VFS driver for $gki_tag from $commit."
}
