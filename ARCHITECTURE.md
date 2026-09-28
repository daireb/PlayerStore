# Architecture

## Responsibilities

- **ProfileStore** owns persistence, session locks, autosave and shutdown saving. It is supplied by the consumer; PlayerStore does not install another shutdown saver.
- **PlayerStore** owns schema validation, load transformations, tracked writes and replication to the owning client.
- **The game** owns load/unload ordering, economy rules, receipt handling, UI bindings and recovery policy. It must settle buffered values before release.

The library stays independent of Fusion, Vide, service frameworks and a game's data schema. `src/init.luau` exposes schema helpers and store constructors; internal modules remain small, ordinary Luau modules.

## Loading and releasing

`ServerStore` serializes acquisition per user ID and binds an acquired profile to the particular Player instance. Concurrent calls for that Player share the acquisition result, including failure or cancellation; a later call may start a new attempt. Cancellation covers departure, explicit unload, destruction and a 30-second acquisition deadline checked by ProfileStore. ProfileStore may still be waiting on a platform request when that deadline passes.

Load transformations use a copy because ProfileStore can autosave while a migration yields, and releasing a failed load also saves. The sequence is: migrate saved shape → normalize migration output → reconcile missing defaults → validate → install candidate → expose observable. Normalization validates persistence-safe values and copies migration output into independent mutable tables. Failures leave the original data untouched. Both new and already-current profiles go through reconciliation and validation. Reconciliation initializes absent maps but never fills entries in existing maps: a missing entry may be an intentional deletion.

Store lookups and tracked writes require current ownership and `IsActive()`, including writes through cached observables. Previously borrowed tables or cached observable reads are not proof of an active session. Cleanup from an old profile cannot remove a replacement. Explicit unload leaves final saving to ProfileStore; `Destroy` disconnects all hooks and is terminal. Neither method claims durable completion.

## Writes and observation

Data remains plain tables. Reads borrow references; tracked writes validate and copy only submitted table values into independent mutable trees. This prevents shared input references from linking unrelated paths or frozen input from blocking later writes, without copying the full profile on every change. Scalar writes need no copy. Direct mutation of borrowed tables remains outside the tracked API.

`Schema` resolves and freezes defaults and marker paths. `Validation` checks fixed fields against defaults; `DataValue` enforces persistence-safe values even inside dynamic maps or extra stored fields. Validation visits the changed value, not the entire profile for every scalar write.

`ObservableTable` indexes observers by path in a trie. A leaf write visits its ancestors; replacing a branch also notifies registered descendants. Batches validate first, apply with rollback for path failures, then notify each affected path once. Overlapping batch paths are rejected to keep validation and commit semantics unambiguous.

Replication runs through a synchronous internal commit hook **before** user callbacks. It must not depend on a consumer listener's ordering or yields. Signals snapshot active subscriptions so disconnecting during dispatch cannot skip unrelated listeners. Callbacks can read the committed state; yielding or reentrant writes mean later callbacks may observe newer state.

## Replication protocol

One `RemoteEvent`, `__PlayerStore_{storeId}`, belongs to each server store. The client subscribes before requesting `"snapshot"`; a request arriving before load is held until the profile is ready. Repeated requests are coalesced to at most one snapshot per second, allowing client recreation without unbounded full-profile responses. Clients send no paths or mutations.

Snapshots contain only declared public root fields. Deltas filter using the same root-field policy; private roots, undeclared legacy roots and `_DataVersion` never replicate. Nested private markers are rejected, avoiding recursive redaction on every message. The client replaces a root snapshot and ignores deltas until initialized. Batches cross the remote as one message.

Normally one client store lives for the player's session; destroying and recreating it requests a fresh snapshot. Server unload/reload while that same client continues running is not a supported reset protocol; normal unloading is paired with departure.

## Save confirmation

Tracked write success proves an in-memory commit. `confirmSavedAsync` checks ProfileStore's `LastSavedData`, subscribes before requesting `Save`, and waits until the predicate holds, ownership ends or the deadline expires. It neither invents a separate save revision nor treats `OnSave` as proof of persistence. Predicates should check a durable marker, not a transient balance that unrelated writes can change.

## Verification boundary

`.lune/test.luau` loads production modules through a small controlled runtime. Existing pure suites cover values, schemas and observables; `tests/unit` exercises actual stores with controllable profiles and copied, queued network messages. The runtime does not emulate Roblox scheduling, DataStore retries or session locks.

`test.project.json` runs engine integration against the locked ProfileStore version using its in-memory mock. This checks actual event and save behavior and client/server replication without requiring API Services or touching production data. Live storage and multi-server recovery remain ProfileStore's responsibility and need deployment-level checks when its configuration changes.
