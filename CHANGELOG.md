# Changelog

All notable changes to PlayerStore will be documented in this file.

This project follows [Semantic Versioning](https://semver.org/).

## Unreleased — breaking changes after 0.3.0

- `setMany` / `trySetMany` reject duplicate and ancestor/descendant paths. Submit one complete parent replacement or disjoint leaf updates.
- Tracked writes copy submitted tables; input mutation and shared references no longer affect stored values. Reads still borrow live tables. Failed batches roll back earlier writes even when a destination is frozen.
- Schemas and tracked writes reject values that cannot persist reliably: non-finite numbers, invalid UTF-8, metatables, cycles, sparse/mixed tables and non-string dictionary keys. Paths are nonempty string segments separated by `/`; arrays are whole-value replacements. `_DataVersion` is reserved.
- Every successful load reconciles missing defaults **after** migrations. Existing maps preserve deleted entries; only absent maps receive defaults. Remove consumer reconciliation wrappers; they otherwise change the shape migrations see. Malformed/future versions fail closed. Failed migrations never install partial edits.
- Install matching server/client versions together: clients now request their initial snapshot. Only declared public root fields replicate; move any required legacy fields into the schema.
- Waits are bounded by default (30 seconds). Check the boolean from `waitUntilLoaded` and the optional result of `waitForData`.
- Store lookups and tracked writes refuse inactive sessions; stale Player/profile callbacks cannot affect replacement owners. Concurrent loads for one Player share failure and cancellation as well as success. Games still explicitly load and unload players.
- `confirmSavedAsync` replaces consumer access to `_profiles` for save confirmation. A successful write is not a durable acknowledgement.
- `onSave` returns a disconnect function. Store `Destroy` is terminal and disconnects hooks before release; settle game buffers first.
- Lune tests now exercise production modules and return a failing exit status. Studio integration uses ProfileStore.Mock and fails when required companion scripts are missing.

No release tag is created by this change. Review and test consumers before publishing the next version.

## [0.3.0] - 2026-08-17

### Added

- `ServerStore:trySet()` and `trySetMany()` return `(boolean, string?)` instead of raising, including `"Data not loaded"` when no profile is present

## [0.2.0] - 2026-07-17

### Added

- Atomic `ObservableTable:setMany()` writes with ordered updates, rollback on failure, coalesced listeners, and end-to-end batched client replication
- Exported `Signal<T>` type

### Changed

- Nested `private()` markers are now rejected at schema creation, preventing private descendants from leaking when a public parent table is replicated
- Fixed-structure table replacements now validate their complete subtree; validation paths also emit targeted MicroProfiler markers
- Replacing a `map()` field now preserves its required table type while dynamic child values remain unrestricted
- Observer dispatch now uses a path trie, avoiding global listener scans and repeated ancestor-path construction

### Fixed

- Replacing a parent table now notifies registered descendant listeners, including when their resolved value becomes `nil`
- Profiles already at the latest migration version are now structurally validated when loaded
- Schema defaults are now cloned recursively for ProfileStore templates, client stores, and data wipes, preventing shared nested table references
- Processed schema templates are now recursively frozen to prevent accidental nested default mutation

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
