# Developing customizations

Start every change from an issue, keep it as small as possible, and prefer
the least invasive mechanism. How changes get from a running system into
this repository is described in [workflow.md](workflow.md).

## Where does my change go?

| I want to … | Use | Example |
|-------------|-----|---------|
| add a file to the live system | overlay module `airootfs/` | `overlays/gaming-kde/airootfs/etc/skel/.config/kwinrc` |
| add / remove a package in the live system | `packages.add` / `packages.remove` | `overlays/gaming/packages.add`: `steam` |
| change a file that upstream ships | patch | `patches/0001-boot-menu-timeout.patch` |
| build a different variant | new profile | `profiles/gaming/profile.conf` |
| change what Calamares installs | not supported yet | see [roadmap.md](roadmap.md) |
| ship own software | not supported yet (needs own packages and repository) | see [redistribution.md](redistribution.md) |

## Overlay modules

```text
overlays/<module>/
├── README.md         what the module does and why (recommended)
├── airootfs/         copied into archiso/airootfs/ (the live root file system)
├── packages.add      optional, one package per line
└── packages.remove   optional, one package per line
```

- Module names: lowercase letters, digits, `-`. Suggested prefixes:
  `gaming-*`, `desktop-*`, `hw-<vendor>`, `svc-*`.
- Modules are applied in the order listed in the profile's `OVERLAYS`.
- Adding new files is preferred. Overriding an upstream file works but
  `prepare.sh` warns — use a patch so upstream changes stay visible.
- File modes are **not** preserved by mkarchiso; executables need an entry in
  `file_permissions` of `archiso/profiledef.sh` (via a patch).
- No secrets: `validate.sh` rejects key/credential-like files.
- Systemd units: place the unit under `airootfs/etc/systemd/system/` and the
  enablement symlink under the matching `*.wants/` directory.

## Package lists

- One package name per line, `#` starts a comment.
- `packages.remove` entries must exist upstream — otherwise `prepare.sh`
  fails, which surfaces upstream renames immediately.
- Adding a package that upstream already ships produces a warning: remove
  the redundant entry.
- These lists change the **live ISO**. The installed system is assembled by
  Calamares from the repositories at install time.

## Profiles

```text
profiles/<name>/
├── profile.conf      DESCRIPTION, UPSTREAM_BUILDSET, OVERLAYS
├── packages.add      optional
└── packages.remove   optional
```

```bash
mkdir profiles/gaming
cat > profiles/gaming/profile.conf <<'EOF'
DESCRIPTION=Gaming-focused live ISO
UPSTREAM_BUILDSET=desktop
OVERLAYS=common gaming-kde
EOF
scripts/prepare.sh gaming
```

## Development loop

```bash
scripts/validate.sh                      # fast static checks
tests/run.sh                             # tooling tests
scripts/prepare.sh <profile>             # assemble, then inspect:
cat build/<profile>/manifest.txt
git -C build/<profile>/src diff upstream --stat
scripts/build-in-container.sh <profile>  # full ISO (x86_64 Linux host)
```

`build/<profile>/src` is a throwaway git repository: `git diff upstream`
shows exactly what this project changes, file by file.

## Changing the tooling

- Scripts: bash ≥ 3.2 compatible (no `mapfile`, associative arrays,
  `${var,,}`; guard empty arrays), `set -Eeuo pipefail`, SPDX header,
  shellcheck-clean. `validate.sh` enforces this.
- Config files are parsed with `kv_get` / `kv_check`, never sourced.
- Anything destructive goes through `safe_rmtree`, and anything that needs
  root belongs in `scripts/build.sh` (isolated environment only).
- Add or extend a test in `tests/` for every behavior change.
