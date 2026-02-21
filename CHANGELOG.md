# Changelog

All notable changes to PlayerStore will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

## [0.1.4] - 2026-02-21

### Added

- Automatic write validation: all `observe():set()` calls are now validated against the schema, catching invalid paths and type mismatches immediately

### Fixed

- Root `applyUpdate` (initial client data load) now fires all registered sub-path listeners, fixing `bind()` and `listen()` callbacks set up before data arrives

## [0.1.3] - 2026-02-21

### Changed

- Extracted `Validation.luau` from ServerStore into its own module
- Added validation unit tests covering missing keys, type mismatches, map path skipping, and deep nesting

## [0.1.2] - 2026-02-21

### Changed

- `profileStore` config field now typed as `{ New: (storeId, template) -> any }` instead of `any`
- Added runtime validation that `profileStore` is provided and has a `.New()` method

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
