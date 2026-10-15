# Patches against upstream

Patches modify files of the pinned upstream
[CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO) checkout.
There are none yet: the `default` profile builds upstream unchanged.

Rules (enforced by `scripts/validate.sh`):

- File name `NNNN-short-description.patch`, applied in lexical order to every profile.
- Git-style unified diff with `a/` and `b/` prefixes, relative to the upstream
  repository root (create with `git format-patch` or `git diff`, see
  [docs/upstream.md](../docs/upstream.md#writing-a-patch)).
- One logical change per patch, with a header explaining *why* and, if it
  could benefit CachyOS, a link to the upstream issue or pull request.
- Use patches to *change* upstream files; use overlays to *add* files.

`scripts/prepare.sh` applies them with `git apply --index` and fails with the
exact rejection if a patch no longer applies after an upstream update.

## Licensing

A patch is a derivative of the upstream file it changes. Patches are
therefore provided under the license of the patched upstream file (see
[docs/redistribution.md](../docs/redistribution.md#licenses)), which may differ from
the GPL-3.0-or-later license of the rest of this repository.
