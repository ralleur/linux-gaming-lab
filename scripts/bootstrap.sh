#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Fetch the upstream CachyOS-Live-ISO repository into the local cache and
# verify it against config/upstream.lock (commit, tree hash, commit date).
#
# Safe to run on any host (Linux or macOS): it only writes below .cache/.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lgl_enable_err_trap

usage() {
    cat <<EOF
Usage: ${0##*/} [--offline] [--verify-branch]

Fetch the pinned upstream into ${LGL_CACHE_DIR#"$LGL_ROOT"/}/upstream/ and verify it.

  --offline        Do not access the network; only verify the existing cache.
  --verify-branch  Fail if the pinned commit is not part of the upstream branch
                   named in the lock file (detects force-pushed or foreign
                   commits) and report how far the pin lags behind.
  -h, --help       Show this help.
EOF
}

offline=0
verify_branch=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --offline) offline=1 ;;
        --verify-branch) verify_branch=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done
[[ $offline -eq 0 || $verify_branch -eq 0 ]] || die "--offline and --verify-branch exclude each other"

require_cmd git
lock_load
repo=$(upstream_cache_repo)
remote_ref="refs/remotes/origin/$UPSTREAM_BRANCH"

log_step "Upstream: $UPSTREAM_NAME @ ${UPSTREAM_COMMIT:0:12} ($UPSTREAM_BRANCH)"

if [[ ! -d "$repo/.git" ]]; then
    [[ $offline -eq 0 ]] || die "no upstream cache at $repo (run without --offline first)"
    log_info "initialising cache at $repo"
    mkdir -p "$(dirname "$repo")"
    git init -q "$repo"
    git -C "$repo" remote add origin "$UPSTREAM_URL"
fi

actual_url=$(git -C "$repo" remote get-url origin)
[[ "$actual_url" == "$UPSTREAM_URL" ]] ||
    die "cache $repo points to '$actual_url' but the lock file says '$UPSTREAM_URL'; delete the cache directory to re-clone"

if [[ $offline -eq 0 ]]; then
    log_info "fetching $UPSTREAM_BRANCH from $UPSTREAM_URL"
    git -C "$repo" fetch --quiet --no-tags --prune origin "+refs/heads/$UPSTREAM_BRANCH:$remote_ref"
    if ! git -C "$repo" cat-file -e "${UPSTREAM_COMMIT}^{commit}" 2>/dev/null; then
        log_warn "pinned commit is not reachable from $UPSTREAM_BRANCH; fetching it directly"
        git -C "$repo" fetch --quiet --no-tags origin "$UPSTREAM_COMMIT" ||
            die "upstream does not provide commit $UPSTREAM_COMMIT (deleted or never pushed?)"
    fi
fi

git -C "$repo" cat-file -e "${UPSTREAM_COMMIT}^{commit}" 2>/dev/null ||
    die "commit $UPSTREAM_COMMIT is not in the cache $repo"

tree=$(git -C "$repo" rev-parse "${UPSTREAM_COMMIT}^{tree}")
[[ "$tree" == "$UPSTREAM_TREE" ]] ||
    die "tree hash mismatch for $UPSTREAM_COMMIT: lock says $UPSTREAM_TREE, repository has $tree"

date=$(git -C "$repo" show -s --format=%cI "$UPSTREAM_COMMIT")
[[ "$date" == "$UPSTREAM_COMMIT_DATE" ]] ||
    die "commit date mismatch for $UPSTREAM_COMMIT: lock says $UPSTREAM_COMMIT_DATE, repository has $date"
log_info "verified commit, tree $tree and date $date"

# Keep a readable checkout for humans. Builds never use this working tree:
# prepare.sh exports the pinned commit object, so local edits cannot leak in.
if [[ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    git -C "$repo" -c advice.detachedHead=false checkout -q --detach "$UPSTREAM_COMMIT"
else
    log_warn "cache working tree $repo has local modifications; they are ignored by builds"
fi

if [[ $verify_branch -eq 1 ]]; then
    git -C "$repo" rev-parse -q --verify "$remote_ref" >/dev/null ||
        die "upstream branch '$UPSTREAM_BRANCH' does not exist at $UPSTREAM_URL"
    if ! git -C "$repo" merge-base --is-ancestor "$UPSTREAM_COMMIT" "$remote_ref"; then
        die "pinned commit $UPSTREAM_COMMIT is not part of upstream branch '$UPSTREAM_BRANCH' (force-push upstream or wrong branch in lock?)"
    fi
    behind=$(git -C "$repo" rev-list --count "${UPSTREAM_COMMIT}..${remote_ref}")
    head=$(git -C "$repo" rev-parse "$remote_ref")
    if [[ "$behind" -eq 0 ]]; then
        log_info "pin is identical to the tip of $UPSTREAM_BRANCH"
    else
        msg="pin is $behind commit(s) behind $UPSTREAM_BRANCH (tip ${head:0:12}); see docs/upstream.md for the update procedure"
        if _lgl_in_ci; then printf '::notice::%s\n' "$msg" >&2; else log_info "$msg"; fi
    fi
fi

log_step "Upstream cache ready: $repo"
