-- Test boundary for the real modules: controllable profiles and queued, copied network messages.
-- It deliberately does not model Roblox scheduling, DataStore persistence, or session locks.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local task = require("@lune/task")

local Runtime = {}

function Runtime.signal()
	local listeners = {}
	local signal = {}
	function signal.Connect(_, callback)
		local connection = { Connected = true }
		listeners[connection] = callback
		function connection:Disconnect()
			self.Connected = false
			listeners[self] = nil
		end
		return connection
	end
	function signal:Fire(...)
		local snapshot = table.clone(listeners)
		for connection, callback in snapshot do
			if connection.Connected then
				callback(...)
			end
		end
	end
	function signal:Destroy()
		for connection in listeners do
			connection:Disconnect()
		end
	end
	return signal
end

local function clone(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, child in value do
		result[key] = clone(child)
	end
	return result
end

function Runtime.new()
	local world = { queue = {}, messages = {}, warnings = {}, profiles = {}, starts = 0 }
	local players = { PlayerRemoving = Runtime.signal(), PlayerAdded = Runtime.signal() }
	local storage = {}
	local root = { _path = "src/init.luau" }
	for _, file in fs.readDir("src") do
		if file ~= "init.luau" and file:sub(-5) == ".luau" then
			root[file:sub(1, -6)] = { _path = "src/" .. file, Parent = root }
		end
	end
	storage.Packages = { PlayerStore = root }
	storage.Tests = { Shared = { TestRunner = { _path = "tests/shared/TestRunner.luau" } } }
	function storage:FindFirstChild(name)
		return self[name]
	end
	function storage:WaitForChild(name)
		return assert(self[name], `Missing test instance {name}`)
	end
	world.players, world.storage, world.root = players, storage, root

	function world.player(_, id)
		local player = {
			UserId = id,
			Name = `Player{id}`,
			DisplayName = `Player{id}`,
			Parent = players,
			Kick = function(self, reason)
				self.kicked = reason
			end,
		}
		return player
	end
	function world:flush()
		while #self.queue > 0 do
			table.remove(self.queue, 1)()
		end
	end

	local function instance(class)
		local object = { ClassName = class }
		function object:IsA(className)
			return className == class
		end
		if class == "RemoteEvent" then
			object.OnServerEvent = Runtime.signal()
			object.clients = {}
			function object:FireClient(player, ...)
				local args = clone(table.pack(...))
				table.insert(world.messages, { player = player, args = args })
				table.insert(world.queue, function()
					local event = self.clients[player]
					if event and not self.destroyed then
						event:Fire(table.unpack(args, 1, args.n))
					end
				end)
			end
		else
			error(`Unexpected test instance {class}`)
		end
		function object:Destroy()
			self.destroyed = true
			if self.OnServerEvent then
				self.OnServerEvent:Destroy()
			end
			if self.Parent and self.Parent[self.Name] == self then
				self.Parent[self.Name] = nil
			end
		end
		return setmetatable(object, {
			__newindex = function(self, key, value)
				rawset(self, key, value)
				if key == "Parent" and value then
					value[self.Name] = self
				end
			end,
		})
	end

	function world.loader(_, player)
		local cache = {}
		local view = storage
		if player then
			view = setmetatable({}, { __index = storage })
			local remotes = {}
			function view.WaitForChild(_, name)
				if remotes[name] then
					return remotes[name]
				end
				local remote = storage:WaitForChild(name)
				local event = Runtime.signal()
				remote.clients[player] = event
				local proxy = { OnClientEvent = event }
				function proxy:IsA(className)
					return className == "RemoteEvent"
				end
				function proxy:FireServer(...)
					local args = table.pack(...)
					table.insert(world.queue, function()
						if not remote.destroyed then
							remote.OnServerEvent:Fire(player, table.unpack(args, 1, args.n))
						end
					end)
				end
				remotes[name] = proxy
				return proxy
			end
		end
		local load
		load = function(module)
			if type(module) == "string" then
				module = { _path = module }
			end
			if cache[module._path] ~= nil then
				return cache[module._path]
			end
			local debugShim = table.clone(debug)
			debugShim.profilebegin = function() end
			debugShim.profileend = function() end
			local environment = {
				script = module,
				require = load,
				task = task,
				tick = os.clock,
				debug = debugShim,
				game = {
					GetService = function(_, name)
						if name == "ReplicatedStorage" then
							return view
						end
						if name == "Players" then
							return players
						end
						error(`Unexpected service {name}`)
					end,
				},
				Instance = { new = instance },
				warn = function(message)
					table.insert(world.warnings, message)
				end,
			}
			local value = luau.load(
				fs.readFile(module._path),
				{ debugName = module._path, injectGlobals = true, environment = environment }
			)()
			cache[module._path] = value
			return value
		end
		return load
	end

	world.ProfileStore = {
		New = function(_storeId, template)
			return {
				StartSessionAsync = function(_, _key, params)
					world.starts += 1
					if world.startHook then
						world.startHook(params)
					end
					if params.Cancel() then
						return nil
					end
					local profile = {
						Data = clone(world.saved or template),
						LastSavedData = clone(world.saved or template),
						active = true,
						OnSave = Runtime.signal(),
						OnAfterSave = Runtime.signal(),
						OnSessionEnd = Runtime.signal(),
						saves = 0,
					}
					function profile:IsActive()
						return self.active
					end
					function profile:AddUserId() end
					function profile:Save()
						self.saves += 1
						self.OnSave:Fire()
						if world.saveHook then
							world.saveHook(self)
						end
					end
					function profile:completeSave()
						self.LastSavedData = clone(self.Data)
						self.OnAfterSave:Fire(self.LastSavedData)
					end
					function profile:EndSession()
						self.active = false
						self.endedData = clone(self.Data)
						if not world.deferSessionEnd then
							self.OnSessionEnd:Fire()
						end
					end
					table.insert(world.profiles, profile)
					return profile
				end,
			}
		end,
	}
	world.load = world:loader()
	return world
end
return Runtime
