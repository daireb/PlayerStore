# PlayerStore

Schema-driven player data management for Roblox. Wraps [ProfileStore](https://madstudioroblox.github.io/ProfileStore/) with reactive change tracking, automatic server-to-client replication, migrations, and structural validation.

## Installation

```bash
pesde add gh#daireb/PlayerStore#v0.1.2
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

-- Read data (typed):
local data = ServerData:getData(player)
print(data.Resources.Cash)

-- Write with replication:
local obs = ServerData:observe(player)
obs:set("Resources/Cash", 100)

-- Listen for changes:
obs:listen("Resources/Cash", function(value)
    print("Cash changed to", value)
end)
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

```lua
return schema {
    Resources = { Cash = 0, XP = 0 },
    Inventory = map {} :: { [string]: number },
    Settings = private { MusicVolume = 0.75 },
    Codes = private(map {} :: { [string]: number }),
}
```

Parentheses are only needed when composing markers: `private(map {})`.

> Note: If using stylua, add `call_parentheses = "Input"` to the top of your stylua.toml file to allow this syntax.

## Server API

### `PlayerStore.createServerStore(config)`

| Config field | Type | Description |
|---|---|---|
| `schema` | `Schema<T>` | The schema from `PlayerStore.schema()` |
| `storeId` | `string` | ProfileStore data store identifier |
| `profileStore` | `any` | The ProfileStore module (`require(...)` result) |
| `migrations` | `{ (data) -> () }?` | Optional ordered list of migration functions |

### Methods

| Method | Returns | Description |
|---|---|---|
| `loadAsync(player)` | `boolean` | Load data, run migrations, start replication |
| `unloadAsync(player)` | | End session and clean up |
| `getData(player)` | `T?` | Raw typed data table (by reference) |
| `observe(player)` | `ObservableTable<T>?` | Observable wrapper for tracked writes and listeners |
| `waitForData(player, timeout?)` | `T?` | Yield until data loaded |
| `onSave(callback)` | | Register pre-save callback |
| `onSessionEnd(callback)` | | Override session-end behavior (default: kick player) |
| `wipeData(player)` | | Reset data to template defaults |

### Write validation

All writes through `observe():set()` are automatically validated against the schema. Invalid paths and type mismatches error immediately:

```lua
obs:set("Resources/Cash", 100)       -- ok
obs:set("Resources/Cash", "wrong")   -- errors: type mismatch
obs:set("Fake/Path", 5)              -- errors: invalid path
obs:set("Inventory/Sword", 3)        -- ok (map path, any key allowed)
```

### Session end behavior

By default, players are kicked if their ProfileStore session ends for any reason (e.g. claimed by another server, or unloadAsync is called). Override with `onSessionEnd` if you need custom handling:

```lua
ServerData:onSessionEnd(function(player)
    -- custom logic instead of kick
    -- maybe check a flag to see if this is a claimed session or a manual unload?
end)
```

### `getData()` vs `observe()`

`getData()` returns the raw table -- use it for typed reads. `observe()` returns an ObservableTable wrapper -- writes through it trigger change listeners and replicate to the client.

```lua
local data = ServerData:getData(player)
if data.Resources.Cash >= 100 then
    ServerData:observe(player):set("Resources/Cash", data.Resources.Cash - 100)
end
```

## Client API

### `PlayerStore.createClientStore(config)`

| Config field | Type | Description |
|---|---|---|
| `schema` | `Schema<T>` | Same schema used on the server |
| `storeId` | `string` | Must match the server's `storeId` |

### Methods

| Method | Returns | Description |
|---|---|---|
| `get(path?)` | `T` or `any` | Full data table, or value at path |
| `listen(path?, callback)` | `() -> ()` | Listen for changes, returns disconnect function |
| `bind(path?, callback)` | `() -> ()` | Like `listen` but fires immediately with current value |
| `waitUntilLoaded()` | | Yields until initial data received |
| `isLoaded()` | `boolean` | Whether initial data has been received |

The client store is **read-only** -- data flows from server to client only.

> ⚠️ Before `waitUntilLoaded()` resolves, `get()` and `bind()` return schema defaults. Call `waitUntilLoaded()` before reading data to ensure you have real values.

## Bridging to UI Frameworks

PlayerStore is framework-agnostic. Bridge to your UI library with a small helper:

### Fusion

```lua
local function observe(path: string)
    local value = scope:Value(ClientData:get(path))
    ClientData:listen(path, function(newValue)
        value:set(newValue)
    end)
    return value
end

local cash = observe("Resources/Cash")
```

### Vide

```lua
local function observe(path: string)
    local value, setValue = Vide.source(ClientData:get(path))
    ClientData:listen(path, setValue)
    return value
end
```

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
- After migrations, data is validated against the schema. If validation fails, the player is kicked.
- Never reorder or remove migrations. Always append new ones to the end.
- Migrations should be idempotent -- check before overwriting.

## License

MIT
