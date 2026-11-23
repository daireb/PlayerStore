# Architecture

## Responsibilities

- **ProfileStore** owns persistence, session locks, autosave and shutdown saving. It is supplied by the consumer; PlayerStore does not install another shutdown saver.
- **PlayerStore** owns schema validation, load transformations, tracked writes and replication to the owning client. With a mailbox configured, it also owns message transport and deduplication between profiles.
- **The game** owns load/unload ordering, economy rules, receipt handling, UI bindings and recovery policy, and the message kinds, their policy and the decisions that send them. It must settle buffered values before release, normally in an `onBeforeRelease` hook.

The library stays independent of Fusion, Vide, service frameworks and a game's data schema. `src/init.luau` exposes schema helpers and store constructors; internal modules remain small, ordinary Luau modules.

## Loading and releasing

`ServerStore` serializes acquisition per user ID and binds an acquired profile to the particular Player instance. Concurrent calls for that Player share the acquisition result, including failure or cancellation; a later call may start a new attempt. Cancellation covers departure, explicit unload, destruction and a 120-second acquisition deadline checked by ProfileStore. This matches ProfileStore's default timeout and leaves time for its stale-session takeover, which can require 45 seconds with default retry intervals. The same deadline includes waiting for an old Player's session to release; `waitForData` also defaults to 120 seconds. ProfileStore may still be waiting on a platform request when that deadline passes.

Load transformations use a copy because ProfileStore can autosave while a migration yields, and releasing a failed load also saves. The sequence is: migrate saved shape → normalize migration output → reconcile missing defaults → validate → install candidate → expose observable. Normalization validates persistence-safe values and copies migration output into independent mutable tables. Failures leave the original data untouched. Both new and already-current profiles go through reconciliation and validation. Reconciliation initializes absent maps but never fills entries in existing maps: a missing entry may be an intentional deletion.

A release holds its user ID on this server until the final write lands. ProfileStore fires `OnSessionEnd` before that write, and a new session for the same key on the same server takes the lock and bumps the load count, after which ProfileStore refuses every retry of the old write. So `OnLastSave` stamps a fresh `_ReleaseToken` into Data before the final transform reads it, and the hold ends when `LastSavedData` carries that token, or at once on a steal (`OnSessionEnd` without `OnLastSave`). Tracked writes stop when the session ends, so any save carrying the token wrote the final Data, even when an earlier queued save answers first. A load waiting on the hold is bounded by the acquisition deadline and kicks when it passes. If another server steals the key while the final save is still retrying, that save is refused, its token never lands and the hold lasts until this server restarts; that takes a DataStore outage of 45 seconds or more during a release.

Store lookups and tracked writes require current ownership and `IsActive()`, including writes through cached observables. Previously borrowed tables or cached observable reads are not proof of an active session. Cleanup from an old profile cannot remove a replacement. The one exception to the departure check is a session running its before-release hooks: `unloadAsync` and `Destroy` run them before clearing ownership, and writes to that session succeed even though the Player may already be unparented under deferred signal behavior. Explicit unload leaves final saving to ProfileStore; `Destroy` runs before-release hooks, then disconnects all hooks and is terminal. Neither method claims durable completion.

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

Tracked write success proves an in-memory commit. `confirmSavedAsync` checks ProfileStore's `LastSavedData`, subscribes before requesting `Save`, and waits until the predicate holds. It neither invents a separate save revision nor treats `OnSave` as proof of persistence.

It captures the profile at the call and follows it, not the Player: a departed Player's session keeps saving, and the release write retries until it lands and fires `OnAfterSave`. ProfileStore tries an ordinary save once and reports a failure only through its global `OnError`, so the confirmation asks for another save after 5 seconds without one while the session is active. It returns false early only when nothing it waits for can still land: `"Session lost"` when the session ended without a final save of ours (a steal), and `"Not in final save"` when the release token has landed without the predicate. Only `true` is a fact; a timed-out write can still land.

`LastSavedData` mirrors what the DataStore held after each write: after a steal that is the new owner's data, and after a migration it keeps the pre-migration shape until the first save. Predicates should therefore check a durable marker the write added, not a balance that unrelated writes can change.

## Messages

With a `mailbox` configured, PlayerStore carries messages between profiles on ProfileStore's per-key message queue. Each profile commits atomically and two never do, so a cross-profile effect is decided by one write on one profile and reaches the other as an at-least-once message, applied exactly once. The invariants:

- **Send only what is saved.** `outboxUpdate` makes the message part of the sender's decision write. The relay sends an entry with `MessageAsync` only when it is in both Data and `LastSavedData`, so a send never runs ahead of a decision a crash could undo. After `MessageAsync` commits, a tracked write deletes the entry; if that delete is lost, the next session resends, which is harmless. The relay runs at load and after every save of a held or releasing profile, the release save included.
- **Effect, mark and removal in one write.** PlayerStore is each profile's only `MessageHandler`. A delivery is checked against the inbox and, if new, planned by the game's handler inside a coroutine. The plan, an inbox mark for the id and any replies go through one `trySetMany`, and `processed()` is called in the same synchronous step only if that write succeeded. ProfileStore removes processed messages in the next save's transform, the same `UpdateAsync` that writes Data, so the effect, the mark and the removal land together or not at all, and a crash or steal redelivers to the next session.
- **Never drop, always defer.** An unknown kind, a newer envelope version, a handler that yields (cancelled, its result ignored), errors or returns `nil, reason`, and a write that fails because the Player is leaving all leave the message unprocessed. Deferred messages are retried after each save, when their kind is registered and on `retryMessages`; the next session receives anything left.
- **Refusals are replies.** A receiver that can't take a message sends a reply in the same write as its inbox mark, so a refusal can be neither lost nor applied twice.

The envelope is `{ v, id, kind, from, body }`, sent to the key `tostring(to)`. The inbox is never pruned and `wipeData` keeps both roots: forgetting an id would let a late resend apply twice. ProfileStore drops the oldest messages past 1000 unread per key, and a corrupt-key reset or `RemoveAsync` discards the queue.

## Verification boundary

`.lune/test.luau` loads production modules through a small controlled runtime. Existing pure suites cover values, schemas and observables; `tests/unit` exercises actual stores with controllable profiles and copied, queued network messages. That runtime does not emulate Roblox scheduling, DataStore retries or session locks.

`tests/support/Cluster.luau` covers those for confirmation, release and messages. It runs the locked ProfileStore source on several simulated servers that share one fake DataStore and MessagingService, with JSON round trips, per-key atomic `UpdateAsync`, injectable errors, lost responses and held writes, and servers killed between API calls. Only the platform is faked, so ProfileStore's own locks, load counts, message queue and save retries run. It needs `pesde install --locked`; without the source those scenarios are skipped, as in Actions.

`test.project.json` runs engine integration against the locked ProfileStore version using its in-memory mock. This checks actual event and save behavior and client/server replication without requiring API Services or touching production data. Live storage and multi-server recovery remain ProfileStore's responsibility and need deployment-level checks when its configuration changes.
