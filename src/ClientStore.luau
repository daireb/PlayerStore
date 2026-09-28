--[=[
	ClientStore

	Read-only ObservableTable that receives data from the server via
	a RemoteEvent. Provides get/listen/bind but no set -- only the
	internal replication handler mutates the underlying data.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local deepClone = require(script.Parent.DeepClone)
local ObservableTable = require(script.Parent.ObservableTable)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type Update = ObservableTable.Update
type Callback = (value: any, path: string, specificValue: any, specificPath: string, updates: { Update }?) -> ()

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
	waitUntilLoaded: (self: ClientStore<T>, timeout: number?) -> boolean,
	isLoaded: (self: ClientStore<T>) -> boolean,
	Destroy: (self: ClientStore<T>) -> (),
}

--------------------------------------------------------------------------------
-- Implementation
--------------------------------------------------------------------------------

local ClientStore = {}
ClientStore.__index = ClientStore

local DEFAULT_WAIT_SECONDS = 30

local function assertAlive(self: any)
	assert(not self._destroyed, "[PlayerStore] ClientStore has been destroyed")
end

function ClientStore.new<T>(config: ClientStoreConfig<T>)
	local schema = config.schema

	-- Build client template (exclude private paths)
	local clientTemplate = {}
	for key, value in schema.template :: any do
		if not schema.privatePaths[key] then
			clientTemplate[key] = deepClone(value)
		end
	end

	local observable = ObservableTable.wrap(clientTemplate)

	local self = setmetatable({
		_observable = observable,
		_loaded = false,
		_destroyed = false,
		_remoteConnection = nil :: RBXScriptConnection?,
	}, ClientStore)

	local remoteName = `__PlayerStore_{config.storeId}`
	local remoteEvent = ReplicatedStorage:WaitForChild(remoteName, DEFAULT_WAIT_SECONDS)
	assert(
		remoteEvent ~= nil and remoteEvent:IsA("RemoteEvent"),
		`[PlayerStore] RemoteEvent {remoteName} was not found`
	)

	-- Subscribe before requesting the snapshot, including when the server loaded first.
	self._remoteConnection = remoteEvent.OnClientEvent:Connect(function(pathOrUpdates: string | { Update }, data: any)
		if self._destroyed then
			return
		end

		if typeof(pathOrUpdates) == "table" then
			if self._loaded then
				observable:applyUpdates(pathOrUpdates)
			end
			return
		end

		local path = pathOrUpdates :: string
		if path ~= "" and not self._loaded then
			return
		end

		observable:applyUpdate(path, data)

		if not self._loaded and path == "" then
			self._loaded = true
		end
	end)
	remoteEvent:FireServer("snapshot")

	return self
end

function ClientStore.get<T>(self: any, path: string?): any
	assertAlive(self)
	return self._observable:get(path)
end

function ClientStore.listen<T>(self: any, pathOrCallback: string | Callback, maybeCallback: Callback?): () -> ()
	assertAlive(self)
	return self._observable:listen(pathOrCallback :: any, maybeCallback :: any)
end

function ClientStore.bind<T>(self: any, pathOrCallback: string | Callback, maybeCallback: Callback?): () -> ()
	assertAlive(self)
	return self._observable:bind(pathOrCallback :: any, maybeCallback :: any)
end

function ClientStore.waitUntilLoaded(self: any, timeout: number?): boolean
	if self._destroyed then
		return false
	end
	if self._loaded then
		return true
	end

	local waitSeconds = if timeout == nil then DEFAULT_WAIT_SECONDS else timeout
	assert(
		typeof(waitSeconds) == "number" and waitSeconds == waitSeconds and math.abs(waitSeconds) < math.huge,
		"[PlayerStore] waitUntilLoaded timeout must be a finite number"
	)
	if waitSeconds <= 0 then
		return false
	end

	local deadline = os.clock() + waitSeconds
	while not self._loaded and not self._destroyed do
		local remaining = deadline - os.clock()
		if remaining <= 0 then
			break
		end
		task.wait(math.min(0.05, remaining))
	end
	return self._loaded and not self._destroyed
end

function ClientStore.isLoaded(self: any): boolean
	return self._loaded and not self._destroyed
end

function ClientStore.Destroy(self: any)
	if self._destroyed then
		return
	end

	self._destroyed = true
	if self._remoteConnection then
		self._remoteConnection:Disconnect()
		self._remoteConnection = nil
	end
	self._observable:Destroy()
end

return ClientStore
