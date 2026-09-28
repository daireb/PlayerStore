-- Exercises the real stores with copied, queued remote messages.
return function(Runtime, TestRunner)
	local t = TestRunner.new("Replication protocol")

	local function setup()
		local world = Runtime.new()
		local library = world.load(world.root)
		local schema = library.schema {
			Cash = 0,
			Inventory = library.map {} :: { [string]: number },
			Secret = library.private { Token = "server only" },
		}
		local player = world:player(1)
		local server = library.createServerStore {
			schema = schema,
			storeId = "ReplicationTest",
			profileStore = world.ProfileStore,
		}
		local clientLibrary = world:loader(player)(world.root)
		local function makeClient()
			return clientLibrary.createClientStore { schema = schema, storeId = "ReplicationTest" }
		end
		return world, player, server, makeClient
	end

	local function messageCount(world, path)
		local count = 0
		for _, message in world.messages do
			if message.args[1] == path then
				count += 1
			end
		end
		return count
	end

	t:test("late client receives current public snapshot, excluding legacy and private keys", function()
		local world, player, server, makeClient = setup()
		world.saved = {
			Cash = 4,
			Inventory = { Sword = 1 },
			Secret = { Token = "sensitive" },
			LegacyExtra = "old data",
			_DataVersion = 0,
		}
		t:expect(server:loadAsync(player), "profile loaded")
		server:observe(player):set("Cash", 9)
		local client = makeClient()
		t:expect(not client:isLoaded(), "client waits for snapshot")
		world:flush()
		t:expect(client:waitUntilLoaded(0), "snapshot completed readiness")
		t:expectEqual(client:get("Cash"), 9, "late client sees latest write")
		t:expectEqual(client:get("Inventory/Sword"), 1, "public map copied")
		t:expectNil(client:get("Secret"), "private root omitted")
		t:expectNil(client:get("LegacyExtra"), "unknown legacy root omitted")
		t:expectNil(client:get("_DataVersion"), "version omitted")
		t:expectEqual(messageCount(world, ""), 1, "one snapshot sent")
		client:Destroy()
		server:Destroy()
	end)

	t:test("request before profile load is fulfilled when load completes", function()
		local world, player, server, makeClient = setup()
		local client = makeClient()
		world:flush() -- Deliver the request while no profile exists.
		t:expect(not client:isLoaded(), "no data yet")
		t:expectEqual(messageCount(world, ""), 0, "no default snapshot")
		t:expect(server:loadAsync(player), "profile loaded")
		world:flush()
		t:expect(client:isLoaded(), "pending request fulfilled")
		t:expectEqual(client:get("Cash"), 0, "loaded data delivered")
		t:expectEqual(messageCount(world, ""), 1, "one snapshot sent")
		client:Destroy()
		server:Destroy()
	end)

	t:test("deltas before initial root are ignored", function()
		local world, player, server, makeClient = setup()
		t:expect(server:loadAsync(player), "profile loaded")
		local client = makeClient()
		server._remoteEvent:FireClient(player, "Cash", 999)
		world:flush()
		t:expect(client:isLoaded(), "root arrived")
		t:expectEqual(client:get("Cash"), 0, "early delta did not replace snapshot")
		client:Destroy()
		server:Destroy()
	end)

	t:test("a root snapshot removes public keys absent from the new root", function()
		local world, player, server, makeClient = setup()
		t:expect(server:loadAsync(player), "profile loaded")
		server:observe(player):set("Inventory/Sword", 1)
		local client = makeClient()
		world:flush()
		t:expectEqual(client:get("Inventory/Sword"), 1, "initial map key present")
		server._remoteEvent:FireClient(player, "", { Cash = 0, Inventory = {} })
		world:flush()
		t:expectNil(client:get("Inventory/Sword"), "stale map key removed")
		client:Destroy()
		server:Destroy()
	end)

	t:test("batch replication filters private writes and remains atomic", function()
		local world, player, server, makeClient = setup()
		t:expect(server:loadAsync(player), "profile loaded")
		local client = makeClient()
		world:flush()
		local observedCash, observedInventory
		local disconnect = client:listen("Cash", function(value)
			observedCash = value
			observedInventory = client:get("Inventory/Sword")
		end)
		server:observe(player):setMany({
			{ path = "Cash", value = 20 },
			{ path = "Secret/Token", value = "changed" },
			{ path = "Inventory/Sword", value = 2 },
		})
		world:flush()
		local task = require("@lune/task")
		task.wait()
		t:expectEqual(client:get("Cash"), 20, "public scalar updated")
		t:expectEqual(client:get("Inventory/Sword"), 2, "public map updated")
		t:expectNil(client:get("Secret"), "private batch member omitted")
		t:expectEqual(observedCash, 20, "listener fired")
		t:expectEqual(observedInventory, 2, "listener saw complete batch")
		local batch = world.messages[#world.messages].args[1]
		t:expectEqual(#batch, 2, "only public updates sent")
		disconnect()
		client:Destroy()
		server:Destroy()
	end)

	t:test("a burst of repeated snapshot requests is coalesced", function()
		local world, player, server, makeClient = setup()
		t:expect(server:loadAsync(player), "profile loaded")
		local client = makeClient()
		world:flush()
		for _ = 1, 10 do
			server._remoteEvent.OnServerEvent:Fire(player, "snapshot")
		end
		server._remoteEvent.OnServerEvent:Fire(player, "unexpected")
		world:flush()
		t:expectEqual(messageCount(world, ""), 1, "burst did not send immediately")
		local task = require("@lune/task")
		local deadline = os.clock() + 2
		while messageCount(world, "") < 2 and os.clock() < deadline do
			task.wait(0.05)
			world:flush()
		end
		t:expectEqual(messageCount(world, ""), 2, "burst produced one later snapshot")
		client:Destroy()
		server:Destroy()
	end)

	t:test("client can recreate its store during the same profile session", function()
		local world, player, server, makeClient = setup()
		t:expect(server:loadAsync(player), "profile loaded")
		local first = makeClient()
		world:flush()
		t:expect(first:isLoaded(), "first client ready")
		first:Destroy()
		local second = makeClient()
		world:flush()
		local task = require("@lune/task")
		local deadline = os.clock() + 2
		while not second:isLoaded() and os.clock() < deadline do
			task.wait(0.05)
			world:flush()
		end
		t:expect(second:isLoaded(), "recreated client received its own snapshot")
		second:Destroy()
		server:Destroy()
	end)

	t:test("client wait times out and Destroy releases pending wait", function()
		local world, _player, server, makeClient = setup()
		local task = require("@lune/task")
		local client = makeClient()
		t:expectError(function()
			client:waitUntilLoaded(math.huge)
		end, "unbounded timeout rejected")
		t:expectError(function()
			client:waitUntilLoaded(-math.huge)
		end, "negative infinity timeout rejected")
		t:expect(not client:waitUntilLoaded(0.01), "bounded wait times out")
		local result = nil
		task.spawn(function()
			result = client:waitUntilLoaded(1)
		end)
		task.wait()
		client:Destroy()
		client:Destroy()
		task.wait(0.06)
		t:expectEqual(result, false, "Destroy woke pending waiter")
		t:expect(not client:isLoaded(), "destroyed store is not ready")
		t:expect(not client:waitUntilLoaded(0), "destroyed store wait fails")
		t:expectError(function()
			client:get("Cash")
		end, "destroyed store rejects reads")
		world:flush()
		server:Destroy()
	end)

	t:run()
end
