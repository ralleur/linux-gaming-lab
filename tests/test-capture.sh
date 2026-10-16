#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# capture.sh against a fake home directory, /etc/skel and package list.

set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPTURE="$REPO_ROOT/scripts/capture.sh"

# setup_capture: sandbox plus a home directory and skel with one default file.
setup_capture() {
    setup_sandbox
    export LGL_CAPTURE_HOME="$T/home" LGL_CAPTURE_SKEL="$T/skel"
    export LGL_CAPTURE_IGNORE="$T/capture.ignore" LGL_CAPTURE_DIRS=".config/hypr"
    mkdir -p "$T/home/.config/hypr" "$T/skel/.config/hypr"
    printf 'default\n' > "$T/skel/.config/hypr/binds.lua"
    printf 'default\n' > "$T/home/.config/hypr/binds.lua"
    printf '*.bak\n' > "$LGL_CAPTURE_IGNORE"
}

test_status_reports_modified_new_and_ignores() {
    setup_capture
    printf 'mine\n' > "$T/home/.config/hypr/binds.lua"
    printf 'extra\n' > "$T/home/.config/hypr/rules.lua"
    printf 'old\n' > "$T/home/.config/hypr/binds.lua.bak"
    run "$CAPTURE" status
    assert_success
    assert_output_contains "modified  -                  .config/hypr/binds.lua"
    assert_output_contains "new       -                  .config/hypr/rules.lua"
    case "$T_OUT" in *binds.lua.bak*) fail "ignored file reported" ;; esac
    assert_output_contains "2 not captured, 0 changed since capture, 0 captured and current"
}

test_add_then_status_tracks_capture() {
    setup_capture
    printf 'mine\n' > "$T/home/.config/hypr/binds.lua"
    run "$CAPTURE" add desktop-test .config/hypr/binds.lua
    assert_success
    assert_contains "$LGL_OVERLAYS_DIR/desktop-test/airootfs/etc/skel/.config/hypr/binds.lua" "mine"
    run "$CAPTURE" status
    assert_output_contains "0 not captured, 0 changed since capture, 1 captured and current"
    printf 'newer\n' > "$T/home/.config/hypr/binds.lua"
    run "$CAPTURE" status
    assert_output_contains "changed   desktop-test       .config/hypr/binds.lua"
}

test_add_rejects_paths_outside_home() {
    setup_capture
    run "$CAPTURE" add desktop-test ../etc/passwd
    assert_failure
    assert_output_contains "must be relative"
    run "$CAPTURE" add Bad-Name .config/hypr/binds.lua
    assert_failure
    assert_output_contains "invalid module name"
}

test_packages_lists_uncovered() {
    setup_capture
    run "$REPO_ROOT/scripts/bootstrap.sh"
    assert_success
    mkdir -p "$LGL_OVERLAYS_DIR/desktop-test"
    printf 'hyprland\n' > "$LGL_OVERLAYS_DIR/desktop-test/packages.add"
    printf 'base\nhyprland\nsteam\n' > "$T/installed"
    export LGL_CAPTURE_PACKAGES="$T/installed"
    run "$CAPTURE" packages
    assert_success
    assert_output_contains "steam"
    assert_output_contains "1 installed package(s) not covered"
}

run_tests
