# PlayerStore

Player data for Roblox: [ProfileStore](https://madstudioroblox.github.io/ProfileStore/) sessions with schema defaults, migrations, observable writes and private-field filtering for replication. Games supply ProfileStore and own when players load and unload.

## Install

Install v0.4.2 with pesde. Review the breaking changes from 0.3.0 in [CHANGELOG.md](CHANGELOG.md) before upgrading.

```sh
pesde add gh#daireb/PlayerStore#v0.4.2
pesde install
```

## Start here

Define a shared schema. `map` allows dynamic keys; `private` excludes an entire **root field** from client data. A shared schema's defaults are visible to clients, so never put secrets in them.

```lua
local PlayerStore = require(path.to.PlayerStore)

return PlayerStore.schema {
    Coins = 0,
    Settings = { MusicEnabled = true },
    Inventory = PlayerStore.map {} :: { [string]: number },
    Receipts = PlayerStore.private(PlayerStore.map {}),
}
```

Create one server store per `storeId` and one client store for that store. Use a separate store ID for development data.

```lua
local Players = game:GetService("Players")
local store = PlayerStore.createServerStore {
    schema = DataSchema,
    storeId = "PlayerData_Dev",
    profileStore = ProfileStore,
}

Players.PlayerAdded:Connect(function(player)
    store:loadAsync(player)
end)
-- Settle game-owned buffers inside the release, while writes still succeed.
store:onBeforeRelease(function(player, data)
    -- e.g. store:trySet(player, "Stats/PlayTime", data.Stats.PlayTime + unflushedSeconds(player))
end)
Players.PlayerRemoving:Connect(function(player)
    store:unloadAsync(player)
end)
for _, player in Players:GetPlayers() do
    task.spawn(store.loadAsync, store, player)
end
```

```lua
local data = PlayerStore.createClientStore {
    schema = DataSchema,
    storeId = "PlayerData_Dev",
}
if not data:waitUntilLoaded() then
    return -- Show the game's loading failure state.
end
local disconnect = data:bind("Coins", function(coins)
    print(coins)
end)
-- Disconnect when this view closes; destroy the store only when its owner ends.
```

## Read and write

`getData(player)`, `observe(player):get()` and client `get()` return **borrowed live tables**. Read them; do not mutate them. Clone any branch you need to edit, then submit it through a tracked write. Direct mutation of a borrowed table bypasses validation, notifications and replication.

Tracked writes copy submitted tables into independent, mutable values. Later changes to your input do not affect the store; table identity and shared references are not preserved.

```lua
local data = store:getData(player)
if data and data.Coins >= 100 then
    local ok, err = store:trySetMany(player, {
        { path = "Coins", value = data.Coins - 100 },
        { path = "Inventory/Sword", value = (data.Inventory.Sword or 0) + 1 },
    })
end
```

Keep read/check/write code synchronous. Batches commit all writes before notifying listeners or replicating; **this is in-memory atomicity, not a confirmed DataStore save**. Batch paths must be disjoint: no duplicates or ancestor/descendant pairs. Replace a parent with its complete new value instead. Use `value = nil` to delete a dynamic map entry.

Paths use string keys separated by `/`. Values must be finite numbers, booleans, valid UTF-8 strings or plain acyclic tables. Tables are string dictionaries or dense arrays; replace arrays as whole values. `map` relaxes structural checks, not persistence checks. Fixed fields retain their declared types. `_DataVersion` and `_ReleaseToken` are reserved.

## API

### Server

| Method | Contract |
| --- | --- |
| `loadAsync(player)` | Returns success; loads, migrates, reconciles and validates before exposing data. Acquisition has a 120-second cancellation deadline, allowing ProfileStore's stale-session recovery to finish. It first waits, within that deadline, for the same user's previous release on this server to land. Failed loads kick by default. Concurrent calls for the same Player share one attempt and its result. |
| `unloadAsync(player)` | Cancels a pending load or starts session release. Does not wait for a save confirmation. |
| `getData(player)` / `observe(player)` | Returns data / writable observable only while this store owns an active session; otherwise `nil`. |
| `trySet(player, path, value)` / `trySetMany(player, updates)` | Returns `(boolean, error?)`. An empty batch is a successful no-op. Observable `set` / `setMany` raises on invalid writes. |
| `waitForData(player, timeout?)` | Returns data or `nil` on timeout, failed load, departure, unload or destruction. Default: 120 seconds, matching the acquisition deadline. |
| `confirmSavedAsync(player, predicate, timeout?)` | Returns `(boolean, error?)` once **LastSavedData** satisfies the predicate, requesting a save if needed and again every 5 seconds while none lands. Follows the session through the Player's departure and its release save. Default: 15 seconds. Predicate must be synchronous, read-only and true only for a durable marker the write added. Only `true` is a fact: `false` means not confirmed (`"Data not loaded"`, `"Session lost"`, `"Not in final save"`, `"Save confirmation timed out"` or a predicate error), and a timed-out write can still land. |
| `onSave(callback)` | Registers `(player, data)` before ProfileStore saves; returns a disconnect function. Synchronous hooks may update save-only metadata directly; these changes are not validated or replicated. |
| `onBeforeRelease(callback)` | Registers `(player, data)` to run synchronously when `unloadAsync` or `Destroy` is about to release a loaded session; returns a disconnect function. Tracked writes to that player succeed inside the hook even after the Player has left (deferred `PlayerRemoving`), so settle game-owned buffers here. Must not yield. ProfileStore-initiated releases (shutdown, session loss) do not run it; flush from `onSave` as well if those saves matter. |
| `onSessionEnd(callback)` | Replaces the kick handler for unexpected session loss. Explicit unload does not call it. |
| `onMessage(kind, handler)` | Registers the handler for messages of `kind`; returns a disconnect function. See [Transfers between players](#transfers-between-players). |
| `outboxUpdate(message)` | Returns the update that queues `{ to, kind, id, body }`; put it in the same `trySetMany` as the decision it belongs to. |
| `retryMessages(player)` | Retries that session's deferred messages now. |
| `wipeData(player)` | Resets schema fields, except the mailbox roots, and kicks the player; the game's removal handler releases the profile. |
| `Destroy()` | Runs before-release hooks, then cancels loads, disconnects callbacks, releases sessions and destroys the remote. Final save uses committed data. Idempotent. |

Use save confirmation for a specific durable marker when required; ordinary writes rely on ProfileStore's autosave. A timeout does not undo a write or prove it was lost. After a session is stolen, LastSavedData is the new owner's data, so test a marker your write added, never a balance. Receipt deduplication, granting policy and retries belong to the game.

## Transfers between players

Two profiles never save together, so an effect on another player (a gift now, a trade leg later) is decided in one write on the sender and reaches the receiver as a message, which the receiver applies exactly once. Declare two private map roots and pass them as `mailbox`:

```lua
local DataSchema = PlayerStore.schema {
    Inventory = PlayerStore.map {} :: { [string]: number },
    Receipts = PlayerStore.private(PlayerStore.map {}),
    MailInbox = PlayerStore.private(PlayerStore.map {}),
    MailOutbox = PlayerStore.private(PlayerStore.map {}),
}
local store = PlayerStore.createServerStore {
    schema = DataSchema,
    storeId = "PlayerData_Dev",
    profileStore = ProfileStore,
    mailbox = { inbox = "MailInbox", outbox = "MailOutbox" },
}
```

Send by putting the message in the same write as the decision:

```lua
local ok, err = store:trySetMany(buyer, {
    { path = `Receipts/{purchaseId}`, value = true },
    store:outboxUpdate { to = recipientId, kind = "gift", id = `gift:{purchaseId}`, body = { item = "Sword" } },
})
```

PlayerStore sends an entry once it is saved, wherever the receiver is (this server, another one, or offline until they next join), and deletes it after the send commits. Receive with one handler per kind:

```lua
store:onMessage("gift", function(player, data, body, meta)
    if (data.Inventory[body.item] or 0) > 0 then
        -- Refuse with a reply; it lands in the same write as the inbox mark.
        return { send = { { to = meta.from, kind = "gift-return", id = `gift-return:{meta.id}`, body = body } } }
    end
    return {
        updates = { { path = `Inventory/{body.item}`, value = 1 } },
        after = function()
            -- Popups and other effects that need not survive a crash.
        end,
    }
end)
```

- Ids are idempotency keys: unique across senders and kinds, so prefix them with the kind. The receiver applies an id once, however often it arrives.
- Handlers plan against `data` and return writes; they never yield or write themselves. A yielding handler is cancelled and its message deferred. Return `nil, reason` to defer a message (for example until something it needs has loaded), then call `retryMessages(player)`. Deferred messages, unknown kinds and handlers that error are retried on later saves, on `onMessage` and in the next session, never dropped.
- Handlers must not write the mailbox roots. Delivery order is unspecified.
- The inbox is never pruned (about 50 bytes per message received): pruning would let a late resend apply twice. `wipeData` keeps both roots; admin tools that replace saved data must keep them too.
- Limits: ProfileStore keeps at most 1000 unread messages per key and drops the oldest. A corrupt-key reset or `RemoveAsync` discards the queue. A message whose sender's server dies or shuts down between saving and sending waits for the sender's next session.

### Client and observation

- `get(path?)`: current value; before loading this is schema defaults.
- `listen(path?, callback)`: future changes; returns a disconnect function.
- `bind(path?, callback)`: subscribes and also invokes the callback with the current value.
- `waitUntilLoaded(timeout?)`: returns readiness, default 30 seconds; `isLoaded()` checks immediately. A timeout does not cancel replication: a later snapshot can still load while the server finishes session recovery.
- `Destroy()`: disconnects replication and wakes pending waits with `false`.

Server observables have the same read/listen/bind methods. Listeners react to writes above, at or below their path; ancestor replacement may notify a descendant with `nil`. Callback arguments are `(value, path, changedValue, changedPath, batch?)`. Keep callbacks short and non-yielding; this is a change notification API, not an immutable event log.

## Migrations

Pass `migrations = { function(data) ... end, ... }` to the server constructor. Each index is a version; append migrations, never reorder them. Keep them deterministic and local to the supplied table.

Existing profiles run missing migrations on an isolated copy **before** missing schema defaults are filled. The candidate is installed only after validation. New profiles start at the latest version without historical migrations. Missing version means legacy version zero; malformed or future versions fail closed. Adding defaults alone needs no migration; renames and changes of meaning do.

Existing `map` contents are preserved, including deleted default entries. Defaults initialize an entirely missing map; use a migration for an intentional grant to existing players.

## Development

```sh
lune run test                 # actual modules, controlled persistence/network boundary
stylua --check src tests .lune
selene src tests
pesde install --locked        # ProfileStore dependency for engine integration
rojo build test.project.json -o PlayerStoreTests.rbxl
```

Pull requests run the same Lune suite in [GitHub Actions](.github/workflows/tests.yml); it needs no Roblox credentials or package installation. The transfer scenarios in `tests/unit/Transfers.luau` run the locked ProfileStore source against a fake DataStore, so they need `pesde install --locked` and are skipped without it, as in Actions.

Open the built place in Studio and Play. Server and client suites use the installed **ProfileStore.Mock**; no cloud data is written. Check both suite summaries. Lune covers failure cases quickly; Studio verifies engine events, replication and the real ProfileStore API. Mock tests do not establish live DataStore availability or cross-server locking.

See [ARCHITECTURE.md](ARCHITECTURE.md) for ownership and implementation decisions. MIT licensed.
