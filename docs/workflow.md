# Workflow: from an idea to the repository

Customizations are tried out on a running system first and only then
recorded in this repository. The ISO is built once the recorded state is
good enough; until then, the repository is the single place where the
intended system is described.

```text
idea ──► issue ──► try it on the reference system ──► live with it ──► capture ──► pull request ──► main
                    (snapshot first)                                  scripts/capture.sh
```

## Roles

| Thing | Role |
|-------|------|
| Reference system | A normal CachyOS Hyprland installation (btrfs, snapper, Limine) on which every change is made and used first |
| Distribution defaults | What CachyOS ships, e.g. `/etc/skel` from `cachyos-hypr-noctalia`; the baseline everything is compared against |
| Overlay modules | Only the deliberate differences from those defaults (see [development.md](development.md)) |
| Issues | The backlog: every idea or annoyance, however small |

## The loop

1. **Note it.** Open an issue for anything that stands out, one per topic.
   A sentence is enough.
2. **Snapshot.** Before a larger change, create a snapshot so it can be
   rolled back from the Limine boot menu:
   `sudo snapper -c root create -d "before: <issue title>"`.
   Configuration in `$HOME` is not part of the root snapshot; copy the
   affected files (or rely on git once they are captured).
3. **Change and use it.** Make the change on the reference system and live
   with it for a while. Revert what does not convince.
4. **Classify it.** Decide where the change belongs:

   | Kind | Example | Goes to |
   |------|---------|---------|
   | Desktop / product | key bindings, bar layout, default apps | `overlays/desktop-hyprland` or another `desktop-*`/`gaming-*` module |
   | Hardware-specific | NVIDIA power management on a laptop model | `overlays/hw-<vendor>-<model>` |
   | Personal | own accounts, a broken key on one device | stays on the machine; add it to `config/capture.ignore` |

5. **Capture it.**

   ```bash
   scripts/capture.sh                  # configuration differing from defaults or from the repo
   scripts/capture.sh packages         # installed packages the repo does not cover yet
   scripts/capture.sh add desktop-hyprland .config/hypr/config/binds.lua
   ```

   `add` copies a file from `$HOME` into the module's
   `airootfs/etc/skel/`. Packages go into the module's `packages.add`.
   Whole files are captured; keep personal settings out of files that are
   captured, or split them into a separate file the main file includes.

6. **Review and merge.** Work on a branch, run `scripts/validate.sh` and
   `tests/run.sh`, open a pull request that references the issue, merge
   after review.

## Reading the status

`scripts/capture.sh status` prints one line per file:

| State | Meaning |
|-------|---------|
| `modified` | differs from the distribution default and is not captured yet |
| `new` | exists only in `$HOME`, in a tracked directory (`.config/hypr`, `.config/noctalia`) |
| `changed` | captured in the named module, but the reference system has moved on |

Files that are rewritten automatically (for example noctalia's theme
templates) are listed in [`config/capture.ignore`](../config/capture.ignore).

## When to build the ISO

Only when the captured state is one worth keeping. Building, testing and
the redistribution constraints are described in [build.md](build.md) and
[redistribution.md](redistribution.md). Note that overlay modules currently
change the live system only; the installed system follows once the
installer can be influenced (see [roadmap.md](roadmap.md)).

## Open points

- **Own software** (`software/`, e.g. a screensaver): how it gets into the
  image (PKGBUILD, own package repository) is not decided yet; until then it
  cannot be captured with this workflow.
