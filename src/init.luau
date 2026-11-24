--[=[
	PlayerStore

	Schema-driven player data management library for Roblox.
	Wraps ProfileStore with reactive ObservableTable access,
	automatic server-to-client replication, migrations, and validation.
]=]

local Schema = require(script.Schema)
local ServerStore = require(script.ServerStore)
local ClientStore = require(script.ClientStore)

export type Outgoing = ServerStore.Outgoing
export type MessageMeta = ServerStore.MessageMeta
export type MessageResult = ServerStore.MessageResult
export type MessageHandler = ServerStore.MessageHandler

return {
	schema = Schema.schema,
	map = Schema.map,
	private = Schema.private,

	createServerStore = ServerStore.new,
	createClientStore = ClientStore.new,
}
