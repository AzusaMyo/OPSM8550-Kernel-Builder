#!/usr/bin/env bash
#
# Retried network helpers for transient upstream failures.
#

git_ls_remote_retry() {
  local attempt
  local output
  local status
  local max_attempts=5

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if output="$(GIT_TERMINAL_PROMPT=0 git ls-remote "$@" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    else
      status=$?
    fi

    # --exit-code returns 2 when the remote is reachable but no ref matches.
    # Retrying cannot make an invalid manual branch selection succeed.
    [[ "$status" -ne 2 ]] || return 2
    echo "[!] git ls-remote attempt ${attempt}/${max_attempts} failed: $output" >&2
    [[ "$attempt" -eq "$max_attempts" ]] || sleep $((attempt * 2))
  done

  return 1
}

git_resolve_branch_commit() {
  local repo="$1" branch="$2" output status commit
  if output="$(git_ls_remote_retry --exit-code --heads "$repo" "refs/heads/$branch")"; then
    commit="$(awk 'NR == 1 {print $1}' <<< "$output")"
    if [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
      printf '%s\n' "$commit"
      return 0
    fi
    echo "::error::Invalid commit returned for branch '$branch' in $repo" >&2
  else
    status=$?
    if [[ "$status" -eq 2 ]]; then
      echo "::error::Branch '$branch' was not found in $repo" >&2
      echo "::error::Select 'Use the recommended branch automatically', or choose a branch that exists in the selected source. LineageOS uses lineage-* branch names; the shared manual menu also contains branches for other sources." >&2
    else
      echo "::error::Could not query branch '$branch' in $repo; check the upstream connection and repository access." >&2
    fi
  fi
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
