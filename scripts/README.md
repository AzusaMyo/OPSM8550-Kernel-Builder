# scripts/

Shell implementation used by the GitHub Actions workflows.

## Top-level scripts

| Script | Purpose |
| --- | --- |
| `check-upstreams.sh` | Resolves all supported profiles against live upstream refs for the scheduled health workflow. |
| `resolve-profile.sh` | Resolves a valid device/source profile, branch, toolchain, add-ons, and every upstream input to exact commits. |
| `set-build-metadata.sh` | Assigns package/diagnostics artifact names and branch-specific cache keys; Android batches add A16/A17 labels. |
| `clone-sources.sh` | Fetches exact kernel and modules commits in parallel and prepares the official OnePlus layout when required. |
| `download-clang.sh` | Downloads and validates an AOSP Clang directory from an exact pinned Gitiles commit, retrying incomplete archives before installing from staging. |
| `compile-kernel.sh` | Applies integrations, generates config, performs validation-only runs or a full ccache-backed build, and reports timing/cache metrics. |
| `make-anykernel-zip.sh` | Creates a device-checked AnyKernel3 ZIP, provenance manifest, release notes, raw Image asset, and SHA-256 checksums. |
| `publish-diagnostics.sh` | Appends config, KPM, SUSFS, NoMount, and ZeroMount proof files to the job summary. |
| `stage-release-assets.sh` | Verifies and merges matrix artifacts into a release, preserving per-variant manifests/checksums and rejecting filename collisions. |

## Shared libraries

- `lib/profile-data.sh` contains pure profile, root, Clang, KPM, SUSFS, and Android
  version mappings, including source-specific repository and modules-branch
  overrides. It performs no network access and is covered by offline tests.
- `lib/git-helpers.sh` provides bounded five-attempt retries for upstream ref
  lookup and fetches, with interactive credential prompts disabled in CI.
- `lib/build-metadata.sh` validates Android batch flags and version labels so
  two branches sharing one commit still produce distinct artifacts and files.
- `lib/anykernel-helpers.sh` applies and verifies device/version protection in
  AnyKernel3 properties.
- `lib/kernel-helpers.sh` edits and verifies Kconfig values and source insertions,
  and repairs the narrowly identified legacy `extract-cert` `key_pass` guard
  regression without changing provider-aware implementations. It also keeps
  module versioning while disabling unused-export trimming for external-driver
  compatibility.
- `lib/ksu-setup.sh` checks out the selected KernelSU-compatible implementation
  at the exact resolved commit and connects it to the kernel driver tree.
- `lib/ksu-uapi.sh` applies guarded UAPI 5/6 backports after SUSFS, preserving
  the pinned hook ABI while implementing the newer manager interfaces. The
  optional SukiSU preinit runner remains unavailable and is not advertised.
  Its extension-hub bridge exposes only config-backed KPM/SuSFS discovery and
  forwards KPM IO to the existing loader, retaining legacy ioctl support.
- `lib/kpm-image.sh` injects a checksum-pinned SukiSU KernelPatch payload after
  full compilation, inspects the result, and binds the packaging gate to its
  Image SHA-256. Source/config validation alone cannot prove KPM is injected.
- `templates/anykernel.sh` provides the slot-aware OnePlus `boot` installer used
  in release ZIPs instead of AnyKernel3's example-device script.
- `templates/detect-slot.sh` resolves only valid A/B slots from boot properties,
  cmdline, and bootconfig. Packaging patches both recovery mounting and core
  partition selection to use it; unrecognized upstream detection code fails.
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
  SUSFS validation also checks exec/SELinux object references against global
  KernelSU, SUSFS, and SELinux service definitions with the active toolchain's
  `llvm-nm` to catch missing hook symbols before the final kernel link.

## Tests

`tests/profile-data-test.sh` verifies all supported profile mappings and keeps
the workflow dropdown synchronized with the mapping library. It also checks
representative root, Clang, KPM, SUSFS, NoMount, and Android version decisions.
FinaSU coverage checks the exact reviewed release pin, checkout routing, required
driver/manager config, and exclusion of the existing SUSFS patch pipeline.
Its upstream-health entries compile the driver on 5.10, 5.15, and 6.1 profiles.
`tests/finasu-manager-test.sh` runs the real pinned FinaSU Kbuild and certificate
matcher against its public release certificate (unchanged from v1.2.1 to
v1.6.5). It reproduces rejection
with the upstream default key, verifies our release-slot arguments authorize
FinaSU while other preset managers stay untrusted, and rejects an Image missing
the release certificate hash. Each FinaSU build also runs this matcher test
against the driver revision it actually checked out, before compiling the
kernel. `lib/finasu-manager.sh` supplies the release identity to every make
invocation; full builds and packaging independently verify the final Image.
`lib/finasu-release.sh` keeps the source commit and matching APK URL/digest
together. The same test job downloads the paired APK and checks its digest and
APK v2 signer against the pinned identity with `tests/finasu-release-test.py`.
`tests/finasu-integration-test.py` applies the guarded netisolate stack patch to
the exact release, compiles the real cleanup function with its UAPI structures,
reproduces the old 2 KiB stack-limit failure, and checks the corrected cleanup
order. It also rejects source drift and missing, wrong-architecture, or
unembedded preinit artifacts. `lib/finasu-integration.sh` applies that patch and
checks preinit in smoke builds, full builds, and packaging. FinaSU config enables
`CONFIG_HEADERS_INSTALL`, disables debug, and installs UAPI headers before
adding `KSU_REQUIRE_PREINIT=1` to subsequent make invocations. Base/NoMount-only
presets use Tracepoint; SUSFS presets use the checked SUSFS Inline backend.
`tests/finasu-features-test.sh` composes all four per-KMI SUSFS snapshots with
the pinned driver. It checks Kconfig/command coverage, executes the real SUSFS
reboot dispatcher (including root restrictions and FD cleanup), and checks the
NoMount add/list/delete wire layouts against ksud. NoMount source integration
is exercised in both `fs/` and `common/fs/` layouts with idempotence checks.
`install_finasu_nomount` verifies the vendored NoMount source digests and reuses the
shared NoMount Kconfig/Makefile wiring. It avoids a floating driver update that
could silently break FinaSU's userspace rule protocol.
crDroid 13 coverage checks Android 17 branch inference, the pinned
`clang-r584948` toolchain, automatic/manual resolver output for all three
crDroid profiles, retained Android 16 selection, and Android 17 ZIP properties.
Android batch coverage resolves A16/A17 separately for all three crDroid
profiles, checks the corresponding recommended Clang and module branches,
and rejects unsupported profiles or an unexpanded batch selection. Real
packaging fixtures check both version gates and A16/A17 filename suffixes.
`tests/android-batch-test.py` runs metadata generation and release staging for
six root/version variants with identical source commits and timestamps. It
checks independent artifacts/caches, retained manifests and checksums, and
rejection of corrupted files or colliding asset names.

The push/PR validation workflow runs Bash syntax checks, ShellCheck, these
offline tests, and actionlint. A separate `tests/ksu-uapi-test.sh` integration
test composes the exact upstream drivers with SUSFS and the backports, then
executes the real C service handlers and symbol resolver with host mocks.
It checks restart semantics, duplicate/suffixed/module symbols, lookup argument
errors, capability/permission wiring, idempotence, and rejection of source drift.
Extension tests execute the real bridge for all KPM/SuSFS config combinations,
checking wire layout, routing, unsupported operations, and copy errors.
`tests/kpm-image-test.sh` checks download integrity, patch failure handling,
output inspection, and rejection of a missing or stale Image proof.
`tests/download-clang-test.py` exercises truncated HTTP-success downloads,
invalid tar archives, missing tools, retry exhaustion, and staged installation.
`tests/anykernel-slot-test.py` runs both patched upstream slot-detection paths
against property/cmdline/bootconfig fixtures and rejects invalid or absent slots.
The scheduled upstream-health workflow resolves
every profile and runs a matrix covering KernelSU-Next + SUSFS + NoMount, the combined
SukiSU Ultra + SUSFS + NoMount + KPM preset, and BakaSU + SUSFS + NoMount on
representative SM7550, SM8450, SM8550 (including crDroid), and SM8650 sources,
including targeted
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
