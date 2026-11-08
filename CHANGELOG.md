# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

## [1.15.0-alpha.2+sm.2] - 2026-11-08

### Fixed 🐛

- Carry the daemons' license notices onto the node (#33)

## [1.15.0-alpha.2+sm.1] - 2026-11-07

### Build system 🛠️

- Take the daemons from talos-extensions v1.14.5+sm.2 (#27)
- Move to Talos v1.15.0-alpha.2 (#31)

### CI/CD ⚙️

- Build only the merged release PR, through the v2 shared workflows (#13)
- Mark the newest stable release latest, through slipmesh/.github@v2.1 (#14)
- Promote before tagging, through slipmesh/.github@v2.2 (#17)
- Call the shared workflows at slipmesh/.github@v2.3 (#19)
- Call the shared workflows at slipmesh/.github@v2.4 (#25)

### Documentation 📚

- Tag alpha.0 when branching a line, and how to withdraw a broken release (#16)

### Fixed 🐛

- Keep this build's variables out of the Talos build (#10)
- Raise machined's network event history to 100k events (#22)

## [1.15.0-alpha.0] - 2026-10-28

### Added ✨

- Build the awg, router and nftables extensions here (#5)
- Build against Talos v1.14.5 (#8)

### CI/CD ⚙️

- Release from release-* branches, named after the Talos release (#6)
- Skip the build for Markdown-only changes (#7)

### Documentation 📚

- Say what the base image does not supply

### Fixed 🐛

- Take the base from installer-base, not installer

### Miscellaneous 🧹

- Bump talos to v1.14.0
- Bump talos to v1.14.2
- Build against Talos v1.14.4

## [0.1.1] - 2026-08-27

### CI/CD ⚙️

- Build each arch on a runner of its own architecture

### Documentation 📚

- Address the reader who cloned one repository, not five
- State the facts, drop how they were found
- State the facts, drop how they were found

### Miscellaneous 🧹

- Bump to Talos 1.13.9
- Add the standard markdownlint config, fix what it found
- Move markdownlint config to the cli2 file

## [0.1.0] - 2026-08-18

### Added ✨

- Initial commit: generic kernel+N-extensions installer assembly

### CI/CD ⚙️

- Migrate to ghcr.io/slipmesh, add license files and workflow_dispatch release CI

### Documentation 📚

- Document the fifth repo (talos-nftables-extension) in the split pipeline
- Fix example extension tag to match awg-extension's +talosX.Y.Z suffix

### Fixed 🐛

- Fix push/push-manifest: read the built tag back, don't recompute BUILD_SLUG
- Fix installer bake: drop :z from the base-oci bind mount
- EXTENSIONS must be arch-less base refs, not pre-suffixed

### Miscellaneous 🧹

- Add cliff.toml for changelog generation, update usage examples
