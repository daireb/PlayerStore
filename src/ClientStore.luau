--[=[
	ClientStore

	Read-only ObservableTable that receives data from the server via
	a RemoteEvent. Provides get/listen/bind but no set -- only the
	internal replication handler mutates the underlying data.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ObservableTable = require(script.Parent.ObservableTable)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type Callback = (value: any, path: string, specificValue: any, specificPath: string) -> ()

type Schema<T> = {
	template: T,
	mapPaths: { [string]: true },
	privatePaths: { [string]: true },
}

type ClientStoreConfig<T> = {
	schema: Schema<T>,
	storeId: string,
}

export type ClientStore<T> = {
	get: ((self: ClientStore<T>) -> T) & ((self: ClientStore<T>, path: string) -> any),
	listen: ((self: ClientStore<T>, callback: Callback) -> () -> ())
		& ((self: ClientStore<T>, path: string, callback: Callback) -> () -> ()),
	bind: ((self: ClientStore<T>, callback: Callback) -> () -> ())
		& ((self: ClientStore<T>, path: string, callback: Callback) -> () -> ()),
	waitUntilLoaded: (self: ClientStore<T>) -> (),
	isLoaded: (self: ClientStore<T>) -> boolean,
}

--------------------------------------------------------------------------------
-- Implementation
--------------------------------------------------------------------------------

local ClientStore = {}
ClientStore.__index = ClientStore

function ClientStore.new<T>(config: ClientStoreConfig<T>)
	local schema = config.schema

	-- Build client template (exclude private paths)
	local clientTemplate = {}
	for key, value in schema.template :: any do
		if not schema.privatePaths[key] then
			clientTemplate[key] = if typeof(value) == "table" then table.clone(value) else value
		end
	end

	local observable = ObservableTable.wrap(clientTemplate)

	local loadedEvent = Instance.new("BindableEvent")

	local self = setmetatable({
		_observable = observable,
		_loaded = false,
		_loadedEvent = loadedEvent,
	}, ClientStore)

	-- Connect to server replication
	local remoteEvent = ReplicatedStorage:WaitForChild(`__PlayerStore_{config.storeId}`)
	remoteEvent.OnClientEvent:Connect(function(path: string, data: any)
		observable:applyUpdate(path, data)

		if not self._loaded and path == "" then
			self._loaded = true
			loadedEvent:Fire()
		end
	end)

	return self
end

function ClientStore.get<T>(self: any, path: string?): any
	return self._observable:get(path)
end

function ClientStore.listen<T>(self: any, pathOrCallback: string | Callback, maybeCallback: Callback?): () -> ()
	return self._observable:listen(pathOrCallback :: any, maybeCallback :: any)
end

function ClientStore.bind<T>(self: any, pathOrCallback: string | Callback, maybeCallback: Callback?): () -> ()
	return self._observable:bind(pathOrCallback :: any, maybeCallback :: any)
end

function ClientStore.waitUntilLoaded(self: any)
	if self._loaded then
		return
	end
	self._loadedEvent.Event:Wait()
end

function ClientStore.isLoaded(self: any): boolean
	return self._loaded
end

return ClientStore
