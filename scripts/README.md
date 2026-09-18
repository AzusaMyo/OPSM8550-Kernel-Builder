# scripts/

Shell implementation used by the GitHub Actions workflows.

## Top-level scripts

| Script | Purpose |
| --- | --- |
| `check-upstreams.sh` | Resolves all supported profiles against live upstream refs for the scheduled health workflow. |
| `resolve-profile.sh` | Resolves a valid device/source profile, branch, toolchain, add-ons, and every upstream input to exact commits. |
| `clone-sources.sh` | Fetches exact kernel and modules commits in parallel and prepares the official OnePlus layout when required. |
| `download-clang.sh` | Downloads an AOSP Clang directory from an exact pinned Gitiles commit. |
| `compile-kernel.sh` | Applies integrations, generates config, performs validation-only runs or a full ccache-backed build, and reports timing/cache metrics. |
| `make-anykernel-zip.sh` | Creates a device-checked AnyKernel3 ZIP, provenance manifest, release notes, raw Image asset, and SHA-256 checksums. |
| `publish-diagnostics.sh` | Appends config, KPM, SUSFS, NoMount, and ZeroMount proof files to the job summary. |

## Shared libraries

- `lib/profile-data.sh` contains pure profile, root, Clang, KPM, SUSFS, and Android
  version mappings, including source-specific repository and modules-branch
  overrides. It performs no network access and is covered by offline tests.
- `lib/git-helpers.sh` provides bounded five-attempt retries for upstream ref
  lookup and fetches, with interactive credential prompts disabled in CI.
- `lib/anykernel-helpers.sh` applies and verifies device/version protection in
  AnyKernel3 properties.
- `lib/kernel-helpers.sh` edits and verifies Kconfig values and source insertions,
  and repairs the narrowly identified legacy `extract-cert` `key_pass` guard
  regression without changing provider-aware implementations. It also keeps
  module versioning while disabling unused-export trimming for external-driver
  compatibility.
- `lib/ksu-setup.sh` checks out the selected KernelSU-compatible implementation
  at the exact resolved commit and connects it to the kernel driver tree.
- `templates/anykernel.sh` provides the slot-aware OnePlus `boot` installer used
  in release ZIPs instead of AnyKernel3's example-device script.
- `lib/susfs-apply.sh` applies SUSFS at an exact commit, repairs explicitly
  recognized upstream drift, enforces the supported version floor, and rejects
  unknown conflicts.
- `patches/sukisu-susfs-core-init-compat.patch` is the guarded compatibility
  delta for the recognized SukiSU Ultra UTS-spoof init and KPM symbol-resolver
  drift.
- `patches/sukisu-susfs-policy-compat.patch` is the guarded compatibility delta
  for the recognized SukiSU Ultra kernel-umount and manager-allowlist drift.
- `lib/nomount-setup.sh` integrates an exact NoMount commit into the kernel fs
  Kconfig/Makefile only for the explicit experimental preset.
- `lib/zeromount-setup.sh` fetches a pinned Super-Builders revision, verifies
  the versioned VFS patch checksum, and preflights it before applying it after
  SUSFS.
- `lib/verify.sh` performs source, config, hook-mode, and binary verification,
  including an LTO-aware `llvm-nm` check of the compiled KPM resolver, plus
  dedicated KPM, SUSFS, NoMount, and ZeroMount proofs. Full builds also verify
  that the final `Image` release suffix identifies the pinned kernel commit.

## Tests

`tests/profile-data-test.sh` verifies all supported profile mappings and keeps
the workflow dropdown synchronized with the mapping library. It also checks
representative root, Clang, KPM, SUSFS, NoMount, and Android version decisions.

The push/PR validation workflow runs Bash syntax checks, ShellCheck, these
offline tests, and actionlint. The scheduled upstream-health workflow resolves
every profile and runs a matrix covering KernelSU-Next + SUSFS, the combined
SukiSU Ultra + SUSFS + NoMount + KPM preset, and ReSukiSU + SUSFS + NoMount on
representative SM7550, SM8450, SM8550, and SM8650 sources, including targeted
integration object compilation and a LunarisOS OnePlus 11 baseline smoke test.

## Conventions

- Top-level scripts use `set -euo pipefail`.
- Library files are sourced and do not enable shell options themselves.
- Exact upstream commits are resolved before clone/fetch operations.
- AnyKernel3 uses a tested commit from the canonical `osm0sis/AnyKernel3`
  repository rather than the removed `Kernel-SU/AnyKernel3` fork.
- Full builds pass ccache compiler launchers on the `make` command line and use
  deterministic Kbuild metadata for repeatability.
- Unknown device/source pairs, invalid branch names, patch rejects, missing
  configs, and missing root/KPM/SUSFS/NoMount/ZeroMount signatures fail closed.
