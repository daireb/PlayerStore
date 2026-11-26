--[=[
	PlayerStore

	Schema-driven player data management library for Roblox.
	Wraps ProfileStore with reactive ObservableTable access,
	automatic server-to-client replication, migrations, and validation.
]=]

local Schema = require(script.Schema)
local ServerStore = require(script.ServerStore)
local ClientStore = require(script.ClientStore)
local Validation = require(script.Validation)

export type Outgoing = ServerStore.Outgoing
export type MessageMeta = ServerStore.MessageMeta
export type MessageResult = ServerStore.MessageResult
export type MessageHandler = ServerStore.MessageHandler

return {
	schema = Schema.schema,
	map = Schema.map,
	private = Schema.private,
	validateWrite = Validation.validateWrite,

	createServerStore = ServerStore.new,
	createClientStore = ClientStore.new,

	OPERATOR_SENDER = ServerStore.OPERATOR_SENDER,
}
