#!/usr/bin/env bash
#
# Retried network helpers for transient upstream failures.
#

git_ls_remote_retry() {
  local attempt
  local output
  local max_attempts=5

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if output="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$@" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi

    echo "[!] git ls-remote attempt ${attempt}/${max_attempts} failed: $output" >&2
    [[ "$attempt" -eq "$max_attempts" ]] || sleep $((attempt * 2))
  done

  return 1
}

git_fetch_retry() {
  local repo_dir="$1"
  shift
  local attempt
  local max_attempts=5

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if GIT_TERMINAL_PROMPT=0 git -C "$repo_dir" fetch "$@"; then
      return 0
    fi

    echo "[!] git fetch attempt ${attempt}/${max_attempts} failed in ${repo_dir}." >&2
    [[ "$attempt" -eq "$max_attempts" ]] || sleep $((attempt * 2))
  done

  return 1
}
