#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Move the upstream pin (config/upstream.lock) to a newer upstream commit and
# show what changed upstream that matters to this project:
#   - commits and changed files since the current pin,
#   - upstream changes to files our patches touch,
#   - upstream changes to files our overlays override,
#   - upstream package list changes.
# Afterwards every profile is re-assembled (prepare.sh) to prove that patches
# and package lists still apply. On failure the previous lock is restored.
#
# Safe to run on any host: writes only config/upstream.lock, .cache/, build/.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lgl_enable_err_trap

usage() {
    cat <<EOF
Usage: ${0##*/} [--to COMMIT] [--dry-run] [--no-check] [--allow-non-descendant]

  --to COMMIT             Pin this upstream commit (default: tip of the branch in the lock).
  --dry-run               Only report; do not change config/upstream.lock.
  --no-check              Do not re-assemble the profiles after updating the lock.
  --allow-non-descendant  Accept a target that does not descend from the current pin.
  -h, --help              Show this help.
EOF
}

target=''
dry_run=0
check=1
allow_non_descendant=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --to) [[ $# -ge 2 ]] || die "--to needs a commit"; target=$2; shift ;;
        --dry-run) dry_run=1 ;;
        --no-check) check=0 ;;
        --allow-non-descendant) allow_non_descendant=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

require_cmd git awk
"$LGL_ROOT/scripts/bootstrap.sh"
lock_load
repo=$(upstream_cache_repo)
old=$UPSTREAM_COMMIT

if [[ -z "$target" ]]; then
    target=$(git -C "$repo" rev-parse "refs/remotes/origin/$UPSTREAM_BRANCH")
else
    if ! git -C "$repo" cat-file -e "${target}^{commit}" 2>/dev/null; then
        git -C "$repo" fetch --quiet --no-tags origin "$target" || die "upstream has no commit '$target'"
    fi
    target=$(git -C "$repo" rev-parse "${target}^{commit}")
fi

if [[ "$target" == "$old" ]]; then
    log_step "Upstream pin is already at ${old:0:12}; nothing to do"
    exit 0
fi

if ! git -C "$repo" merge-base --is-ancestor "$old" "$target"; then
    [[ $allow_non_descendant -eq 1 ]] ||
        die "${target:0:12} does not descend from the current pin ${old:0:12}; use --allow-non-descendant if this is intended"
    log_warn "${target:0:12} does not descend from the current pin ${old:0:12}"
fi
if ! git -C "$repo" merge-base --is-ancestor "$target" "refs/remotes/origin/$UPSTREAM_BRANCH"; then
    log_warn "${target:0:12} is not part of upstream branch $UPSTREAM_BRANCH"
fi

new_tree=$(git -C "$repo" rev-parse "${target}^{tree}")
new_date=$(git -C "$repo" show -s --format=%cI "$target")
new_subject=$(git -C "$repo" show -s --format=%s "$target")

# --- report ------------------------------------------------------------------------------

log_step "Upstream changes ${old:0:12}..${target:0:12}"
git -C "$repo" --no-pager log --no-merges --format='  %h %cs %s' "$old..$target" >&2
printf '\n' >&2
git -C "$repo" --no-pager diff --stat "$old" "$target" >&2

changed=$(git -C "$repo" diff --name-only "$old" "$target")
attention=0

# files our patches modify
patched=''
for p in "$LGL_PATCHES_DIR"/*.patch; do
    [[ -f "$p" ]] || continue
    patched="$patched $(awk '/^\+\+\+ b\// { sub(/^\+\+\+ b\//, ""); sub(/\t.*$/, ""); print }' "$p" | tr '\n' ' ')"
done
for f in $patched; do
    if printf '%s\n' "$changed" | grep -qxF -- "$f"; then
        log_warn "upstream changed $f, which our patches modify: review and rebase the patch"
        attention=$((attention + 1))
    fi
done

# files our overlays override
for m in "$LGL_OVERLAYS_DIR"/*/airootfs; do
    [[ -d "$m" ]] || continue
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        f="archiso/airootfs/${rel#./}"
        if printf '%s\n' "$changed" | grep -qxF -- "$f"; then
            log_warn "upstream changed $f, which overlay $(basename "$(dirname "$m")") overrides"
            attention=$((attention + 1))
        fi
    done < <(cd "$m" && find . \( -type f -o -type l \) ! -name .gitkeep)
done

# package lists
for f in $(printf '%s\n' "$changed" | grep -E '^archiso/packages_.*\.x86_64$' || true); do
    log_step "Package list changes in $f"
    git -C "$repo" --no-pager diff -U0 "$old" "$target" -- "$f" | grep -E '^[+-][^+-]' >&2 || true
done

if [[ $dry_run -eq 1 ]]; then
    log_step "Dry run: config/upstream.lock unchanged ($attention item(s) need attention)"
    exit 0
fi

# --- update lock ---------------------------------------------------------------------------

backup=$(mktemp)
cp "$LGL_LOCK_FILE" "$backup"
tmp=$(mktemp)
awk -v c="$target" -v t="$new_tree" -v d="$new_date" -v s="$new_subject" '
    /^UPSTREAM_COMMIT=/      { print "UPSTREAM_COMMIT=" c; next }
    /^UPSTREAM_TREE=/        { print "UPSTREAM_TREE=" t; next }
    /^UPSTREAM_COMMIT_DATE=/ { print "UPSTREAM_COMMIT_DATE=" d; next }
    /^UPSTREAM_SUBJECT=/     { print "UPSTREAM_SUBJECT=" s; next }
    { print }' "$LGL_LOCK_FILE" > "$tmp"
cat "$tmp" > "$LGL_LOCK_FILE"
rm -f "$tmp"

restore_lock() {
    cat "$backup" > "$LGL_LOCK_FILE"
    rm -f "$backup"
    die "$1; restored the previous config/upstream.lock"
}

problems=$(lock_check "$LGL_LOCK_FILE") || restore_lock "generated lock file is invalid: $problems"
"$LGL_ROOT/scripts/bootstrap.sh" --offline || restore_lock "verification of the new pin failed"

if [[ $check -eq 1 ]]; then
    for p in $(profile_list); do
        "$LGL_ROOT/scripts/prepare.sh" "$p" || restore_lock "profile '$p' no longer assembles against ${target:0:12}"
    done
fi
rm -f "$backup"

log_step "Pinned upstream ${target:0:12} ($new_date): $new_subject"
log_info "$attention item(s) above need review; then add a CHANGELOG.md entry and commit, e.g.:"
log_info "  git commit -am 'upstream: bump $UPSTREAM_NAME to ${target:0:12}'"
