# Overlay module `desktop-hyprland`

The desktop base of this project: Hyprland with the noctalia shell, as
CachyOS ships it in its Hyprland edition (package `cachyos-hypr-noctalia`).

| Part | Content |
|------|---------|
| `packages.add` | `cachyos-hypr-noctalia`, which installs Hyprland, noctalia and CachyOS's default configuration under `/etc/skel` |
| `airootfs/etc/skel/` | Only the files this project changes compared to that default, captured from the reference system with `scripts/capture.sh` |

CachyOS's defaults are the baseline. Files land here only when they are
deliberately changed, so `git diff` against the package's `/etc/skel` shows
exactly what this project customizes.

Open points:

- The live session still starts KDE Plasma via upstream's
  `plasma-login-manager`; switching the live session to Hyprland is a later step.
- What Calamares installs is not influenced yet (see
  [docs/roadmap.md](../../docs/roadmap.md)).

See [docs/workflow.md](../../docs/workflow.md) for how changes get here.
