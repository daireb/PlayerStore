--[=[
	ObservableTable

	Wraps a table and provides path-based change notifications.
	When a value is set, listeners at every ancestor path (including root)
	and registered descendant path are fired with both the path's resolved
	value and the specific change.

	Path format: "Key1/Key2/Key3" using "/" as separator.
	Omit the path argument to operate on the root.
]=]

local Signal = require(script.Parent.Signal)
local DataValue = require(script.Parent.DataValue)

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type Update = {
	path: string,
	value: any,
}

type Callback = (value: any, path: string, specificValue: any, specificPath: string, updates: { Update }?) -> ()

type ObserverNode = {
	path: string,
	keys: { string },
	signal: Signal.Signal<unknown>,
	children: { [string]: ObserverNode },
}

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
	_observerRoot: ObserverNode,
	_validator: ((path: string, value: any) -> (boolean, string?))?,
	_onCommit: ((path: string, value: any, updates: { Update }?) -> ())?,
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
	validator: ((path: string, value: any) -> (boolean, string?))?,
	onCommit: ((path: string, value: any, updates: { Update }?) -> ())?
): ObservableTable<T>
	local self = setmetatable({}, ObservableTable) :: any
	self._table = tbl or {}
	self._observerRoot = {
		path = ROOT,
		keys = {},
		signal = nil,
		children = {},
	}
	self._validator = validator
	self._onCommit = onCommit
	return self
end

local function notifyNode(
	node: ObserverNode,
	value: any,
	specificPath: string,
	specificValue: any,
	updates: { Update }?
)
	if node.signal ~= nil then
		node.signal:Fire(value, node.path, specificValue, specificPath, updates)
	end
end

local function getOrCreateObserverNode(self: InternalObservableTable<any>, path: string): ObserverNode
	if path ~= ROOT then
		local ok, err = DataValue.path(path)
		if not ok then
			error(`[PlayerStore] Invalid observer path: {err}`)
		end
	end
	local node = self._observerRoot
	if path == ROOT then
		return node
	end

	for _, key in string.split(path, "/") do
		local child = node.children[key]
		if child == nil then
			local keys = table.clone(node.keys)
			table.insert(keys, key)
			child = {
				path = if node.path == ROOT then key else `{node.path}/{key}`,
				keys = keys,
				signal = nil,
				children = {},
			}
			node.children[key] = child
		end
		node = child
	end

	return node
end

local function resolveNodeValue(self: InternalObservableTable<any>, node: ObserverNode): any
	local current: any = self._table
	for _, key in node.keys do
		if typeof(current) ~= "table" then
			return nil
		end
		current = current[key]
	end
	return current
end

local function notifySubtree(
	node: ObserverNode,
	value: any,
	specificPath: string,
	specificValue: any,
	updates: { Update }?
)
	notifyNode(node, value, specificPath, specificValue, updates)

	for key, child in node.children do
		local childValue = if typeof(value) == "table" then value[key] else nil
		notifySubtree(child, childValue, specificPath, specificValue, updates)
	end
end

local function notifyPath(
	self: InternalObservableTable<any>,
	keys: { string },
	specificPath: string,
	specificValue: any,
	updates: { Update }?
)
	local node = self._observerRoot
	local value: any = self._table
	notifyNode(node, value, specificPath, specificValue, updates)

	for _, key in keys do
		local child = node.children[key]
		if child == nil then
			return
		end

		node = child
		value = if typeof(value) == "table" then value[key] else nil
		notifyNode(node, value, specificPath, specificValue, updates)
	end

	for key, child in node.children do
		local childValue = if typeof(value) == "table" then value[key] else nil
		notifySubtree(child, childValue, specificPath, specificValue, updates)
	end
end

local function copyUpdates(updates: { Update }): { Update }
	local copied = {}
	local paths = {}

	for index, update in ipairs(updates) do
		local ok, err
		if typeof(update) == "table" then
			ok, err = DataValue.path(update.path)
		else
			ok, err = false, "expected a path/value record"
		end
		if not ok then
			error(`[PlayerStore] Invalid update at index {index}: {err}`)
		end
		for _, prior in paths do
			if
				prior == update.path
				or string.sub(prior, 1, #update.path + 1) == update.path .. "/"
				or string.sub(update.path, 1, #prior + 1) == prior .. "/"
			then
				error(`[PlayerStore] Overlapping batch paths: "{prior}" and "{update.path}"`)
			end
		end
		table.insert(paths, update.path)

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
	keys: { string },
	createIntermediates: boolean,
	undo: { any }
): (any, string)
	local current: any = self._table

	for i = 1, #keys - 1 do
		if typeof(current) ~= "table" then
			error(`Path "{path}" does not exist in the table`)
		end
		if current[1] ~= nil then
			error(`Path "{path}" cannot write inside an array; replace the whole array`)
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
	if current[1] ~= nil then
		error(`Path "{path}" cannot write inside an array; replace the whole array`)
	end

	return current, keys[#keys]
end

local function addBatchNode(
	nodes: { ObserverNode },
	seenNodes: { [ObserverNode]: true },
	lastUpdateByNode: { [ObserverNode]: Update },
	node: ObserverNode,
	update: Update
)
	if node.signal == nil then
		return
	end

	if not seenNodes[node] then
		seenNodes[node] = true
		table.insert(nodes, node)
	end
	lastUpdateByNode[node] = update
end

local function addBatchSubtree(
	nodes: { ObserverNode },
	seenNodes: { [ObserverNode]: true },
	lastUpdateByNode: { [ObserverNode]: Update },
	node: ObserverNode,
	update: Update
)
	for _, child in node.children do
		addBatchNode(nodes, seenNodes, lastUpdateByNode, child, update)
		addBatchSubtree(nodes, seenNodes, lastUpdateByNode, child, update)
	end
end

local function notifyUpdates(
	self: InternalObservableTable<any>,
	updates: { Update },
	keysByUpdate: { [Update]: { string } }
)
	local nodes = {}
	local seenNodes = {}
	local lastUpdateByNode = {}

	for _, update in ipairs(updates) do
		local node = self._observerRoot
		addBatchNode(nodes, seenNodes, lastUpdateByNode, node, update)

		for _, key in keysByUpdate[update] do
			local child = node.children[key]
			if child == nil then
				node = nil :: any
				break
			end

			node = child
			addBatchNode(nodes, seenNodes, lastUpdateByNode, node, update)
		end

		if node ~= nil then
			addBatchSubtree(nodes, seenNodes, lastUpdateByNode, node, update)
		end
	end

	for _, node in nodes do
		local lastUpdate = lastUpdateByNode[node]
		notifyNode(node, resolveNodeValue(self, node), lastUpdate.path, lastUpdate.value, updates)
	end
end

local function commitUpdates(
	self: InternalObservableTable<any>,
	updates: { Update },
	createIntermediates: boolean,
	runCommitHook: boolean
)
	local undo = {}
	local keysByUpdate = {}
	local success, err = pcall(function()
		for _, update in ipairs(updates) do
			local keys = string.split(update.path, "/")
			keysByUpdate[update] = keys
			local parent, key = resolveWriteTarget(self, update.path, keys, createIntermediates, undo)
			local oldValue = parent[key]
			table.insert(undo, {
				parent = parent,
				key = key,
				hadValue = oldValue ~= nil,
				value = oldValue,
			})
			parent[key] = update.value
		end
		-- Earlier assignments can turn an individually valid borrowed table into
		-- a cycle through another path. Check only newly attached subgraphs.
		if self._validator then
			for _, update in ipairs(updates) do
				if typeof(update.value) == "table" then
					local valid, reason = DataValue.validate(update.value, update.path)
					if not valid then
						error(reason)
					end
				end
			end
		end
	end)

	if not success then
		for i = #undo, 1, -1 do
			local entry = undo[i]
			entry.parent[entry.key] = if entry.hadValue then entry.value else nil
		end
		error(err, 0)
	end

	if runCommitHook and self._onCommit and #updates > 0 then
		self._onCommit(ROOT, self._table, updates)
	end
	notifyUpdates(self, updates, keysByUpdate)
end

function ObservableTable.get<T>(self: InternalObservableTable<T>, path: string?): any
	if path == nil or path == ROOT then
		return self._table
	end
	local ok, err = DataValue.path(path)
	if not ok then
		error(`[PlayerStore] Invalid path: {err}`)
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
	local valid, pathError = DataValue.path(path)
	if not valid then
		error(`[PlayerStore] Invalid path: {pathError}`)
	end
	if self._validator then
		local ok, err = self._validator(path, value)
		if not ok then
			error(`[PlayerStore] Invalid write to "{path}": {err}`)
		end
	end

	local keys = string.split(path, "/")
	local current, key = resolveWriteTarget(self, path, keys, false, {})
	local previous = current[key]
	current[key] = value
	if self._validator and typeof(value) == "table" then
		local valueValid, reason = DataValue.validate(value, path)
		if not valueValid then
			current[key] = previous
			error(`[PlayerStore] Invalid write to "{path}": {reason}`)
		end
	end
	if self._onCommit then
		self._onCommit(path, value, nil)
	end
	notifyPath(self, keys, path, value, nil)
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

	commitUpdates(self, copiedUpdates, false, true)
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

	local node = getOrCreateObserverNode(self, path)
	if node.signal == nil then
		node.signal = Signal.new()
	end

	return node.signal:Connect(callback)
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

	local disconnect = self:listen(path, callback)
	local val = self:get(if path == ROOT then nil else path)
	task.spawn(callback, val, path, val, path)
	return disconnect
end

--[=[
	Applies an update from an external source (used by ClientStore for
	server replication). Unlike set(), this creates intermediate tables
	if they don't exist, and handles root-level updates.
]=]
function ObservableTable.applyUpdate<T>(self: InternalObservableTable<T>, path: string, value: any)
	if path == ROOT then
		if typeof(value) ~= "table" then
			error("[PlayerStore] Root snapshot must be a table")
		end
		if value ~= self._table then
			table.clear(self._table :: any)
			for k, v in value do
				(self._table :: any)[k] = v
			end
		end
		notifySubtree(self._observerRoot, self._table, ROOT, self._table, nil)
		return
	end
	local valid, pathError = DataValue.path(path)
	if not valid then
		error(`[PlayerStore] Invalid path: {pathError}`)
	end

	local keys = string.split(path, "/")
	local current: any = self._table

	for i = 1, #keys - 1 do
		if typeof(current) ~= "table" or current[1] ~= nil then
			error(`Path "{path}" cannot traverse a non-dictionary table`)
		end
		if current[keys[i]] == nil then
			current[keys[i]] = {}
		end
		current = current[keys[i]]
	end

	if typeof(current) ~= "table" or current[1] ~= nil then
		error(`Path "{path}" cannot write inside an array or scalar`)
	end
	current[keys[#keys]] = value
	notifyPath(self, keys, path, value, nil)
end

--[=[
	Applies an ordered batch from an external source. Like applyUpdate(), this
	creates missing intermediate tables and bypasses validation.
]=]
function ObservableTable.applyUpdates<T>(self: InternalObservableTable<T>, updates: { Update })
	commitUpdates(self, copyUpdates(updates), true, false)
end

local function destroyObserverNode(node: ObserverNode)
	if node.signal ~= nil then
		node.signal:Destroy()
		node.signal = nil :: any
	end

	for _, child in node.children do
		destroyObserverNode(child)
	end
	table.clear(node.children)
end

function ObservableTable.Destroy<T>(self: InternalObservableTable<T>)
	destroyObserverNode(self._observerRoot)
	self._table = nil :: any
	self._observerRoot = nil :: any
	setmetatable(self :: any, nil)
end

return ObservableTable
