#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the live ISO for one profile. Runs INSIDE the isolated build
# environment (the container from container/Containerfile, or a dedicated
# Arch Linux build VM) - never on a workstation:
#
#   - upstream's buildiso.sh edits /usr/bin/mkarchiso with `sudo sed -i`,
#   - mkarchiso needs root, mounts file systems and runs pacstrap.
#
# From a workstation use scripts/build-in-container.sh, which starts this
# script in the container.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lgl_enable_err_trap

usage() {
    cat <<EOF
Usage: ${0##*/} [options] [PROFILE]

Build the live ISO for PROFILE (default: 'default') with upstream's buildiso.sh.

  --check           Only check the build environment and dependencies.
  --prepare-only    Check, fetch upstream and assemble the build tree; skip mkarchiso.
  --offline         Do not fetch upstream; use the existing cache.
  --keep-build-dir  Keep upstream's mkarchiso work directory after the build.
  -v, --verbose     Pass -v to upstream buildiso.sh (verbose mkarchiso).
  -h, --help        Show this help.

Environment:
  LGL_ALLOW_HOST_BUILD=1   Allow running outside a container. Only for a
                           dedicated, disposable Arch Linux build VM.
EOF
}

mode=build
offline=0
keep_build_dir=0
verbose=0
profile=default
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) mode=check ;;
        --prepare-only) mode=prepare ;;
        --offline) offline=1 ;;
        --keep-build-dir) keep_build_dir=1 ;;
        -v | --verbose) verbose=1 ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; die "unknown option: $1" ;;
        *) profile=$1 ;;
    esac
    shift
done

build_env_load
lock_load
profile_load "$profile"

# --- environment checks -------------------------------------------------------------

problems=0
problem() { log_error "$*"; problems=$((problems + 1)); }

in_container() {
    [[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
    command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container --quiet
}

check_environment() {
    log_step "Checking build environment"
    [[ "$(uname -s)" == "Linux" ]] ||
        die "ISO builds need Linux (found $(uname -s)); use scripts/build-in-container.sh or an Arch Linux VM (docs/build.md)"
    [[ "$(uname -m)" == "x86_64" ]] || problem "architecture is $(uname -m), x86_64 is required"
    [[ -f /etc/arch-release ]] || problem "not an Arch Linux system (/etc/arch-release missing)"

    if in_container; then
        log_info "running in a container"
    elif [[ "${LGL_ALLOW_HOST_BUILD:-0}" == "1" ]]; then
        log_warn "LGL_ALLOW_HOST_BUILD=1: building outside a container; upstream buildiso.sh will modify /usr/bin/mkarchiso on this system"
    else
        die "refusing to build outside an isolated environment: upstream buildiso.sh modifies /usr/bin/mkarchiso and mkarchiso needs root. Use scripts/build-in-container.sh, or set LGL_ALLOW_HOST_BUILD=1 in a dedicated build VM."
    fi
    [[ $EUID -ne 0 ]] || problem "do not run as root; upstream buildiso.sh expects a regular user with passwordless sudo"
}

check_dependencies() {
    local c p missing_cmds='' missing_pkgs='' free_kib free_gib mnt rc

    for c in bash git curl sudo pacman pacman-key pacstrap mkarchiso mksquashfs xorriso mcopy mkfs.fat grub-mkstandalone gettext awk sed; do
        command -v "$c" >/dev/null 2>&1 || missing_cmds="$missing_cmds $c"
    done
    [[ -z "$missing_cmds" ]] || problem "missing commands:${missing_cmds}"

    if command -v pacman >/dev/null 2>&1; then
        for p in archiso mkinitcpio-archiso squashfs-tools grub cachyos-keyring; do
            pacman -Qi "$p" >/dev/null 2>&1 || missing_pkgs="$missing_pkgs $p"
        done
        [[ -z "$missing_pkgs" ]] || problem "missing packages:${missing_pkgs} (see container/Containerfile)"
    fi

    if ! sudo -n true 2>/dev/null; then
        problem "passwordless sudo is not available for $(id -un)"
        return 0
    fi

    if sudo -n pacman-key --list-keys "$CACHYOS_KEY_FPR" >/dev/null 2>&1; then
        log_info "CachyOS signing key $CACHYOS_KEY_FPR present in pacman keyring"
    else
        problem "CachyOS signing key $CACHYOS_KEY_FPR is not in the pacman keyring"
    fi

    # mkarchiso/pacstrap mount proc, sys and dev into the chroot: probe whether
    # this environment may mount at all (needs a privileged container).
    mnt=$(mktemp -d)
    rc=0
    sudo -n mount -t tmpfs lgl-probe "$mnt" 2>/dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then
        sudo -n umount "$mnt"
        log_info "mounting works (privileged environment)"
    else
        problem "cannot mount file systems; run the container with --privileged (scripts/build-in-container.sh does this)"
    fi
    rmdir "$mnt"

    mkdir -p "$LGL_WORK_DIR"
    free_kib=$(df -Pk "$LGL_WORK_DIR" | awk 'NR == 2 { print $4 }')
    free_gib=$((free_kib / 1024 / 1024))
    if [[ $free_gib -lt $MIN_FREE_GIB ]]; then
        problem "only ${free_gib} GiB free in $LGL_WORK_DIR, at least ${MIN_FREE_GIB} GiB expected"
    else
        log_info "${free_gib} GiB free in $LGL_WORK_DIR"
    fi
}

check_environment
check_dependencies
[[ $problems -eq 0 ]] || die "build environment check failed with $problems problem(s)"
log_step "Build environment OK"
[[ "$mode" != check ]] || exit 0

# --- prepare -----------------------------------------------------------------------------

base="$LGL_WORK_DIR/$profile"
src="$base/src"

# A previous mkarchiso run leaves root-owned files behind; remove them with
# sudo, but only after the same mount-safety checks safe_rmtree applies.
if [[ -d "$src/build" ]]; then
    log_info "removing previous mkarchiso work directory"
    if awk -v p="$src/build" '$2 == p || index($2, p "/") == 1 { f = 1 } END { exit !f }' /proc/self/mounts; then
        die "file systems are still mounted below $src/build; unmount them first"
    fi
    sudo -n rm -rf --one-file-system -- "$src/build"
fi

if [[ $offline -eq 1 ]]; then
    "$LGL_ROOT/scripts/bootstrap.sh" --offline
else
    "$LGL_ROOT/scripts/bootstrap.sh"
fi
"$LGL_ROOT/scripts/prepare.sh" "$profile"
[[ "$mode" != prepare ]] || exit 0

# --- build ----------------------------------------------------------------------------------

out="$LGL_OUT_DIR/$profile"
mkdir -p "$out"
log_file="$out/build.log"
args=(-p "$PROFILE_UPSTREAM_BUILDSET")
[[ $verbose -eq 0 ]] || args+=(-v)
[[ $keep_build_dir -eq 1 ]] || args+=(-w)

# upstream uses $USER for `chown`; containers usually do not set it
export USER="${USER:-$(id -un)}"

log_step "Running upstream buildiso.sh ${args[*]} (log: ${log_file#"$LGL_ROOT"/})"
log_info "note: upstream prints 'An unknown error has occurred' from its EXIT trap even on success; the exit code below is authoritative"
rc=0
(cd "$src" && ./buildiso.sh "${args[@]}") 2>&1 | tee "$log_file" || rc=$?
[[ $rc -eq 0 ]] || die "upstream buildiso.sh failed with exit code $rc; see $log_file"

iso_dir="$src/out/$PROFILE_UPSTREAM_BUILDSET"
shopt -s nullglob
isos=("$iso_dir"/*.iso)
shopt -u nullglob
[[ ${#isos[@]} -gt 0 ]] || die "buildiso.sh succeeded but produced no ISO in $iso_dir"

for f in "$iso_dir"/*; do
    mv -f "$f" "$out/"
done
cp "$base/manifest.txt" "$base/changes.stat" "$base/changes.patch" "$out/"
cp "$src/archiso/airootfs/etc/$LGL_PROJECT/build-info" "$out/"

log_step "ISO ready in $out:"
ls -lh "$out" >&2
log_warn "this ISO contains packages from the CachyOS repositories: do not publish or redistribute it (docs/redistribution.md)"
