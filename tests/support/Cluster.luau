-- Several simulated servers running the locked ProfileStore source against one shared fake DataStore and
-- MessagingService, so PlayerStore meets ProfileStore's real session locks, message queue and save retries.
-- Only the platform is faked: per-key atomic UpdateAsync with JSON round trips, injectable faults, and
-- servers that can be killed between any two API calls. The source comes from `pesde install --locked`.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local serde = require("@lune/serde")
local task = require("@lune/task")

local SOURCE = "roblox_server_packages/.pesde/lm-loleris_profilestore@1.0.3/profilestore/ProfileStore.luau"

local Cluster = {}

function Cluster.available(): boolean
	return fs.isFile(SOURCE)
end

local function roundTrip(value: any): any
	if value == nil then
		return nil
	end
	return serde.decode("json", serde.encode("json", value))
end

--- Parks the calling thread for good: a killed server never finishes an API call.
local function park()
	coroutine.yield()
end

function Cluster.new(Runtime: any)
	local source = fs.readFile(SOURCE)
	local cluster = { stores = {}, topics = {}, servers = {}, guids = 0, writes = 0 }

	function cluster.read(_, key: string, storeName: string?): any
		local store = cluster.stores[storeName or "Transfers"]
		return if store and store[key] then roundTrip(serde.decode("json", store[key])) else nil
	end

	function cluster.queue(_, key: string, storeName: string?): { any }
		local value = cluster:read(key, storeName)
		return if value and value.GlobalUpdates then value.GlobalUpdates[2] else {}
	end

	function cluster.server(_, name: string)
		local server = {
			name = name,
			killed = false,
			faults = {},
			closeCallbacks = {},
			-- ProfileStore and PlayerStore read the same shifted clock; ProfileStore's task.wait backoffs stay real.
			clockOffset = 0,
			timeOffset = 0,
			warnings = {},
		}
		table.insert(cluster.servers, server)

		local function api()
			if server.killed then
				park()
			end
			task.wait()
			if server.killed then
				park()
			end
		end

		local function takeFault(key: string, before: any?, after: any?): any
			for index, fault in server.faults do
				local applies = if fault.match then before ~= nil and fault.match(before, after) else before == nil
				if (fault.key == nil or fault.key == key) and applies then
					fault.remaining -= 1
					if fault.remaining <= 0 then
						table.remove(server.faults, index)
					end
					return fault
				end
			end
			return nil
		end

		local function waitForGate(fault: any)
			while not fault.opened do
				if server.killed then
					park()
				end
				task.wait()
			end
		end

		local function keyInfo()
			return {
				Version = tostring(cluster.writes),
				CreatedTime = 0,
				UpdatedTime = 0,
				GetMetadata = function()
					return {}
				end,
				GetUserIds = function()
					return {}
				end,
			}
		end

		local dataStores = {}
		local DataStoreService = {}
		function DataStoreService.GetDataStore(_, storeName: string)
			if dataStores[storeName] then
				return dataStores[storeName]
			end
			cluster.stores[storeName] = cluster.stores[storeName] or {}
			local stored = cluster.stores[storeName]
			local dataStore = {}
			function dataStore.UpdateAsync(_, key: string, transform)
				local fault = takeFault(key)
				api()
				if fault and fault.kind == "hold" and fault.phase == "before" then
					waitForGate(fault)
				end
				if fault and fault.kind == "error" then
					error("502: injected DataStore error")
				end
				local current = if stored[key] then serde.decode("json", stored[key]) else nil
				local value = transform(current)
				if fault == nil then
					fault =
						takeFault(key, roundTrip(if stored[key] then serde.decode("json", stored[key]) else {}), value)
					if fault and fault.kind == "error" then
						error("502: injected DataStore error")
					end
				end
				stored[key] = serde.encode("json", value)
				cluster.writes += 1
				if fault and fault.kind == "hold" and fault.phase == "after" then
					waitForGate(fault)
				end
				if server.killed then
					park()
				end
				if fault and fault.kind == "lost" then
					error("injected: the write committed but its response was lost")
				end
				return serde.decode("json", stored[key]), keyInfo()
			end
			function dataStore.GetAsync(_, key: string)
				api()
				if stored[key] == nil then
					return nil, nil
				end
				return serde.decode("json", stored[key]), keyInfo()
			end
			function dataStore.SetAsync(_, key: string, value: any)
				api()
				stored[key] = serde.encode("json", value)
			end
			dataStores[storeName] = dataStore
			return dataStore
		end

		local MessagingService = {}
		function MessagingService.SubscribeAsync(_, topic: string, callback)
			cluster.topics[topic] = cluster.topics[topic] or {}
			local subscription = { server = server, callback = callback }
			cluster.topics[topic][subscription] = true
			function subscription.Disconnect()
				cluster.topics[topic][subscription] = nil
			end
			return subscription
		end
		function MessagingService.PublishAsync(_, topic: string, data: any)
			api()
			for subscription in table.clone(cluster.topics[topic] or {}) do
				if not subscription.server.killed then
					task.spawn(subscription.callback, { Data = roundTrip(data), Sent = os.time() })
				end
			end
		end

		local HttpService = {}
		function HttpService.GenerateGUID()
			cluster.guids += 1
			return `guid-{cluster.guids}`
		end

		local RunService = { Heartbeat = Runtime.signal() }
		function RunService.IsStudio()
			return false
		end

		local osShim = table.clone(os)
		osShim.clock = function()
			return os.clock() + server.clockOffset
		end
		osShim.time = function(...)
			return os.time(...) + server.timeOffset
		end

		local services = {
			DataStoreService = DataStoreService,
			MessagingService = MessagingService,
			HttpService = HttpService,
			RunService = RunService,
		}
		local game = {
			PlaceId = 1,
			JobId = name,
			GetService = function(_, serviceName)
				return assert(services[serviceName], `Unexpected service {serviceName}`)
			end,
			BindToClose = function(_, callback)
				table.insert(server.closeCallbacks, callback)
			end,
		}
		server.ProfileStore = luau.load(source, {
			debugName = SOURCE,
			injectGlobals = true,
			environment = {
				script = { Name = "ProfileStore" },
				game = game,
				task = task,
				os = osShim,
				Instance = {
					new = function(className)
						assert(className == "DataStoreOptions", `Unexpected instance {className}`)
						return { SetExperimentalFeatures = function() end }
					end,
				},
				warn = function(message)
					table.insert(server.warnings, message)
				end,
				print = function() end,
			},
		})()

		local world = Runtime.new { jobId = name }
		world.clock = osShim.clock
		server.world = world
		server.library = world.load(world.root)

		--- Queues a fault for the next UpdateAsync on `key` (any key when nil). Kinds: "error" fails before
		--- the write; "lost" commits, then fails; "hold" blocks before or after the commit until `open()`.
		--- `match(stored, written)` limits an "error" or "lost" fault to the calls it accepts.
		function server.fault(
			_,
			key: string?,
			kind: string,
			options: { count: number?, phase: string?, match: ((any, any) -> boolean)? }?
		)
			local fault = {
				key = key,
				kind = kind,
				remaining = options and options.count or 1,
				phase = options and options.phase or "after",
				match = options and options.match,
				opened = false,
			}
			function fault.open()
				fault.opened = true
			end
			function fault.clear()
				local index = table.find(server.faults, fault)
				if index then
					table.remove(server.faults, index)
				end
			end
			table.insert(server.faults, fault)
			return fault
		end

		function server.player(_, userId: number)
			return world:player(userId)
		end

		--- Unparents the Player and fires PlayerRemoving, as deferred signal behaviour does.
		function server.leave(_, player: any)
			player.Parent = nil
			world.players.PlayerRemoving:Fire(player)
		end

		--- Moves this server's clocks; `seconds` of os.time also lets it treat older locks as dead.
		function server.advance(_, seconds: number, timeSeconds: number?)
			server.clockOffset += seconds
			server.timeOffset += timeSeconds or seconds
		end

		function server.heartbeat()
			RunService.Heartbeat:Fire()
		end

		--- Runs ProfileStore's BindToClose handler to completion.
		function server.shutdown()
			local remaining = #server.closeCallbacks
			for _, callback in server.closeCallbacks do
				task.spawn(function()
					callback()
					remaining -= 1
				end)
			end
			while remaining > 0 do
				task.wait()
			end
		end

		--- Stops the server between API calls: nothing it has in flight commits after this.
		function server.kill()
			server.killed = true
			-- Lets PlayerStore's polling loops reach their deadlines instead of keeping Lune alive.
			server.clockOffset += 1e6
		end

		return server
	end

	function cluster.destroy()
		for _, server in cluster.servers do
			server:kill()
		end
	end

	return cluster
end

return Cluster
