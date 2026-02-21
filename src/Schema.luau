--[=[
	Schema definition and processing.

	Provides `schema()`, `map()`, and `private()` for consumers to define
	their data schema. Markers use type-erased generics so the consumer's
	types flow through cleanly.
]=]

local MARKER_KEY = "__playerstore"

--------------------------------------------------------------------------------
-- Marker detection
--------------------------------------------------------------------------------

local function isMarker(value: any): boolean
	return typeof(value) == "table" and value[MARKER_KEY] == true
end

--------------------------------------------------------------------------------
-- Schema processing (internal)
--------------------------------------------------------------------------------

--[=[
	Recursively walks a schema definition and extracts:
	  - template: plain table with markers resolved to defaults
	  - mapPaths: set of paths that have dynamic keys (skip deep validation)
	  - privatePaths: set of paths excluded from client replication
]=]
local function processSchema(
	definition: { [string]: any },
	template: { [string]: any },
	mapPaths: { [string]: true },
	privatePaths: { [string]: true },
	prefix: string
)
	for key, value in definition do
		local path = if prefix == "" then key else `{prefix}/{key}`

		if isMarker(value) then
			template[key] = value.default

			if value.kind == "map" then
				mapPaths[path] = true
			end
			if value.replicate == false then
				privatePaths[path] = true
			end
		elseif typeof(value) == "table" then
			template[key] = {}
			processSchema(value, template[key], mapPaths, privatePaths, path)
		else
			template[key] = value
		end
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local Schema = {}

export type Schema<T> = {
	template: T,
	mapPaths: { [string]: true },
	privatePaths: { [string]: true },
}

--[=[
	Processes a schema definition into a frozen Schema object containing
	a data template, map paths, and private paths. Define your data
	structure once in a shared module and pass the result to both
	`createServerStore` and `createClientStore`.

	```lua
	local PlayerData = PlayerStore.schema {
		Resources = { Cash = 0, XP = 0 },
		Inventory = map {} :: { [string]: number },
		Settings = private { Volume = 0.75 },
	}
	```
]=]
function Schema.schema<T>(definition: T): Schema<T>
	local template = {}
	local mapPaths = {}
	local privatePaths = {}

	processSchema(definition :: any, template, mapPaths, privatePaths, "")

	local schema: Schema<T> = {
		template = table.freeze(template) :: any,
		mapPaths = table.freeze(mapPaths),
		privatePaths = table.freeze(privatePaths),
	}

	return table.freeze(schema)
end

--[=[
	Marks a field as a dynamic-key map. Map fields skip deep structural
	validation since their keys are user-defined at runtime and can't
	be checked against a fixed template.

	```lua
	Inventory = map {} :: { [string]: number },
	```

	Compose with `private` to keep a map server-only:
	```lua
	Codes = private(map {} :: { [string]: number }),
	```
]=]
function Schema.map<V>(default: V): V
	return {
		[MARKER_KEY] = true,
		kind = "map",
		default = if typeof(default) == "table" then default else default,
		replicate = true,
	} :: never
end

--[=[
	Marks a field as server-only. Private fields are never replicated
	to the client and will not appear in the client store.

	```lua
	Settings = private {
		MusicVolume = 0.75,
		ShowTutorial = true,
	},
	```

	Can wrap other markers:
	```lua
	Codes = private(map {} :: { [string]: number }),
	```
]=]
function Schema.private<V>(default: V): V
	if isMarker(default) then
		local marker = table.clone(default :: any)
		marker.replicate = false
		return marker :: never
	end

	return {
		[MARKER_KEY] = true,
		kind = "value",
		default = default,
		replicate = false,
	} :: never
end

return Schema
