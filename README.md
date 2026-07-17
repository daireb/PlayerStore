# PlayerStore

Schema-driven player data management for Roblox. Wraps [ProfileStore](https://madstudioroblox.github.io/ProfileStore/) with reactive change tracking, automatic server-to-client replication, migrations, and structural validation.

## Installation

```bash
pesde add gh#daireb/PlayerStore#v0.2.0
pesde install
```

## Quick Start

### 1. Define your schema (shared)

Create a module in a shared location (e.g. `ReplicatedStorage`) so both server and client can require it:

```lua
-- shared/DataSchema.luau
local PlayerStore = require(path.to.PlayerStore)

local schema = PlayerStore.schema
local map = PlayerStore.map
local private = PlayerStore.private

return schema {
    Resources = {
        Cash = 0,
        XP = 0,
    },

    Stats = {
        HighestTierReached = 0,
        TotalWins = 0,
    },

    Inventory = map {} :: { [string]: number },
    SelectedSlot = "Default",

    Settings = private {
        MusicVolume = 0.75,
        ShowTutorial = true,
    },
}
```

### 2. Set up the server

```lua
-- server/DataService.luau
local PlayerStore = require(path.to.PlayerStore)
local DataSchema = require(path.to.DataSchema)
local ProfileStore = require(path.to.ProfileStore)
local Players = game:GetService("Players")

local ServerData = PlayerStore.createServerStore {
    schema = DataSchema,
    storeId = "PlayerData_Production",
    profileStore = ProfileStore,
}

Players.PlayerAdded:Connect(function(player)
    ServerData:loadAsync(player)
end)

Players.PlayerRemoving:Connect(function(player)
    ServerData:unloadAsync(player)
end)

for _, player in Players:GetPlayers() do
    task.spawn(ServerData.loadAsync, ServerData, player)
end

local function addCash(player: Player, amount: number)
    local data = ServerData:getData(player)
    local obs = ServerData:observe(player)
    if data and obs then
        obs:set("Resources/Cash", data.Resources.Cash + amount)
    end
end
```

### 3. Set up the client

```lua
-- client/DataController.luau
local PlayerStore = require(path.to.PlayerStore)
local DataSchema = require(path.to.DataSchema)

local ClientData = PlayerStore.createClientStore {
    schema = DataSchema,
    storeId = "PlayerData_Production",
}

ClientData:waitUntilLoaded()

-- Read current values:
local cash = ClientData:get("Resources/Cash")

-- Listen for changes:
ClientData:listen("Resources/Cash", function(value)
    print("Cash is now", value)
end)
```

## Schema

The schema defines your data structure with default values. It's a plain Luau table with two optional markers:

- **`map {}`** -- Dynamic keys. Skips structural validation since keys aren't known ahead of time.
- **`private {}`** -- Server-only. Never sent to the client.

Everything else is strictly validated on load -- every key in the schema must exist in the player's data with the correct type.

`private()` fields must be declared at the schema root. A top-level private table can contain any nested server-only structure. Nested private markers inside otherwise replicated tables are rejected when the schema is created.

When composing markers, use parentheses as in `private(map {})`.

> Note: Stylua users should set `call_parentheses = "Input"` in `stylua.toml`

## Server usage

`getData(player)` returns the typed profile table for reads. Use `observe(player)` for writes so changes are validated, observed, and replicated.

### Write validation

All writes through `observe():set()` and `observe():setMany()` are automatically validated against the schema. Invalid paths and type mismatches error immediately:

```lua
obs:set("Resources/Cash", 100)       -- ok
obs:set("Resources/Cash", "wrong")   -- errors: type mismatch
obs:set("Fake/Path", 5)              -- errors: invalid path
obs:set("Inventory/Sword", 3)        -- ok (map path, any key allowed)
```

Replacing a fixed-structure table validates its complete subtree. Dynamic `map()` contents skip deep validation.

### Atomic batch writes

Use `setMany()` when related values must change together. It accepts an ordered list of updates, validates the complete batch before writing, and rolls back if any path cannot be applied:

```lua
local data = ServerData:getData(player)
local obs = ServerData:observe(player)

if data and obs and data.Resources.Cash >= 100 then
    obs:setMany({
        { path = "Resources/Cash", value = data.Resources.Cash - 100 },
        { path = "Inventory/Sword", value = (data.Inventory.Sword or 0) + 1 },
    })
end
```

All writes are applied before listeners run. Each affected root, ancestor, or leaf listener fires once with the final state, and the batch is sent to the client in one replication event so client listeners also avoid intermediate states. The ordered form supports deleting dynamic map entries with `value = nil`.

### Other server methods

- `waitForData(player, timeout?)` waits for a profile and returns its typed data.
- `onSave(callback)` registers work to run before ProfileStore saves.
- `wipeData(player)` resets the profile to schema defaults.
- `onSessionEnd(callback)` overrides the default behavior of kicking when a session ends.

## Client usage

The client store is read-only and receives updates automatically.

- `get(path?)` reads one path or the full data table.
- `listen(path?, callback)` reacts to future changes and returns a disconnect function.
- `bind(path?, callback)` behaves like `listen` but also fires immediately.
- `waitUntilLoaded()` waits for the initial server data; `isLoaded()` checks without yielding.

Listeners are hierarchical: they react to changes at their exact path, below it, or above it. If replacing an ancestor removes the listened-to value, the callback receives `nil`.

Call `waitUntilLoaded()` before reading real player data. Until then, `get()` and `bind()` use schema defaults.

## Migrations

Migrations transform existing player data when your schema changes. Provide them as an ordered list of functions -- the version is the index:

```lua
local ServerData = PlayerStore.createServerStore {
    schema = DataSchema,
    storeId = "PlayerData_Production",
    profileStore = ProfileStore,
    migrations = {
        function(data) -- 1
            data.Stats.TotalWins = data.Stats.TotalWins or 0
        end,
        function(data) -- 2
            data.Inventory = data.Inventory or {}
        end,
    },
}
```

- New players start at the latest version (no migrations run).
- Existing players run all migrations from their current version forward.
- Every loaded profile is validated against the schema. If validation fails, the player is kicked.
- Never reorder or remove migrations. Always append new ones to the end.
- Migrations should be idempotent -- check before overwriting.

## License

MIT
