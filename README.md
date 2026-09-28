# PlayerStore

Player data for Roblox: [ProfileStore](https://madstudioroblox.github.io/ProfileStore/) sessions with schema defaults, migrations, observable writes and private-field filtering for replication. Games supply ProfileStore and own when players load and unload.

## Install

Install v0.4.0 with pesde. Review the breaking changes from 0.3.0 in [CHANGELOG.md](CHANGELOG.md) before upgrading.

```sh
pesde add gh#daireb/PlayerStore#v0.4.0
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
Players.PlayerRemoving:Connect(function(player)
    -- Settle game-owned buffers before releasing the profile.
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

Paths use string keys separated by `/`. Values must be finite numbers, booleans, valid UTF-8 strings or plain acyclic tables. Tables are string dictionaries or dense arrays; replace arrays as whole values. `map` relaxes structural checks, not persistence checks. Fixed fields retain their declared types. `_DataVersion` is reserved.

## API

### Server

| Method | Contract |
| --- | --- |
| `loadAsync(player)` | Returns success; loads, migrates, reconciles and validates before exposing data. Failed loads kick by default. Concurrent calls for the same Player share one attempt and its result. |
| `unloadAsync(player)` | Cancels a pending load or starts session release. Does not wait for a save confirmation. |
| `getData(player)` / `observe(player)` | Returns data / writable observable only while this store owns an active session; otherwise `nil`. |
| `trySet(player, path, value)` / `trySetMany(player, updates)` | Returns `(boolean, error?)`. An empty batch is a successful no-op. Observable `set` / `setMany` raises on invalid writes. |
| `waitForData(player, timeout?)` | Returns data or `nil` on timeout, failed load, departure, unload or destruction. Default: 30 seconds. |
| `confirmSavedAsync(player, predicate, timeout?)` | Returns `(boolean, error?)` after checking **LastSavedData**, requesting a save if needed. Default: 15 seconds. Predicate must be synchronous, read-only and true only for the persisted state you need. |
| `onSave(callback)` | Registers `(player, data)` before ProfileStore saves; returns a disconnect function. Synchronous hooks may update save-only metadata directly; these changes are not validated or replicated. Settle gameplay through tracked writes before unloading. |
| `onSessionEnd(callback)` | Replaces the kick handler for unexpected session loss. Explicit unload does not call it. |
| `wipeData(player)` | Resets schema fields and kicks the player; the game's removal handler releases the profile. |
| `Destroy()` | Cancels loads, disconnects callbacks, releases sessions and destroys the remote. Final save uses committed data; settle game buffers first. Idempotent. |

Use save confirmation for a specific durable marker when required; ordinary writes rely on ProfileStore's autosave. A timeout does not undo a write or prove it was lost. Receipt deduplication, granting policy and retries belong to the game.

### Client and observation

- `get(path?)`: current value; before loading this is schema defaults.
- `listen(path?, callback)`: future changes; returns a disconnect function.
- `bind(path?, callback)`: subscribes and also invokes the callback with the current value.
- `waitUntilLoaded(timeout?)`: returns readiness, default 30 seconds; `isLoaded()` checks immediately.
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

Pull requests run the same Lune suite in [GitHub Actions](.github/workflows/tests.yml); it needs no Roblox credentials or package installation.

Open the built place in Studio and Play. Server and client suites use the installed **ProfileStore.Mock**; no cloud data is written. Check both suite summaries. Lune covers failure cases quickly; Studio verifies engine events, replication and the real ProfileStore API. Mock tests do not establish live DataStore availability or cross-server locking.

See [ARCHITECTURE.md](ARCHITECTURE.md) for ownership and implementation decisions. MIT licensed.
