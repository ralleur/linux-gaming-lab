# Architecture

This document records how upstream builds its ISO, which approach this
project chose on that basis, and why.

## 1. Upstream analysis

Analyzed: [CachyOS/CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO)
at `3215497d2e8c` (2026-10-03, branch `master`, 564 commits, ~2 MB history).

### Structure

| Path | Role |
|------|------|
| `archiso/` | A standard [archiso](https://gitlab.archlinux.org/archlinux/archiso) profile: `profiledef.sh`, `pacman.conf`, `packages_desktop.x86_64` (~200 packages), `airootfs/` (live system files), boot loader configs (`grub/`, `syslinux/`, `efiboot/`) |
| `buildiso.sh` + `util*.sh` | Wrapper around `mkarchiso` (derived from Manjaro tools) |
| `.github/workflows/build.yml` | Official CI: builds the ISO in an `archlinux:base-devel` container (`--privileged`), then installs it in VMs with [quicktest](https://github.com/quickemu-project/quicktest) for 4 boot loaders × 5 file systems |
| `testcases/`, `machines/` | quicktest scenarios (Calamares installation) |

### Official build process (`buildiso.sh -p desktop`)

1. `prepare_profile` **writes into its own source tree**: version into
   `archiso/grub/grub.cfg`, `airootfs/etc/motd`, `etc/environment`,
   `etc/version-tag`, `etc/edition-tag`, the display-manager symlink, and
   copies `packages_desktop.x86_64` to `packages.x86_64`.
2. It downloads `cachyos-mirrorlist` from the **`master` branch** of
   CachyOS-PKGBUILDS (unpinned network input).
3. `modify_mkarchiso` patches **`/usr/bin/mkarchiso` of the build host** with
   `sudo sed -i` (removes the archlinux-keyring WKD timer from the image).
4. `sudo mkarchiso` installs the packages with pacstrap from the CachyOS and
   Arch repositories (rolling, unpinned) and creates the ISO. Boot modes:
   `bios.syslinux` + `uefi.grub`; squashfs with xz.
5. The ISO is renamed `cachyos-desktop-linux-<YYMMDD>.iso`, checksums are
   created, and it is signed only if a `GPGKEY` is configured.

Further observations:

- `desktop` is the only buildset `prepare_profile` accepts.
- The live session runs KDE Plasma (Wayland) with `plasma-login-manager`;
  the installer is **Calamares, installed and updated online at start**
  (`calamares-online.sh` runs `pacman -Sy cachyos-calamares-next`). The
  desktop environment, boot loader and file system of the *installed* system
  are chosen in Calamares and pulled from the repositories at install time.
- The build host needs the CachyOS signing key and the `[cachyos]` repository
  (the CI imports key `F3B607488DB35A47` and inserts `[cachyos]` before `[core]`).
- The repository's `LICENSE` is GPL-3.0, while the shell scripts carry a
  "version 2 of the License" header (see [redistribution.md](redistribution.md#licenses)).

## 2. Decision: pinned upstream + overlays + patches

The upstream repository is small and is itself only an archiso profile plus a
wrapper. The cleanest way to stay "upstream first" is therefore to **not copy
it at all**, but to pin it and assemble a build tree from it on demand.

| Option | Verdict |
|--------|---------|
| Fork of CachyOS-Live-ISO | Rejected: our changes would be interleaved with upstream history; every update is a merge with conflicts in the same files; changes are hard to enumerate. |
| Vendored copy in this repository | Rejected: duplicates upstream, hides which lines are ours, updates are manual diffs. |
| Git submodule | Considered: pins natively, but the build mutates the source tree (step 1 above), so a separate work copy is needed anyway; submodules add friction and cannot carry a tree-hash/date check. |
| **Lock file + fetched cache + assembled work tree** | **Chosen.** Explicit, reviewable pin (`config/upstream.lock`); upstream stays pristine; our changes are separate files; one script reports exactly what differs. |

## 3. Build pipeline

```text
                    config/upstream.lock (URL, branch, commit, tree, date)
                                   │
scripts/bootstrap.sh   fetch branch ─► verify commit exists, tree hash, commit date
                                   │   (CI: commit is an ancestor of the branch)
                                   ▼
                    .cache/upstream/CachyOS-Live-ISO        never modified by builds
                                   │ git archive <commit>
scripts/prepare.sh                 ▼
                    build/<profile>/src  ── throwaway git repo, tag 'upstream'
                      1. patches/*.patch        git apply --index, in order
                      2. overlays/<module>/airootfs/  → archiso/airootfs/
                      3. packages.remove / packages.add → archiso/packages_<buildset>.x86_64
                      4. etc/linux-gaming-lab/build-info (provenance)
                      5. commit → manifest.txt, changes.{stat,files,patch}
                                   │
scripts/build.sh (inside the isolated build environment only)
                      environment + dependency checks → bootstrap → prepare
                      → upstream ./buildiso.sh -p <buildset> -w → out/<profile>/
```

Because upstream's `buildiso.sh` runs unchanged inside the assembled tree, all
of upstream's behavior (versioning, mirrorlist, boot loaders, checksums)
applies automatically and updates arrive with each new pin.

### Components

- **Upstream lock** (`config/upstream.lock`): parsed, never sourced. Pins
  commit *and* tree hash and commit date, so a rewritten or substituted
  commit is detected.
- **Profiles** (`profiles/<name>/profile.conf`): a build variant. Selects the
  upstream buildset (`UPSTREAM_BUILDSET`) and the overlay modules
  (`OVERLAYS`), optionally adds/removes packages.
- **Overlay modules** (`overlays/<module>/`): a self-contained feature —
  files for the live system under `airootfs/` plus optional `packages.add` /
  `packages.remove`. Profiles combine modules, e.g. later
  `common gaming-kde hw-nvidia`.
- **Patches** (`patches/NNNN-*.patch`): the only way to *change* upstream
  files. Strict application (no fuzz) makes every upstream conflict visible.
- **Change record**: `build/<profile>/manifest.txt`, `changes.stat`,
  `changes.files` and `changes.patch` describe the exact difference between
  the build tree and the pinned upstream. The build-info file inside the image
  links an ISO back to the source revision.
- **Build environment** (`container/Containerfile`, `config/build-env.conf`):
  reproduces upstream's CI environment with a digest-pinned base image and
  the CachyOS key pinned by full fingerprint.

### Isolation

Upstream's build modifies `/usr/bin/mkarchiso`, needs root and mounts file
systems. `scripts/build.sh` therefore refuses to run unless it detects a
container (or `LGL_ALLOW_HOST_BUILD=1` is set in a dedicated VM), runs as an
unprivileged user with sudo, and probes that mounting works.
`scripts/bootstrap.sh`, `prepare.sh`, `update-upstream.sh` and `validate.sh`
write only below `.cache/`, `build/` and `config/upstream.lock` and run on any
Linux or macOS host. Deletions go through `safe_rmtree`, which only removes
paths inside the work/cache directories and refuses if anything is still
mounted below them.

## 4. Where future customizations go

| Change | Mechanism |
|--------|-----------|
| Configuration files, skel defaults, systemd units in the **live** system | overlay module (`airootfs/`) |
| Packages in the **live** system | `packages.add` / `packages.remove` of a module or profile |
| Behavior of upstream files (boot menu, `profiledef.sh`, scripts) | patch |
| Hardware-specific tweaks | dedicated overlay module per vendor/device, combined per profile |
| New variant (e.g. handheld, minimal) | new profile |
| **Installed** system (packages, DE, defaults chosen in Calamares) | not covered yet: requires an own Calamares configuration/netinstall source, see [roadmap.md](roadmap.md) |
| Own software | not covered yet: needs own packages and an own repository, see [redistribution.md](redistribution.md) |

## 5. Reproducibility: what is pinned

| Input | Pinned? | Where |
|-------|---------|-------|
| Upstream ISO profile and scripts | yes — commit, tree, date | `config/upstream.lock` |
| Our patches, overlays, profiles | yes — git revision | `build-info` in the image, `manifest.txt` |
| Build environment base image | yes — digest | `config/build-env.conf` |
| CachyOS signing key | yes — full fingerprint | `config/build-env.conf` |
| Build tool versions (archiso, grub, …) | no — latest at image build time | recorded by `pacman -Q` in the container |
| Packages in the ISO | no — rolling repositories | `out/<profile>/*.pkgs.txt` lists exact versions |
| Mirrorlist in the ISO | no — fetched from CachyOS-PKGBUILDS `master` | upstream behavior |
| ISO file name / version | date-based | upstream behavior |

A given source revision therefore always produces the same *build tree*
(verified by CI). Bit-identical ISOs additionally require pinned package
snapshots; this is part of the "Reproducible ISO Build" milestone in
[roadmap.md](roadmap.md).

## 6. Known limitations

- Overlay files are copied by mkarchiso with `--no-preserve=ownership,mode`.
  Executable overlay files therefore need an entry in `file_permissions` of
  `profiledef.sh` (currently via a patch).
- The `.gitignore` shipped by upstream applies inside the work tree, so files
  it ignores (e.g. `airootfs/etc/motd`) do not appear in the change record.
- Only upstream buildset `desktop` exists.
- A full ISO build has not yet been verified with this tooling (environment
  checks and tree assembly are; see [build.md](build.md#verification-status)).
