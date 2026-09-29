--[=[
	ServerStore

	Manages player data loading, saving, and cleanup using ProfileStore.
	Provides ObservableTable wrappers with automatic client replication
	and private path filtering.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local deepClone = require(script.Parent.DeepClone)
local DataValue = require(script.Parent.DataValue)
local ObservableTable = require(script.Parent.ObservableTable)
local Validation = require(script.Parent.Validation)

local DATA_VERSION_KEY = "_DataVersion"
-- Match ProfileStore's default timeout so its stale-session takeover can finish.
local DEFAULT_LOAD_WAIT = 120
local DEFAULT_SAVE_CONFIRM_WAIT = 15
local SNAPSHOT_COOLDOWN = 1

local function validTimeout(timeout: any): boolean
	return type(timeout) == "number" and timeout == timeout and timeout >= 0 and timeout < math.huge
end

local function reconcile(target: { [any]: any }, template: { [any]: any }, mapPaths: { [string]: true }, path: string)
	for key, value in template do
		if type(key) == "string" then
			local current = target[key]
			local childPath = if path == "" then key else `{path}/{key}`
			if current == nil then
				target[key] = deepClone(value)
			elseif type(current) == "table" and type(value) == "table" and not mapPaths[childPath] then
				reconcile(current, value, mapPaths, childPath)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type Schema<T> = {
	template: T,
	mapPaths: { [string]: true },
	privatePaths: { [string]: true },
}

type ProfileStoreModule = {
	New: (storeId: string, template: { [string]: any }) -> any,
}

type ServerStoreConfig<T> = {
	schema: Schema<T>,
	storeId: string,
	profileStore: ProfileStoreModule,
	migrations: { (data: { [string]: any }) -> () }?,
}

--------------------------------------------------------------------------------
-- ServerStore class
--------------------------------------------------------------------------------

local ServerStore = {}
ServerStore.__index = ServerStore

local function cancelSnapshotTimer(self: any, player: Player)
	local timer = self._snapshotTimers[player]
	self._snapshotTimers[player] = nil
	if timer and timer.thread then
		pcall(task.cancel, timer.thread)
	end
end

function ServerStore.new<T>(config: ServerStoreConfig<T>)
	assert(
		config.profileStore ~= nil,
		"[PlayerStore] profileStore is required — pass in require(path.to.ProfileStore)"
	)
	assert(
		typeof(config.profileStore) == "table" and typeof(config.profileStore.New) == "function",
		"[PlayerStore] profileStore must be a ProfileStore module with a .New() method"
	)

	local schema = config.schema
	local migrations = config.migrations or {}

	-- Inject _DataVersion into template for ProfileStore
	local templateWithVersion = deepClone(schema.template :: any)
	templateWithVersion[DATA_VERSION_KEY] = -1

	local playerStore = config.profileStore.New(config.storeId, templateWithVersion)

	local remoteEvent = Instance.new("RemoteEvent")
	remoteEvent.Name = `__PlayerStore_{config.storeId}`
	remoteEvent.Parent = ReplicatedStorage

	local self = setmetatable({
		_schema = schema,
		_migrations = migrations,
		_playerStore = playerStore,
		_remoteEvent = remoteEvent,
		_profiles = {} :: { [number]: any },
		_owners = {} :: { [number]: Player },
		_observables = {} :: { [Player]: any },
		_loadAttempts = {} :: { [Player]: any },
		_loading = {} :: { [number]: any },
		_releasing = {} :: { [number]: any },
		_releaseConnections = {} :: { [any]: any },
		_profileConnections = {} :: { [any]: { any } },
		_manualEnd = {} :: { [any]: boolean },
		_snapshotPending = {} :: { [Player]: boolean },
		_snapshotReady = {} :: { [Player]: boolean },
		_snapshotTimers = {} :: { [Player]: any },
		_lastSnapshotSent = {} :: { [Player]: number },
		-- Late load/removal callbacks must not retain departed Player instances.
		_loadFailed = setmetatable({} :: { [Player]: boolean }, { __mode = "k" }),
		_saveCallbacks = {} :: { [number]: (player: Player, data: any) -> () },
		_nextSaveCallbackId = 0,
		_releaseCallbacks = {} :: { [number]: (player: Player, data: any) -> () },
		_nextReleaseCallbackId = 0,
		-- Sessions running before-release hooks stay writable after their Player leaves.
		_settling = {} :: { [Player]: any },
		_destroyed = false,
		_onSessionEnd = function(plr: Player)
			plr:Kick("Data session ended - Please rejoin")
		end,
	}, ServerStore)
	self._remoteConnection = remoteEvent.OnServerEvent:Connect(function(player: Player, request: any)
		if self._destroyed or player.Parent ~= Players or request ~= "snapshot" then
			return
		end
		if self._snapshotPending[player] then
			return
		end
		self._snapshotPending[player] = true
		if self._snapshotReady[player] then
			local profile = self:_activeProfile(player)
			if not profile then
				return
			end
			local remaining = SNAPSHOT_COOLDOWN - (os.clock() - (self._lastSnapshotSent[player] or 0))
			if remaining > 0 then
				local token = {}
				self._snapshotTimers[player] = token
				token.thread = task.delay(remaining, function()
					if self._snapshotTimers[player] ~= token or self:_activeProfile(player) ~= profile then
						return
					end
					self._snapshotTimers[player] = nil
					self:_sendSnapshotIfReady(player)
				end)
				return
			end
		end
		self:_sendSnapshotIfReady(player)
	end)
	self._removingConnection = Players.PlayerRemoving:Connect(function(player: Player)
		local token = self._loadAttempts[player]
		if token then
			token.cancelled = true
		end
		self._snapshotPending[player] = nil
		self._snapshotReady[player] = nil
		cancelSnapshotTimer(self, player)
		self._lastSnapshotSent[player] = nil
		self._loadFailed[player] = nil
	end)

	return self
end

--------------------------------------------------------------------------------
-- Migration system
--------------------------------------------------------------------------------

function ServerStore._runMigrations(self: any, player: Player, profile: any, canCommit: (() -> boolean)?): boolean
	local original = profile.Data
	if typeof(original) ~= "table" then
		warn(`[PlayerStore] Invalid profile data for {player.DisplayName}`)
		player:Kick("Invalid data - Please contact support")
		return false
	end
	local currentVersion = original[DATA_VERSION_KEY]
	if currentVersion == nil then
		currentVersion = 0 -- Legacy profiles predating the version key.
	end
	local latestVersion = #self._migrations
	if
		type(currentVersion) ~= "number"
		or currentVersion ~= math.floor(currentVersion)
		or currentVersion < -1
		or currentVersion > latestVersion
	then
		warn(`[PlayerStore] Unsupported data version {tostring(currentVersion)} for {player.DisplayName}`)
		player:Kick("Unsupported data version - Please contact support")
		return false
	end

	-- Never run migrations on live Data. An autosave can happen while a
	-- migration yields, and EndSession also saves after a failed load.
	local data = deepClone(original)
	if currentVersion ~= -1 then
		for i = currentVersion + 1, latestVersion do
			local success, err = pcall(function()
				self._migrations[i](data)
				if table.isfrozen(data) then
					data = table.clone(data)
				end
				data[DATA_VERSION_KEY] = i
			end)
			if not success then
				warn(`[PlayerStore] Migration {i} failed for {player.DisplayName}: {err}`)
				player:Kick(`Data migration failed at version {i}. Please rejoin or contact support.`)
				return false
			end
		end
	end
	if currentVersion ~= -1 and currentVersion < latestVersion then
		-- Migrations may introduce aliases or frozen branches. Reject cycles before
		-- copying their output into independently owned, mutable trees.
		local valid, errorPath = DataValue.validate(data)
		if not valid then
			warn(`[PlayerStore] Validation failed for {player.DisplayName}: {errorPath}`)
			player:Kick(`Data validation failed: {errorPath}. Please contact support.`)
			return false
		end
		data = deepClone(data)
	end
	local reconciled, reconcileError = pcall(reconcile, data, self._schema.template :: any, self._schema.mapPaths, "")
	if not reconciled then
		warn(`[PlayerStore] Reconcile failed for {player.DisplayName}: {reconcileError}`)
		player:Kick("Data migration failed - Please contact support")
		return false
	end
	data[DATA_VERSION_KEY] = latestVersion

	local valid, errorPath = Validation.validateData(data, self._schema.template :: any, self._schema.mapPaths)
	if not valid then
		warn(`[PlayerStore] Validation failed for {player.DisplayName}: {errorPath}`)
		player:Kick(`Data validation failed: {errorPath}. Please contact support.`)
		return false
	end

	if canCommit and not canCommit() then
		return false
	end
	profile.Data = data
	return true
end

--------------------------------------------------------------------------------
-- Replication
--------------------------------------------------------------------------------

function ServerStore._isPublicPath(self: any, path: string): boolean
	local root = string.split(path, "/")[1]
	return root ~= DATA_VERSION_KEY
		and (self._schema.template :: any)[root] ~= nil
		and not self._schema.privatePaths[root]
end

function ServerStore._activeProfile(self: any, player: Player): any?
	if self._destroyed then
		return nil
	end
	local profile = self._profiles[player.UserId]
	if profile == nil or self._owners[player.UserId] ~= player or not profile:IsActive() then
		return nil
	end
	if player.Parent ~= Players and self._settling[player] ~= profile then
		return nil
	end
	return profile
end

function ServerStore._sendSnapshotIfReady(self: any, player: Player)
	if not self._snapshotPending[player] then
		return
	end
	local profile = self:_activeProfile(player)
	if profile == nil then
		return
	end
	local filtered = {}
	for key in self._schema.template do
		if self:_isPublicPath(key) then
			filtered[key] = profile.Data[key]
		end
	end
	self._snapshotPending[player] = nil
	self._snapshotReady[player] = true
	self._lastSnapshotSent[player] = os.clock()
	self._remoteEvent:FireClient(player, "", filtered)
end

function ServerStore._sendDelta(self: any, player: Player, profile: any, path: string, value: any, updates: any?)
	if
		self._destroyed
		or self._profiles[player.UserId] ~= profile
		or not profile:IsActive()
		or not self._snapshotReady[player]
	then
		return
	end
	if updates ~= nil then
		local publicUpdates = {}
		for _, update in updates do
			if self:_isPublicPath(update.path) then
				table.insert(publicUpdates, { path = update.path, value = update.value })
			end
		end
		if #publicUpdates > 0 then
			self._remoteEvent:FireClient(player, publicUpdates)
		end
	elseif self:_isPublicPath(path) then
		self._remoteEvent:FireClient(player, path, value)
	end
end

function ServerStore._clearOwnedProfile(self: any, player: Player, profile: any)
	if self._profiles[player.UserId] ~= profile or self._owners[player.UserId] ~= player then
		return
	end
	self._profiles[player.UserId] = nil
	self._owners[player.UserId] = nil
	local observable = self._observables[player]
	if observable then
		observable:Destroy()
		self._observables[player] = nil
	end
	self._snapshotPending[player] = nil
	self._snapshotReady[player] = nil
	cancelSnapshotTimer(self, player)
	self._lastSnapshotSent[player] = nil
end

function ServerStore._runSaveCallbacks(self: any, player: Player, profile: any)
	if self._destroyed then
		return
	end
	for _, callback in self._saveCallbacks do
		local ok, err = pcall(callback, player, profile.Data)
		if not ok then
			warn(`[PlayerStore] Save callback error for {player.DisplayName}: {err}`)
		end
	end
end

function ServerStore._runReleaseCallbacks(self: any, player: Player, profile: any)
	if
		self._destroyed
		or self._profiles[player.UserId] ~= profile
		or self._owners[player.UserId] ~= player
		or not profile:IsActive()
	then
		return
	end
	self._settling[player] = profile
	for _, callback in self._releaseCallbacks do
		local ok, err = pcall(callback, player, profile.Data)
		if not ok then
			warn(`[PlayerStore] Release callback error for {player.DisplayName}: {err}`)
		end
	end
	self._settling[player] = nil
end

function ServerStore._releaseUnpublished(self: any, userId: number, profile: any)
	if not profile:IsActive() then
		return
	end
	self._releasing[userId] = profile
	local connection: any
	connection = profile.OnSessionEnd:Connect(function()
		if self._releasing[userId] == profile then
			self._releasing[userId] = nil
		end
		self._releaseConnections[profile] = nil
		connection:Disconnect()
	end)
	self._releaseConnections[profile] = connection
	profile:EndSession()
end

--------------------------------------------------------------------------------
-- Public methods
--------------------------------------------------------------------------------

function ServerStore.loadAsync(self: any, player: Player): boolean
	if self._destroyed or player.Parent ~= Players then
		return false
	end
	local userId = player.UserId
	if self:_activeProfile(player) ~= nil then
		return true
	end
	local deadline = os.clock() + DEFAULT_LOAD_WAIT
	local pending = self._loadAttempts[player]
	if pending then
		-- Share this call's outcome even if it is still queued behind an old Player.
		while pending.result == nil do
			if pending.cancelled or self._destroyed or player.Parent ~= Players or os.clock() >= deadline then
				return false
			end
			task.wait(0.05)
		end
		return pending.result == true and self:_activeProfile(player) ~= nil
	end
	local token = { cancelled = false, player = player }
	self._loadAttempts[player] = token
	local function cancelled(): boolean
		return token.cancelled or self._destroyed or player.Parent ~= Players or os.clock() >= deadline
	end
	local function complete(result: boolean): boolean
		token.result = result
		if self._loadAttempts[player] == token then
			self._loadAttempts[player] = nil
		end
		if self._loading[userId] == token then
			self._loading[userId] = nil
		end
		return result
	end
	-- ProfileStore rejects a second StartSessionAsync for a key already
	-- loading or owned in this process.
	while self._loading[userId] ~= nil or self._profiles[userId] ~= nil or self._releasing[userId] ~= nil do
		if cancelled() then
			return complete(false)
		end
		if self:_activeProfile(player) ~= nil then
			return complete(true)
		end
		local releasing = self._releasing[userId]
		if releasing and not releasing:IsActive() then
			self._releasing[userId] = nil
			continue
		end
		task.wait(0.05)
	end
	if cancelled() then
		return complete(false)
	end
	self._loading[userId] = token
	self._loadFailed[player] = nil
	local success, profile = pcall(function()
		return self._playerStore:StartSessionAsync(`{userId}`, {
			Cancel = cancelled,
		})
	end)
	if not success or profile == nil then
		self._loadFailed[player] = true
		if not success then
			warn(`[PlayerStore] Load failed for {player.DisplayName}: {profile}`)
		end
		if player.Parent == Players and not token.cancelled and not self._destroyed then
			player:Kick("Failed to load data - Please rejoin")
		end
		return complete(false)
	end
	if cancelled() then
		self:_releaseUnpublished(userId, profile)
		return complete(false)
	end
	profile:AddUserId(userId)
	if
		not self:_runMigrations(player, profile, function()
			return self._loading[userId] == token and not cancelled() and profile:IsActive()
		end)
	then
		self._loadFailed[player] = true
		self:_releaseUnpublished(userId, profile)
		return complete(false)
	end
	if cancelled() or not profile:IsActive() then
		self:_releaseUnpublished(userId, profile)
		return complete(false)
	end

	local observable = ObservableTable.wrap(profile.Data, function(path, value)
		if self:_activeProfile(player) ~= profile then
			return false, "Data not loaded"
		end
		return Validation.validateWrite(self._schema, path, value)
	end, function(path, value, updates)
		self:_sendDelta(player, profile, path, value, updates)
	end)
	self._profiles[userId] = profile
	self._owners[userId] = player
	self._observables[player] = observable
	local sessionConnection = profile.OnSessionEnd:Connect(function()
		local wasCurrent = self._profiles[userId] == profile and self._owners[userId] == player
		local intentional = self._manualEnd[profile] == true
		if self._releasing[userId] == profile then
			self._releasing[userId] = nil
		end
		self:_clearOwnedProfile(player, profile)
		local connections = self._profileConnections[profile]
		if connections then
			for _, connection in connections do
				connection:Disconnect()
			end
			self._profileConnections[profile] = nil
		end
		self._manualEnd[profile] = nil
		if wasCurrent and not intentional and not self._destroyed and player.Parent == Players then
			self._onSessionEnd(player)
		end
	end)
	local saveConnection = profile.OnSave:Connect(function()
		self:_runSaveCallbacks(player, profile)
	end)
	self._profileConnections[profile] = { sessionConnection, saveConnection }
	complete(true)
	self:_sendSnapshotIfReady(player)
	return true
end

function ServerStore.unloadAsync(self: any, player: Player)
	local loading = self._loadAttempts[player]
	if loading then
		loading.cancelled = true
	end
	self._loadFailed[player] = true
	self._snapshotPending[player] = nil
	self._snapshotReady[player] = nil
	cancelSnapshotTimer(self, player)
	self._lastSnapshotSent[player] = nil
	local profile = self._profiles[player.UserId]
	if profile and self._owners[player.UserId] == player then
		self:_runReleaseCallbacks(player, profile)
	end
	-- Re-check: a hook may have yielded while the session was lost or replaced.
	if profile and self._profiles[player.UserId] == profile and self._owners[player.UserId] == player then
		self._manualEnd[profile] = true
		self._releasing[player.UserId] = profile
		self:_clearOwnedProfile(player, profile)
		profile:EndSession()
	end
end

function ServerStore.getData<T>(self: any, player: Player): T?
	local profile = self:_activeProfile(player)
	return if profile then profile.Data else nil
end

function ServerStore.observe<T>(self: any, player: Player): ObservableTable.ObservableTable<T>?
	if self:_activeProfile(player) == nil then
		return nil
	end
	return self._observables[player]
end

function ServerStore.trySet(self: any, player: Player, path: string, value: any): (boolean, string?)
	local obs = self:observe(player)
	if obs == nil then
		return false, "Data not loaded"
	end

	local ok, err = pcall(obs.set, obs, path, value)
	if not ok then
		return false, tostring(err)
	end

	return true, nil
end

function ServerStore.trySetMany(self: any, player: Player, updates: { ObservableTable.Update }): (boolean, string?)
	if #updates == 0 then
		return true, nil
	end

	local obs = self:observe(player)
	if obs == nil then
		return false, "Data not loaded"
	end

	local ok, err = pcall(obs.setMany, obs, updates)
	if not ok then
		return false, tostring(err)
	end

	return true, nil
end

function ServerStore.waitForData<T>(self: any, player: Player, timeout: number?): T?
	if timeout ~= nil and not validTimeout(timeout) then
		return nil
	end
	local deadline = os.clock() + (timeout or DEFAULT_LOAD_WAIT)
	while not self._destroyed and player.Parent == Players and not self._loadFailed[player] do
		local data = self:getData(player)
		if data then
			return data
		end
		if os.clock() >= deadline then
			break
		end
		task.wait(0.05)
	end
	return nil
end

function ServerStore.onSave(self: any, callback: (player: Player, data: any) -> ()): () -> ()
	self._nextSaveCallbackId += 1
	local id = self._nextSaveCallbackId
	self._saveCallbacks[id] = callback
	return function()
		self._saveCallbacks[id] = nil
	end
end

--- Runs synchronously when unloadAsync or Destroy is about to release a loaded session,
--- while tracked writes to that player still succeed (even after the Player has left).
--- Settle game-owned buffers here so the final save includes them. Hooks must not yield.
--- ProfileStore-initiated releases (server shutdown, session steal) bypass this; use onSave.
function ServerStore.onBeforeRelease(self: any, callback: (player: Player, data: any) -> ()): () -> ()
	self._nextReleaseCallbackId += 1
	local id = self._nextReleaseCallbackId
	self._releaseCallbacks[id] = callback
	return function()
		self._releaseCallbacks[id] = nil
	end
end

function ServerStore.onSessionEnd(self: any, callback: (player: Player) -> ())
	self._onSessionEnd = callback
end

function ServerStore.confirmSavedAsync(
	self: any,
	player: Player,
	predicate: (data: any) -> boolean,
	timeout: number?
): (boolean, string?)
	local profile = self:_activeProfile(player)
	if not profile then
		return false, "Data not loaded"
	end
	if timeout ~= nil and not validTimeout(timeout) then
		return false, "Invalid timeout"
	end
	local predicateError: string? = nil
	local function isConfirmed(): boolean
		local saved = profile.LastSavedData
		if typeof(saved) ~= "table" then
			return false
		end
		local ok, result = pcall(predicate, saved)
		if not ok then
			predicateError = tostring(result)
			return false
		end
		return ok and result == true
	end
	if isConfirmed() then
		return true, nil
	end
	if predicateError then
		return false, predicateError
	end
	local confirmed = false
	local connection = profile.OnAfterSave:Connect(function()
		confirmed = isConfirmed()
	end)
	if self:_activeProfile(player) ~= profile then
		connection:Disconnect()
		return false, "Session ended"
	end
	local ok, err = pcall(profile.Save, profile)
	if not ok then
		connection:Disconnect()
		return false, tostring(err)
	end
	local deadline = os.clock() + (timeout or DEFAULT_SAVE_CONFIRM_WAIT)
	while not confirmed and not isConfirmed() do
		if predicateError then
			connection:Disconnect()
			return false, predicateError
		end
		if self:_activeProfile(player) ~= profile then
			connection:Disconnect()
			return false, "Session ended"
		end
		if os.clock() >= deadline then
			connection:Disconnect()
			return false, "Save confirmation timed out"
		end
		task.wait(0.05)
	end
	connection:Disconnect()
	return true, nil
end

function ServerStore.wipeData(self: any, player: Player)
	local profile = self:_activeProfile(player)
	if profile == nil then
		error("[PlayerStore] No profile found for player")
	end

	local template = self._schema.template :: any
	for key, value in template do
		profile.Data[key] = deepClone(value)
	end

	player:Kick("Your data has been wiped. Please rejoin.")
end

function ServerStore.Destroy(self: any)
	if self._destroyed then
		return
	end
	local settling = {}
	for userId, profile in self._profiles do
		local player = self._owners[userId]
		if player then
			table.insert(settling, { player = player, profile = profile })
		end
	end
	for _, entry in settling do
		self:_runReleaseCallbacks(entry.player, entry.profile)
	end
	self._destroyed = true
	-- Destroy ends wrapper callbacks immediately. ProfileStore still performs the
	-- final save of already committed data when each session is released.
	for _, token in self._loadAttempts do
		token.cancelled = true
	end
	local owned = {}
	for userId, profile in self._profiles do
		table.insert(owned, { userId = userId, profile = profile, player = self._owners[userId] })
	end
	for _, entry in owned do
		local userId = entry.userId
		local profile = entry.profile
		local player = entry.player
		self._manualEnd[profile] = true
		self._releasing[userId] = profile
		if player then
			self:_clearOwnedProfile(player, profile)
		else
			self._profiles[userId] = nil
		end
		local connections = self._profileConnections[profile]
		if connections then
			for _, connection in connections do
				connection:Disconnect()
			end
			self._profileConnections[profile] = nil
		end
		profile:EndSession()
	end
	for profile, connections in self._profileConnections do
		for _, connection in connections do
			connection:Disconnect()
		end
		self._profileConnections[profile] = nil
	end
	for profile, connection in self._releaseConnections do
		connection:Disconnect()
		self._releaseConnections[profile] = nil
	end
	table.clear(self._manualEnd)
	table.clear(self._releasing)
	table.clear(self._loadAttempts)
	table.clear(self._loading)
	table.clear(self._loadFailed)
	self._remoteConnection:Disconnect()
	self._removingConnection:Disconnect()
	self._remoteEvent:Destroy()
	table.clear(self._snapshotPending)
	table.clear(self._snapshotReady)
	for player in self._snapshotTimers do
		cancelSnapshotTimer(self, player)
	end
	table.clear(self._lastSnapshotSent)
	table.clear(self._saveCallbacks)
	table.clear(self._releaseCallbacks)
	table.clear(self._settling)
end

return ServerStore
