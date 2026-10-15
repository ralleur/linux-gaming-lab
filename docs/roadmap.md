# Roadmap

The project grows in small, verifiable iterations. Each milestone is an
issue; nothing beyond the current foundation is implemented yet.

## Phase 0 — Foundation (done)

- Upstream CachyOS-Live-ISO pinned by commit, tree hash and date
- Assembly of build trees from upstream + patches + overlay modules + package lists
- Isolated build environment (container) mirroring upstream's CI
- Build entry point with environment, dependency and privilege checks
- Upstream update script with automatic compatibility checks and rollback
- CI: validation, shellcheck, actionlint, tests on Linux and macOS,
  upstream reference check, build-environment check
- Documentation, including redistribution constraints

## Phase 1 — Reproducible ISO build

[#1 Reproducible ISO Build](https://github.com/ralleur/linux-gaming-lab/issues/1):
verify a complete ISO build in the isolated environment, add a manually
triggered ISO build workflow that keeps the image private (no artifact
upload of the ISO), add boot/installation smoke tests (QEMU, possibly
upstream's quicktest), and decide how far to pin package versions.

## Phase 2 — Product baseline (parallel tracks)

- [#2 Gaming Desktop Baseline](https://github.com/ralleur/linux-gaming-lab/issues/2):
  package and configuration baseline for KDE Plasma, Steam and gaming tools —
  including the decision how to influence the *installed* system (Calamares
  configuration), not only the live ISO.
- [#3 Hardware Compatibility](https://github.com/ralleur/linux-gaming-lab/issues/3):
  NVIDIA, AMD and Intel support (as delivered by CachyOS today) and a test matrix.
- [#4 Upstream Update Strategy](https://github.com/ralleur/linux-gaming-lab/issues/4):
  cadence, automated update pull requests, compatibility gates.

## Later (not scheduled)

- Product name and branding
- Clarification of the redistribution questions in [redistribution.md](redistribution.md)
- Own package repository (only if needed for own software)
- Release process: signing, checksums, source offers — only after the
  redistribution questions are resolved
- Additional profiles (e.g. handheld, minimal)
