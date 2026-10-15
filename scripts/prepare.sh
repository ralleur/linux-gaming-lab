#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Assemble the build tree for one profile:
#
#   1. export the pinned upstream commit (from the cache filled by bootstrap.sh)
#   2. apply patches/*.patch in lexical order
#   3. copy the overlay modules listed in the profile into archiso/airootfs/
#   4. apply package additions/removals to the upstream package list
#   5. write provenance (build-info) and a change record against upstream
#
# The result lives in build/<profile>/src and is what upstream's buildiso.sh
# runs in. The upstream cache itself is never modified.
#
# Safe to run on any host (Linux or macOS): it only writes below build/.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lgl_enable_err_trap

usage() {
    cat <<EOF
Usage: ${0##*/} [PROFILE]

Assemble ${LGL_WORK_DIR#"$LGL_ROOT"/}/PROFILE/src from the pinned upstream plus this project's
patches, overlays and package lists. PROFILE defaults to 'default'.
Available profiles: $(profile_list | tr '\n' ' ')

Run scripts/bootstrap.sh first to fill the upstream cache.
EOF
}

profile=default
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; die "unknown option: $1" ;;
        *) profile=$1 ;;
    esac
    shift
done

require_cmd git tar awk sed sort
lock_load
profile_load "$profile"

repo=$(upstream_cache_repo)
git -C "$repo" cat-file -e "${UPSTREAM_COMMIT}^{commit}" 2>/dev/null ||
    die "upstream commit $UPSTREAM_COMMIT not in cache $repo; run scripts/bootstrap.sh first"
tree=$(git -C "$repo" rev-parse "${UPSTREAM_COMMIT}^{tree}")
[[ "$tree" == "$UPSTREAM_TREE" ]] || die "cached upstream tree $tree does not match lock ($UPSTREAM_TREE); run scripts/bootstrap.sh"

base="$LGL_WORK_DIR/$profile"
src="$base/src"
mkdir -p "$LGL_WORK_DIR"
safe_rmtree "$base"
mkdir -p "$src"

log_step "Preparing profile '$profile' (upstream buildset '$PROFILE_UPSTREAM_BUILDSET')"

# --- 1. upstream export ----------------------------------------------------------

log_info "exporting upstream ${UPSTREAM_COMMIT:0:12} to ${src#"$LGL_ROOT"/}"
git -C "$repo" archive --format=tar "$UPSTREAM_COMMIT" | tar -xf - -C "$src"

# A throwaway repository inside the build tree records every change we make
# relative to upstream (tag 'upstream'), see changes.* below.
lgl_git -C "$src" init -q
lgl_git -C "$src" add -A
lgl_git -C "$src" commit -q -m "upstream $UPSTREAM_NAME $UPSTREAM_COMMIT"
lgl_git -C "$src" tag upstream

pkg_list="$src/archiso/packages_${PROFILE_UPSTREAM_BUILDSET}.x86_64"
[[ -f "$pkg_list" ]] ||
    die "upstream has no package list for buildset '$PROFILE_UPSTREAM_BUILDSET' (${pkg_list#"$src"/} missing); check UPSTREAM_BUILDSET in $PROFILE_DIR/profile.conf"

# --- 2. patches ----------------------------------------------------------------------

applied_patches=''
patch_count=0
if [[ -d "$LGL_PATCHES_DIR" ]]; then
    while IFS= read -r patch; do
        [[ -n "$patch" ]] || continue
        name=$(basename "$patch")
        log_info "applying patch $name"
        if ! out=$(lgl_git -C "$src" apply --index --whitespace=nowarn "$patch" 2>&1); then
            log_error "patch $name does not apply to upstream ${UPSTREAM_COMMIT:0:12}:"
            printf '%s\n' "$out" >&2
            die "rebase or drop $name (see docs/upstream.md, 'Rebasing patches')"
        fi
        applied_patches="$applied_patches $name"
        patch_count=$((patch_count + 1))
    done < <(find "$LGL_PATCHES_DIR" -maxdepth 1 -type f -name '*.patch' | LC_ALL=C sort)
fi
[[ $patch_count -gt 0 ]] || log_info "no patches"

# --- 3. overlays ---------------------------------------------------------------------

airootfs="$src/archiso/airootfs"
overlay_files=0
overridden=''
for module in $PROFILE_OVERLAYS; do
    [[ "$module" =~ $LGL_NAME_RE ]] || die "profile '$profile': invalid overlay name '$module'"
    mdir="$LGL_OVERLAYS_DIR/$module"
    [[ -d "$mdir" ]] || die "profile '$profile' references overlay '$module', but $mdir does not exist"
    [[ -d "$mdir/airootfs" ]] || continue
    log_info "copying overlay $module"
    file_list=$(mktemp)
    (cd "$mdir/airootfs" && find . -mindepth 1 \( -type f -o -type l \) ! -name .gitkeep) | LC_ALL=C sort > "$file_list"
    while IFS= read -r rel; do
        rel=${rel#./}
        dest="$airootfs/$rel"
        if [[ -d "$dest" && ! -L "$dest" ]]; then
            die "overlay $module: $rel would replace a directory of the upstream tree"
        fi
        if [[ -e "$dest" || -L "$dest" ]]; then
            if lgl_git -C "$src" cat-file -e "upstream:archiso/airootfs/$rel" 2>/dev/null; then
                log_warn "overlay $module overrides upstream file archiso/airootfs/$rel (prefer a patch so upstream changes stay visible)"
                overridden="$overridden archiso/airootfs/$rel"
            fi
            rm -f "$dest"
        fi
        mkdir -p "$(dirname "$dest")"
        cp -P "$mdir/airootfs/$rel" "$dest"
        overlay_files=$((overlay_files + 1))
    done < "$file_list"
    rm -f "$file_list"
done

# --- 4. package lists -----------------------------------------------------------------

pkg_added=''
pkg_removed=''
pkg_added_n=0
pkg_removed_n=0

# pkg_present NAME: is NAME an entry of the package list?
pkg_present() {
    awk -v n="$1" '{ l = $0; sub(/#.*/, "", l); split(l, f, " "); if (f[1] == n) { found = 1 } }
        END { exit !found }' "$pkg_list"
}

pkg_remove() {
    local name=$1 source=$2 tmp
    pkg_present "$name" ||
        die "$source: cannot remove '$name': not in upstream ${pkg_list#"$src"/} (dropped upstream? update the list)"
    tmp=$(mktemp)
    awk -v n="$name" '{ l = $0; sub(/#.*/, "", l); split(l, f, " "); if (f[1] != n) print }' "$pkg_list" > "$tmp"
    cat "$tmp" > "$pkg_list"
    rm -f "$tmp"
    pkg_removed="$pkg_removed $name"
    pkg_removed_n=$((pkg_removed_n + 1))
}

pkg_add() {
    local name=$1 source=$2
    if pkg_present "$name"; then
        log_warn "$source: '$name' is already in the upstream package list; remove it from $source"
        return 0
    fi
    printf '%s\n' "$name" >> "$pkg_list"
    pkg_added="$pkg_added $name"
    pkg_added_n=$((pkg_added_n + 1))
}

apply_package_lists() {
    local dir=$1 label=$2 name header=0
    for name in $(list_read "$dir/packages.remove"); do
        pkg_remove "$name" "$label/packages.remove"
    done
    for name in $(list_read "$dir/packages.add"); do
        if [[ $header -eq 0 ]]; then
            # make sure the upstream list ends with a newline before appending
            [[ -z "$(tail -c 1 "$pkg_list")" ]] || printf '\n' >> "$pkg_list"
            printf '\n# --- %s: added by %s ---\n' "$LGL_PROJECT" "$label" >> "$pkg_list"
            header=1
        fi
        pkg_add "$name" "$label/packages.add"
    done
}

for module in $PROFILE_OVERLAYS; do
    apply_package_lists "$LGL_OVERLAYS_DIR/$module" "overlays/$module"
done
apply_package_lists "$PROFILE_DIR" "profiles/$profile"

# --- 5. provenance and change record ----------------------------------------------

project_rev=$(project_revision)
info_dir="$airootfs/etc/$LGL_PROJECT"
mkdir -p "$info_dir"
{
    printf '# Generated by scripts/prepare.sh - provenance of this image.\n'
    printf 'LGL_PROJECT=%s\n' "$LGL_PROJECT"
    printf 'LGL_REVISION=%s\n' "$project_rev"
    printf 'LGL_PROFILE=%s\n' "$profile"
    printf 'LGL_OVERLAYS=%s\n' "$PROFILE_OVERLAYS"
    printf 'LGL_PATCHES=%s\n' "${applied_patches# }"
    printf 'UPSTREAM_URL=%s\n' "$UPSTREAM_URL"
    printf 'UPSTREAM_COMMIT=%s\n' "$UPSTREAM_COMMIT"
    printf 'UPSTREAM_BUILDSET=%s\n' "$PROFILE_UPSTREAM_BUILDSET"
} > "$info_dir/build-info"

lgl_git -C "$src" add -A
lgl_git -C "$src" commit -q --allow-empty -m "$LGL_PROJECT profile $profile ($project_rev)"
lgl_git -C "$src" diff --binary upstream HEAD > "$base/changes.patch"
lgl_git -C "$src" diff --stat upstream HEAD > "$base/changes.stat"
lgl_git -C "$src" diff --name-status upstream HEAD > "$base/changes.files"

{
    printf '%s build manifest\n\n' "$LGL_PROJECT"
    printf 'profile            %s\n' "$profile"
    printf 'description        %s\n' "$PROFILE_DESCRIPTION"
    printf 'project revision   %s\n' "$project_rev"
    printf 'upstream           %s\n' "$UPSTREAM_URL"
    printf 'upstream commit    %s (%s)\n' "$UPSTREAM_COMMIT" "$UPSTREAM_COMMIT_DATE"
    printf 'upstream buildset  %s\n' "$PROFILE_UPSTREAM_BUILDSET"
    printf 'overlays           %s\n' "${PROFILE_OVERLAYS:-(none)}"
    printf 'patches            %s\n' "${applied_patches# }"
    printf 'packages added     %s\n' "${pkg_added# }"
    printf 'packages removed   %s\n' "${pkg_removed# }"
    printf 'overridden files   %s\n' "${overridden# }"
    printf '\nchanged files against upstream (git diff --name-status):\n'
    sed 's/^/  /' "$base/changes.files"
} > "$base/manifest.txt"

log_info "patches: $patch_count, overlay files: $overlay_files, packages +${pkg_added_n}/-${pkg_removed_n}"
log_info "change record: ${base#"$LGL_ROOT"/}/{manifest.txt,changes.stat,changes.patch}"
log_step "Build tree ready: $src"
