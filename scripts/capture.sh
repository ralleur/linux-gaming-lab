#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bring customizations from the running reference system into overlay modules.
#
# The reference system is a normal CachyOS installation on which changes are
# tried out first (see docs/workflow.md). This script compares it with the
# distribution defaults and with what the repository already holds:
#
#   status    user configuration that differs from the default in /etc/skel,
#             or from the copy already captured in an overlay module
#   packages  explicitly installed packages that neither the pinned upstream
#             package list nor any packages.add in this repository contains
#   add       copy a file from the home directory into an overlay module
#             (airootfs/etc/skel/...)
#
# Read-only on the reference system; 'add' writes only below overlays/.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lgl_enable_err_trap

# Overridable for tests.
CAPTURE_HOME="${LGL_CAPTURE_HOME:-$HOME}"
CAPTURE_SKEL="${LGL_CAPTURE_SKEL:-/etc/skel}"
CAPTURE_IGNORE="${LGL_CAPTURE_IGNORE:-$LGL_ROOT/config/capture.ignore}"
# Directories (relative to the home directory) whose files are reported even
# when the distribution ships no default for them.
CAPTURE_DIRS="${LGL_CAPTURE_DIRS:-.config/hypr .config/noctalia}"
# File with one installed package per line; default: pacman -Qqe.
CAPTURE_PACKAGES="${LGL_CAPTURE_PACKAGES:-}"

usage() {
    cat <<EOF
Usage: ${0##*/} [status]
       ${0##*/} packages
       ${0##*/} add MODULE PATH...

  status     Show configuration in \$HOME that differs from the distribution
             default (/etc/skel) or from the copy captured in overlays/.
  packages   Show explicitly installed packages not covered by the pinned
             upstream package list or any packages.add (needs bootstrap.sh).
  add        Copy PATH (relative to \$HOME, e.g. .config/hypr/config/binds.lua)
             to overlays/MODULE/airootfs/etc/skel/PATH.

Ignored paths: ${CAPTURE_IGNORE#"$LGL_ROOT"/}
See docs/workflow.md.
EOF
}

# is_ignored PATH -> true if PATH matches a glob in the ignore file.
is_ignored() {
    local p=$1 pattern
    for pattern in $(list_read "$CAPTURE_IGNORE"); do
        # shellcheck disable=SC2254 # the pattern is a glob on purpose
        case "$p" in $pattern) return 0 ;; esac
    done
    return 1
}

# captured_in PATH -> prints the first module that holds PATH in its skel.
captured_in() {
    local p=$1 d
    for d in "$LGL_OVERLAYS_DIR"/*/; do
        if [[ -f "${d}airootfs/etc/skel/$p" ]]; then
            basename "$d"
            return 0
        fi
    done
    return 1
}

# candidate_paths -> home-relative paths worth comparing, unique and sorted.
candidate_paths() {
    local d
    {
        if [[ -d "$CAPTURE_SKEL" ]]; then
            (cd "$CAPTURE_SKEL" && find . -type f) | sed 's#^\./##'
        fi
        for d in "$LGL_OVERLAYS_DIR"/*/airootfs/etc/skel; do
            [[ -d "$d" ]] && (cd "$d" && find . -type f) | sed 's#^\./##'
        done
        for d in $CAPTURE_DIRS; do
            [[ -d "$CAPTURE_HOME/$d" ]] && (cd "$CAPTURE_HOME" && find "$d" -type f)
        done
    } | sort -u
}

cmd_status() {
    local p module host new=0 changed=0 current=0
    while IFS= read -r p; do
        is_ignored "$p" && continue
        host="$CAPTURE_HOME/$p"
        [[ -f "$host" ]] || continue
        if module=$(captured_in "$p"); then
            if cmp -s "$host" "$LGL_OVERLAYS_DIR/$module/airootfs/etc/skel/$p"; then
                current=$((current + 1))
            else
                printf 'changed   %-18s %s\n' "$module" "$p"
                changed=$((changed + 1))
            fi
        elif [[ ! -f "$CAPTURE_SKEL/$p" ]]; then
            printf 'new       %-18s %s\n' "-" "$p"
            new=$((new + 1))
        elif ! cmp -s "$host" "$CAPTURE_SKEL/$p"; then
            printf 'modified  %-18s %s\n' "-" "$p"
            new=$((new + 1))
        fi
    done < <(candidate_paths)
    log_step "$new not captured, $changed changed since capture, $current captured and current"
    if [[ $new -gt 0 || $changed -gt 0 ]]; then
        log_info "inspect:  diff -u $CAPTURE_SKEL/PATH $CAPTURE_HOME/PATH"
        log_info "capture:  ${0##*/} add MODULE PATH   (or add PATH to ${CAPTURE_IGNORE#"$LGL_ROOT"/})"
    fi
}

cmd_packages() {
    local repo upstream installed covered f n=0 p
    lock_load
    repo=$(upstream_cache_repo)
    git -C "$repo" cat-file -e "${UPSTREAM_COMMIT}^{commit}" 2>/dev/null ||
        die "upstream commit $UPSTREAM_COMMIT not in cache $repo; run scripts/bootstrap.sh first"

    upstream=$(mktemp)
    covered=$(mktemp)
    installed=$(mktemp)
    # shellcheck disable=SC2064 # expand the temp file names now
    trap "rm -f '$upstream' '$covered' '$installed'" EXIT
    git -C "$repo" show "$UPSTREAM_COMMIT:archiso/packages_desktop.x86_64" > "$upstream"
    {
        list_read "$upstream"
        for f in "$LGL_OVERLAYS_DIR"/*/packages.add "$LGL_PROFILES_DIR"/*/packages.add; do
            list_read "$f"
        done
    } | sort -u > "$covered"
    if [[ -n "$CAPTURE_PACKAGES" ]]; then
        list_read "$CAPTURE_PACKAGES" | sort -u > "$installed"
    else
        require_cmd pacman
        pacman -Qqe | sort -u > "$installed"
    fi
    while IFS= read -r p; do
        printf '%s\n' "$p"
        n=$((n + 1))
    done < <(comm -13 "$covered" "$installed")
    log_step "$n installed package(s) not covered by upstream or packages.add"
    [[ $n -eq 0 ]] || log_info "capture:  add the name to overlays/MODULE/packages.add"
}

cmd_add() {
    local module=$1 p src dst
    shift
    [[ "$module" =~ $LGL_NAME_RE ]] || die "invalid module name '$module' (allowed: ${LGL_NAME_RE})"
    [[ $# -gt 0 ]] || die "no PATH given"
    for p in "$@"; do
        p=${p#"$CAPTURE_HOME"/}
        case "$p" in
            /* | ../* | */../* | *..) die "PATH must be relative to \$HOME and stay inside it: $p" ;;
        esac
        src="$CAPTURE_HOME/$p"
        [[ -f "$src" ]] || die "not a file: $src"
        dst="$LGL_OVERLAYS_DIR/$module/airootfs/etc/skel/$p"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        log_info "captured $p -> ${dst#"$LGL_ROOT"/}"
    done
    [[ -f "$LGL_OVERLAYS_DIR/$module/README.md" ]] ||
        log_warn "overlays/$module/README.md is missing: describe what the module does and why"
    log_step "Review with: git status && git diff"
}

command=${1:-status}
[[ $# -eq 0 ]] || shift
case "$command" in
    status) cmd_status ;;
    packages) cmd_packages ;;
    add)
        [[ $# -ge 1 ]] || { usage >&2; die "add needs MODULE and PATH"; }
        cmd_add "$@"
        ;;
    -h | --help) usage ;;
    *) usage >&2; die "unknown command: $command" ;;
esac
