local task = require("@lune/task")

local MAILBOX = { inbox = "MailInbox", outbox = "MailOutbox" }

local function transferSchema(library)
	return library.schema {
		Coins = 0,
		Receipts = library.private(library.map {}),
		MailInbox = library.private(library.map {}),
		MailOutbox = library.private(library.map {}),
	}
end

local function receipt(id: string)
	return function(data)
		return data.Receipts[id] == true
	end
end

local function gift(_player, data, body)
	return { updates = { { path = "Coins", value = data.Coins + body.amount } } }
end

return function(Runtime, TestRunner)
	local Cluster = require("../support/Cluster")
	local t = TestRunner.new("Transfers: save confirmation, release and messages")

	local function fakeStore(schemaFactory, mailbox)
		local world = Runtime.new()
		local library = world.load(world.root)
		local store = library.createServerStore {
			schema = (schemaFactory or transferSchema)(library),
			storeId = "Unit",
			profileStore = world.ProfileStore,
			mailbox = mailbox,
		}
		return world, store, world:player(1), library
	end

	t:test("mailbox roots must be distinct private maps declared in the schema", function()
		local world = Runtime.new()
		local library = world.load(world.root)
		local function create(definition, mailbox)
			return library.createServerStore {
				schema = library.schema(definition),
				storeId = "Unit",
				profileStore = world.ProfileStore,
				mailbox = mailbox,
			}
		end
		local private = library.private(library.map {})
		t:expectError(function()
			create({ MailInbox = library.map {}, MailOutbox = private }, MAILBOX)
		end, "a public map is refused")
		t:expectError(function()
			create({ MailInbox = library.private {}, MailOutbox = private }, MAILBOX)
		end, "a private fixed table is refused")
		t:expectError(function()
			create({ MailInbox = private }, MAILBOX)
		end, "an undeclared root is refused")
		t:expectError(function()
			create({ MailInbox = private }, { inbox = "MailInbox", outbox = "MailInbox" })
		end, "one root cannot be both")
		create({ MailInbox = private, MailOutbox = library.private(library.map {}) }, MAILBOX):Destroy()
	end)

	t:test("without a mailbox the message API is refused and no handler is registered", function()
		local world, store, player = fakeStore()
		t:expectError(function()
			store:onMessage("gift", gift)
		end)
		t:expectError(function()
			store:outboxUpdate { to = 2, kind = "gift", id = "gift:1" }
		end)
		t:expect(store:loadAsync(player))
		t:expectEqual(#world.profiles[1].messageHandlers, 0)
		store:Destroy()
	end)

	t:test("outboxUpdate builds one private write and checks the envelope", function()
		local _, store = fakeStore(nil, MAILBOX)
		local update = store:outboxUpdate { to = 2, kind = "gift", id = "gift:1", body = { amount = 1 } }
		t:expectEqual(update.path, "MailOutbox/gift:1")
		t:expectEqual(update.value.to, 2)
		t:expectEqual(update.value.kind, "gift")
		t:expectEqual(update.value.body.amount, 1)
		local invalid = {
			{ to = 2, kind = "gift", id = "a/b" },
			{ to = 2, kind = "gift", id = "" },
			{ to = 1.5, kind = "gift", id = "gift:1" },
			{ to = 2, kind = "", id = "gift:1" },
		}
		for _, message in invalid do
			t:expectError(function()
				store:outboxUpdate(message)
			end, message.id)
		end
		t:expectError(function()
			store:onMessage("gift", gift)
			store:onMessage("gift", gift)
		end, "one handler per kind")
		store:Destroy()
	end)

	t:test("wipeData keeps both mailbox roots and the roots it is asked to keep", function()
		local world, store, player = fakeStore(nil, MAILBOX)
		t:expect(store:loadAsync(player))
		t:expect(store:trySetMany(player, {
			{ path = "Coins", value = 5 },
			{ path = "MailInbox/gift:1", value = 1 },
			store:outboxUpdate { to = 2, kind = "gift", id = "gift:2" },
		}))
		t:expect(store:trySet(player, "Receipts/r1", true))
		t:expectError(function()
			store:wipeData(player, { "Unknown" })
		end, "only schema roots can be kept")
		store:wipeData(player, { "Receipts" })
		local data = world.profiles[1].Data
		t:expectEqual(data.Coins, 0)
		t:expectEqual(data.MailInbox["gift:1"], 1)
		t:expectNotNil(data.MailOutbox["gift:2"])
		t:expectEqual(data.Receipts.r1, true, "a kept root survives")
		store:Destroy()
	end)

	t:test("a replacement load waits until the release write lands", function()
		local world, store, old = fakeStore()
		t:expect(store:loadAsync(old))
		t:expect(store:trySet(old, "Coins", 5))
		local released
		world.finalSaveHook = function(profile)
			released = profile
		end
		store:unloadAsync(old)
		local player = world:player(1)
		local loaded
		task.spawn(function()
			loaded = store:loadAsync(player)
		end)
		task.wait(0.1)
		t:expectNil(loaded, "must not start a session while the final write is pending")
		t:expectEqual(world.starts, 1)
		released:completeSave()
		task.wait(0.1)
		t:expectEqual(loaded, true)
		t:expectNotNil(released.LastSavedData._ReleaseToken, "the final save carries the release token")
		store:Destroy()
	end)

	t:test("save confirmation follows the release save and reports how it ended", function()
		for _, case in { "landed", "not in final save", "lost" } do
			local world, store, player = fakeStore()
			t:expect(store:loadAsync(player))
			t:expect(store:trySet(player, "Receipts/r1", true))
			local profile = world.profiles[1]
			local result
			task.spawn(function()
				result =
					table.pack(store:confirmSavedAsync(player, receipt(if case == "landed" then "r1" else "r2"), 1))
			end)
			if case == "lost" then
				-- A steal: the session ends without a final save of ours.
				profile.active = false
				profile.OnSessionEnd:Fire()
			else
				player.Parent = nil
				store:unloadAsync(player)
			end
			task.wait(0.1)
			t:expectNotNil(result, case)
			if case == "landed" then
				t:expectEqual(result[1], true, case)
			elseif case == "not in final save" then
				t:expectEqual(result[2], "Not in final save", case)
			else
				t:expectEqual(result[2], "Session lost", case)
			end
			store:Destroy()
		end
	end)

	t:test("save confirmation asks again when a save never answers", function()
		local world, store, player = fakeStore()
		local elapsed = 0
		world.clock = function()
			return elapsed
		end
		t:expect(store:loadAsync(player))
		t:expect(store:trySet(player, "Receipts/r1", true))
		local result
		task.spawn(function()
			result = store:confirmSavedAsync(player, receipt("r1"))
		end)
		task.wait() -- The confirmation's save is coalesced to the end of the frame.
		local profile = world.profiles[1]
		t:expectEqual(profile.saves, 1)
		elapsed = 4.9
		task.wait(0.1)
		t:expectEqual(profile.saves, 1, "waits before asking again")
		elapsed = 5
		task.wait(0.1)
		t:expectEqual(profile.saves, 2)
		profile:completeSave()
		task.wait(0.1)
		t:expectEqual(result, true)
		store:Destroy()
	end)

	if not Cluster.available() then
		print("\n[TestRunner] Real ProfileStore scenarios skipped: run `pesde install --locked` to include them.")
		t:run()
		return
	end

	local cluster

	local function boot(name: string, options: { mailbox: boolean?, timeOffset: number? }?)
		local server = cluster:server(name)
		if options and options.timeOffset then
			-- Far enough ahead that ProfileStore treats other servers' locks as dead and takes them at once.
			server:advance(0, options.timeOffset)
		end
		local library = server.library
		local store = library.createServerStore {
			schema = transferSchema(library),
			storeId = "Transfers",
			profileStore = server.ProfileStore,
			mailbox = if options and options.mailbox == false then nil else MAILBOX,
		}
		return server, store
	end

	local function scenario(name: string, fn: () -> ())
		t:test(name, function()
			cluster = Cluster.new(Runtime)
			local ok, err = pcall(fn)
			cluster:destroy()
			if not ok then
				error(err, 0)
			end
		end)
	end

	local function waitFor(condition: () -> boolean, message: string, timeout: number?)
		local deadline = os.clock() + (timeout or 5)
		while not condition() do
			if os.clock() >= deadline then
				error(`Timed out: {message}`, 2)
			end
			task.wait()
		end
	end

	local function spawnCall(fn, ...)
		local box = { done = false }
		local args = table.pack(...)
		task.spawn(function()
			box.result = table.pack(fn(table.unpack(args, 1, args.n)))
			box.done = true
		end)
		return box
	end

	local function send(store, player, to: number, id: string, kind: string?, amount: number?)
		local ok, err = store:trySetMany(player, {
			store:outboxUpdate { to = to, kind = kind or "gift", id = id, body = { amount = amount or 1 } },
		})
		t:expect(ok, err)
		t:expect(store:confirmSavedAsync(player, function(data)
			return data.MailOutbox[id] ~= nil
		end))
	end

	--- Matches the write that clears the session lock: a release.
	local function isFinalSave(stored, written): boolean
		return stored.MetaData ~= nil and stored.MetaData.ActiveSession ~= nil and written.MetaData.ActiveSession == nil
	end

	local function released(store, userId: number): () -> boolean
		return function()
			return store._releasing[userId] == nil and cluster:read(`{userId}`).MetaData.ActiveSession == nil
		end
	end

	-- Save confirmation ---------------------------------------------------------

	scenario("confirmation follows the release save when the Player leaves mid-confirm", function()
		local server, store = boot("A")
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		t:expect(store:trySet(player, "Receipts/r1", true))
		server:fault("1", "error") -- The confirmation's own save fails; only the release can land the marker.
		local finalSave = server:fault("1", "hold", { phase = "before" })
		local call = spawnCall(store.confirmSavedAsync, store, player, receipt("r1"))
		task.wait(0.1)
		server:leave(player)
		store:unloadAsync(player)
		task.wait(0.2)
		t:expect(not call.done, "still waiting while the final save is in flight")
		finalSave.open()
		waitFor(function()
			return call.done
		end, "confirmation")
		t:expectEqual(call.result[1], true, tostring(call.result[2]))
		t:expectEqual(cluster:read("1").Data.Receipts.r1, true)
	end)

	scenario("confirmation keeps waiting while an unparented Player's session saves", function()
		local server, store = boot("A")
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		t:expect(store:trySet(player, "Receipts/r1", true))
		local save = server:fault("1", "hold", { phase = "before" })
		local call = spawnCall(store.confirmSavedAsync, store, player, receipt("r1"))
		player.Parent = nil -- Deferred PlayerRemoving: the game has not unloaded yet.
		task.wait(0.2)
		save.open()
		waitFor(function()
			return call.done
		end, "confirmation")
		t:expectEqual(call.result[1], true, tostring(call.result[2]))
	end)

	scenario("confirmation asks for another save after a failed one", function()
		local server, store = boot("A")
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		t:expect(store:trySet(player, "Receipts/r1", true))
		server:fault("1", "error")
		local call = spawnCall(store.confirmSavedAsync, store, player, receipt("r1"), 30)
		task.wait(0.2)
		t:expect(not call.done, "the failed save fires nothing")
		server:advance(5)
		waitFor(function()
			return call.done
		end, "confirmation")
		t:expectEqual(call.result[1], true, tostring(call.result[2]))
	end)

	scenario("confirmation reports a session stolen by another server", function()
		local serverA, storeA = boot("A")
		local serverB, storeB = boot("B", { timeOffset = 700 })
		local player = serverA:player(1)
		t:expect(storeA:loadAsync(player))
		t:expect(storeA:trySet(player, "Receipts/r1", true))
		t:expect(storeB:loadAsync(serverB:player(1)), "B takes the lock")
		local started = os.clock()
		local ok, err = storeA:confirmSavedAsync(player, receipt("r1"), 10)
		t:expect(not ok)
		t:expectEqual(err, "Session lost")
		t:expect(os.clock() - started < 2, "returns at the steal, not the deadline")
		t:expectNil(cluster:read("1").Data.Receipts.r1, "A's write never lands")
	end)

	scenario("confirmation reports a final save without the marker", function()
		local server, store = boot("A")
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		local call = spawnCall(store.confirmSavedAsync, store, player, receipt("never"), 10)
		task.wait(0.1)
		server:leave(player)
		store:unloadAsync(player)
		waitFor(function()
			return call.done
		end, "confirmation")
		t:expectEqual(call.result[2], "Not in final save")
	end)

	scenario("a timed-out confirmation is not proof the write is missing", function()
		local server, store = boot("A")
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		t:expect(store:trySet(player, "Receipts/r1", true))
		server:fault("1", "error", { count = 2 }) -- The confirmation's save, then the final save's first try.
		local call = spawnCall(store.confirmSavedAsync, store, player, receipt("r1"), 0.5)
		task.wait(0.1)
		server:leave(player)
		store:unloadAsync(player)
		waitFor(function()
			return call.done
		end, "confirmation")
		t:expectEqual(call.result[2], "Save confirmation timed out")
		waitFor(function()
			return cluster:read("1").Data.Receipts.r1 == true
		end, "the release write lands after the timeout")
	end)

	-- Release -------------------------------------------------------------------

	scenario("a same-server rejoin waits out a failing final save instead of discarding it", function()
		local server, store = boot("A")
		local old = server:player(1)
		t:expect(store:loadAsync(old))
		t:expect(store:trySet(old, "Coins", 5))
		server:fault("1", "error")
		server:leave(old)
		store:unloadAsync(old)
		local player = server:player(1)
		local call = spawnCall(store.loadAsync, store, player)
		task.wait(0.3)
		t:expect(not call.done, "the new session waits for the release")
		waitFor(function()
			return call.done
		end, "load", 5)
		t:expectEqual(call.result[1], true)
		t:expectEqual(store:getData(player).Coins, 5, "the old session's last write survives")
	end)

	scenario("a release that never lands fails the replacement load at the deadline", function()
		local server, store = boot("A")
		local old = server:player(1)
		t:expect(store:loadAsync(old))
		server:fault("1", "error", { count = math.huge, match = isFinalSave })
		server:leave(old)
		store:unloadAsync(old)
		local player = server:player(1)
		local call = spawnCall(store.loadAsync, store, player)
		task.wait(0.2)
		t:expect(not call.done)
		server:advance(120)
		waitFor(function()
			return call.done
		end, "load")
		t:expectEqual(call.result[1], false)
		t:expectNotNil(player.kicked)
		local meta = cluster:read("1").MetaData
		t:expectEqual(meta.SessionLoadCount, 1, "no newer session took the lock from the retrying save")
		t:expectEqual(meta.ActiveSession[2], "A")
	end)

	scenario("an earlier save answering after the release starts does not end the hold", function()
		local server, store = boot("A")
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		t:expect(store:trySet(player, "Coins", 1))
		local held = server:fault("1", "hold", { phase = "after" }) -- Commits, answers late.
		server:fault("1", "error") -- The final save's first attempt.
		spawnCall(store.confirmSavedAsync, store, player, function(data)
			return data.Coins == 1
		end)
		task.wait(0.1)
		server:leave(player)
		store:unloadAsync(player)
		held.open()
		task.wait(0.3)
		t:expectNotNil(store._releasing[1], "a save without this release's token is not the release")
		waitFor(released(store, 1), "release", 5)
		t:expectNotNil(cluster:read("1").Data._ReleaseToken)
	end)

	scenario("a release answered with another server's data ends its hold when the next load reads the key", function()
		local serverA, storeA = boot("A")
		local old = serverA:player(1)
		t:expect(storeA:loadAsync(old))
		local lost = serverA:fault("1", "lost", { match = isFinalSave }) -- The final save commits; its answer is lost.
		serverA:leave(old)
		storeA:unloadAsync(old)
		waitFor(function()
			return table.find(serverA.faults, lost) == nil
		end, "the final save commits")
		local retry = serverA:fault("1", "hold", { phase = "before" })
		-- Another server loads and releases before the retry, which then writes nothing and answers with its data.
		local serverB, storeB = boot("B")
		local other = serverB:player(1)
		t:expect(storeB:loadAsync(other))
		t:expect(storeB:trySet(other, "Coins", 7))
		serverB:leave(other)
		storeB:unloadAsync(other)
		waitFor(released(storeB, 1), "B's release")
		retry.open()
		waitFor(function()
			return table.find(serverA.faults, retry) == nil
		end, "A's retry")
		task.wait(0.2)
		t:expectNotNil(storeA._releasing[1], "no token of ours ever lands")
		local player = serverA:player(1)
		local call = spawnCall(storeA.loadAsync, storeA, player)
		task.wait(0.2)
		t:expect(not call.done, "the load waits on the hold")
		serverA:advance(5)
		waitFor(function()
			return call.done
		end, "the read of the key ends the hold")
		t:expectEqual(call.result[1], true)
		t:expectEqual(storeA:getData(player).Coins, 7)
	end)

	-- Messages ------------------------------------------------------------------

	scenario("an outbox entry is sent once it is saved, then deleted", function()
		local server, store = boot("A")
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		t:expect(store:trySet(player, "Coins", 1))
		local held = server:fault("1", "hold", { phase = "after" })
		local earlier = spawnCall(store.confirmSavedAsync, store, player, function(data)
			return data.Coins == 1
		end)
		task.wait(0.1)
		-- Written after that save's transform ran, so its OnAfterSave arrives without the entry.
		t:expect(store:trySetMany(player, { store:outboxUpdate { to = 2, kind = "gift", id = "gift:1" } }))
		held.open()
		waitFor(function()
			return earlier.done
		end, "the earlier save answers")
		task.wait(0.2)
		t:expectEqual(#cluster:queue("2"), 0, "an unsaved decision is never sent")
		t:expect(store:confirmSavedAsync(player, function(data)
			return data.MailOutbox["gift:1"] ~= nil
		end))
		waitFor(function()
			return #cluster:queue("2") == 1
		end, "send")
		waitFor(function()
			return store:getData(player).MailOutbox["gift:1"] == nil
		end, "delete after send")
		t:expect(store:confirmSavedAsync(player, function(data)
			return data.MailOutbox["gift:1"] == nil
		end))
		task.wait(0.2)
		t:expectEqual(#cluster:queue("2"), 1, "sent once")
	end)

	scenario("a sender whose release is refused after a steal never sends its unsaved entry", function()
		local serverA, storeA = boot("A")
		local player = serverA:player(1)
		t:expect(storeA:loadAsync(player))
		local profile = storeA._profiles[1]
		local outage = serverA:fault("1", "error", { count = math.huge, match = isFinalSave })
		t:expect(storeA:trySetMany(player, {
			{ path = "Receipts/P", value = true },
			storeA:outboxUpdate { to = 2, kind = "gift", id = "gift:P" },
		}))
		serverA:leave(player)
		storeA:unloadAsync(player)
		task.wait(0.2)
		-- The thief decides the same id afresh, for another recipient, and saves it.
		local serverB, storeB = boot("B", { timeOffset = 700 })
		local thief = serverB:player(1)
		t:expect(storeB:loadAsync(thief))
		t:expectNil(storeB:getData(thief).MailOutbox["gift:P"], "A's decision never landed")
		send(storeB, thief, 3, "gift:P")
		waitFor(function()
			return #cluster:queue("3") == 1
		end, "the thief sends its decision")
		outage.clear()
		waitFor(function()
			return profile.LastSavedData.MailOutbox["gift:P"] ~= nil
		end, "A's refused retry answers with the thief's data", 30)
		task.wait(0.3)
		t:expectEqual(#cluster:queue("2"), 0, "A's unsaved entry is not sent under the thief's saved id")
		t:expectEqual(#cluster:queue("3"), 1)
	end)

	scenario("an id rewritten while its send is in flight is kept and sent as its own write", function()
		local server, store = boot("A")
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		local inFlight = server:fault("2", "hold", { phase = "before" }) -- MessageAsync's append to user 2.
		send(store, player, 2, "gift:1")
		task.wait(0.2)
		t:expect(store:trySetMany(player, { store:outboxUpdate { to = 3, kind = "gift", id = "gift:1" } }))
		inFlight.open()
		waitFor(function()
			return #cluster:queue("2") == 1
		end, "the first write is sent")
		task.wait(0.2)
		t:expectEqual(store:getData(player).MailOutbox["gift:1"].to, 3, "the rewrite is not deleted unsent")
		t:expect(store:confirmSavedAsync(player, function(data)
			return data.MailOutbox["gift:1"] ~= nil and data.MailOutbox["gift:1"].to == 3
		end))
		waitFor(function()
			return #cluster:queue("3") == 1 and store:getData(player).MailOutbox["gift:1"] == nil
		end, "the rewrite is sent, then deleted")
	end)

	scenario("an entry refused while closing waits for the sender's next session", function()
		local serverA, storeA = boot("A")
		local player = serverA:player(1)
		t:expect(storeA:loadAsync(player))
		serverA.ProfileStore.IsClosing = true
		send(storeA, player, 2, "gift:1")
		task.wait(0.2)
		t:expectEqual(#cluster:queue("2"), 0)
		t:expectNotNil(storeA:getData(player).MailOutbox["gift:1"])
		serverA:leave(player)
		storeA:unloadAsync(player)
		waitFor(released(storeA, 1), "release")
		local serverB, storeB = boot("B")
		t:expect(storeB:loadAsync(serverB:player(1)))
		waitFor(function()
			return #cluster:queue("2") == 1
		end, "the next session sends it")
	end)

	scenario("a message to an offline player applies at load with its inbox mark in one save", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		send(storeA, sender, 2, "gift:1", "gift", 3)
		waitFor(function()
			return #cluster:queue("2") == 1
		end, "send")
		local serverB, storeB = boot("B")
		storeB:onMessage("gift", gift)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		t:expectEqual(storeB:getData(player).Coins, 3)
		t:expectNotNil(storeB:getData(player).MailInbox["gift:1"])
		waitFor(function()
			return #cluster:queue("2") == 0
		end, "the next save removes it")
		local saved = cluster:read("2").Data
		t:expectEqual(saved.Coins, 3)
		t:expectNotNil(saved.MailInbox["gift:1"])
	end)

	scenario("a duplicate from a lost MessageAsync response applies once", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		serverA:fault("2", "lost")
		send(storeA, sender, 2, "gift:1")
		waitFor(function()
			return #cluster:queue("2") == 2
		end, "MessageAsync retried a committed append")
		local serverB, storeB = boot("B")
		storeB:onMessage("gift", gift)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		waitFor(function()
			return #cluster:queue("2") == 0
		end, "both copies removed")
		t:expectEqual(storeB:getData(player).Coins, 1)
	end)

	scenario("a crash between applying and saving loses both, and the next session applies once", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		send(storeA, sender, 2, "gift:1")
		waitFor(function()
			return #cluster:queue("2") == 1
		end, "send")
		local serverB, storeB = boot("B")
		storeB:onMessage("gift", gift)
		t:expect(storeB:loadAsync(serverB:player(2)))
		serverB:kill()
		task.wait(0.2)
		t:expectEqual(cluster:read("2").Data.Coins, 0)
		t:expectEqual(#cluster:queue("2"), 1, "the message is still queued")
		local serverC, storeC = boot("C", { timeOffset = 700 })
		storeC:onMessage("gift", gift)
		local player = serverC:player(2)
		t:expect(storeC:loadAsync(player))
		t:expectEqual(storeC:getData(player).Coins, 1)
		waitFor(function()
			return #cluster:queue("2") == 0
		end, "removed")
		t:expectEqual(cluster:read("2").Data.Coins, 1)
	end)

	scenario("a deferred message applies on retryMessages, or in the next session", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		send(storeA, sender, 2, "gift:1")
		send(storeA, sender, 2, "gift:2")
		waitFor(function()
			return #cluster:queue("2") == 2
		end, "send")
		local ready = {}
		local serverB, storeB = boot("B")
		storeB:onMessage("gift", function(player, data, body, meta)
			if not ready[meta.id] then
				return nil, "not ready"
			end
			return gift(player, data, body)
		end)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		t:expectEqual(storeB:getData(player).Coins, 0)
		ready["gift:1"] = true
		storeB:retryMessages(player)
		t:expectEqual(storeB:getData(player).Coins, 1)
		serverB:leave(player)
		storeB:unloadAsync(player)
		waitFor(released(storeB, 2), "release")
		t:expectEqual(#cluster:queue("2"), 1, "the deferred message stays queued")
		ready["gift:2"] = true
		local rejoined = serverB:player(2)
		t:expect(storeB:loadAsync(rejoined))
		t:expectEqual(storeB:getData(rejoined).Coins, 2)
	end)

	scenario("a yielding handler is closed and its late result ignored", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		send(storeA, sender, 2, "gift:1")
		local serverB, storeB = boot("B")
		local late = false
		local disconnect = storeB:onMessage("gift", function()
			task.wait(0.05)
			late = true
			return { updates = { { path = "Coins", value = 99 } } }
		end)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		task.wait(0.2)
		t:expect(not late, "the closed handler never resumes")
		t:expectEqual(storeB:getData(player).Coins, 0)
		disconnect()
		storeB:onMessage("gift", gift)
		t:expectEqual(storeB:getData(player).Coins, 1, "registering a kind retries its deferred messages")
	end)

	scenario("unknown kinds and throwing handlers defer until a handler applies them", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		send(storeA, sender, 2, "gift:1")
		send(storeA, sender, 2, "boom:1", "boom")
		local serverB, storeB = boot("B")
		local disconnect = storeB:onMessage("boom", function()
			error("broken plan")
		end)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		t:expectEqual(storeB:getData(player).Coins, 0)
		storeB:onMessage("gift", gift)
		t:expectEqual(storeB:getData(player).Coins, 1)
		disconnect()
		storeB:onMessage("boom", gift)
		t:expectEqual(storeB:getData(player).Coins, 2)
		waitFor(function()
			return #cluster:queue("2") == 0
		end, "both removed")
	end)

	scenario("a handler that writes data itself, or returns no plan, consumes nothing", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		local modes = { "mutate", "missing", "false", "number" }
		for _, mode in modes do
			t:expect(storeA:trySetMany(sender, {
				storeA:outboxUpdate { to = 2, kind = "gift", id = `gift:{mode}`, body = { mode = mode, amount = 1 } },
			}))
		end
		t:expect(storeA:confirmSavedAsync(sender, function(data)
			return data.MailOutbox["gift:number"] ~= nil
		end))
		waitFor(function()
			return #cluster:queue("2") == #modes
		end, "send")
		local serverB, storeB = boot("B")
		local disconnect = storeB:onMessage("gift", function(_player, data, body)
			if body.mode == "mutate" then
				data.Coins += 50
				return nil, "not ready"
			elseif body.mode == "missing" then
				local plan = nil -- A planner that failed.
				return { updates = plan }
			elseif body.mode == "false" then
				return { updates = false }
			end
			return { updates = 123 }
		end)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		t:expectEqual(storeB:getData(player).Coins, 0)
		t:expectNil(next(storeB:getData(player).MailInbox), "nothing marked")
		disconnect()
		storeB:onMessage("gift", gift)
		t:expectEqual(storeB:getData(player).Coins, #modes, "each applies once its handler plans")
	end)

	scenario("a message that arrives as the Player leaves applies in the next session", function()
		local serverB, storeB = boot("B")
		storeB:onMessage("gift", gift)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		player.Parent = nil
		send(storeA, sender, 2, "gift:1")
		waitFor(function()
			return #cluster:queue("2") == 1
		end, "send")
		task.wait(0.3) -- B's publish-triggered save delivers it; the write fails while the Player is leaving.
		serverB.world.players.PlayerRemoving:Fire(player)
		storeB:unloadAsync(player)
		waitFor(released(storeB, 2), "release")
		t:expectEqual(cluster:read("2").Data.Coins, 0)
		t:expectEqual(#cluster:queue("2"), 1, "not processed")
		local rejoined = serverB:player(2)
		t:expect(storeB:loadAsync(rejoined))
		t:expectEqual(storeB:getData(rejoined).Coins, 1)
	end)

	scenario("a reply lands with the inbox mark and comes back once", function()
		local serverA, storeA = boot("A")
		storeA:onMessage("gift-return", gift)
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		local serverB, storeB = boot("B")
		storeB:onMessage("gift", function(_player, _data, body, meta)
			return { send = { { to = meta.from, kind = "gift-return", id = `gift-return:{meta.id}`, body = body } } }
		end)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		local replyWithMark
		storeB:observe(player):listen("MailInbox", function()
			replyWithMark = storeB:getData(player).MailOutbox["gift-return:gift:1"] ~= nil
		end)
		send(storeA, sender, 2, "gift:1", "gift", 2)
		waitFor(function()
			return storeA:getData(sender).Coins == 2
		end, "the return applies")
		t:expectEqual(replyWithMark, true, "the reply is in the same write as the inbox mark")
		t:expectEqual(storeB:getData(player).Coins, 0)
		waitFor(function()
			return #cluster:queue("1") == 0 and #cluster:queue("2") == 0
		end, "both queues drain")
		task.wait(0.2)
		t:expectEqual(storeA:getData(sender).Coins, 2, "applied once")
	end)

	scenario("a player can message themself", function()
		local server, store = boot("A")
		store:onMessage("gift", gift)
		local player = server:player(1)
		t:expect(store:loadAsync(player))
		send(store, player, 1, "gift:self")
		waitFor(function()
			return store:getData(player).Coins == 1
		end, "applied")
		waitFor(function()
			return #cluster:queue("1") == 0 and cluster:read("1").Data.MailOutbox["gift:self"] == nil
		end, "queue and outbox drain")
	end)

	scenario("a sender stolen after sending resends, and the receiver applies once", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		send(storeA, sender, 2, "gift:1")
		waitFor(function()
			return #cluster:queue("2") == 1
		end, "send")
		serverA:kill() -- The outbox delete never reaches a save.
		local serverC, storeC = boot("C", { timeOffset = 700 })
		t:expect(storeC:loadAsync(serverC:player(1)))
		waitFor(function()
			return #cluster:queue("2") == 2
		end, "the stealer resends its saved copy")
		local serverB, storeB = boot("B")
		storeB:onMessage("gift", gift)
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		t:expectEqual(storeB:getData(player).Coins, 1)
	end)

	scenario("a store without a mailbox leaves queued messages alone", function()
		local serverA, storeA = boot("A")
		local sender = serverA:player(1)
		t:expect(storeA:loadAsync(sender))
		send(storeA, sender, 2, "gift:1")
		waitFor(function()
			return #cluster:queue("2") == 1
		end, "send")
		local serverB, storeB = boot("B", { mailbox = false })
		local player = serverB:player(2)
		t:expect(storeB:loadAsync(player))
		t:expect(storeB:trySet(player, "Coins", 1))
		t:expect(storeB:confirmSavedAsync(player, function(data)
			return data.Coins == 1
		end))
		task.wait(0.2)
		t:expectEqual(#cluster:queue("2"), 1)
	end)

	t:run()
end
