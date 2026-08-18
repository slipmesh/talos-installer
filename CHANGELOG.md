# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and follows [Semantic Versioning](https://semver.org/).

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
