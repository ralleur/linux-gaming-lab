#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# validate.sh on a copy of this repository: passes as-is, and detects
# typical configuration mistakes.

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# copy_repo -> $T/repo with the repository files (no build output or caches)
copy_repo() {
    T=$(mktemp -d)
    mkdir "$T/repo"
    (cd "$REPO_ROOT" && tar -cf - --exclude ./.git --exclude ./build --exclude ./out --exclude ./.cache .) |
        (cd "$T/repo" && tar -xf -)
}

test_repository_validates() {
    copy_repo
    run "$T/repo/scripts/validate.sh" --no-shellcheck
    assert_success
    assert_output_contains "Validation passed"
}

test_detects_unpinned_action() {
    copy_repo
    sed -i.bak -E 's#uses: actions/checkout@[0-9a-f]{40}#uses: actions/checkout@v4#' "$T/repo/.github/workflows/ci.yml"
    rm -f "$T/repo/.github/workflows/ci.yml.bak"
    run "$T/repo/scripts/validate.sh" --no-shellcheck
    assert_failure
    assert_output_contains "must be pinned to a full commit SHA"
}

test_detects_bad_package_and_overlap() {
    copy_repo
    printf 'Steam\nnano\n' > "$T/repo/profiles/default/packages.add"
    printf 'nano\n' > "$T/repo/profiles/default/packages.remove"
    run "$T/repo/scripts/validate.sh" --no-shellcheck
    assert_failure
    assert_output_contains "invalid package name 'Steam'"
    assert_output_contains "'nano' is both added and removed"
}

test_detects_secret_in_overlay() {
    copy_repo
    mkdir -p "$T/repo/overlays/common/airootfs/etc/ssh"
    printf 'x\n' > "$T/repo/overlays/common/airootfs/etc/ssh/host.key"
    run "$T/repo/scripts/validate.sh" --no-shellcheck
    assert_failure
    assert_output_contains "looks like a secret"
}

test_detects_token_in_file() {
    copy_repo
    printf 'token=ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$T/repo/docs/leak.md"
    run "$T/repo/scripts/validate.sh" --no-shellcheck
    assert_failure
    assert_output_contains "docs/leak.md: contains something that looks like a private key or access token"
}

test_detects_broken_doc_link() {
    copy_repo
    printf '\nSee [missing](does-not-exist.md).\n' >> "$T/repo/docs/build.md"
    run "$T/repo/scripts/validate.sh" --no-shellcheck
    assert_failure
    assert_output_contains "broken link to 'does-not-exist.md'"
}

test_detects_missing_overlay_reference() {
    copy_repo
    sed -i.bak 's/^OVERLAYS=.*/OVERLAYS=common nope/' "$T/repo/profiles/default/profile.conf"
    rm -f "$T/repo/profiles/default/profile.conf.bak"
    run "$T/repo/scripts/validate.sh" --no-shellcheck
    assert_failure
    assert_output_contains "overlay 'nope' does not exist"
}

run_tests
