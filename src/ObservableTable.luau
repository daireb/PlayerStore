--[=[
	ObservableTable

	Wraps a table and provides path-based change notifications.
	When a value is set, listeners at every ancestor path (including root)
	are fired with both the ancestor's full value and the specific change.

	Path format: "Key1/Key2/Key3" using "/" as separator.
	Omit the path argument to operate on the root.
]=]

local Signal = require(script.Parent.Signal)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type Update = {
	path: string,
	value: any,
}

type Callback = (value: any, path: string, specificValue: any, specificPath: string, updates: { Update }?) -> ()

export type ObservableTable<T> = {
	get: (self: ObservableTable<T>, path: string?) -> any,
	set: (self: ObservableTable<T>, path: string, value: any) -> (),
	setMany: (self: ObservableTable<T>, updates: { Update }) -> (),
	listen: ((self: ObservableTable<T>, callback: Callback) -> () -> ())
		& ((self: ObservableTable<T>, path: string, callback: Callback) -> () -> ()),
	bind: ((self: ObservableTable<T>, callback: Callback) -> () -> ())
		& ((self: ObservableTable<T>, path: string, callback: Callback) -> () -> ()),
	applyUpdate: (self: ObservableTable<T>, path: string, value: any) -> (),
	applyUpdates: (self: ObservableTable<T>, updates: { Update }) -> (),
	Destroy: (self: ObservableTable<T>) -> (),
}

type InternalObservableTable<T> = ObservableTable<T> & {
	_table: T & { [string]: any },
	_signals: { [string]: typeof(Signal.new()) },
	_validator: ((path: string, value: any) -> (boolean, string?))?,
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local ROOT = ""

--------------------------------------------------------------------------------
-- Implementation
--------------------------------------------------------------------------------

local ObservableTable = {}
ObservableTable.__index = ObservableTable

function ObservableTable.wrap<T>(
	tbl: T,
	validator: ((path: string, value: any) -> (boolean, string?))?
): ObservableTable<T>
	local self = setmetatable({}, ObservableTable) :: any
	self._table = tbl or {}
	self._signals = {}
	self._validator = validator
	return self
end

local function notify(
	self: InternalObservableTable<any>,
	path: string,
	value: any,
	specificPath: string,
	specificValue: any,
	updates: { Update }?
)
	if self._signals[path] ~= nil then
		self._signals[path]:Fire(value, path, specificValue, specificPath, updates)
	end
end

local function copyUpdates(updates: { Update }): { Update }
	local copied = {}

	for index, update in ipairs(updates) do
		if typeof(update) ~= "table" or typeof(update.path) ~= "string" or update.path == ROOT then
			error(`[PlayerStore] Invalid update at index {index}: expected a non-empty string path`)
		end

		table.insert(copied, {
			path = update.path,
			value = update.value,
		})
	end

	return copied
end

local function resolveWriteTarget(
	self: InternalObservableTable<any>,
	path: string,
	createIntermediates: boolean,
	undo: { any }
): (any, string)
	local keys = string.split(path, "/")
	local current: any = self._table

	for i = 1, #keys - 1 do
		if typeof(current) ~= "table" then
			error(`Path "{path}" does not exist in the table`)
		end

		if current[keys[i]] == nil then
			if not createIntermediates then
				error(`Path "{path}" does not exist in the table`)
			end
			table.insert(undo, {
				parent = current,
				key = keys[i],
				hadValue = false,
			})
			current[keys[i]] = {}
		end

		current = current[keys[i]]
	end

	if typeof(current) ~= "table" then
		error(`Path "{path}" does not exist in the table`)
	end

	return current, keys[#keys]
end

local function notifyUpdates(self: InternalObservableTable<any>, updates: { Update })
	local paths = {}
	local seenPaths = {}
	local lastUpdateByPath = {}

	for _, update in ipairs(updates) do
		local keys = string.split(update.path, "/")

		if not seenPaths[ROOT] then
			seenPaths[ROOT] = true
			table.insert(paths, ROOT)
		end
		lastUpdateByPath[ROOT] = update

		for i = 1, #keys do
			local path = table.concat(keys, "/", 1, i)
			if not seenPaths[path] then
				seenPaths[path] = true
				table.insert(paths, path)
			end
			lastUpdateByPath[path] = update
		end
	end

	for _, path in paths do
		local lastUpdate = lastUpdateByPath[path]
		local value = self:get(if path == ROOT then nil else path)
		notify(self, path, value, lastUpdate.path, lastUpdate.value, updates)
	end
end

local function commitUpdates(self: InternalObservableTable<any>, updates: { Update }, createIntermediates: boolean)
	local undo = {}
	local success, err = pcall(function()
		for _, update in ipairs(updates) do
			local parent, key = resolveWriteTarget(self, update.path, createIntermediates, undo)
			local oldValue = parent[key]
			table.insert(undo, {
				parent = parent,
				key = key,
				hadValue = oldValue ~= nil,
				value = oldValue,
			})
			parent[key] = update.value
		end
	end)

	if not success then
		for i = #undo, 1, -1 do
			local entry = undo[i]
			entry.parent[entry.key] = if entry.hadValue then entry.value else nil
		end
		error(err, 0)
	end

	notifyUpdates(self, updates)
end

function ObservableTable.get<T>(self: InternalObservableTable<T>, path: string?): any
	if path == nil or path == ROOT then
		return self._table
	end

	local keys = string.split(path, "/")
	local current: any = self._table

	for _, key in keys do
		if typeof(current) ~= "table" or current[key] == nil then
			return nil
		end
		current = current[key]
	end

	return current
end

function ObservableTable.set<T>(self: InternalObservableTable<T>, path: string, value: any)
	if self._validator then
		local ok, err = self._validator(path, value)
		if not ok then
			error(`[PlayerStore] Invalid write to "{path}": {err}`)
		end
	end

	local keys = string.split(path, "/")
	local current: any = self._table

	for i = 1, #keys - 1 do
		if current[keys[i]] == nil then
			error(`Path "{path}" does not exist in the table`)
		end
		current = current[keys[i]]
	end

	current[keys[#keys]] = value

	-- Notify: root, then each ancestor, then the exact path
	notify(self, ROOT, self._table, path, value)

	local ancestor: any = self._table
	for i = 1, #keys - 1 do
		local subPath = table.concat(keys, "/", 1, i)
		notify(self, subPath, ancestor[keys[i]], path, value)
		ancestor = ancestor[keys[i]]
	end

	notify(self, path, value, path, value)
end

--[=[
	Validates and applies an ordered list of writes atomically. All writes are
	committed before affected listeners fire, and each listener fires at most
	once with the final state. If a write fails, earlier writes are rolled back.
]=]
function ObservableTable.setMany<T>(self: InternalObservableTable<T>, updates: { Update })
	local copiedUpdates = copyUpdates(updates)

	if self._validator then
		for _, update in ipairs(copiedUpdates) do
			local ok, err = self._validator(update.path, update.value)
			if not ok then
				error(`[PlayerStore] Invalid write to "{update.path}": {err}`)
			end
		end
	end

	commitUpdates(self, copiedUpdates, false)
end

function ObservableTable.listen<T>(
	self: InternalObservableTable<T>,
	pathOrCallback: string | Callback,
	maybeCallback: Callback?
): () -> ()
	local path: string
	local callback: Callback

	if typeof(pathOrCallback) == "function" then
		path = ROOT
		callback = pathOrCallback
	else
		path = pathOrCallback :: string
		callback = maybeCallback :: Callback
	end

	if not self._signals[path] then
		self._signals[path] = Signal.new()
	end

	return self._signals[path]:Connect(callback)
end

function ObservableTable.bind<T>(
	self: InternalObservableTable<T>,
	pathOrCallback: string | Callback,
	maybeCallback: Callback?
): () -> ()
	local path: string
	local callback: Callback

	if typeof(pathOrCallback) == "function" then
		path = ROOT
		callback = pathOrCallback
	else
		path = pathOrCallback :: string
		callback = maybeCallback :: Callback
	end

	local val = self:get(if path == ROOT then nil else path)
	task.spawn(callback, val, path, val, path)

	return self:listen(path, callback)
end

--[=[
	Applies an update from an external source (used by ClientStore for
	server replication). Unlike set(), this creates intermediate tables
	if they don't exist, and handles root-level updates.
]=]
function ObservableTable.applyUpdate<T>(self: InternalObservableTable<T>, path: string, value: any)
	if path == ROOT or path == "" then
		-- Root update: merge incoming data into internal table
		if typeof(value) == "table" then
			for k, v in value do
				(self._table :: any)[k] = v
			end
		end
		notify(self, ROOT, self._table, ROOT, self._table)

		-- Notify any registered sub-path signals so listeners set up before
		-- the initial load still fire with the real data.
		for signalPath in self._signals do
			if signalPath ~= ROOT then
				local resolved = self:get(signalPath)
				if resolved ~= nil then
					notify(self, signalPath, resolved, ROOT, self._table)
				end
			end
		end
		return
	end

	local keys = string.split(path, "/")
	local current: any = self._table

	for i = 1, #keys - 1 do
		if current[keys[i]] == nil then
			current[keys[i]] = {}
		end
		current = current[keys[i]]
	end

	current[keys[#keys]] = value

	-- Fire the same notification hierarchy as set()
	notify(self, ROOT, self._table, path, value)

	local ancestor: any = self._table
	for i = 1, #keys - 1 do
		local subPath = table.concat(keys, "/", 1, i)
		notify(self, subPath, ancestor[keys[i]], path, value)
		ancestor = ancestor[keys[i]]
	end

	notify(self, path, value, path, value)
end

--[=[
	Applies an ordered batch from an external source. Like applyUpdate(), this
	creates missing intermediate tables and bypasses validation.
]=]
function ObservableTable.applyUpdates<T>(self: InternalObservableTable<T>, updates: { Update })
	commitUpdates(self, copyUpdates(updates), true)
end

function ObservableTable.Destroy<T>(self: InternalObservableTable<T>)
	for path, signal in self._signals do
		signal:Destroy()
		self._signals[path] = nil
	end

	self._table = nil :: any
	self._signals = nil :: any
	setmetatable(self :: any, nil)
end

return ObservableTable
