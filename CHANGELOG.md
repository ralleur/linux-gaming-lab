# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). No releases have
been made yet.

## [Unreleased]

### Added

- Upstream pin of CachyOS-Live-ISO `3215497d2e8c` (2026-10-03) with commit,
  tree hash and date verification (`config/upstream.lock`, `scripts/bootstrap.sh`).
- Build tree assembly from upstream, patches, overlay modules and package
  lists, with provenance file and change record (`scripts/prepare.sh`).
- Isolated build environment mirroring upstream's CI (`container/Containerfile`,
  `config/build-env.conf`) and entry points `scripts/build-in-container.sh` and
  `scripts/build.sh` with environment, dependency and privilege checks.
- Upstream update script with compatibility report and automatic rollback
  (`scripts/update-upstream.sh`).
- Profile `default` (upstream desktop buildset) and overlay module `common`.
- Repository validation (`scripts/validate.sh`) and offline tests (`tests/`).
- CI workflows: validation, shellcheck, actionlint, tests on Linux and macOS,
  upstream reference check, build-environment check.
- Documentation: architecture, build, upstream tracking, development,
  redistribution and licensing, roadmap.
