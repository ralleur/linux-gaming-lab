#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Static validation of the repository: structure, configuration files,
# profiles, overlays, patches, shell scripts, workflows, docs links and an
# accidental-secret scan. Needs no network and no Arch Linux; runs on Linux
# and macOS. Used locally and by CI (.github/workflows/ci.yml).

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lgl_enable_err_trap

usage() {
    cat <<EOF
Usage: ${0##*/} [--strict] [--no-shellcheck]

  --strict         Treat warnings as errors and require shellcheck (CI mode).
  --no-shellcheck  Skip the shellcheck run (other checks still run).
  -h, --help       Show this help.
EOF
}

strict=0
run_shellcheck=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --strict) strict=1 ;;
        --no-shellcheck) run_shellcheck=0 ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
done

errors=0
warnings=0
err() { log_error "$*"; errors=$((errors + 1)); }
warn() { log_warn "$*"; warnings=$((warnings + 1)); }
section() { log_step "$*"; }

cd "$LGL_ROOT"

# Files that are part of the repository (tracked or not ignored).
repo_files() {
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files --cached --others --exclude-standard | while IFS= read -r f; do
            [[ -e "$f" ]] && printf '%s\n' "$f"
        done
    else
        find . -path ./.git -prune -o -path ./build -prune -o -path ./out -prune \
            -o -path ./.cache -prune -o -type f -print | sed 's|^\./||'
    fi
}
FILES=$(repo_files | LC_ALL=C sort)

# --- structure ----------------------------------------------------------------------

section "Repository structure"
for f in README.md LICENSE CONTRIBUTING.md CHANGELOG.md .gitignore .shellcheckrc .editorconfig \
    config/upstream.lock config/build-env.conf container/Containerfile \
    scripts/lib/common.sh scripts/bootstrap.sh scripts/prepare.sh scripts/build.sh \
    scripts/build-in-container.sh scripts/validate.sh scripts/update-upstream.sh \
    docs/architecture.md docs/build.md docs/upstream.md docs/development.md \
    docs/redistribution.md docs/roadmap.md \
    .github/workflows/ci.yml profiles/default/profile.conf tests/run.sh; do
    [[ -f "$f" ]] || err "missing required file: $f"
done
for d in profiles overlays patches scripts tests docs config container .github/workflows; do
    [[ -d "$d" ]] || err "missing required directory: $d"
done
if ! grep -q 'GNU GENERAL PUBLIC LICENSE' LICENSE 2>/dev/null || ! grep -q 'Version 3, 29 June 2007' LICENSE; then
    err "LICENSE is not the GPL-3.0 text"
fi
for pattern in '/build/' '/out/' '/.cache/' '*.iso'; do
    grep -qxF -- "$pattern" .gitignore || err ".gitignore must exclude $pattern"
done

# --- configuration ---------------------------------------------------------------------

section "Upstream lock and build environment"
if out=$(lock_check "$LGL_LOCK_FILE"); then
    lock_load
    case "$UPSTREAM_URL" in
        https://github.com/CachyOS/*) ;;
        *) warn "upstream URL $UPSTREAM_URL is not a CachyOS repository on GitHub" ;;
    esac
    log_info "upstream pinned to ${UPSTREAM_COMMIT:0:12} ($UPSTREAM_COMMIT_DATE)"
else
    while IFS= read -r line; do err "$line"; done <<< "$out"
fi
if out=$(build_env_check "$LGL_BUILD_ENV_FILE"); then
    build_env_load
    log_info "build environment base image pinned by digest"
else
    while IFS= read -r line; do err "$line"; done <<< "$out"
fi
# shellcheck disable=SC2016 # literal ${BASE_IMAGE} in the Containerfile
grep -q '^FROM --platform=linux/amd64 \${BASE_IMAGE}$' container/Containerfile ||
    err "container/Containerfile must start from 'FROM --platform=linux/amd64 \${BASE_IMAGE}'"
for arg in BASE_IMAGE CACHYOS_KEY_FPR CACHYOS_KEYSERVER CACHYOS_MIRROR; do
    grep -q "^ARG ${arg}\$" container/Containerfile ||
        err "container/Containerfile must declare 'ARG $arg' without a default (value comes from config/build-env.conf)"
done

# --- profiles and overlays ---------------------------------------------------------------

check_pkg_file() {
    local file=$1 name seen=' '
    [[ -f "$file" ]] || return 0
    for name in $(list_read "$file"); do
        [[ "$name" =~ $LGL_PKG_RE ]] || err "$file: invalid package name '$name'"
        case "$seen" in *" $name "*) err "$file: duplicate entry '$name'" ;; esac
        seen="$seen$name "
    done
    return 0
}

check_add_remove_overlap() {
    local dir=$1 name
    [[ -f "$dir/packages.add" && -f "$dir/packages.remove" ]] || return 0
    for name in $(list_read "$dir/packages.add"); do
        list_read "$dir/packages.remove" | grep -qxF -- "$name" &&
            err "$dir: '$name' is both added and removed"
    done
    return 0
}

section "Profiles"
referenced_overlays=' '
profiles=$(profile_list)
[[ -n "$profiles" ]] || err "no profiles found in profiles/"
for d in profiles/*/; do
    p=$(basename "$d")
    [[ "$p" =~ $LGL_NAME_RE ]] || err "profiles/$p: invalid profile name"
    [[ -f "$d/profile.conf" ]] || { err "profiles/$p: profile.conf missing"; continue; }
    if ! out=$(kv_check "$d/profile.conf" "$LGL_PROFILE_REQUIRED" "$LGL_PROFILE_OPTIONAL"); then
        while IFS= read -r line; do err "$line"; done <<< "$out"
        continue
    fi
    buildset=$(kv_get "$d/profile.conf" UPSTREAM_BUILDSET)
    [[ "$buildset" =~ $LGL_NAME_RE ]] || err "profiles/$p: invalid UPSTREAM_BUILDSET '$buildset'"
    for m in $(kv_get "$d/profile.conf" OVERLAYS || true); do
        [[ "$m" =~ $LGL_NAME_RE ]] || err "profiles/$p: invalid overlay name '$m'"
        [[ -d "overlays/$m" ]] || err "profiles/$p: overlay '$m' does not exist"
        referenced_overlays="$referenced_overlays$m "
    done
    for f in "$d"*; do
        case "$(basename "$f")" in
            profile.conf | packages.add | packages.remove | README.md) ;;
            *) err "profiles/$p: unexpected file $(basename "$f") (allowed: profile.conf, packages.add, packages.remove, README.md)" ;;
        esac
    done
    check_pkg_file "$d/packages.add"
    check_pkg_file "$d/packages.remove"
    check_add_remove_overlap "$d"
    log_info "profile $p -> upstream buildset '$buildset'"
done

section "Overlays"
for d in overlays/*/; do
    [[ -d "$d" ]] || continue
    m=$(basename "$d")
    [[ "$m" =~ $LGL_NAME_RE ]] || err "overlays/$m: invalid overlay name"
    case "$referenced_overlays" in *" $m "*) ;; *) warn "overlays/$m is not used by any profile" ;; esac
    for f in "$d"* "$d".[!.]*; do
        [[ -e "$f" ]] || continue
        case "$(basename "$f")" in
            airootfs | packages.add | packages.remove | README.md) ;;
            *) err "overlays/$m: unexpected entry $(basename "$f") (allowed: airootfs/, packages.add, packages.remove, README.md)" ;;
        esac
    done
    check_pkg_file "$d/packages.add"
    check_pkg_file "$d/packages.remove"
    check_add_remove_overlap "$d"
    [[ -d "$d/airootfs" ]] || continue
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        rel=${f#"$d"airootfs/}
        case "$rel" in *[[:space:]]*) err "$f: whitespace in overlay file names is not supported" ;; esac
        case "$rel" in
            etc/shadow | etc/gshadow | *.key | *.pem | *.p12 | *id_rsa* | *id_ed25519* | *.env)
                err "$f: looks like a secret or credential file; overlays must not contain secrets" ;;
        esac
    done < <(find "$d/airootfs" \( -type f -o -type l \) | sed 's|//|/|g')
    log_info "overlay $m"
done

# --- patches ----------------------------------------------------------------------------

section "Patches"
patch_count=0
for f in patches/*; do
    [[ -e "$f" ]] || continue
    name=$(basename "$f")
    case "$name" in
        README.md) continue ;;
        *.patch) ;;
        *) err "patches/$name: only *.patch files and README.md belong here"; continue ;;
    esac
    patch_count=$((patch_count + 1))
    [[ "$name" =~ ^[0-9]{4}-[a-z0-9][a-z0-9.-]*\.patch$ ]] ||
        err "patches/$name: name must look like 0001-short-description.patch"
    grep -q '^diff --git a/' "$f" || err "patches/$name: not a git-style unified diff (create it with git format-patch / git diff)"
    while IFS= read -r line; do
        path=${line#??? }
        path=${path%%$'\t'*}
        case "$path" in
            /dev/null) ;;
            a/*.. | a/*../* | b/*.. | b/*../*) err "patches/$name: path escapes the tree: $path" ;;
            a/* | b/*) ;;
            *) err "patches/$name: unexpected path '$path' (patches must use a/ and b/ prefixes)" ;;
        esac
    done < <(grep -E '^(---|\+\+\+) ' "$f" || true)
done
log_info "$patch_count patch(es)"

# --- shell scripts -------------------------------------------------------------------------

section "Shell scripts"
shell_files=$(printf '%s\n' "$FILES" | grep -E '\.sh$' || true)
for f in $shell_files; do
    first=$(head -n 1 "$f")
    head -n 5 "$f" | grep -q 'SPDX-License-Identifier: GPL-3.0-or-later' || err "$f: missing SPDX-License-Identifier header"
    case "$f" in
        scripts/lib/*.sh | tests/lib.sh)
            [[ "$first" == '# shellcheck shell=bash' ]] || err "$f: library files must start with '# shellcheck shell=bash'"
            ;;
        *)
            [[ "$first" == '#!/usr/bin/env bash' ]] || err "$f: must start with '#!/usr/bin/env bash'"
            grep -q '^set -Eeuo pipefail$' "$f" || err "$f: must use 'set -Eeuo pipefail'"
            [[ -x "$f" ]] || err "$f: not executable (chmod +x, git update-index --chmod=+x)"
            if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                mode=$(git ls-files -s -- "$f" | awk '{ print $1 }')
                [[ -z "$mode" || "$mode" == 100755 ]] || err "$f: committed without the executable bit (mode $mode)"
            fi
            ;;
    esac
    # Host-side scripts must keep working with bash 3.2 (macOS).
    [[ "$f" == scripts/validate.sh ]] && continue
    if grep -nE '(^|[^[:alnum:]_])(mapfile|readarray)[[:space:]]|declare -A|local -A|\$\{[A-Za-z_][A-Za-z0-9_]*(,,|\^\^)' "$f" |
        grep -vE '^[0-9]+:[[:space:]]*#'; then
        err "$f: uses bash >= 4 features; keep scripts compatible with bash 3.2 (see scripts/lib/common.sh)"
    fi
done

if [[ $run_shellcheck -eq 1 ]]; then
    if command -v shellcheck >/dev/null 2>&1; then
        log_info "$(shellcheck --version | awk '/^version:/ { print "shellcheck " $2 }')"
        # shellcheck disable=SC2086 # word splitting of the file list is intended
        if ! shellcheck --external-sources $shell_files; then
            err "shellcheck reported problems"
        fi
    elif [[ $strict -eq 1 ]]; then
        err "shellcheck not installed (required with --strict)"
    else
        warn "shellcheck not installed; skipping static shell analysis (install it or rely on CI)"
    fi
fi

# --- workflows ------------------------------------------------------------------------------

section "GitHub workflows"
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [[ -f "$f" ]] || continue
    grep -qE '^permissions:' "$f" || err "$f: needs a top-level 'permissions:' block (least privilege)"
    grep -q 'pull_request_target' "$f" && err "$f: pull_request_target is not allowed"
    while IFS= read -r line; do
        ref=$(printf '%s' "$line" | sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]]*(#.*)?$//')
        case "$ref" in
            ./*) ;;
            docker://*@sha256:*) ;;
            *@*)
                [[ "${ref##*@}" =~ ^[0-9a-f]{40}$ ]] ||
                    err "$f: action '$ref' must be pinned to a full commit SHA"
                ;;
            *) err "$f: action '$ref' has no version" ;;
        esac
    done < <(grep -E '^[[:space:]-]*uses:' "$f" || true)
    if grep -nE 'upload-artifact|softprops/action-gh-release|gh release' "$f" | grep -iE '\.iso|out/' >/dev/null; then
        err "$f: workflows must not publish ISO images in this phase (docs/redistribution.md)"
    fi
done

# --- documentation links --------------------------------------------------------------------

section "Documentation links"
for f in $(printf '%s\n' "$FILES" | grep -E '\.md$' || true); do
    dir=$(dirname "$f")
    while IFS= read -r link; do
        target=${link#*](}
        target=${target%)}
        target=${target%%#*}
        target=${target%% *}
        case "$target" in '' | http://* | https://* | mailto:*) continue ;; esac
        [[ -e "$dir/$target" ]] || err "$f: broken link to '$target'"
    done < <(grep -oE '\]\([^)]+\)' "$f" || true)
done

# --- secrets --------------------------------------------------------------------------------

section "Secret scan"
# The private-key marker is split so this file does not match itself.
key_marker='-----BEGIN ([A-Z]+ )?PRIVATE'' KEY-----'
token_re='(gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-ant-[A-Za-z0-9_-]{20,}|glpat-[A-Za-z0-9_-]{20})'
for f in $FILES; do
    [[ -f "$f" ]] || continue
    if grep -lE -- "$key_marker|$token_re" "$f" >/dev/null 2>&1; then
        err "$f: contains something that looks like a private key or access token"
    fi
done

# --- result ---------------------------------------------------------------------------------

if [[ $strict -eq 1 && $warnings -gt 0 ]]; then
    err "$warnings warning(s) treated as errors (--strict)"
fi
if [[ $errors -gt 0 ]]; then
    die "validation failed: $errors error(s), $warnings warning(s)"
fi
log_step "Validation passed ($warnings warning(s))"
