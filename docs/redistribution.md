# Redistribution and licensing

> This is a technical summary to steer the project, not legal advice.
> Get the open questions below answered — in writing, by the CachyOS team
> where their policy is concerned — before distributing any image.

## Two different activities

| | A. Publishing this source repository | B. Distributing an operating-system image |
|---|---|---|
| What | Own scripts, configuration, docs, patches; a *reference* (URL + commit) to upstream | An ISO, VM disk, container image or sysroot that contains packages from the CachyOS repositories or has them configured |
| Contains CachyOS packages? | No | Yes — kernel, settings, keyring, installer, … and `pacman.conf` with `[cachyos]` |
| Status | Done (public GitHub repository, GPL-3.0-or-later) | **Not allowed for this project today** |

## CachyOS Repository Usage Policy

Source: <https://wiki.cachyos.org/policy/repository_policy/> (last updated
2026-06-01 when reviewed on 2026-10-15). Relevant sections:

- **§4/§5 Supported users** — only CachyOS and Arch Linux users are
  supported; other distributions are strongly discouraged from using the
  repositories.
- **§6 Redistribution** — defined as including the CachyOS repository, its
  mirrors, or packages obtained from it *as part of a distributed operating
  system image or sysroot*. It also covers Linux distributions that ship
  tools or official documents enabling the CachyOS repository. The policy
  states redistribution is "exclusively authorized to the CachyOS team only".
  End users and third-party mirrors are exempt.
- **§7 Prohibited redistribution** — unauthorized redistribution in any
  Linux distribution, explicitly including other Arch-based ones, is
  prohibited.
- **§8 Mirrors** — mirroring (rsync, syncthing) is allowed if the data
  stays unchanged.
- **§9/§11** — CachyOS may monitor use, revoke access, and change the policy
  at any time.

### Consequences for this project

1. **Building for yourself is end use.** Building an ISO from this repository
   on your own machine and using it yourself does not distribute anything.
2. **No public images.** Do not upload ISOs, VM images, or the build container
   image (it contains `cachyos-keyring` and the `[cachyos]` repository) anywhere
   public: not as GitHub release, not as Actions artifact, not to a registry or
   file host. CI is built accordingly; `validate.sh` rejects workflows that
   upload ISO files.
3. **Keep the repository a build recipe**, not a distribution: it documents
   how *you* build locally, the same way upstream's own public README does.
   Do not market it as a distribution that users should switch to. Whether
   the CachyOS team considers a public build recipe for a derivative to fall
   under §6 is an **open question** (see below).
4. **Paths to a distributable image**, each requiring its own decision:
   - written authorization from the CachyOS team for a defined scope, or
   - replacing everything obtained from the CachyOS repositories with own
     builds from the public PKGBUILDs (under their licenses), served from an own
     repository, with own branding — i.e. a fork with significant build
     infrastructure, or
   - basing a distributable image on Arch Linux packages only.

## Licenses

| Component | License (as declared) | Note |
|-----------|-----------------------|------|
| This repository | GPL-3.0-or-later | [LICENSE](../LICENSE) |
| `patches/*.patch` | license of the patched upstream file | derivative of upstream files |
| CachyOS-Live-ISO | `LICENSE` file: GPL-3.0; script headers: "GPL … version 2 of the License" | inconsistent → open question |
| archiso | GPL-3.0-or-later | build tool; parts end up in the image |
| cachyos-keyring | GPL-3.0-or-later (PKGBUILD) | |
| CachyOS-Settings, cachyos-welcome, chwd, linux-cachyos (repo) | GPL-3.0 (repository license) | the kernel itself is GPL-2.0 |
| cachyos-calamares | REUSE set: GPL-3.0-or-later, LGPL-2.1-only, LGPL-3.0-or-later, BSD-2-Clause, MIT, CC0-1.0, CC-BY-4.0 | per-file |
| cachyos-kde-settings, CachyOS-PKGBUILDS | no repository-level license detected | per package / open question |

Checked via the GitHub license API and the repositories' license files on
2026-10-15. Our own code only *invokes* upstream's `buildiso.sh` and is
distributed separately from it, so GPL-3.0-or-later is compatible with both
readings of the upstream license; patches follow the patched file.

### If an image is ever distributed

Independent of the CachyOS policy, distributing an image means:

- **Corresponding source** for every GPL/LGPL component in the image (≈ 200
  top-level packages plus dependencies) must be provided or offered
  (GPL-3.0 §6, GPL-2.0 §3) — e.g. a source mirror per release.
- **Non-free components** need individual review of their redistribution
  terms: `nvidia-utils`, `linux-firmware*`, `sof-firmware`, CPU microcode.
- **ZFS**: upstream ships prebuilt `linux-cachyos-*-zfs` kernel modules
  (CDDL-licensed ZFS combined with the GPL-2.0 kernel). Distributing such
  binaries is legally contested; decide deliberately whether to keep them.
- **Trademarks and branding**: the image identifies itself as CachyOS
  (`/etc/os-release`, boot menu, motd, logos). A distributed derivative must
  not present itself as CachyOS; rebranding is required unless agreed
  otherwise. The repository policy does not cover trademarks — ask.
- **Signing and checksums** under the project's own key, a security
  contact and an update/end-of-life statement.

## Open questions (to clarify before any public image)

1. Does CachyOS authorize redistribution of an image built from this
   repository (scope, branding, attribution, mirror use)?
2. Is a public build recipe for a CachyOS-based derivative acceptable under §6?
3. Which license applies to CachyOS-Live-ISO: GPL-3.0 (LICENSE) or GPL-2.0
   (file headers)? Under which license are cachyos-kde-settings and the
   PKGBUILDs offered?
4. Trademark use: may the name "CachyOS" appear in "based on CachyOS"
   statements, and what must be rebranded?
5. Should prebuilt ZFS modules and proprietary NVIDIA components be shipped?

## Pre-release checklist

- [ ] Written answer to open questions 1, 2 and 4
- [ ] Product name and branding decided; CachyOS branding replaced where required
- [ ] Source-offer process for all GPL/LGPL packages in the image
- [ ] Redistribution terms of non-free components and ZFS reviewed
- [ ] Release signing key, checksums, security contact
- [ ] Reproducible build verified ([roadmap.md](roadmap.md))
