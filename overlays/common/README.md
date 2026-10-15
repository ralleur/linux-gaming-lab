# Overlay module `common`

Applied by every profile. Contains only project provenance for now:

| File | Purpose |
|------|---------|
| `airootfs/etc/linux-gaming-lab/README` | States that the image is an unofficial linux-gaming-lab build and links project and upstream. |

`scripts/prepare.sh` additionally generates `/etc/linux-gaming-lab/build-info`
(project revision, upstream commit, profile, overlays, patches).

See [docs/development.md](../../docs/development.md) for how overlay modules work.
