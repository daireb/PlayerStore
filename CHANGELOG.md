# Changelog

All notable changes to PlayerStore will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-02-21

Fixed build config for the project.

## [0.1.0] - 2026-02-21

Initial release.

### Added

- Schema definition with `schema()`, `map()`, and `private()` markers
- `ServerStore` with ProfileStore integration, automatic replication, and private path filtering
- `ClientStore` with read-only ObservableTable access and `waitUntilLoaded`
- `ObservableTable` with hierarchical path-based change tracking (`get`, `set`, `listen`, `bind`)
- Migration system using ordered function lists with automatic versioning
- Structural validation on load (skipping `map` paths)
- Default session-end kick behavior with `onSessionEnd` override
- `onSave` hook for pre-save callbacks
- `wipeData` for resetting player data to template defaults
