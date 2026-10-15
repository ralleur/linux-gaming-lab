# Building and testing

## Overview

| Step | Command | Where it runs |
|------|---------|---------------|
| Validate the repository | `scripts/validate.sh` | any Linux/macOS host |
| Run the tooling tests | `tests/run.sh` | any Linux/macOS host |
| Fetch + verify upstream | `scripts/bootstrap.sh` | any Linux/macOS host |
| Assemble a build tree | `scripts/prepare.sh <profile>` | any Linux/macOS host |
| Check the build environment | `scripts/build-in-container.sh --check` | container (Docker/Podman) |
| Build the ISO | `scripts/build-in-container.sh <profile>` | container on an x86_64 Linux host |

Host-side scripts need `bash` ≥ 3.2, `git`, `tar`, `awk`, `sed`, `find`. They
write only below `.cache/`, `build/` and `out/` inside the repository.

## Requirements for ISO builds

The ISO is built by upstream's `buildiso.sh` with `mkarchiso`. That requires
Arch Linux, root privileges, mounting, and it **modifies `/usr/bin/mkarchiso`**.
It must therefore run in an isolated, disposable environment:

| Build host | Status |
|------------|--------|
| x86_64 Linux with Docker | **Recommended.** The container mirrors upstream's CI. |
| x86_64 Linux with Podman | Expected to work (`--engine podman`), not verified yet. |
| Dedicated Arch Linux x86_64 VM | Supported without containers, see [below](#building-in-an-arch-linux-vm). |
| macOS on Apple Silicon (Docker Desktop) | Environment check and `--prepare-only` verified. Full ISO builds run under x86_64 emulation and are **not verified** (very slow). Use an x86_64 Linux VM/host instead. |
| macOS without containers | Not possible: archiso does not run on macOS. |

Resources: ≥ 30 GiB free disk space for the work directory
(`MIN_FREE_GIB` in `config/build-env.conf`), 8 GiB RAM recommended, network
access to GitHub, the Arch Linux mirrors, the CachyOS mirror and
`keyserver.ubuntu.com`.

The container runs with `--privileged` because pacstrap and mkarchiso mount
file systems. Treat it like root access to the Docker host (or Docker VM).

## Building in the container

```bash
# 1. build the image (first run, or after changes to container/ or config/build-env.conf)
scripts/build-in-container.sh --image-only

# 2. check the environment: Arch, x86_64, packages, CachyOS key, sudo, mounting, disk space
scripts/build-in-container.sh --check

# 3. optional: assemble the tree only (no mkarchiso)
scripts/build-in-container.sh --prepare-only default

# 4. full build
scripts/build-in-container.sh default
```

What `scripts/build-in-container.sh` does:

- builds `container/Containerfile` with the pins from `config/build-env.conf`
  (image tag = hash of both files, so changes produce a new image),
- runs `scripts/build.sh` as user `builder` inside the container with the
  repository mounted at `/workspace` and the mkarchiso work directory on the
  named volume `linux-gaming-lab-work`,
- passes all other options to `scripts/build.sh` (`--verbose`,
  `--keep-build-dir`, `--offline`, profile name; see `--help`).

`--rebuild-image` refreshes the image (new Arch/CachyOS tool versions);
`--shell` opens a shell in the build environment for debugging.

### Outputs

`out/<profile>/` (ignored by git):

| File | Content |
|------|---------|
| `cachyos-desktop-linux-<YYMMDD>.iso` | the image (upstream naming) |
| `*.sha1`, `*.sha256` | checksums created by upstream |
| `*.pkgs.txt` | exact package versions in the image |
| `build-info` | project revision, upstream commit, profile, overlays, patches |
| `manifest.txt`, `changes.stat`, `changes.patch` | all changes against upstream |
| `build.log` | full output of upstream's `buildiso.sh` |

Upstream's `EXIT` trap prints "An unknown error has occurred" even after a
successful build; `scripts/build.sh` relies on the exit code and on the ISO
actually existing.

**Do not publish these files** — see [redistribution.md](redistribution.md).

## Building in an Arch Linux VM

For a dedicated, disposable x86_64 Arch Linux VM (never a workstation):

1. Replicate `container/Containerfile`: import and locally sign the CachyOS key
   (`CACHYOS_KEY_FPR` from `config/build-env.conf`), add `[cachyos]` before
   `[core]` in `/etc/pacman.conf`, install
   `archiso cachyos-keyring mkinitcpio-archiso squashfs-tools grub git sudo curl`.
2. Use a regular user with passwordless sudo.
3. Run `LGL_ALLOW_HOST_BUILD=1 scripts/build.sh --check`, then
   `LGL_ALLOW_HOST_BUILD=1 scripts/build.sh default`.

## Testing an ISO

Boot it in a VM on the build host (KVM recommended), UEFI and BIOS:

```bash
# Arch Linux host: helper shipped with archiso
run_archiso -u -i out/default/*.iso    # UEFI
run_archiso -i out/default/*.iso       # BIOS

# any Linux host with QEMU and OVMF (firmware path differs per distribution;
# Debian/Ubuntu: /usr/share/OVMF/OVMF_CODE_4M.fd)
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 8G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -cdrom out/default/cachyos-desktop-linux-*.iso -boot d
```

Smoke test checklist:

- boots in UEFI and BIOS mode; Plasma (Wayland) live session starts,
- `cat /etc/linux-gaming-lab/build-info` shows the expected revision,
- network works; the Calamares installer starts,
- an installation to a VM disk boots.

Upstream automates installation tests with quicktest (`testcases/`); adopting
it is part of the "Reproducible ISO Build" milestone.

## Verification status

| Step | Status |
|------|--------|
| `validate.sh`, `tests/run.sh` | verified on Linux (CI) and macOS (bash 3.2) |
| `bootstrap.sh --verify-branch`, `prepare.sh default` against real upstream | verified on Linux (CI) and macOS |
| Container image build, `--check`, `--prepare-only` | verified on x86_64 Linux (CI workflow *Build environment*) and Docker Desktop on Apple Silicon (emulated) |
| Negative check: container without `--privileged` is rejected | verified |
| Full ISO build (`mkarchiso`) | **not yet verified** — tracked in the roadmap |
| Boot/installation test of a built ISO | **not yet verified** |

## Cleaning up

```bash
rm -rf build out .cache                        # work trees, outputs, upstream cache
docker volume rm linux-gaming-lab-work         # mkarchiso work directory
docker image ls localhost/linux-gaming-lab-builder   # then docker image rm <tag>
```

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `error restricting syscalls via seccomp` during image build | pacman's syscall sandbox under emulation; the Containerfile enables `DisableSandboxSyscalls`. Rebuild with `--rebuild-image`. |
| `cannot mount file systems` | Container started without `--privileged`; use `scripts/build-in-container.sh`. |
| Key import fails | `keyserver.ubuntu.com` unreachable; retry, or change `CACHYOS_KEYSERVER`. |
| `refusing to build outside an isolated environment` | `scripts/build.sh` was run on a host; use the container or a dedicated VM. |
| `patch … does not apply` / `cannot remove '…'` | Upstream changed; see [upstream.md](upstream.md#rebasing-patches). |
| `refusing to delete … still mounted` | An aborted mkarchiso left mounts; unmount them (inside the container) and retry. |
