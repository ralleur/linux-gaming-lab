# Upstream tracking

## The dependency on CachyOS

| Upstream input | How it is referenced | Pinned |
|----------------|----------------------|--------|
| [CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO) — ISO profile and build scripts | `config/upstream.lock` | commit + tree hash + commit date |
| CachyOS package repositories (`[cachyos]` and Arch repos) | upstream `archiso/pacman.conf`, used by mkarchiso | no (rolling) |
| CachyOS signing key | `CACHYOS_KEY_FPR` in `config/build-env.conf` | full fingerprint |
| Arch Linux base image of the build environment | `BASE_IMAGE` in `config/build-env.conf` | digest |
| `cachyos-mirrorlist` in the image | downloaded by upstream `buildiso.sh` from CachyOS-PKGBUILDS `master` | no |
| Calamares installer and its settings | installed online by the live system at installer start | no |

Only the first row is under this project's version control today; the
others are documented so they can be pinned step by step.

## How the pin is verified

`scripts/bootstrap.sh` keeps a git clone in `.cache/upstream/<name>` and checks:

1. the cached remote URL equals `UPSTREAM_URL`,
2. `UPSTREAM_COMMIT` exists (fetched with the branch, or directly by SHA),
3. its tree hash equals `UPSTREAM_TREE` and its commit date equals
   `UPSTREAM_COMMIT_DATE` — a different commit with the same message or a
   rewritten history is detected,
4. with `--verify-branch` (CI): the commit is an ancestor of
   `UPSTREAM_BRANCH`, and the number of newer upstream commits is reported.

Builds never use the cache's working tree: `prepare.sh` exports the commit
object with `git archive`, so local edits in the cache cannot leak into a
build.

## Updating upstream

```bash
scripts/update-upstream.sh --dry-run          # report only
scripts/update-upstream.sh                    # pin the tip of UPSTREAM_BRANCH
scripts/update-upstream.sh --to <commit>      # pin a specific commit
```

The script

1. fetches upstream and lists the new commits and changed files,
2. warns about upstream changes to files our **patches** modify and to files
   our **overlays** override, and prints package-list changes,
3. rewrites commit, tree, date and subject in `config/upstream.lock`,
4. re-verifies the pin and re-assembles **every profile**; if any patch no
   longer applies or a removed package no longer exists upstream, the previous
   lock file is restored and the script fails.

Then:

1. Read upstream's commit log and `CHANGELOG.md` for behavioral changes
   (boot loader, installer, package renames).
2. Build and smoke-test the ISO ([build.md](build.md#testing-an-iso)).
3. Add a `CHANGELOG.md` entry and commit, e.g.
   `upstream: bump CachyOS-Live-ISO to 1a2b3c4d5e6f`.
4. Open a pull request; CI re-checks the pin and assembles all profiles.

Update cadence, automation (scheduled update PRs) and compatibility gates
are defined in the "Upstream Update Strategy" milestone ([roadmap.md](roadmap.md)).

## Writing a patch

Patches are git-style diffs relative to the upstream repository root,
applied in lexical order before overlays and package changes.

```bash
scripts/bootstrap.sh
scripts/prepare.sh default
cd build/default/src            # throwaway git repo; tag 'upstream' = pinned commit
$EDITOR archiso/profiledef.sh   # change upstream files only
git diff > ../../../patches/0001-short-description.patch
cd ../../.. && scripts/prepare.sh default && cat build/default/manifest.txt
```

Put a short header above the first `diff --git` line explaining why the
patch exists (git ignores text before it):

```text
Why: executable overlay files need explicit modes (mkarchiso drops them).
Upstream: not proposed (project-specific).
diff --git a/archiso/profiledef.sh b/archiso/profiledef.sh
...
```

Upstream first: if a change could benefit CachyOS, propose it upstream
and link the pull request in the header; drop the patch once it is merged
and pinned.

## Rebasing patches

When `prepare.sh` reports `patch NNNN-….patch does not apply`:

```bash
scripts/prepare.sh default || true   # stops at the failing patch; earlier ones are staged
cd build/default/src
git -c user.name=lab -c user.email=lab@localhost commit -qm base   # state the patch must apply to
git apply --3way ../../../patches/NNNN-name.patch   # resolve conflicts (git status), then
git diff HEAD > ../../../patches/NNNN-name.patch
cd ../../.. && scripts/prepare.sh default
```

When it reports `cannot remove '<pkg>'`, upstream dropped or renamed the
package: update or delete the entry in the `packages.remove` file named in
the message.
