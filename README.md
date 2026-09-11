# OnePlus Snapdragon Kernel Builder

GitHub Actions pipeline for building selected OnePlus Snapdragon 7 Gen 3(SM7550),
8 Gen 1(SM8450), 8 Gen 2(SM8550), and 8 Gen 3(SM8650) kernels. The repository contains the build
pipeline, validation, packaging, and release automation; kernel sources are
resolved from upstream repositories at build time.

## Supported build profiles

The workflow exposes only device/source combinations that are intentionally
configured. This avoids late failures caused by selecting an incompatible SoC
and source independently.

| SoC | Target device | AnyKernel accepted device IDs | Source preset |
| --- | --- | --- | --- |
| `sm7550` | OnePlus Nord CE4 | `benz`, `OP5D3FL1`, `CPH2613` | Nord CE4 development |
| `sm7550` | OnePlus Nord CE4 | `benz`, `OP5D3FL1`, `CPH2613` | crDroid (recommended for crDroid) |
| `sm8450` | OnePlus 10 Pro | `negroni`, `OP516EL1`, `OP516FL1` | OnePlus official |
| `sm8450` | OnePlus 10T / Ace Pro | `ovaltine`, `OP5551L1`, `OP5552L1` | LineageOS community |
| `sm8550` | OnePlus 11 | `salami`, `OP591BL1`, `OP594DL1` | OnePlus official |
| `sm8550` | OnePlus 11 | `salami`, `OP591BL1`, `OP594DL1` | LunarisOS |
| `sm8550` | OnePlus 11 / 12R | OnePlus 11 IDs plus `aston`, `OP5D35L1` | LineageOS |
| `sm8550` | OnePlus 11 / 12R | OnePlus 11 IDs plus `aston`, `OP5D35L1` | crDroid |
| `sm8550` | OnePlus 12R | `aston`, `OP5D35L1` | OnePlus 12R development |
| `sm8650` | OnePlus 12 | `waffle`, `OP5929L1`, `OP595DL1` | OnePlus official |
| `sm8650` | OnePlus 12 | `waffle`, `OP5929L1`, `OP595DL1` | LineageOS |
| `sm8650` | OnePlus 12 | `waffle`, `OP5929L1`, `OP595DL1` | crDroid |

The OnePlus 10T community source is intentionally labeled `ovaltine`; it is
not presented as a OnePlus 10 Pro source.

The Nord CE4 source projects store their SM7550/crow device support in
`sm8550`-named kernel and modules repositories and build it with the Kalama
GKI fragments plus the benz-specific `CONFIG_OPLUS_DEVICE_DTBS=y` and
`CONFIG_BENZ_DTB=y` make flags. The profiles keep the real `sm7550` device
identity in release metadata while resolving that upstream naming explicitly.
Use the dedicated crDroid profile on crDroid: it pins crDroid's own `16.0`
kernel and modules instead of the unrelated development/Lineage branch, which
is not ABI-compatible with crDroid's first-stage vendor modules.

The LunarisOS OnePlus 11 profile follows the kernel source published in the
LunarisOS OTA metadata. Its maintainer kernel uses `lineage-23.2`, while its
matching external modules use the `los` branch; the resolver pins both branches
independently and records both exact commits in the build provenance.

Every package accepts both its custom-ROM codename and the device-specific
stock board IDs published by the corresponding device tree. Generic SoC board
names such as `taro`, `kalama`, and `pineapple` are deliberately excluded so a
package cannot pass the check merely because another phone shares its chipset.
The check remains enabled, and a rejected flash prints all four device values
reported to AnyKernel so a genuinely missing regional alias can be diagnosed
safely.

## Build modes

`Build OnePlus Kernel` offers three modes:

- `Patch/config validation only` clones exact upstream revisions, applies the
  selected KernelSU/KPM/SUSFS/NoMount integration, verifies the final config,
  and smoke-compiles the affected KPM, SUSFS, VFS, proc, reboot, and NoMount
  objects without spending time on a full kernel compile.
- `Full build (artifact only)` builds and uploads a 14-day workflow artifact.
  This is the default and does not create a permanent GitHub Release.
- `Full build and publish release` first reserves an immutable tag at the
  workflow commit, builds the same verified artifact, then a separate
  least-privilege job publishes the release from that tag.

## Root integrations

Available workflow presets:

| Preset | Integration | Status |
| --- | --- | --- |
| `No root changes` | No root integration | Baseline |
| `Official KernelSU` | Official KernelSU | Supported |
| `KernelSU-Next` | KernelSU-Next | Supported |
| `KernelSU-Next + SUSFS` | KernelSU-Next with SUSFS | Supported |
| `KowSU` | KowSU | Supported |
| `SukiSU Ultra + KPM (experimental)` | SukiSU Ultra with KPM | Experimental |
| `SukiSU Ultra + SUSFS + KPM (experimental)` | SukiSU Ultra with SUSFS and KPM | Experimental |
| `SukiSU Ultra + SUSFS + NoMount + KPM (experimental)` | SukiSU Ultra with SUSFS, NoMount, and KPM | Experimental |
| `ReSukiSU` | ReSukiSU | Supported |
| `ReSukiSU + susfs` | ReSukiSU with SUSFS | Supported |
| `ReSukiSU + SUSFS + NoMount (experimental)` | ReSukiSU with SUSFS and NoMount | Experimental |

KPM is available only through the dedicated SukiSU Ultra presets because current
ReSukiSU no longer supports it. The pipeline resolves SukiSU Ultra to an exact
`main` commit, checks its KPM sources and Kbuild wiring, and enables `CONFIG_KPM`,
`CONFIG_KALLSYMS`, and `CONFIG_KALLSYMS_ALL`. The SUSFS presets additionally
resolve and apply the matching SUSFS branch at an exact commit. The four-feature
preset also resolves NoMount at an exact commit and enables `CONFIG_KEYS` and
`CONFIG_NOMOUNT`. Validation mode compiles the KPM, SUSFS, VFS, and NoMount
integration objects and checks their exported signatures; a full build repeats
the signature checks against the final kernel artifacts. Both paths fail closed
when expected wiring, config, objects, or symbols are missing. KPM resolver
verification uses AOSP Clang's LTO-aware `llvm-nm` on the compiled resolver
object instead of GNU `nm` on the aggregate LTO intermediate.

SUSFS branches are selected from the SoC and Android/kernel branch. Known vendor
include drift and the current SukiSU Ultra UTS-spoof, KPM resolver, kernel-umount,
and allowlist drift are repaired only for explicitly recognized conflicts. The
compatibility checks keep the KPM symbol resolver linked and initialized and
preserve SukiSU's WebView zygote policy after the SUSFS patch. Unknown patch
rejects fail closed and are included in diagnostics.

The KernelSU-Next + SUSFS preset resolves `pershoot/KernelSU-Next@dev-susfs`
to an exact commit. The regular KernelSU-Next preset remains on the official
`KernelSU-Next/KernelSU-Next@dev` branch. The compatibility branch is required
because the SUSFS KernelSU-side patch does not apply to the current official
development tree; the pipeline still takes the kernel-side SUSFS files and
patch from `simonpunk/susfs4ksu` at an exact commit.

SUSFS builds require upstream v2.2.0 or newer and explicitly verify the
`SUS_MAP` and `OPEN_REDIRECT` features in the final config. The NoMount presets
integrate the exact resolved `master` commit, enable `CONFIG_NOMOUNT=y`, and
checks both source wiring and final kernel signatures. NoMount hooks VFS
operations and is marked experimental by its upstream project, so it remains
an explicit opt-in instead of changing existing build presets.

## Quick start

1. Open `Actions` -> `Build OnePlus Kernel` -> `Run workflow`.
2. Select one device/source profile.
3. Keep automatic branch and Clang selection unless testing a known branch.
4. Select the root integration.
5. Start with `Patch/config validation only` after an upstream update, then run
   a full build when validation passes.
6. Use release mode only for an artifact you intend to keep or distribute.

Manually selected branch names are validated with Git before they are written
to GitHub Actions environment files. Every kernel, modules, root implementation,
SUSFS, NoMount, and AnyKernel input is resolved to an exact commit before cloning.

## Build performance

The full build passes `CC="ccache clang"` and host compiler wrappers directly
on every `make` invocation so Kbuild cannot replace the ccache launcher.
Build timestamps, user, and host metadata are deterministic for a given kernel
commit, which improves repeat-build cache hits.

The workflow also:

- clones kernel and modules repositories in parallel at exact commits
- caches the exact pinned AOSP Clang archive
- restores a profile/branch/compiler-specific 3 GB compressed ccache
- reports config, compile, total time, and ccache statistics in the job summary
- uses an adaptive 8/16 GB swap file with low swappiness for full builds

GitHub cache entries are an optimization only. A build remains able to download
or regenerate every cached input.

## Safe packaging and provenance

Generated AnyKernel3 ZIPs enable `do.devicecheck=1` and contain only the
device-specific codenames and stock board IDs assigned to the selected profile.
Android version checking is also enabled when the selected branch identifies a
known Android generation.

Each full build produces `release-assets/` containing:

- a device-checked AnyKernel3 ZIP
- a uniquely named raw `Image`
- `build-info.json` with all exact source commits, the KPM enabled state, and
  the workflow run URL
- `SHA256SUMS`
- generated `release-notes.md`

GitHub Actions uploads these release-ready files as one flat package artifact.
Build logs and configuration are kept in a separate diagnostics artifact,
along with `kpm-source-proof.txt` and `kpm-proof.txt` when KPM is selected (and
equivalent SUSFS/NoMount proofs for those presets). The release job downloads
only the package artifact and verifies its checksums before publishing.

The same `build-info.json` is embedded in the flashable ZIP. Keep a known-good
stock boot image available and never flash a package whose device check does
not match the phone.

## CI security and reliability

The tag-reservation job has `contents: write` but checks out and executes no
repository or external source. The build job keeps read-only repository
permissions and does not persist checkout credentials, so external kernel
Makefiles never run with release write credentials. After a successful build,
the separate publication job receives `contents: write`, verifies the reserved
tag and artifact checksums, and creates the Release. A failed build removes its
unused reserved tag automatically.

Network Git operations use bounded retries. Release creation and asset uploads
are idempotent, time-limited, and retried, preventing a stalled upload from
holding the build runner indefinitely.

All third-party GitHub Actions are pinned to full commit hashes. AOSP Clang
archive URLs are pinned to exact Gitiles commits, and changing the downloader
invalidates the toolchain cache.

## Validation and upstream health

Pushes and pull requests run:

- Bash syntax checks
- ShellCheck at warning severity
- offline tests for all twelve profile mappings, root mappings (including
  KernelSU-Next + SUSFS and SukiSU Ultra + SUSFS + NoMount + KPM), Clang selection,
  KPM configuration, SUSFS selection/version floor, NoMount selection/wiring,
  Android version inference, and workflow option synchronization
- actionlint for all workflow files

`Check upstream health` runs every Monday and can also be started manually. It
resolves exact commits for all twelve profiles, then runs a seventeen-job
smoke-test matrix: KernelSU-Next + SUSFS, SukiSU Ultra + SUSFS + NoMount + KPM,
and ReSukiSU + SUSFS + NoMount are validated on representative SM7550 (including
both CE4 source families), SM8450, SM8550, and SM8650 sources, with an additional
baseline validation for the LunarisOS OnePlus 11 and crDroid OnePlus 12 sources.

## Important limitations

- A successful build does not prove that a kernel is safe for every firmware,
  region, or boot stack of the listed device.
- Community sources are not official OnePlus sources.
- Manual or unusual branches may disable Android version checking when their
  version cannot be inferred safely.
- This pipeline builds the raw GKI `Image`; it does not rebuild every vendor
  module or replace device-specific firmware.
- NoMount modifies VFS behavior and upstream labels it experimental. Test its
  opt-in presets on a recoverable device before distributing them.
- KPM dynamically patches kernel behavior at runtime. Treat all SukiSU Ultra
  presets as experimental and test them only on a recoverable device.
- Runtime performance tuning is intentionally left at upstream/vendor config
  defaults. Options such as KASAN, LTO mode, scheduler changes, and compiler
  optimization flags require device-specific boot, stability, power, and
  benchmark testing before becoming defaults.
