#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Parsing and validation of KEY=value config files, lists and profiles.

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../scripts/lib/common.sh
source "$REPO_ROOT/scripts/lib/common.sh"

test_repository_lock_is_valid() {
    run lock_check "$REPO_ROOT/config/upstream.lock"
    assert_success
}

test_repository_build_env_is_valid() {
    run build_env_check "$REPO_ROOT/config/build-env.conf"
    assert_success
}

test_lock_rejects_abbreviated_commit() {
    T=$(mktemp -d)
    sed 's/^UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=3215497d/' "$REPO_ROOT/config/upstream.lock" > "$T/lock"
    run lock_check "$T/lock"
    assert_failure
    assert_output_contains "UPSTREAM_COMMIT must be a full 40-character"
}

test_lock_rejects_unknown_duplicate_and_missing_keys() {
    T=$(mktemp -d)
    grep -v '^UPSTREAM_TREE=' "$REPO_ROOT/config/upstream.lock" > "$T/lock"
    printf 'UPSTREAM_BRANCH=main\nFOO=bar\n' >> "$T/lock"
    run lock_check "$T/lock"
    assert_failure
    assert_output_contains "unknown key FOO"
    assert_output_contains "duplicate key UPSTREAM_BRANCH"
    assert_output_contains "missing required key UPSTREAM_TREE"
}

test_lock_rejects_plain_http() {
    T=$(mktemp -d)
    sed 's|^UPSTREAM_URL=.*|UPSTREAM_URL=http://example.com/x.git|' "$REPO_ROOT/config/upstream.lock" > "$T/lock"
    run lock_check "$T/lock"
    assert_failure
    assert_output_contains "UPSTREAM_URL must be an https://"
}

test_lock_load_never_executes_values() {
    T=$(mktemp -d)
    sed "s|^UPSTREAM_SUBJECT=.*|UPSTREAM_SUBJECT=\$(touch $T/pwned)|" "$REPO_ROOT/config/upstream.lock" > "$T/lock"
    lock_load "$T/lock"
    assert_no_file "$T/pwned"
    assert_eq "$UPSTREAM_SUBJECT" "\$(touch $T/pwned)"
}

test_build_env_requires_pinned_digest() {
    T=$(mktemp -d)
    sed 's|^BASE_IMAGE=.*|BASE_IMAGE=docker.io/library/archlinux:base-devel|' "$REPO_ROOT/config/build-env.conf" > "$T/env"
    run build_env_check "$T/env"
    assert_failure
    assert_output_contains "BASE_IMAGE must be registry/repo:tag@sha256"
}

test_build_env_requires_full_fingerprint() {
    T=$(mktemp -d)
    sed 's|^CACHYOS_KEY_FPR=.*|CACHYOS_KEY_FPR=F3B607488DB35A47|' "$REPO_ROOT/config/build-env.conf" > "$T/env"
    run build_env_check "$T/env"
    assert_failure
    assert_output_contains "full 40-character uppercase fingerprint"
}

test_list_read_strips_comments_and_blanks() {
    T=$(mktemp -d)
    printf '# comment\n\n  steam  \ngamemode # trailing comment\r\n\t\n' > "$T/list"
    assert_eq "$(list_read "$T/list" | tr '\n' ' ')" "steam gamemode "
}

test_profile_load_rejects_unknown_key() {
    setup_sandbox
    printf 'TYPO=1\n' >> "$LGL_PROFILES_DIR/default/profile.conf"
    run profile_load default
    assert_failure
    assert_output_contains "unknown key TYPO"
}

test_profile_load_rejects_bad_name() {
    setup_sandbox
    run profile_load '../etc'
    assert_failure
    assert_output_contains "invalid profile name"
}

run_tests
