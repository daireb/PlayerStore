local task = require("@lune/task")

return function(Runtime, TestRunner)
	local t = TestRunner.new("Persistence and ownership")
	local function setup(saved, migrations, schemaFactory)
		local world = Runtime.new()
		world.saved = saved
		local library = world.load(world.root)
		local player = world:player(1)
		local store = library.createServerStore {
			schema = if schemaFactory
				then schemaFactory(library)
				else library.schema { Count = 0, Added = 7, Private = library.private {} },
			storeId = "Unit",
			profileStore = world.ProfileStore,
			migrations = migrations,
		}
		return world, store, player
	end
	local function saved(version)
		return { _DataVersion = version, Count = 2, Private = {} }
	end
	local function seededMapSchema(library)
		return library.schema {
			Inventory = library.map { StarterItem = 1 },
			Progress = { Rewards = library.map { StarterReward = true }, Level = 1 },
			Private = library.private(library.map { StarterFlag = true }),
			Added = 7,
		}
	end
	local function waitForResults(results)
		local deadline = os.clock() + 1
		while results[1] == nil or results[2] == nil do
			t:expect(os.clock() < deadline, "concurrent loads did not finish")
			task.wait()
		end
	end

	t:test("migrations see saved shape, then missing defaults reconcile", function()
		local ran = false
		local world, store, player = setup(saved(0), {
			function(data)
				ran = true
				t:expectNil(data.Added, "migration must see pre-reconcile data")
				data.Count += 1
			end,
		})
		t:expect(store:loadAsync(player))
		t:expect(ran)
		t:expectEqual(store:getData(player).Count, 3)
		t:expectEqual(store:getData(player).Added, 7)
		t:expectEqual(world.profiles[1].Data._DataVersion, 1)
		store:Destroy()
	end)

	t:test("already-current profiles receive new defaults", function()
		local _, store, player = setup(saved(0))
		t:expect(store:loadAsync(player))
		t:expectEqual(store:getData(player).Added, 7)
		store:Destroy()
	end)

	for _, path in { "Inventory/StarterItem", "Progress/Rewards/StarterReward", "Private/StarterFlag" } do
		t:test(`reconciliation preserves deleted entry at {path}`, function()
			local _, store, player = setup({
				_DataVersion = 0,
				Inventory = {},
				Progress = { Rewards = {} },
				Private = {},
			}, nil, seededMapSchema)
			t:expect(store:loadAsync(player))
			t:expectNil(store:observe(player):get(path), "deleted map entry stays deleted")
			local data = store:getData(player)
			t:expectEqual(data.Progress.Level, 1, "ordinary nested defaults still reconcile")
			t:expectEqual(data.Added, 7, "ordinary root defaults still reconcile")
			store:Destroy()
		end)
	end

	t:test("reconciliation initializes entirely missing root and nested maps", function()
		local _, store, player = setup({ _DataVersion = 0, Progress = {} }, nil, seededMapSchema)
		t:expect(store:loadAsync(player))
		local data = store:getData(player)
		t:expectEqual(data.Inventory.StarterItem, 1)
		t:expectEqual(data.Progress.Rewards.StarterReward, true)
		t:expectEqual(data.Private.StarterFlag, true)
		t:expectEqual(data.Progress.Level, 1)
		t:expectEqual(data.Added, 7)
		store:Destroy()
	end)

	t:test("new profiles skip old migrations", function()
		local _, store, player = setup(nil, {
			function()
				error("new player ran old migration")
			end,
		})
		t:expect(store:loadAsync(player))
		t:expectEqual(store:getData(player).Count, 0)
		store:Destroy()
	end)

	t:test("failed yielding migration cannot leak into autosave or release", function()
		local world, store, player
		world, store, player = setup(saved(0), {
			function(data)
				data.Count = 999
				task.wait()
				world.profiles[1]:completeSave()
				error("migration failed")
			end,
		})
		t:expect(not store:loadAsync(player))
		t:expectEqual(world.profiles[1].LastSavedData.Count, 2)
		t:expectEqual(world.profiles[1].endedData.Count, 2)
		t:expectEqual(world.profiles[1].endedData._DataVersion, 0)
		store:Destroy()
	end)

	t:test("validation failure never installs migrated data", function()
		local world, store, player = setup(saved(0), {
			function(data)
				data.Count = "broken"
			end,
		})
		t:expect(not store:loadAsync(player))
		t:expectEqual(world.profiles[1].endedData.Count, 2)
		t:expectEqual(world.profiles[1].endedData._DataVersion, 0)
		store:Destroy()
	end)

	t:test("migration-created aliases cannot couple fixed fields to map writes", function()
		local _, store, player = setup({ _DataVersion = 0 }, {
			function(data)
				local shared = { Value = 2 }
				data.Fixed = shared
				data.Dynamic = shared
			end,
		}, function(library)
			return library.schema { Fixed = { Value = 0 }, Dynamic = library.map {} }
		end)
		t:expect(store:loadAsync(player))
		t:expect(store:trySet(player, "Dynamic/Value", "map value"))
		t:expectEqual(store:getData(player).Fixed.Value, 2, "map writes must not alter fixed fields")
		store:Destroy()
	end)

	for _, freezeRoot in { false, true } do
		t:test(`frozen migration output is reconciled and writable (root frozen: {freezeRoot})`, function()
			local _, store, player = setup(saved(0), {
				function(data)
					data.Fixed = table.freeze { Value = 2 }
					if freezeRoot then
						table.freeze(data)
					end
				end,
			}, function(library)
				return library.schema { Fixed = { Value = 0, Added = 7 } }
			end)
			t:expect(store:loadAsync(player))
			t:expectEqual(store:getData(player).Fixed.Added, 7)
			t:expect(store:trySet(player, "Fixed/Value", 3))
			t:expectEqual(store:getData(player).Fixed.Value, 3)
			store:Destroy()
		end)
	end

	t:test("cyclic migration output fails without replacing the saved profile", function()
		local world, store, player = setup(saved(0), {
			function(data)
				data.Count = 999
				data.Cycle = data
			end,
		})
		t:expect(not store:loadAsync(player))
		t:expectEqual(world.profiles[1].endedData.Count, 2)
		t:expectEqual(world.profiles[1].endedData._DataVersion, 0)
		t:expectNil(world.profiles[1].endedData.Cycle)
		store:Destroy()
	end)

	t:test("future and malformed versions fail without replacing saved data", function()
		for _, version in { 1, -2, 0.5, "invalid", math.huge } do
			local world, store, player = setup(saved(version))
			t:expect(not store:loadAsync(player), tostring(version))
			t:expectEqual(world.profiles[1].endedData._DataVersion, version)
			t:expectEqual(world.profiles[1].endedData.Count, 2)
			store:Destroy()
		end
	end)

	t:test("missing version retains legacy migration path", function()
		local _, store, player = setup(saved(nil), {
			function(data)
				data.Count += 10
			end,
		})
		t:expect(store:loadAsync(player))
		t:expectEqual(store:getData(player).Count, 12)
		store:Destroy()
	end)

	t:test("duplicate loads acquire one session", function()
		local world, store, player = setup()
		t:expect(store:loadAsync(player))
		store:loadAsync(player)
		t:expectEqual(world.starts, 1)
		t:expectNotNil(store:getData(player))
		store:Destroy()
	end)

	t:test("unload cancels an in-flight load without kicking", function()
		local world, store, player = setup()
		world.startHook = function()
			task.wait(0.03)
		end
		local result
		task.spawn(function()
			result = store:loadAsync(player)
		end)
		task.wait(0.005)
		store:unloadAsync(player)
		task.wait(0.04)
		t:expectEqual(result, false)
		t:expectNil(store:getData(player))
		t:expectNil(player.kicked)
		store:Destroy()
	end)

	t:test("stale end callback cannot clear replacement and manual release does not kick", function()
		local world, store, player = setup()
		world.deferSessionEnd = true
		t:expect(store:loadAsync(player))
		local first = world.profiles[1]
		store:unloadAsync(player)
		t:expectNil(player.kicked)
		t:expect(store:loadAsync(player))
		first.OnSessionEnd:Fire()
		t:expectNotNil(store:getData(player))
		t:expectNil(player.kicked)
		store:Destroy()
	end)

	t:test("inactive profiles refuse writes before session-end callback runs", function()
		local world, store, player = setup()
		world.deferSessionEnd = true
		store:loadAsync(player)
		local cached = store:observe(player)
		world.profiles[1].active = false
		local ok = store:trySet(player, "Count", 5)
		t:expect(not ok)
		t:expectNil(store:getData(player))
		t:expectNil(store:observe(player))
		t:expectError(function()
			cached:set("Count", 5)
		end)
		store:Destroy()
	end)

	t:test("waitForData terminates for leave and timeout", function()
		local _, store, player = setup()
		t:expectNil(store:waitForData(player, 0.005))
		player.Parent = nil
		t:expectNil(store:waitForData(player))
		store:Destroy()
	end)

	t:test("in-memory success is not save confirmation", function()
		local world, store, player = setup()
		store:loadAsync(player)
		t:expect(store:trySet(player, "Count", 5))
		local ok = store:confirmSavedAsync(player, function(data)
			return data.Count == 5
		end, 0.005)
		t:expect(not ok)
		t:expectEqual(world.profiles[1].LastSavedData.Count, 0)
		world.saveHook = function(profile)
			task.delay(0.005, function()
				profile:completeSave()
			end)
		end
		t:expect(store:confirmSavedAsync(player, function(data)
			return data.Count == 5
		end, 0.2))
		store:Destroy()
	end)

	t:test("already-saved predicate avoids redundant save", function()
		local world, store, player = setup()
		store:loadAsync(player)
		t:expect(store:confirmSavedAsync(player, function(data)
			return data.Count == 0
		end))
		t:expectEqual(world.profiles[1].saves, 0)
		store:Destroy()
	end)

	t:test("save confirmation stops on ownership loss and predicate errors", function()
		local world, store, player = setup()
		store:loadAsync(player)
		local ok = store:confirmSavedAsync(player, function()
			error("bad predicate")
		end, 0.01)
		t:expect(not ok)
		world.saveHook = function(profile)
			profile:EndSession()
		end
		ok = store:confirmSavedAsync(player, function()
			return false
		end, 0.2)
		t:expect(not ok)
		store:Destroy()
	end)

	t:test("Destroy releases profiles and is idempotent", function()
		local world, store, player = setup()
		store:loadAsync(player)
		store:Destroy()
		store:Destroy()
		t:expect(not world.profiles[1]:IsActive())
		t:expectNil(world.storage.__PlayerStore_Unit)
		t:expectNil(store:waitForData(player))
	end)

	t:test("concurrent loads share one acquisition", function()
		local world, store, player = setup()
		world.startHook = function()
			task.wait(0.02)
		end
		local first
		task.spawn(function()
			first = store:loadAsync(player)
		end)
		local second = store:loadAsync(player)
		t:expectEqual(first, true)
		t:expectEqual(second, true)
		t:expectEqual(world.starts, 1)
		store:Destroy()
	end)

	t:test("unload cancels both in-flight loads but allows a later new call", function()
		local world, store, player = setup()
		local acquisition
		world.startHook = function()
			acquisition = coroutine.running()
			coroutine.yield()
		end
		local results = {}
		local entered = 0
		for index = 1, 2 do
			task.spawn(function()
				entered += 1
				results[index] = store:loadAsync(player)
			end)
		end
		t:expectEqual(entered, 2, "both calls started before unload")
		t:expectEqual(world.starts, 1, "duplicate call waits for the first acquisition")
		store:unloadAsync(player)
		world.startHook = nil
		task.spawn(acquisition)
		waitForResults(results)
		t:expectEqual(results[1], false)
		t:expectEqual(results[2], false, "waiting duplicate must share cancellation")
		t:expectEqual(world.starts, 1, "cancelled duplicate must not acquire again")
		t:expectNil(store:getData(player))
		t:expectNil(player.kicked)
		t:expect(store:loadAsync(player), "a new call after cancellation may acquire")
		t:expectEqual(world.starts, 2)
		store:Destroy()
	end)

	t:test("a waiting duplicate shares acquisition failure without retrying", function()
		local world, store, player = setup()
		local acquisition
		world.startHook = function()
			acquisition = coroutine.running()
			coroutine.yield()
			error("injected acquisition failure")
		end
		local results = {}
		local entered = 0
		for index = 1, 2 do
			task.spawn(function()
				entered += 1
				results[index] = store:loadAsync(player)
			end)
		end
		t:expectEqual(entered, 2)
		t:expectEqual(world.starts, 1)
		world.startHook = nil
		task.spawn(acquisition)
		waitForResults(results)
		t:expectEqual(results[1], false)
		t:expectEqual(results[2], false, "waiting duplicate must share failure")
		t:expectEqual(world.starts, 1, "failed acquisition must not be silently retried")
		t:expectNil(store:getData(player))
		store:Destroy()
	end)

	t:test("unload cancels a replacement Player waiting behind the old Player", function()
		local world, store, old = setup()
		local player = world:player(old.UserId)
		local acquisition
		world.startHook = function()
			acquisition = coroutine.running()
			coroutine.yield()
		end
		local results = {}
		task.spawn(function()
			results[1] = store:loadAsync(old)
		end)
		old.Parent = nil
		world.players.PlayerRemoving:Fire(old)
		local entered = false
		task.spawn(function()
			entered = true
			results[2] = store:loadAsync(player)
		end)
		t:expect(entered, "replacement call started before unload")
		t:expectEqual(world.starts, 1, "replacement waits for the old acquisition")
		store:unloadAsync(player)
		world.startHook = nil
		task.spawn(acquisition)
		waitForResults(results)
		t:expectEqual(results[1], false)
		t:expectEqual(results[2], false, "queued replacement must be cancelled")
		t:expectEqual(world.starts, 1)
		t:expectNil(store:getData(player))
		t:expectNil(player.kicked)
		t:expect(store:loadAsync(player), "a later explicit call may acquire")
		t:expectEqual(world.starts, 2)
		store:Destroy()
	end)

	t:test("queued replacement duplicates share a failed acquisition", function()
		local world, store, old = setup()
		local player = world:player(old.UserId)
		local acquisition
		world.startHook = function()
			acquisition = coroutine.running()
			coroutine.yield()
		end
		local oldResult
		task.spawn(function()
			oldResult = store:loadAsync(old)
		end)
		old.Parent = nil
		world.players.PlayerRemoving:Fire(old)
		local results = {}
		local entered = 0
		for index = 1, 2 do
			task.spawn(function()
				entered += 1
				results[index] = store:loadAsync(player)
			end)
		end
		t:expectEqual(entered, 2, "both replacement calls started while the old acquisition was blocked")
		t:expectEqual(world.starts, 1)
		world.startHook = function()
			if world.starts == 2 then
				error("injected replacement acquisition failure")
			end
		end
		task.spawn(acquisition)
		waitForResults(results)
		t:expectEqual(oldResult, false)
		t:expectEqual(results[1], false)
		t:expectEqual(results[2], false, "queued duplicate must share the replacement failure")
		t:expectEqual(world.starts, 2, "only one replacement acquisition may start")
		t:expectNil(store:getData(player))
		store:Destroy()
	end)

	t:test("stale Player cannot cancel or unload a new Player sharing UserId", function()
		local world, store, old = setup()
		local player = world:player(old.UserId)
		world.startHook = function()
			task.wait(0.02)
		end
		local loaded
		task.spawn(function()
			loaded = store:loadAsync(player)
		end)
		task.wait(0.005)
		store:unloadAsync(old)
		world.players.PlayerRemoving:Fire(old)
		task.wait(0.03)
		t:expectEqual(loaded, true)
		store:unloadAsync(old)
		t:expectNotNil(store:getData(player))
		t:expectNil(store:getData(old))
		store:Destroy()
	end)

	t:test("invalid timeouts return promptly", function()
		local _, store, player = setup()
		store:loadAsync(player)
		for _, timeout in { math.huge, 0 / 0, -1 } do
			t:expectNil(store:waitForData(player, timeout))
			t:expect(not store:confirmSavedAsync(player, function()
				return false
			end, timeout))
		end
		store:Destroy()
	end)

	t:test("onSave disconnect and Destroy prevent callbacks after teardown", function()
		local world, store, player = setup()
		world.deferSessionEnd = true
		store:loadAsync(player)
		local calls = 0
		local disconnect = store:onSave(function()
			calls += 1
		end)
		local profile = world.profiles[1]
		profile.OnSave:Fire()
		t:expectEqual(calls, 1)
		disconnect()
		profile.OnSave:Fire()
		t:expectEqual(calls, 1)
		store:onSave(function()
			calls += 1
		end)
		store:Destroy()
		profile.OnSave:Fire()
		profile.OnSessionEnd:Fire()
		t:expectEqual(calls, 1)
		t:expectNil(player.kicked)
	end)

	t:test("cancelled yielding migrations never install candidate", function()
		for _, action in { "unload", "destroy", "end" } do
			local world, store, player
			world, store, player = setup(saved(0), {
				function(data)
					data.Count = 999
					task.delay(0.005, function()
						if action == "unload" then
							store:unloadAsync(player)
						elseif action == "destroy" then
							store:Destroy()
						else
							world.profiles[1]:EndSession()
						end
					end)
					task.wait(0.02)
				end,
			})
			t:expect(not store:loadAsync(player), action)
			t:expectEqual(world.profiles[1].Data.Count, 2, action)
			t:expectEqual(world.profiles[1].Data._DataVersion, 0, action)
			t:expectNil(store:getData(player), action)
			store:Destroy()
		end
	end)

	t:run()
end
