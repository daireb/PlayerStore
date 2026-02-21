--[=[
	ServerStore

	Manages player data loading, saving, and cleanup using ProfileStore.
	Provides ObservableTable wrappers with automatic client replication
	and private path filtering.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ObservableTable = require(script.Parent.ObservableTable)

local DATA_VERSION_KEY = "_DataVersion"

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type Schema<T> = {
	template: T,
	mapPaths: { [string]: true },
	privatePaths: { [string]: true },
}

type ServerStoreConfig<T> = {
	schema: Schema<T>,
	storeId: string,
	profileStore: any,
	migrations: { (data: { [string]: any }) -> () }?,
}

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

--[=[
	Recursively validates that all keys in template exist in data with
	matching types. Allows extra keys in data. Skips deep validation
	for paths in mapPaths.
]=]
local function validateDataStructure(
	data: { [string]: any },
	template: { [string]: any },
	mapPaths: { [string]: true },
	path: string?
): (boolean, string?)
	path = path or ""

	for key, templateValue in template do
		if key == DATA_VERSION_KEY then
			continue
		end

		local dataValue = data[key]
		local currentPath = if path == "" then key else `{path}/{key}`

		if dataValue == nil then
			return false, `Missing key: {currentPath}`
		end

		local templateType = typeof(templateValue)
		local dataType = typeof(dataValue)

		if templateType ~= dataType then
			return false, `Type mismatch at {currentPath}: expected {templateType}, got {dataType}`
		end

		if templateType == "table" then
			if mapPaths[currentPath] then
				continue
			end

			local success, errorPath = validateDataStructure(dataValue, templateValue, mapPaths, currentPath)
			if not success then
				return false, errorPath
			end
		end
	end

	return true, nil
end

--------------------------------------------------------------------------------
-- ServerStore class
--------------------------------------------------------------------------------

local ServerStore = {}
ServerStore.__index = ServerStore

function ServerStore.new<T>(config: ServerStoreConfig<T>)
	local schema = config.schema
	local migrations = config.migrations or {}

	-- Inject _DataVersion into template for ProfileStore
	local templateWithVersion = table.clone(schema.template :: any)
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
		_observables = {} :: { [Player]: any },
		_saveCallbacks = {} :: { (player: Player, data: any) -> () },
		_onSessionEnd = function(plr: Player)
			plr:Kick("Data session ended - Please rejoin")
		end,
	}, ServerStore)

	return self
end

--------------------------------------------------------------------------------
-- Migration system
--------------------------------------------------------------------------------

function ServerStore._runMigrations(self: any, player: Player, profile: any): boolean
	local data = profile.Data
	local latestVersion = #self._migrations

	-- New player: reconcile from template, set to latest version
	if data[DATA_VERSION_KEY] == -1 then
		profile:Reconcile()
		data[DATA_VERSION_KEY] = latestVersion
		return true
	end

	local currentVersion: number = data[DATA_VERSION_KEY] or 0

	if currentVersion >= latestVersion then
		return true
	end

	for i = currentVersion + 1, latestVersion do
		local success, err = pcall(self._migrations[i], data)
		if not success then
			warn(`[PlayerStore] Migration {i} failed for {player.DisplayName}: {err}`)
			player:Kick(`Data migration failed at version {i}. Please rejoin or contact support.`)
			return false
		end

		data[DATA_VERSION_KEY] = i
	end

	-- Validate final structure
	local valid, errorPath = validateDataStructure(data, self._schema.template :: any, self._schema.mapPaths)
	if not valid then
		warn(`[PlayerStore] Validation failed for {player.DisplayName}: {errorPath}`)
		player:Kick(`Data validation failed: {errorPath}. Please contact support.`)
		return false
	end

	return true
end

--------------------------------------------------------------------------------
-- Replication
--------------------------------------------------------------------------------

function ServerStore._isPrivatePath(self: any, path: string): boolean
	if self._schema.privatePaths[path] then
		return true
	end

	-- Check if any ancestor of this path is private
	local keys = string.split(path, "/")
	for i = 1, #keys - 1 do
		local ancestor = table.concat(keys, "/", 1, i)
		if self._schema.privatePaths[ancestor] then
			return true
		end
	end

	return false
end

--------------------------------------------------------------------------------
-- Public methods
--------------------------------------------------------------------------------

function ServerStore.loadAsync(self: any, player: Player): boolean
	local profile = self._playerStore:StartSessionAsync(`{player.UserId}`, {
		Cancel = function()
			return player.Parent ~= Players
		end,
	})

	if profile == nil then
		warn(`[PlayerStore] Failed to load data for {player.DisplayName}`)
		player:Kick("Failed to load data - Please rejoin")
		return false
	end

	profile:AddUserId(player.UserId)

	local migrationSuccess = self:_runMigrations(player, profile)
	if not migrationSuccess then
		profile:EndSession()
		return false
	end

	-- Handle session end (another server claimed the session, or we called unloadAsync)
	profile.OnSessionEnd:Connect(function()
		self._profiles[player.UserId] = nil

		if self._observables[player] ~= nil then
			self._observables[player]:Destroy()
			self._observables[player] = nil
		end

		self._onSessionEnd(player)
	end)

	-- Verify player still in game
	if player.Parent ~= Players then
		profile:EndSession()
		return false
	end

	self._profiles[player.UserId] = profile

	-- Create observable wrapper and bind replication
	local observable = ObservableTable.wrap(profile.Data)
	self._observables[player] = observable

	observable:bind(function(_value, _path, specificValue, specificPath)
		if specificPath == "" then
			-- Root bind (initial): send all non-private top-level keys
			local filteredData = {}
			for key, val in profile.Data do
				if key == DATA_VERSION_KEY then
					continue
				end
				if not self:_isPrivatePath(key) then
					filteredData[key] = val
				end
			end
			self._remoteEvent:FireClient(player, "", filteredData)
		else
			if not self:_isPrivatePath(specificPath) then
				self._remoteEvent:FireClient(player, specificPath, specificValue)
			end
		end
	end)

	-- Set up save hook
	profile.OnSave:Connect(function()
		for _, callback in self._saveCallbacks do
			local success, err = pcall(callback, player, profile.Data)
			if not success then
				warn(`[PlayerStore] Save callback error for {player.DisplayName}: {err}`)
			end
		end
	end)

	return true
end

function ServerStore.unloadAsync(self: any, player: Player)
	local profile = self._profiles[player.UserId]

	if profile then
		profile:EndSession()
		self._profiles[player.UserId] = nil
	end
end

function ServerStore.getData<T>(self: any, player: Player): T?
	local profile = self._profiles[player.UserId]
	if profile == nil then
		return nil
	end
	return profile.Data
end

function ServerStore.observe<T>(self: any, player: Player): ObservableTable.ObservableTable<T>?
	return self._observables[player]
end

function ServerStore.waitForData<T>(self: any, player: Player, timeout: number?): T?
	local startTime = tick()

	while not self._profiles[player.UserId] do
		task.wait()
		if timeout and tick() - startTime > timeout then
			return nil
		end
	end

	return self._profiles[player.UserId].Data
end

function ServerStore.onSave(self: any, callback: (player: Player, data: any) -> ())
	table.insert(self._saveCallbacks, callback)
end

function ServerStore.onSessionEnd(self: any, callback: (player: Player) -> ())
	self._onSessionEnd = callback
end

function ServerStore.wipeData(self: any, player: Player)
	local profile = self._profiles[player.UserId]
	if profile == nil then
		error("[PlayerStore] No profile found for player")
	end

	local template = self._schema.template :: any
	for key, value in template do
		profile.Data[key] = if typeof(value) == "table" then table.clone(value) else value
	end

	player:Kick("Your data has been wiped. Please rejoin.")
end

return ServerStore
