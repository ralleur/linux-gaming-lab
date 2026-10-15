# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
# shellcheck disable=SC2034 # variables are set here for the sourcing scripts
#
# Shared helpers for linux-gaming-lab scripts.
#
# Compatibility: must run with bash >= 3.2 (macOS /bin/bash) because the
# host-side scripts (bootstrap, prepare, validate, tests) are expected to work
# on macOS development machines. Avoid mapfile, associative arrays, ${x,,},
# and expanding possibly-empty arrays without the ${a[@]+"${a[@]}"} guard.

if [[ -n "${LGL_COMMON_LOADED:-}" ]]; then
    return 0
fi
LGL_COMMON_LOADED=1

LGL_PROJECT=linux-gaming-lab

# --- paths (each one can be overridden from the environment, e.g. by tests) --

LGL_ROOT="${LGL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
LGL_LOCK_FILE="${LGL_LOCK_FILE:-$LGL_ROOT/config/upstream.lock}"
LGL_BUILD_ENV_FILE="${LGL_BUILD_ENV_FILE:-$LGL_ROOT/config/build-env.conf}"
LGL_PROFILES_DIR="${LGL_PROFILES_DIR:-$LGL_ROOT/profiles}"
LGL_OVERLAYS_DIR="${LGL_OVERLAYS_DIR:-$LGL_ROOT/overlays}"
LGL_PATCHES_DIR="${LGL_PATCHES_DIR:-$LGL_ROOT/patches}"
LGL_CACHE_DIR="${LGL_CACHE_DIR:-$LGL_ROOT/.cache}"
LGL_WORK_DIR="${LGL_WORK_DIR:-$LGL_ROOT/build}"
LGL_OUT_DIR="${LGL_OUT_DIR:-$LGL_ROOT/out}"

# --- logging ------------------------------------------------------------------

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    _C_RESET=$'\033[0m' _C_BOLD=$'\033[1m' _C_RED=$'\033[1;31m'
    _C_GREEN=$'\033[1;32m' _C_YELLOW=$'\033[1;33m' _C_BLUE=$'\033[1;34m'
else
    _C_RESET='' _C_BOLD='' _C_RED='' _C_GREEN='' _C_YELLOW='' _C_BLUE=''
fi

_lgl_in_ci() { [[ "${GITHUB_ACTIONS:-}" == "true" ]]; }

log_step()  { printf '%s==>%s %s%s%s\n' "$_C_GREEN" "$_C_RESET" "$_C_BOLD" "$*" "$_C_RESET" >&2; }
log_info()  { printf '%s  ->%s %s\n' "$_C_BLUE" "$_C_RESET" "$*" >&2; }
log_warn() {
    if _lgl_in_ci; then
        printf '::warning::%s\n' "$*" >&2
    else
        printf '%sWARN:%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2
    fi
}
log_error() {
    if _lgl_in_ci; then
        printf '::error::%s\n' "$*" >&2
    else
        printf '%sERROR:%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2
    fi
}
die() {
    log_error "$*"
    exit 1
}

# Report the failing command, its exit code and location instead of exiting
# silently under `set -e`. Inside subshells and command substitutions only the
# status is propagated: the parent shell either handles it (if/||) or reports
# its own failing command, so nothing is reported twice or spuriously.
lgl_on_error() {
    local rc=$1 line=$2 cmd=$3
    if [[ "${BASH_SUBSHELL:-0}" -eq 0 ]]; then
        log_error "command failed (exit ${rc}) at ${0##*/}:${line}: ${cmd}"
    fi
    exit "$rc"
}

lgl_enable_err_trap() {
    set -o errtrace
    trap 'lgl_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

# --- generic helpers ------------------------------------------------------------

require_cmd() {
    local missing='' c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    [[ -z "$missing" ]] || die "required command(s) not found:${missing}"
}

# git without user/global config influence for throwaway repositories.
lgl_git() {
    git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c tag.gpgsign=false \
        -c user.name="$LGL_PROJECT" -c user.email="build@$LGL_PROJECT.invalid" \
        -c init.defaultBranch=main -c core.autocrlf=false "$@"
}

# Print the entries of a list file: one item per line, '#' starts a comment,
# surrounding whitespace is ignored, empty lines are skipped.
list_read() {
    local file=$1 line
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        line=$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [[ -n "$line" ]] && printf '%s\n' "$line"
    done < "$file"
    return 0
}

# --- KEY=value config files --------------------------------------------------
#
# Config files are parsed, never sourced: lines are 'KEY=value' with KEY in
# [A-Z][A-Z0-9_]*, '#' comment lines and blank lines are ignored. The value is
# everything after the first '=' (no quote processing).

# kv_get FILE KEY -> prints the value; returns 1 if the key is missing.
kv_get() {
    local file=$1 key=$2 line value='' found=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in '' | '#'*) continue ;; esac
        if [[ "${line%%=*}" == "$key" ]]; then
            value=${line#*=}
            found=$((found + 1))
        fi
    done < "$file"
    [[ $found -ge 1 ]] || return 1
    printf '%s\n' "$value"
}

# kv_check FILE "REQUIRED KEYS" "OPTIONAL KEYS"
# Prints one problem per line on stdout and returns non-zero if any exist.
kv_check() {
    local file=$1 required=$2 optional=$3
    local line key n=0 problems=0 seen=' '
    if [[ ! -f "$file" ]]; then
        printf '%s: file not found\n' "$file"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        case "$line" in '' | '#'*) continue ;; esac
        if [[ "$line" == *$'\r'* ]]; then
            printf '%s:%d: contains a carriage return (use LF line endings)\n' "$file" "$n"
            problems=$((problems + 1))
            continue
        fi
        if ! [[ "$line" =~ ^[A-Z][A-Z0-9_]*= ]]; then
            printf '%s:%d: not a KEY=value line: %s\n' "$file" "$n" "$line"
            problems=$((problems + 1))
            continue
        fi
        key=${line%%=*}
        case " $required $optional " in
            *" $key "*) ;;
            *)
                printf '%s:%d: unknown key %s\n' "$file" "$n" "$key"
                problems=$((problems + 1))
                ;;
        esac
        case "$seen" in
            *" $key "*)
                printf '%s:%d: duplicate key %s\n' "$file" "$n" "$key"
                problems=$((problems + 1))
                ;;
        esac
        seen="$seen$key "
        if [[ -z "${line#*=}" ]]; then
            printf '%s:%d: empty value for %s\n' "$file" "$n" "$key"
            problems=$((problems + 1))
        fi
    done < "$file"
    for key in $required; do
        case "$seen" in
            *" $key "*) ;;
            *)
                printf '%s: missing required key %s\n' "$file" "$key"
                problems=$((problems + 1))
                ;;
        esac
    done
    [[ $problems -eq 0 ]]
}

# --- upstream lock -------------------------------------------------------------

LGL_LOCK_REQUIRED="UPSTREAM_NAME UPSTREAM_URL UPSTREAM_BRANCH UPSTREAM_COMMIT UPSTREAM_TREE UPSTREAM_COMMIT_DATE"
LGL_LOCK_OPTIONAL="UPSTREAM_SUBJECT"

# lock_check FILE -> prints problems, returns non-zero if any.
lock_check() {
    local file=$1 out rc=0 v key
    out=$(kv_check "$file" "$LGL_LOCK_REQUIRED" "$LGL_LOCK_OPTIONAL") || rc=1
    [[ -z "$out" ]] || printf '%s\n' "$out"
    [[ -f "$file" ]] || return 1

    v=$(kv_get "$file" UPSTREAM_NAME || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        printf '%s: UPSTREAM_NAME must be a plain directory name: %s\n' "$file" "$v"; rc=1
    fi
    v=$(kv_get "$file" UPSTREAM_URL || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^(https://[^[:space:]]+|file://[^[:space:]]+)$ ]]; then
        printf '%s: UPSTREAM_URL must be an https:// (or, for tests, file://) URL: %s\n' "$file" "$v"; rc=1
    fi
    v=$(kv_get "$file" UPSTREAM_BRANCH || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
        printf '%s: UPSTREAM_BRANCH is not a valid branch name: %s\n' "$file" "$v"; rc=1
    fi
    for key in UPSTREAM_COMMIT UPSTREAM_TREE; do
        v=$(kv_get "$file" "$key" || true)
        if [[ -n "$v" ]] && ! [[ "$v" =~ ^[0-9a-f]{40}$ ]]; then
            printf '%s: %s must be a full 40-character lowercase SHA-1: %s\n' "$file" "$key" "$v"; rc=1
        fi
    done
    v=$(kv_get "$file" UPSTREAM_COMMIT_DATE || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
        printf '%s: UPSTREAM_COMMIT_DATE must be ISO 8601 (git %%cI): %s\n' "$file" "$v"; rc=1
    fi
    return $rc
}

# lock_load [FILE] -> validates and exports UPSTREAM_* variables.
lock_load() {
    local file=${1:-$LGL_LOCK_FILE} problems
    if ! problems=$(lock_check "$file"); then
        log_error "invalid upstream lock file $file:"
        printf '%s\n' "$problems" >&2
        exit 1
    fi
    UPSTREAM_NAME=$(kv_get "$file" UPSTREAM_NAME)
    UPSTREAM_URL=$(kv_get "$file" UPSTREAM_URL)
    UPSTREAM_BRANCH=$(kv_get "$file" UPSTREAM_BRANCH)
    UPSTREAM_COMMIT=$(kv_get "$file" UPSTREAM_COMMIT)
    UPSTREAM_TREE=$(kv_get "$file" UPSTREAM_TREE)
    UPSTREAM_COMMIT_DATE=$(kv_get "$file" UPSTREAM_COMMIT_DATE)
    UPSTREAM_SUBJECT=$(kv_get "$file" UPSTREAM_SUBJECT || true)
    export UPSTREAM_NAME UPSTREAM_URL UPSTREAM_BRANCH UPSTREAM_COMMIT UPSTREAM_TREE \
        UPSTREAM_COMMIT_DATE UPSTREAM_SUBJECT
}

upstream_cache_repo() {
    printf '%s/upstream/%s\n' "$LGL_CACHE_DIR" "$UPSTREAM_NAME"
}

# --- build environment config ------------------------------------------------

LGL_BUILD_ENV_REQUIRED="BASE_IMAGE CACHYOS_KEY_FPR CACHYOS_KEYSERVER CACHYOS_MIRROR IMAGE_NAME MIN_FREE_GIB"

build_env_check() {
    local file=$1 out rc=0 v
    out=$(kv_check "$file" "$LGL_BUILD_ENV_REQUIRED" "") || rc=1
    [[ -z "$out" ]] || printf '%s\n' "$out"
    [[ -f "$file" ]] || return 1
    v=$(kv_get "$file" BASE_IMAGE || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]]; then
        printf '%s: BASE_IMAGE must be registry/repo:tag@sha256:<digest>: %s\n' "$file" "$v"; rc=1
    fi
    v=$(kv_get "$file" CACHYOS_KEY_FPR || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^[0-9A-F]{40}$ ]]; then
        printf '%s: CACHYOS_KEY_FPR must be a full 40-character uppercase fingerprint: %s\n' "$file" "$v"; rc=1
    fi
    v=$(kv_get "$file" CACHYOS_KEYSERVER || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^hkps://[a-z0-9.-]+$ ]]; then
        printf '%s: CACHYOS_KEYSERVER must be an hkps:// keyserver: %s\n' "$file" "$v"; rc=1
    fi
    v=$(kv_get "$file" CACHYOS_MIRROR || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^https://[^[:space:]]+/\$arch/\$repo$ ]]; then
        # shellcheck disable=SC2016 # literal $arch/$repo (pacman variables)
        printf '%s: CACHYOS_MIRROR must be an https URL ending in /$arch/$repo: %s\n' "$file" "$v"; rc=1
    fi
    v=$(kv_get "$file" MIN_FREE_GIB || true)
    if [[ -n "$v" ]] && ! [[ "$v" =~ ^[0-9]+$ ]]; then
        printf '%s: MIN_FREE_GIB must be an integer: %s\n' "$file" "$v"; rc=1
    fi
    return $rc
}

build_env_load() {
    local file=${1:-$LGL_BUILD_ENV_FILE} problems
    if ! problems=$(build_env_check "$file"); then
        log_error "invalid build environment file $file:"
        printf '%s\n' "$problems" >&2
        exit 1
    fi
    BASE_IMAGE=$(kv_get "$file" BASE_IMAGE)
    CACHYOS_KEY_FPR=$(kv_get "$file" CACHYOS_KEY_FPR)
    CACHYOS_KEYSERVER=$(kv_get "$file" CACHYOS_KEYSERVER)
    CACHYOS_MIRROR=$(kv_get "$file" CACHYOS_MIRROR)
    IMAGE_NAME=$(kv_get "$file" IMAGE_NAME)
    MIN_FREE_GIB=$(kv_get "$file" MIN_FREE_GIB)
}

# --- profiles ----------------------------------------------------------------

LGL_PROFILE_REQUIRED="DESCRIPTION UPSTREAM_BUILDSET"
LGL_PROFILE_OPTIONAL="OVERLAYS"
LGL_NAME_RE='^[a-z0-9][a-z0-9-]*$'
LGL_PKG_RE='^[a-z0-9@_+][a-z0-9@._+-]*$'

profile_list() {
    local d
    for d in "$LGL_PROFILES_DIR"/*/; do
        [[ -f "${d}profile.conf" ]] && basename "$d"
    done
    return 0
}

# profile_load NAME -> sets PROFILE_NAME PROFILE_DIR PROFILE_DESCRIPTION
#                      PROFILE_UPSTREAM_BUILDSET PROFILE_OVERLAYS
profile_load() {
    local name=$1 problems
    [[ "$name" =~ $LGL_NAME_RE ]] || die "invalid profile name '$name' (allowed: ${LGL_NAME_RE})"
    PROFILE_NAME=$name
    PROFILE_DIR="$LGL_PROFILES_DIR/$name"
    [[ -f "$PROFILE_DIR/profile.conf" ]] ||
        die "profile '$name' not found ($PROFILE_DIR/profile.conf missing); available: $(profile_list | tr '\n' ' ')"
    if ! problems=$(kv_check "$PROFILE_DIR/profile.conf" "$LGL_PROFILE_REQUIRED" "$LGL_PROFILE_OPTIONAL"); then
        log_error "invalid profile $PROFILE_DIR/profile.conf:"
        printf '%s\n' "$problems" >&2
        exit 1
    fi
    PROFILE_DESCRIPTION=$(kv_get "$PROFILE_DIR/profile.conf" DESCRIPTION)
    PROFILE_UPSTREAM_BUILDSET=$(kv_get "$PROFILE_DIR/profile.conf" UPSTREAM_BUILDSET)
    PROFILE_OVERLAYS=$(kv_get "$PROFILE_DIR/profile.conf" OVERLAYS || true)
    [[ "$PROFILE_UPSTREAM_BUILDSET" =~ $LGL_NAME_RE ]] ||
        die "profile '$name': invalid UPSTREAM_BUILDSET '$PROFILE_UPSTREAM_BUILDSET'"
}

# --- project revision ----------------------------------------------------------

project_revision() {
    local rev
    if git -C "$LGL_ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        rev=$(git -C "$LGL_ROOT" rev-parse HEAD)
        if [[ -n "$(git -C "$LGL_ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
            rev="${rev}-dirty"
        fi
        printf '%s\n' "$rev"
    else
        printf 'unknown\n'
    fi
}

# --- safe removal ----------------------------------------------------------------
#
# safe_rmtree PATH: removes PATH only if it is strictly inside LGL_WORK_DIR or
# LGL_CACHE_DIR, and (on Linux) only if nothing is mounted below it. This
# protects against deleting through leftover bind mounts of an aborted
# mkarchiso run (proc, sys, dev inside the chroot).
safe_rmtree() {
    local target=$1 parent base abs allowed=0 root
    [[ -e "$target" || -L "$target" ]] || return 0
    parent=$(cd "$(dirname "$target")" && pwd -P)
    base=$(basename "$target")
    abs="$parent/$base"
    for root in "$LGL_WORK_DIR" "$LGL_CACHE_DIR"; do
        [[ -d "$root" ]] || continue
        root=$(cd "$root" && pwd -P)
        case "$abs" in
            "$root"/?*) allowed=1 ;;
        esac
    done
    [[ $allowed -eq 1 ]] || die "refusing to delete '$abs': not inside the work or cache directory"
    if [[ -r /proc/self/mounts ]] &&
        awk -v p="$abs" '$2 == p || index($2, p "/") == 1 { found = 1 } END { exit !found }' /proc/self/mounts; then
        die "refusing to delete '$abs': file systems are still mounted below it (check: grep '$abs' /proc/self/mounts)"
    fi
    if rm --version >/dev/null 2>&1; then
        rm -rf --one-file-system -- "$abs"
    else
        rm -rf -- "$abs"
    fi
}
