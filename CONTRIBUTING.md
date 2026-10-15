# Contributing

Thanks for helping! This project is an experimental customization layer on
top of CachyOS. Please read [docs/architecture.md](docs/architecture.md) first.

## Principles

1. **Upstream first.** Change as little of CachyOS as possible. If a fix is
   useful for CachyOS itself, propose it upstream and link it.
2. **One change, one mechanism.** New files → overlay; changed upstream files
   → patch; packages → package lists; variants → profiles
   ([docs/development.md](docs/development.md)).
3. **Traceable.** Every difference to upstream must show up in
   `build/<profile>/manifest.txt`.
4. **Small steps.** Open or reference an issue before larger changes.

## Workflow

```bash
git switch -c <topic>
# make the change
scripts/validate.sh
tests/run.sh
scripts/prepare.sh default && cat build/default/manifest.txt
git commit -s -m "area: short summary"
```

- Branch from `main`, open a pull request, keep CI green.
- Commit subjects: `area: summary` (e.g. `overlays: add gaming-kde module`,
  `upstream: bump CachyOS-Live-ISO to 1a2b3c4d5e6f`, `ci: …`, `docs: …`).
- Sign off your commits (`git commit -s`, [Developer Certificate of Origin](https://developercertificate.org/)).
- Add a line under *Unreleased* in [CHANGELOG.md](CHANGELOG.md).

## Code standards

- Bash, compatible with bash 3.2 (macOS) — enforced by `scripts/validate.sh`.
- `#!/usr/bin/env bash`, `set -Eeuo pipefail`, `# SPDX-License-Identifier: GPL-3.0-or-later`.
- shellcheck-clean (CI runs a pinned shellcheck).
- Config files are parsed, never sourced. Fail loudly with an actionable
  message (`die "..."`), never silently.
- Nothing outside `.cache/`, `build/`, `out/` may be written by host-side
  scripts; root-only steps belong in `scripts/build.sh`.
- GitHub Actions are pinned to full commit SHAs; workflows get least-privilege
  `permissions`.

## What must never be committed

- Secrets, tokens, private keys, passwords (`validate.sh` scans for common patterns)
- ISO images, packages or other build outputs
- Copies of upstream files (use a patch instead)

## Licensing

Contributions are licensed under GPL-3.0-or-later. Patches in `patches/`
are licensed like the upstream file they modify.
