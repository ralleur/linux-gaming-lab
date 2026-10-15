#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# update-upstream.sh: moving the pin, reporting and rollback on breakage.

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UPDATE="$REPO_ROOT/scripts/update-upstream.sh"

new_upstream_commit() {
    printf 'mesa\n' >> "$T/upstream/archiso/packages_desktop.x86_64"
    GIT_COMMITTER_DATE='2026-02-01T12:00:00+00:00' fixture_git -C "$T/upstream" commit -q -am "add mesa"
}

test_update_moves_pin_to_branch_tip() {
    setup_sandbox
    new_upstream_commit
    run "$UPDATE"
    assert_success
    assert_output_contains "add mesa"
    assert_output_contains "+mesa"
    head=$(git -C "$T/upstream" rev-parse HEAD)
    assert_contains "$LGL_LOCK_FILE" "UPSTREAM_COMMIT=$head"
    assert_contains "$LGL_LOCK_FILE" "UPSTREAM_TREE=$(git -C "$T/upstream" rev-parse 'HEAD^{tree}')"
    assert_contains "$LGL_LOCK_FILE" "UPSTREAM_SUBJECT=add mesa"
    assert_contains "$LGL_LOCK_FILE" "# test lock"
    run "$REPO_ROOT/scripts/bootstrap.sh" --offline
    assert_success
}

test_update_noop_when_current() {
    setup_sandbox
    cp "$LGL_LOCK_FILE" "$T/before"
    run "$UPDATE"
    assert_success
    assert_output_contains "already at"
    cmp -s "$LGL_LOCK_FILE" "$T/before" || fail "lock changed"
}

test_dry_run_keeps_lock() {
    setup_sandbox
    new_upstream_commit
    cp "$LGL_LOCK_FILE" "$T/before"
    run "$UPDATE" --dry-run
    assert_success
    cmp -s "$LGL_LOCK_FILE" "$T/before" || fail "lock changed in dry-run"
}

test_update_rolls_back_when_patch_breaks() {
    setup_sandbox
    cat > "$LGL_PATCHES_DIR/0001-hostname.patch" <<'EOF'
diff --git a/archiso/airootfs/etc/hostname b/archiso/airootfs/etc/hostname
--- a/archiso/airootfs/etc/hostname
+++ b/archiso/airootfs/etc/hostname
@@ -1 +1 @@
-cachyos
+gaming-lab
EOF
    printf 'cachyos-live\n' > "$T/upstream/archiso/airootfs/etc/hostname"
    fixture_git -C "$T/upstream" commit -q -am "rename host"
    cp "$LGL_LOCK_FILE" "$T/before"
    run "$UPDATE"
    assert_failure
    assert_output_contains "which our patches modify"
    assert_output_contains "restored the previous config/upstream.lock"
    cmp -s "$LGL_LOCK_FILE" "$T/before" || fail "lock was not restored"
}

run_tests
