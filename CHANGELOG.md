# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

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
