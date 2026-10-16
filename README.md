# linux-gaming-lab

An experimental, open-source customization base for building a gaming- and
desktop-focused live/installer ISO on top of [CachyOS](https://cachyos.org)
(Arch Linux, x86_64, KDE Plasma on Wayland).

> **Status: experimental foundation.** This repository contains build tooling
> and configuration only. It publishes **no ISO images and no packages**.
> It is an independent project and **not affiliated with or endorsed by
> CachyOS**. Whether it becomes a remix, respin, fork or distribution — and
> its final name and branding — is intentionally still open.

## Goals

| Principle | How this repository implements it |
|-----------|-----------------------------------|
| Upstream first | The official [CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO) build is used unchanged and pinned to an exact commit. |
| Modular customizations | Own changes live in `patches/`, `overlays/` and `profiles/`, separate from the upstream tree. |
| Reproducibility | Upstream commit + tree hash, base image digest and signing-key fingerprint are pinned; every build writes a manifest of all changes. |
| Maintainability | `scripts/update-upstream.sh` moves the pin and re-checks every patch, overlay and package list automatically. |
| Open source | GPL-3.0-or-later; every change against upstream is a reviewable file in this repository. |
| No unnecessary decisions | The `default` profile builds upstream as-is plus a provenance file. |

## How it works

```text
config/upstream.lock ──► scripts/bootstrap.sh ──► .cache/upstream/CachyOS-Live-ISO  (pinned, verified, read-only)
                                                          │ git archive <commit>
patches/*.patch ─┐                                        ▼
overlays/<mod>/ ─┼──────────► scripts/prepare.sh ──► build/<profile>/src   (+ manifest.txt, changes.patch)
profiles/<p>/ ───┘                                        │ upstream ./buildiso.sh -p <buildset>
                                                          ▼
container/Containerfile ──► scripts/build.sh (isolated build env) ──► out/<profile>/*.iso  (local only)
```

Details: [docs/architecture.md](docs/architecture.md).

## Quick start

Works on Linux and macOS (no Arch Linux needed):

```bash
scripts/validate.sh          # structure, config, scripts, docs, secret scan
tests/run.sh                 # offline tests with an upstream fixture
scripts/bootstrap.sh         # fetch + verify the pinned upstream commit
scripts/prepare.sh default   # assemble build/default/src and the change record
```

ISO build — needs Docker (or Podman) on an x86_64 Linux host, or an Arch Linux VM:

```bash
scripts/build-in-container.sh --check   # verify the isolated build environment
scripts/build-in-container.sh default   # build out/default/*.iso
```

See [docs/build.md](docs/build.md) for requirements, macOS notes and how to test the ISO.

## Repository layout

| Path | Content |
|------|---------|
| `config/upstream.lock` | Pinned upstream repository, commit, tree hash and commit date |
| `config/build-env.conf` | Build environment pins: Arch base image digest, CachyOS key fingerprint |
| `container/Containerfile` | Isolated build environment, mirroring upstream's CI |
| `profiles/<name>/` | Build variants: upstream buildset, overlay modules, package changes |
| `overlays/<module>/` | Files added to the live system (`airootfs/`) plus package changes |
| `patches/` | Changes to upstream files, applied in order |
| `scripts/` | `bootstrap`, `prepare`, `build`, `build-in-container`, `update-upstream`, `validate`, `capture` |
| `tests/` | Offline tests for the build tooling |
| `docs/` | Architecture, build, upstream, development, redistribution, roadmap |

## Documentation

- [Architecture](docs/architecture.md) — upstream analysis and design decisions
- [Building and testing](docs/build.md) — build environment, ISO build, VM tests
- [Upstream tracking](docs/upstream.md) — pinning, updates, patches
- [Developing customizations](docs/development.md) — profiles, overlays, packages
- [Workflow](docs/workflow.md) — from an idea on the reference system to the repository
- [Redistribution and licensing](docs/redistribution.md) — **read before sharing any image**
- [Roadmap](docs/roadmap.md)
- [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)

## Redistribution notice

Publishing this source code and distributing an operating-system image are
different things. ISO images built from this repository contain packages
from the CachyOS repositories, and the
[CachyOS Repository Usage Policy](https://wiki.cachyos.org/policy/repository_policy/)
reserves redistribution of those to the CachyOS team. Build images for your own
use only and do not share them. See [docs/redistribution.md](docs/redistribution.md).

## License

The code and documentation in this repository are licensed under the
[GNU General Public License v3.0 or later](LICENSE). Files in `patches/` are
derived from upstream files and carry the license of the file they modify.
CachyOS, Arch Linux and all packages in a built image remain under their
respective licenses and trademarks.
