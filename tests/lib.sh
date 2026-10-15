# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2034 # variables are used by the sourcing test files
#
# Minimal test helpers (no external test framework, bash 3.2 compatible).
# Each test file sources this, defines test_* functions and calls run_tests.

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd -P)
export NO_COLOR=1
unset GITHUB_ACTIONS

fail() {
    printf '    assertion failed: %s\n' "$*" >&2
    exit 1
}

assert_eq() { [[ "$1" == "$2" ]] || fail "${3:-values differ}: expected '$2', got '$1'"; }
assert_file() { [[ -f "$1" ]] || fail "file missing: $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "file should not exist: $1"; }
assert_contains() { grep -qF -- "$2" "$1" || fail "'$1' does not contain '$2'"; }
assert_not_contains() { ! grep -qF -- "$2" "$1" || fail "'$1' unexpectedly contains '$2'"; }
assert_output_contains() {
    case "$T_OUT" in *"$1"*) ;; *) printf '%s\n' "$T_OUT" >&2; fail "output does not contain '$1'" ;; esac
}

# run CMD... -> sets T_RC and T_OUT (stdout+stderr) without aborting.
run() {
    set +e
    T_OUT=$("$@" 2>&1)
    T_RC=$?
    set -e
}
assert_success() { [[ $T_RC -eq 0 ]] || { printf '%s\n' "$T_OUT" >&2; fail "command failed with exit code $T_RC"; }; }
assert_failure() { [[ $T_RC -ne 0 ]] || { printf '%s\n' "$T_OUT" >&2; fail "command succeeded but should have failed"; }; }

# Deterministic commits for fixtures.
fixture_git() {
    GIT_AUTHOR_DATE='2026-01-01T12:00:00+00:00' GIT_COMMITTER_DATE='2026-01-01T12:00:00+00:00' \
        git -c user.name=fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false \
        -c init.defaultBranch=master -c core.hooksPath=/dev/null "$@"
}

# make_upstream DIR: a tiny stand-in for CachyOS-Live-ISO.
make_upstream() {
    local dir=$1
    mkdir -p "$dir/archiso/airootfs/etc"
    printf 'base\nlinux\nplasma-desktop\nnano\n' > "$dir/archiso/packages_desktop.x86_64"
    printf 'NAME="CachyOS"\n' > "$dir/archiso/airootfs/etc/os-release"
    printf 'cachyos\n' > "$dir/archiso/airootfs/etc/hostname"
    printf '#!/bin/bash\necho "buildiso stub $*"\n' > "$dir/buildiso.sh"
    chmod +x "$dir/buildiso.sh"
    fixture_git -C "$dir" init -q
    fixture_git -C "$dir" add -A
    fixture_git -C "$dir" commit -q -m "initial"
}

# write_lock FILE UPSTREAM_DIR [COMMIT]
write_lock() {
    local file=$1 dir=$2 commit=${3:-}
    [[ -n "$commit" ]] || commit=$(git -C "$dir" rev-parse HEAD)
    cat > "$file" <<EOF
# test lock
UPSTREAM_NAME=fixture-upstream
UPSTREAM_URL=file://$dir
UPSTREAM_BRANCH=master
UPSTREAM_COMMIT=$commit
UPSTREAM_TREE=$(git -C "$dir" rev-parse "$commit^{tree}")
UPSTREAM_COMMIT_DATE=$(git -C "$dir" show -s --format=%cI "$commit")
UPSTREAM_SUBJECT=$(git -C "$dir" show -s --format=%s "$commit")
EOF
}

# setup_sandbox: temp dirs for every path the scripts read or write, plus an
# upstream fixture and a 'default' profile using overlay 'common'.
setup_sandbox() {
    T=$(mktemp -d)
    T=$(cd "$T" && pwd -P)
    export LGL_LOCK_FILE="$T/upstream.lock"
    export LGL_CACHE_DIR="$T/cache"
    export LGL_WORK_DIR="$T/work"
    export LGL_OUT_DIR="$T/out"
    export LGL_PROFILES_DIR="$T/profiles"
    export LGL_OVERLAYS_DIR="$T/overlays"
    export LGL_PATCHES_DIR="$T/patches"
    mkdir -p "$LGL_PROFILES_DIR/default" "$LGL_OVERLAYS_DIR/common/airootfs" "$LGL_PATCHES_DIR"
    printf 'DESCRIPTION=test profile\nUPSTREAM_BUILDSET=desktop\nOVERLAYS=common\n' \
        > "$LGL_PROFILES_DIR/default/profile.conf"
    make_upstream "$T/upstream"
    write_lock "$LGL_LOCK_FILE" "$T/upstream"
}

run_tests() {
    local fn rc passed=0 failed=0 failed_names=''
    for fn in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
        set +e
        (
            set -e
            trap '[[ -n "${T:-}" && -d "${T:-}" ]] && rm -rf "$T"' EXIT
            "$fn"
        )
        rc=$?
        set -e
        if [[ $rc -eq 0 ]]; then
            printf '  ok    %s\n' "$fn"
            passed=$((passed + 1))
        else
            printf '  FAIL  %s\n' "$fn"
            failed=$((failed + 1))
            failed_names="$failed_names $fn"
        fi
    done
    printf '  %d passed, %d failed\n' "$passed" "$failed"
    [[ $failed -eq 0 ]]
}
