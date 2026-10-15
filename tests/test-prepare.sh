#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# bootstrap.sh + prepare.sh against a local upstream fixture: patches,
# overlays, package lists, provenance, change record and failure modes.

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$REPO_ROOT/scripts/bootstrap.sh"
PREPARE="$REPO_ROOT/scripts/prepare.sh"

add_hostname_patch() {
    cat > "$LGL_PATCHES_DIR/0001-hostname.patch" <<'EOF'
diff --git a/archiso/airootfs/etc/hostname b/archiso/airootfs/etc/hostname
--- a/archiso/airootfs/etc/hostname
+++ b/archiso/airootfs/etc/hostname
@@ -1 +1 @@
-cachyos
+gaming-lab
EOF
}

test_full_assembly() {
    setup_sandbox
    add_hostname_patch
    mkdir -p "$LGL_OVERLAYS_DIR/common/airootfs/etc/skel" "$LGL_OVERLAYS_DIR/common/airootfs/usr/local/bin"
    printf 'hello\n' > "$LGL_OVERLAYS_DIR/common/airootfs/etc/skel/.lab"
    printf 'NAME="Lab"\n' > "$LGL_OVERLAYS_DIR/common/airootfs/etc/os-release"
    printf '#!/bin/sh\n' > "$LGL_OVERLAYS_DIR/common/airootfs/usr/local/bin/lab-tool"
    : > "$LGL_OVERLAYS_DIR/common/airootfs/.gitkeep"
    printf 'gamemode\n' > "$LGL_OVERLAYS_DIR/common/packages.add"
    printf 'steam # comment\nplasma-desktop\n' > "$LGL_PROFILES_DIR/default/packages.add"
    printf 'nano\n' > "$LGL_PROFILES_DIR/default/packages.remove"

    run "$BOOTSTRAP"
    assert_success
    run "$PREPARE" default
    assert_success
    assert_output_contains "overrides upstream file archiso/airootfs/etc/os-release"
    assert_output_contains "'plasma-desktop' is already in the upstream package list"

    src="$LGL_WORK_DIR/default/src"
    assert_eq "$(cat "$src/archiso/airootfs/etc/hostname")" "gaming-lab" "patch applied"
    assert_eq "$(cat "$src/archiso/airootfs/etc/os-release")" 'NAME="Lab"' "overlay override"
    assert_file "$src/archiso/airootfs/etc/skel/.lab"
    assert_file "$src/archiso/airootfs/usr/local/bin/lab-tool"
    assert_no_file "$src/archiso/airootfs/.gitkeep"
    assert_file "$src/buildiso.sh"

    pkgs=$(list_packages "$src/archiso/packages_desktop.x86_64")
    assert_eq "$pkgs" "base linux plasma-desktop gamemode steam " "package list"

    info="$src/archiso/airootfs/etc/linux-gaming-lab/build-info"
    assert_contains "$info" "UPSTREAM_COMMIT=$(git -C "$T/upstream" rev-parse HEAD)"
    assert_contains "$info" "LGL_PATCHES=0001-hostname.patch"
    assert_contains "$info" "LGL_PROFILE=default"

    manifest="$LGL_WORK_DIR/default/manifest.txt"
    assert_contains "$manifest" "packages added     gamemode steam"
    assert_contains "$manifest" "packages removed   nano"
    assert_contains "$manifest" "overridden files   archiso/airootfs/etc/os-release"
    assert_contains "$LGL_WORK_DIR/default/changes.files" "M	archiso/airootfs/etc/hostname"
    assert_contains "$LGL_WORK_DIR/default/changes.files" "A	archiso/airootfs/etc/skel/.lab"

    # the upstream cache stays pristine
    cache="$LGL_CACHE_DIR/upstream/fixture-upstream"
    assert_eq "$(git -C "$cache" status --porcelain)" "" "cache is clean"
    assert_eq "$(git -C "$cache" rev-parse HEAD)" "$(git -C "$T/upstream" rev-parse HEAD)" "cache at pin"

    # re-running replaces the previous tree
    run "$PREPARE" default
    assert_success
}

list_packages() {
    grep -v '^#' "$1" | grep -v '^$' | tr '\n' ' '
}

test_bootstrap_detects_tree_mismatch() {
    setup_sandbox
    sed -i.bak 's/^UPSTREAM_TREE=.*/UPSTREAM_TREE=0000000000000000000000000000000000000000/' "$LGL_LOCK_FILE"
    run "$BOOTSTRAP"
    assert_failure
    assert_output_contains "tree hash mismatch"
}

test_bootstrap_detects_unknown_commit() {
    setup_sandbox
    sed -i.bak 's/^UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=1111111111111111111111111111111111111111/' "$LGL_LOCK_FILE"
    run "$BOOTSTRAP"
    assert_failure
    assert_output_contains "1111111111111111111111111111111111111111"
}

test_bootstrap_detects_url_change() {
    setup_sandbox
    run "$BOOTSTRAP"
    assert_success
    sed -i.bak "s|^UPSTREAM_URL=.*|UPSTREAM_URL=file://$T/elsewhere|" "$LGL_LOCK_FILE"
    run "$BOOTSTRAP" --offline
    assert_failure
    assert_output_contains "but the lock file says"
}

test_verify_branch_reports_lag() {
    setup_sandbox
    printf 'more\n' >> "$T/upstream/archiso/packages_desktop.x86_64"
    fixture_git -C "$T/upstream" commit -q -am "newer"
    run "$BOOTSTRAP" --verify-branch
    assert_success
    assert_output_contains "pin is 1 commit(s) behind master"
}

test_prepare_requires_bootstrap() {
    setup_sandbox
    run "$PREPARE" default
    assert_failure
    assert_output_contains "run scripts/bootstrap.sh first"
}

test_prepare_fails_on_rejected_patch() {
    setup_sandbox
    add_hostname_patch
    sed -i.bak 's/^-cachyos$/-something-else/' "$LGL_PATCHES_DIR/0001-hostname.patch"
    rm -f "$LGL_PATCHES_DIR/0001-hostname.patch.bak"
    run "$BOOTSTRAP"
    assert_success
    run "$PREPARE" default
    assert_failure
    assert_output_contains "patch 0001-hostname.patch does not apply"
}

test_prepare_fails_on_removing_unknown_package() {
    setup_sandbox
    printf 'not-in-upstream\n' > "$LGL_PROFILES_DIR/default/packages.remove"
    run "$BOOTSTRAP"
    run "$PREPARE" default
    assert_failure
    assert_output_contains "cannot remove 'not-in-upstream'"
}

test_prepare_fails_on_unknown_buildset() {
    setup_sandbox
    sed -i.bak 's/^UPSTREAM_BUILDSET=.*/UPSTREAM_BUILDSET=handheld/' "$LGL_PROFILES_DIR/default/profile.conf"
    rm -f "$LGL_PROFILES_DIR/default/profile.conf.bak"
    run "$BOOTSTRAP"
    run "$PREPARE" default
    assert_failure
    assert_output_contains "upstream has no package list for buildset 'handheld'"
}

test_prepare_fails_on_missing_overlay() {
    setup_sandbox
    printf 'OVERLAYS=common missing\n' >> "$LGL_PROFILES_DIR/default/profile.conf"
    sed -i.bak '/^OVERLAYS=common$/d' "$LGL_PROFILES_DIR/default/profile.conf"
    rm -f "$LGL_PROFILES_DIR/default/profile.conf.bak"
    run "$BOOTSTRAP"
    run "$PREPARE" default
    assert_failure
    assert_output_contains "references overlay 'missing'"
}

test_safe_rmtree_refuses_paths_outside_work_dir() {
    setup_sandbox
    mkdir -p "$LGL_WORK_DIR" "$T/precious"
    # shellcheck source=../scripts/lib/common.sh
    source "$REPO_ROOT/scripts/lib/common.sh"
    run safe_rmtree "$T/precious"
    assert_failure
    assert_output_contains "refusing to delete"
    [[ -d "$T/precious" ]] || fail "directory outside the work dir was deleted"
    run safe_rmtree "$LGL_WORK_DIR"
    assert_failure
    [[ -d "$LGL_WORK_DIR" ]] || fail "the work dir itself was deleted"
}

run_tests
