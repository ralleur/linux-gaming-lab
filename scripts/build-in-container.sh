#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Host-side entry point: build the isolated build environment image from
# container/Containerfile and run scripts/build.sh inside it.
#
# Nothing on the host is modified except:
#   - the container image (tag from config/build-env.conf),
#   - the named volume 'linux-gaming-lab-work' (mkarchiso work directory),
#   - .cache/ and out/ in this repository (bind mount).
#
# The container runs with --privileged because pacstrap/mkarchiso mount file
# systems. Run it on a machine (or VM) you are comfortable granting that to.

set -Eeuo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
lgl_enable_err_trap

WORK_VOLUME=linux-gaming-lab-work
CONTAINER_WORK_DIR=/var/lib/linux-gaming-lab/work

usage() {
    cat <<EOF
Usage: ${0##*/} [wrapper options] [--] [build.sh options] [PROFILE]

Build the container image (if needed) and run scripts/build.sh in it.

Wrapper options:
  --engine ENGINE   docker or podman (default: \$LGL_CONTAINER_ENGINE, else docker,
                    else podman; podman is not verified yet)
  --rebuild-image   Rebuild the image even if it exists (pulls the newest Arch packages).
  --image-only      Only build the image.
  --shell           Open an interactive shell in the build environment instead.
  -h, --help        Show this help.

Examples:
  ${0##*/} --check                 # verify the build environment
  ${0##*/} --prepare-only default  # assemble build/default/src in the container
  ${0##*/} default                 # full ISO build

All other options are passed to scripts/build.sh (see scripts/build.sh --help).
EOF
}

engine="${LGL_CONTAINER_ENGINE:-}"
rebuild=0
image_only=0
shell=0
build_args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) [[ $# -ge 2 ]] || die "--engine needs a value"; engine=$2; shift ;;
        --rebuild-image) rebuild=1 ;;
        --image-only) image_only=1 ;;
        --shell) shell=1 ;;
        -h | --help) usage; exit 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do build_args+=("$1"); shift; done; break ;;
        *) build_args+=("$1") ;;
    esac
    shift
done

if [[ -z "$engine" ]]; then
    if command -v docker >/dev/null 2>&1; then engine=docker
    elif command -v podman >/dev/null 2>&1; then engine=podman
    else die "neither podman nor docker found; install one or use an Arch Linux VM (docs/build.md)"
    fi
fi
case "$engine" in docker | podman) ;; *) die "unsupported container engine: $engine" ;; esac
require_cmd "$engine"
"$engine" info >/dev/null 2>&1 || die "$engine is installed but not usable (daemon/machine not running?)"

build_env_load

host_arch=$(uname -m)
if [[ "$host_arch" != "x86_64" && "$host_arch" != "amd64" ]]; then
    log_warn "host architecture is $host_arch: the x86_64 build environment runs under emulation."
    log_warn "Environment checks and --prepare-only work; full ISO builds under emulation are slow and not verified (docs/build.md)."
fi

# The image tag encodes the inputs, so changing config/build-env.conf or the
# Containerfile yields a new image instead of silently reusing an old one.
builder_uid=$(id -u)
[[ "$builder_uid" -ne 0 ]] || builder_uid=1000
inputs_hash=$(cat "$LGL_ROOT/container/Containerfile" "$LGL_BUILD_ENV_FILE" | git hash-object --stdin)
image="${IMAGE_NAME}:${inputs_hash:0:12}-u${builder_uid}"

if [[ $rebuild -eq 1 ]] || ! "$engine" image inspect "$image" >/dev/null 2>&1; then
    log_step "Building build environment image $image"
    "$engine" build \
        --platform linux/amd64 \
        --build-arg "BASE_IMAGE=$BASE_IMAGE" \
        --build-arg "CACHYOS_KEY_FPR=$CACHYOS_KEY_FPR" \
        --build-arg "CACHYOS_KEYSERVER=$CACHYOS_KEYSERVER" \
        --build-arg "CACHYOS_MIRROR=$CACHYOS_MIRROR" \
        --build-arg "BUILDER_UID=$builder_uid" \
        --tag "$image" \
        --file "$LGL_ROOT/container/Containerfile" \
        "$LGL_ROOT/container"
else
    log_info "using existing image $image (--rebuild-image to refresh)"
fi
[[ $image_only -eq 0 ]] || exit 0

run_opts=(--rm --privileged --platform linux/amd64
    --volume "$LGL_ROOT:/workspace"
    --volume "$WORK_VOLUME:$CONTAINER_WORK_DIR"
    --env "LGL_WORK_DIR=$CONTAINER_WORK_DIR"
    --env "NO_COLOR=${NO_COLOR:-}"
    --workdir /workspace)

if [[ $shell -eq 1 ]]; then
    log_step "Opening a shell in the build environment ($image)"
    exec "$engine" run -it "${run_opts[@]}" "$image" bash
fi

log_step "Running scripts/build.sh ${build_args[*]+"${build_args[*]}"} in $image"
exec "$engine" run "${run_opts[@]}" "$image" /workspace/scripts/build.sh ${build_args[@]+"${build_args[@]}"}
