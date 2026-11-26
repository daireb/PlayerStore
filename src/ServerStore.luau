--[=[
	ServerStore

	Manages player data loading, saving, and cleanup using ProfileStore.
	Provides ObservableTable wrappers with automatic client replication
	and private path filtering.
]=]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local deepClone = require(script.Parent.DeepClone)
local DataValue = require(script.Parent.DataValue)
local ObservableTable = require(script.Parent.ObservableTable)
local Validation = require(script.Parent.Validation)

local DATA_VERSION_KEY = "_DataVersion"
--- Reserved root stamped into Data when the final save starts; seeing it in LastSavedData proves the release landed.
local RELEASE_TOKEN_KEY = "_ReleaseToken"
-- Match ProfileStore's default timeout so its stale-session takeover can finish.
local DEFAULT_LOAD_WAIT = 120
local DEFAULT_SAVE_CONFIRM_WAIT = 15
--- Seconds a confirmation waits for a save before asking again; ProfileStore never retries a failed ordinary save. Judgement.
local SAVE_RETRY_INTERVAL = 5
--- Seconds a load waits on a release hold between reads of the key that check whether the hold can end;
--- each is one GetAsync, and most holds end with their first save. Judgement.
local RELEASE_PROBE_INTERVAL = 5
local SNAPSHOT_COOLDOWN = 1
--- Envelope version this build reads; a newer envelope waits for a newer server.
local MESSAGE_VERSION = 1
--- `from` of a message sent with `sendAsync`: no player has UserId 0, and a relayed entry carries its sender's.
local OPERATOR_SENDER = 0

local function deepFreeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value) then
		for _, child in value do
			deepFreeze(child)
		end
		table.freeze(value)
	end
	return value
end

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

type MailboxConfig = {
	inbox: string,
	outbox: string,
}

type ServerStoreConfig<T> = {
	schema: Schema<T>,
	storeId: string,
	profileStore: ProfileStoreModule,
	migrations: { (data: { [string]: any }) -> () }?,
	mailbox: MailboxConfig?,
}

export type Outgoing = {
	to: number,
	kind: string,
	id: string,
	body: any,
}

export type MessageMeta = {
	id: string,
	from: number,
}

export type MessageResult = {
	--- The effect; lands in one write with the inbox mark.
	updates: { ObservableTable.Update }?,
	--- Replies (e.g. a return); land in the same write.
	send: { Outgoing }?,
	--- Spawned after the write; not durable.
	after: (() -> ())?,
}

export type MessageHandler = (player: Player, data: any, body: any, meta: MessageMeta) -> (MessageResult?, string?)

--------------------------------------------------------------------------------
-- ServerStore class
--------------------------------------------------------------------------------

local ServerStore = {}
ServerStore.__index = ServerStore
ServerStore.OPERATOR_SENDER = OPERATOR_SENDER

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
	local mailbox: MailboxConfig? = nil
	if config.mailbox ~= nil then
		local inbox, outbox = (config.mailbox :: any).inbox, (config.mailbox :: any).outbox
		for _, name in { inbox, outbox } do
			assert(
				type(name) == "string" and schema.mapPaths[name] == true and schema.privatePaths[name] == true,
				`[PlayerStore] mailbox root "{tostring(name)}" must be a root field declared as private(map \{})`
			)
		end
		assert(inbox ~= outbox, "[PlayerStore] mailbox inbox and outbox must be different roots")
		mailbox = table.freeze { inbox = inbox, outbox = outbox }
	end

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
		-- Held from the final save's start until it lands, so a same-server rejoin can't take the lock from it.
		_releasing = {} :: { [number]: any },
		_sessions = {} :: { [any]: any },
		_releaseTokens = setmetatable({} :: { [any]: string }, { __mode = "k" }),
		_releaseProbes = {} :: { [any]: boolean },
		-- When each profile last saved or was asked to, shared by every confirmation waiting on it.
		_saveActivity = setmetatable({} :: { [any]: number }, { __mode = "k" }),
		_mailbox = mailbox,
		_messageHandlers = {} :: { [string]: MessageHandler },
		_sending = {} :: { [string]: boolean },
		_saveRequests = {} :: { [any]: boolean },
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

--------------------------------------------------------------------------------
-- Sessions: release tracking and messages
--------------------------------------------------------------------------------

--- Follows an acquired profile until its release write lands (or it is stolen), relaying its saved outbox.
function ServerStore._openSession(self: any, userId: number, profile: any): any
	local session = {
		userId = userId,
		profile = profile,
		player = nil :: Player?,
		token = nil :: string?,
		deferred = {} :: { [() -> ()]: any },
		warned = {} :: { [string]: boolean },
		sent = {} :: { [string]: boolean },
		--- Set while a message handler runs; tracked writes to this profile are refused meanwhile.
		planning = false,
		connections = {} :: { any },
	}
	self._sessions[profile] = session
	table.insert(
		session.connections,
		profile.OnLastSave:Connect(function()
			-- Runs before the final transform reads Data, and tracked writes stop once the session ends,
			-- so any save carrying this token wrote the final Data.
			local token = HttpService:GenerateGUID(false)
			session.token = token
			self._releaseTokens[profile] = token
			profile.Data[RELEASE_TOKEN_KEY] = token
			if self._releasing[userId] == nil then
				self._releasing[userId] = profile
			end
		end)
	)
	table.insert(
		session.connections,
		profile.OnSessionEnd:Connect(function()
			if session.token == nil then
				-- Ended without a final save of ours (a steal): nothing this session wrote can land now.
				self:_closeSession(session)
			end
		end)
	)
	table.insert(
		session.connections,
		profile.OnAfterSave:Connect(function(saved)
			if self._mailbox then
				self:_relay(session)
			end
			if session.token == nil then
				self:_retrySession(session)
			elseif typeof(saved) == "table" and saved[RELEASE_TOKEN_KEY] == session.token then
				self:_closeSession(session)
			end
		end)
	)
	return session
end

--- Ends a release hold if a view of the key shows the released session can never write again: a newer
--- session started, or ours cleared the lock (the fence rule). This covers a release whose final save was
--- refused, or answered with someone else's data, so its token never lands. While SessionLoadCount never
--- goes down these facts never revert, so a cached read only delays the load. A removed, reset or restored
--- key breaks that: its hold lasts until the key's count catches up, or while the key stays missing.
function ServerStore._probeRelease(self: any, userId: number)
	local profile = self._releasing[userId]
	if profile == nil or self._releaseProbes[profile] then
		return
	end
	self._releaseProbes[profile] = true
	task.spawn(function()
		local ok, view = pcall(self._playerStore.GetAsync, self._playerStore, tostring(userId))
		self._releaseProbes[profile] = nil
		if not ok or typeof(view) ~= "table" or typeof(view.SessionLoadCount) ~= "number" then
			return
		end
		local loadCount = profile.SessionLoadCount
		if (view.Session == nil and view.SessionLoadCount >= loadCount) or view.SessionLoadCount > loadCount then
			local session = self._sessions[profile]
			if session then
				self:_closeSession(session)
			elseif self._releasing[userId] == profile then
				self._releasing[userId] = nil
			end
		end
	end)
end

function ServerStore._closeSession(self: any, session: any)
	if self._sessions[session.profile] ~= session then
		return
	end
	self._sessions[session.profile] = nil
	for _, connection in session.connections do
		connection:Disconnect()
	end
	table.clear(session.deferred)
	if self._releasing[session.userId] == session.profile then
		self._releasing[session.userId] = nil
	end
end

local function validOutboxEntry(entry: any): boolean
	return typeof(entry) == "table"
		and typeof(entry.to) == "number"
		and typeof(entry.kind) == "string"
		and typeof(entry.nonce) == "string"
end

--- Sends an outbox entry once Data and LastSavedData hold the same write of it (same nonce), and sends
--- the saved copy, so a send never runs ahead of a decision that a crash could still undo. After a steal,
--- LastSavedData is the thief's, and only a copy the thief saved of this very write matches. Receivers
--- dedupe by id, so resends are harmless.
function ServerStore._relay(self: any, session: any)
	local profile = session.profile
	local name = self._mailbox.outbox
	local outbox = if typeof(profile.Data) == "table" then profile.Data[name] else nil
	local saved = profile.LastSavedData
	local savedOutbox = if typeof(saved) == "table" then saved[name] else nil
	if typeof(outbox) ~= "table" or typeof(savedOutbox) ~= "table" then
		return
	end
	for id, entry in outbox do
		local savedEntry = savedOutbox[id]
		if savedEntry == nil or self._sending[id] then
			continue
		end
		if typeof(id) ~= "string" or not validOutboxEntry(entry) or not validOutboxEntry(savedEntry) then
			if not session.warned[id] then
				session.warned[id] = true
				warn(`[PlayerStore] Malformed outbox entry {tostring(id)} for {session.userId} was not sent`)
			end
			continue
		end
		local nonce = savedEntry.nonce
		if entry.nonce ~= nonce or session.sent[id] == nonce then
			continue -- An unsaved rewrite waits for its own save; this write was already sent.
		end
		self._sending[id] = true
		local envelope =
			{ v = MESSAGE_VERSION, id = id, kind = savedEntry.kind, from = session.userId, body = savedEntry.body }
		task.spawn(function()
			local ok, sent = pcall(self._playerStore.MessageAsync, self._playerStore, tostring(savedEntry.to), envelope)
			self._sending[id] = nil
			if not ok then
				warn(`[PlayerStore] Message {id} failed to send: {sent}`)
				return
			end
			if sent ~= true then
				return -- Closing: the entry stays, and the next session sends it.
			end
			session.sent[id] = nonce
			local player = session.player
			local current = if typeof(profile.Data) == "table" then profile.Data[name] else nil
			local live = if typeof(current) == "table" then current[id] else nil
			-- A rewrite that landed while MessageAsync yielded is a different write: it stays and is sent itself.
			if
				player
				and self:_activeProfile(player) == profile
				and typeof(live) == "table"
				and live.nonce == nonce
			then
				self:trySet(player, `{name}/{id}`, nil)
			end
		end)
	end
end

local function deferMessage(session: any, message: any, processed: () -> (), reason: string)
	session.deferred[processed] = message
	local id = tostring(message.id)
	if not session.warned[id] then
		session.warned[id] = true
		warn(`[PlayerStore] Message {id} for {session.userId} deferred: {reason}`)
	end
end

--- Builds the single write that applies a handler's plan: its updates, the inbox mark and any replies.
function ServerStore._messageWrites(self: any, id: string, result: any): ({ ObservableTable.Update }?, string?)
	if typeof(result) ~= "table" then
		return nil, "handler result must be a table"
	end
	if result.after ~= nil and typeof(result.after) ~= "function" then
		return nil, "after must be a function"
	end
	for _, field in { "updates", "send" } do
		if result[field] ~= nil and typeof(result[field]) ~= "table" then
			return nil, `{field} must be a table`
		end
	end
	-- `{ updates = plan }` with a nil plan must not consume the message as if nothing were intended.
	if result.updates == nil and result.send == nil then
		return nil, "a plan needs updates or send; return { updates = {} } to consume a message on purpose"
	end
	local inbox, outbox = self._mailbox.inbox, self._mailbox.outbox
	local writes = {}
	for _, update in result.updates or {} do
		if typeof(update) ~= "table" or typeof(update.path) ~= "string" then
			return nil, "updates must be { path, value } tables"
		end
		local root = string.split(update.path, "/")[1]
		if root == inbox or root == outbox then
			return nil, `handlers must not write the mailbox root {root}`
		end
		table.insert(writes, update)
	end
	table.insert(writes, { path = `{inbox}/{id}`, value = os.time() })
	for _, outgoing in result.send or {} do
		local ok, update = pcall(self.outboxUpdate, self, outgoing)
		if not ok then
			return nil, tostring(update)
		end
		table.insert(writes, update)
	end
	return writes, nil
end

--- Applies one delivered message exactly once. Everything up to `processed()` is synchronous, so the
--- effect, the inbox mark and the queue removal reach the DataStore in the same save or not at all.
function ServerStore._deliver(self: any, session: any, message: any, processed: () -> ())
	local profile = session.profile
	local player = session.player
	if self._sessions[profile] ~= session or player == nil then
		return -- Not processed: the next session receives it again.
	end
	if
		typeof(message) ~= "table"
		or typeof(message.id) ~= "string"
		or message.id == ""
		or string.find(message.id, "/", 1, true)
		or typeof(message.kind) ~= "string"
	then
		warn(`[PlayerStore] Dropped a malformed message for {session.userId}`)
		processed()
		return
	end
	local id = message.id
	if typeof(message.v) ~= "number" or message.v > MESSAGE_VERSION then
		deferMessage(session, message, processed, `envelope version {tostring(message.v)} is newer than this server`)
		return
	end
	local inbox = profile.Data[self._mailbox.inbox]
	if typeof(inbox) == "table" and inbox[id] ~= nil then
		processed()
		return
	end
	if self:_activeProfile(player) ~= profile then
		deferMessage(session, message, processed, "session is not writable")
		return
	end
	local handler = self._messageHandlers[message.kind]
	if handler == nil then
		deferMessage(session, message, processed, `no handler for kind "{message.kind}"`)
		return
	end
	local thread = coroutine.create(handler)
	-- A frozen copy, so a handler that writes data itself errors instead of leaving an effect with no
	-- inbox mark, which a later save would carry and a redelivery would apply again. Messages are rare,
	-- so the copy's cost is per delivery, not per frame. The body is frozen for the same reason: a
	-- deferred message is retried with this same table. The planning flag is restored, not cleared,
	-- because a handler that reaches retryMessages or onMessage runs a nested delivery.
	local wasPlanning = session.planning
	session.planning = true
	local ok, result, reason = coroutine.resume(
		thread,
		player,
		deepFreeze(deepClone(profile.Data)),
		deepFreeze(message.body),
		table.freeze { id = id, from = message.from }
	)
	session.planning = wasPlanning
	if coroutine.status(thread) ~= "dead" then
		-- Cancelled, not closed: the scheduler may hold it in a wait, and must never resume it.
		task.cancel(thread)
		warn(`[PlayerStore] Message handler for "{message.kind}" yielded on {id}; its result is ignored`)
		session.deferred[processed] = message
		return
	end
	if not ok then
		warn(`[PlayerStore] Message handler for "{message.kind}" errored on {id}: {result}`)
		session.deferred[processed] = message
		return
	end
	if result == nil then
		deferMessage(session, message, processed, if typeof(reason) == "string" then reason else "handler deferred")
		return
	end
	local planOk, writes, writeError = pcall(self._messageWrites, self, id, result)
	if not planOk then
		writes, writeError = nil, writes
	end
	if writes == nil then
		warn(`[PlayerStore] Message handler for "{message.kind}" returned an invalid plan for {id}: {writeError}`)
		session.deferred[processed] = message
		return
	end
	local written, setError = self:trySetMany(player, writes)
	if not written then
		deferMessage(session, message, processed, tostring(setError))
		return
	end
	processed()
	session.deferred[processed] = nil
	local after = result.after
	if after then
		task.spawn(function()
			local afterOk, afterError = pcall(after)
			if not afterOk then
				warn(`[PlayerStore] Message after-callback for {id} errored: {afterError}`)
			end
		end)
	end
	self:_requestSave(profile)
end

function ServerStore._retrySession(self: any, session: any)
	if next(session.deferred) == nil then
		return
	end
	local pending = session.deferred
	session.deferred = {}
	for processed, message in pending do
		self:_deliver(session, message, processed)
	end
end

--- Coalesces requested saves (applied messages, confirmations) to one per frame per profile.
function ServerStore._requestSave(self: any, profile: any)
	if self._saveRequests[profile] then
		return
	end
	self._saveRequests[profile] = true
	self._saveActivity[profile] = os.clock()
	task.defer(function()
		self._saveRequests[profile] = nil
		if profile:IsActive() then
			pcall(profile.Save, profile)
		end
	end)
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
	-- ProfileStore rejects a second StartSessionAsync for a key already loading or owned in this
	-- process. A release counts until its final write lands: a session started here sooner would
	-- make ProfileStore refuse that write's retries (same server, newer load count).
	local nextProbe = os.clock() + RELEASE_PROBE_INTERVAL
	while self._loading[userId] ~= nil or self._profiles[userId] ~= nil or self._releasing[userId] ~= nil do
		if cancelled() then
			if not token.cancelled and not self._destroyed and player.Parent == Players then
				self._loadFailed[player] = true
				player:Kick("Failed to load data - Please rejoin")
			end
			return complete(false)
		end
		if self:_activeProfile(player) ~= nil then
			return complete(true)
		end
		if self._releasing[userId] ~= nil and os.clock() >= nextProbe then
			nextProbe = os.clock() + RELEASE_PROBE_INTERVAL
			self:_probeRelease(userId)
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
	local session = self:_openSession(userId, profile)
	if cancelled() then
		profile:EndSession()
		return complete(false)
	end
	profile:AddUserId(userId)
	if
		not self:_runMigrations(player, profile, function()
			return self._loading[userId] == token and not cancelled() and profile:IsActive()
		end)
	then
		self._loadFailed[player] = true
		profile:EndSession()
		return complete(false)
	end
	if cancelled() or not profile:IsActive() then
		profile:EndSession()
		return complete(false)
	end

	local outboxPrefix = if self._mailbox then `{self._mailbox.outbox}/` else nil
	local function queuesMessage(path: string, value: any): boolean
		return value ~= nil and string.sub(path, 1, #outboxPrefix) == outboxPrefix
	end
	local observable = ObservableTable.wrap(profile.Data, function(path, value)
		if self:_activeProfile(player) ~= profile then
			return false, "Data not loaded"
		end
		if session.planning then
			-- A write that lands outside the plan has no inbox mark, so a deferral would apply it again.
			return false, "message handlers must return their writes in the plan"
		end
		return Validation.validateWrite(self._schema, path, value)
	end, function(path, value, updates)
		self:_sendDelta(player, profile, path, value, updates)
		if outboxPrefix == nil then
			return
		end
		-- The relay only sends saved entries, so without a save a queued message waits for the autosave.
		local queued = if updates then false else queuesMessage(path, value)
		for _, update in updates or {} do
			queued = queued or queuesMessage(update.path, update.value)
		end
		if queued then
			self:_requestSave(profile)
		end
	end)
	self._profiles[userId] = profile
	self._owners[userId] = player
	self._observables[player] = observable
	local sessionConnection = profile.OnSessionEnd:Connect(function()
		local wasCurrent = self._profiles[userId] == profile and self._owners[userId] == player
		local intentional = self._manualEnd[profile] == true
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
	session.player = player
	if self._mailbox then
		-- The only handler for this profile, so ProfileStore never hands one message to a second handler.
		profile:MessageHandler(function(message, processed)
			self:_deliver(session, message, processed)
		end)
		self:_relay(session)
	end
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
		self:_clearOwnedProfile(player, profile)
		-- Synchronously fires OnLastSave, which holds `_releasing` until the final write lands.
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
	-- Follows the captured profile, not the Player: a departing Player's session keeps saving, and
	-- its release write retries until it lands.
	local confirmed = false
	local finalSaveStarted = false
	local sessionLost = false
	local connections = {
		profile.OnAfterSave:Connect(function()
			self._saveActivity[profile] = os.clock()
			confirmed = confirmed or isConfirmed()
		end),
		profile.OnLastSave:Connect(function()
			finalSaveStarted = true
		end),
		profile.OnSessionEnd:Connect(function()
			sessionLost = sessionLost or not finalSaveStarted
		end),
	}
	local function finish(result: boolean, err: string?): (boolean, string?)
		for _, connection in connections do
			connection:Disconnect()
		end
		return result, err
	end
	-- Coalesced per frame, so confirmations of writes made in one frame share one save.
	self:_requestSave(profile)
	local deadline = os.clock() + (timeout or DEFAULT_SAVE_CONFIRM_WAIT)
	while true do
		if confirmed or isConfirmed() then
			return finish(true, nil)
		end
		if predicateError then
			return finish(false, predicateError)
		end
		if sessionLost then
			return finish(false, "Session lost")
		end
		local token = self._releaseTokens[profile]
		local saved = profile.LastSavedData
		if token ~= nil and typeof(saved) == "table" and saved[RELEASE_TOKEN_KEY] == token then
			return finish(false, "Not in final save")
		end
		local now = os.clock()
		if now >= deadline then
			return finish(false, "Save confirmation timed out")
		end
		if profile:IsActive() and now - (self._saveActivity[profile] or 0) >= SAVE_RETRY_INTERVAL then
			self:_requestSave(profile)
		end
		task.wait(0.05)
	end
end

--- Handles messages of `kind`. The handler plans against `data`, a frozen copy, and a frozen `body`, and
--- tracked writes to that player are refused while it runs. It must not yield: a yielding handler is
--- cancelled and its message deferred. Return nil plus a reason to defer; deferred messages are retried,
--- never dropped. A plan needs `updates` or `send`; `{ updates = {} }` consumes on purpose.
function ServerStore.onMessage(self: any, kind: string, handler: MessageHandler): () -> ()
	assert(self._mailbox ~= nil, "[PlayerStore] onMessage needs the mailbox option")
	assert(type(kind) == "string" and kind ~= "", "[PlayerStore] message kind must be a non-empty string")
	assert(type(handler) == "function", "[PlayerStore] message handler must be a function")
	assert(self._messageHandlers[kind] == nil, `[PlayerStore] a handler for "{kind}" is already registered`)
	self._messageHandlers[kind] = handler
	local sessions = {}
	for _, session in self._sessions do
		table.insert(sessions, session)
	end
	for _, session in sessions do
		self:_retrySession(session)
	end
	return function()
		if self._messageHandlers[kind] == handler then
			self._messageHandlers[kind] = nil
		end
	end
end

local function checkOutgoing(message: Outgoing): (number, string, string)
	assert(typeof(message) == "table", "[PlayerStore] message must be a table")
	local to, kind, id = message.to, message.kind, message.id
	assert(
		type(to) == "number" and to == to and math.abs(to) < math.huge and to % 1 == 0,
		"[PlayerStore] message.to must be a UserId"
	)
	assert(type(kind) == "string" and kind ~= "", "[PlayerStore] message.kind must be a non-empty string")
	assert(
		type(id) == "string" and id ~= "" and not string.find(id, "/", 1, true),
		"[PlayerStore] message.id must be a non-empty string without '/'"
	)
	return to, kind, id
end

--- Builds the write that queues `message`; put it in the same trySetMany as the decision it belongs to.
--- `id` must be unique across all senders and kinds (prefix it with the kind: "gift:<PurchaseId>"), and
--- written once: a rewrite of an id already sent reaches its new recipient as a second message.
function ServerStore.outboxUpdate(self: any, message: Outgoing): ObservableTable.Update
	assert(self._mailbox ~= nil, "[PlayerStore] outboxUpdate needs the mailbox option")
	local to, kind, id = checkOutgoing(message)
	return {
		path = `{self._mailbox.outbox}/{id}`,
		-- The nonce names this write, so the relay can tell a saved entry from an unsaved rewrite of its id.
		value = { to = to, kind = kind, body = message.body, nonce = HttpService:GenerateGUID(false) },
	}
end

--- Sends `message` straight to the recipient's queue, with `from = OPERATOR_SENDER`, for operator tools
--- that hold no sender session; it writes no outbox. Yields. `true` means ProfileStore stored it. After
--- `false` or a timeout, send the same id again: the receiver applies an id once. Ids follow outbox rules.
function ServerStore.sendAsync(self: any, message: Outgoing): (boolean, string?)
	assert(self._mailbox ~= nil, "[PlayerStore] sendAsync needs the mailbox option")
	local to, kind, id = checkOutgoing(message)
	if self._destroyed then
		return false, "Store destroyed"
	end
	local envelope = { v = MESSAGE_VERSION, id = id, kind = kind, from = OPERATOR_SENDER, body = message.body }
	local ok, sent = pcall(self._playerStore.MessageAsync, self._playerStore, tostring(to), envelope)
	if not ok then
		return false, tostring(sent)
	end
	if sent ~= true then
		return false, "ProfileStore is closing"
	end
	return true, nil
end

--- Retries this session's deferred messages now (e.g. once something a handler waited for is ready).
function ServerStore.retryMessages(self: any, player: Player)
	local profile = self:_activeProfile(player)
	local session = if profile then self._sessions[profile] else nil
	if session then
		self:_retrySession(session)
	end
end

--- `keep` names further root fields to leave alone, such as receipt marks that bind outbox entries:
--- wiping a mark while its receipt is still pending lets the redelivery decide again.
function ServerStore.wipeData(self: any, player: Player, keep: { string }?)
	local profile = self:_activeProfile(player)
	if profile == nil then
		error("[PlayerStore] No profile found for player")
	end

	local template = self._schema.template :: any
	local kept = {}
	for _, key in keep or {} do
		assert(template[key] ~= nil, `[PlayerStore] wipeData can only keep schema root fields, not "{tostring(key)}"`)
		kept[key] = true
	end
	local mailbox = self._mailbox
	if mailbox then
		-- Wiping the inbox would let a resend apply twice; wiping the outbox would drop undelivered messages.
		kept[mailbox.inbox] = true
		kept[mailbox.outbox] = true
	end
	for key, value in template do
		if not kept[key] then
			profile.Data[key] = deepClone(value)
		end
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
	local sessions = {}
	for _, session in self._sessions do
		table.insert(sessions, session)
	end
	for _, session in sessions do
		self:_closeSession(session)
	end
	table.clear(self._messageHandlers)
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
