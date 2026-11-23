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

	t:test("wipeData keeps both mailbox roots", function()
		local world, store, player = fakeStore(nil, MAILBOX)
		t:expect(store:loadAsync(player))
		t:expect(store:trySetMany(player, {
			{ path = "Coins", value = 5 },
			{ path = "MailInbox/gift:1", value = 1 },
			store:outboxUpdate { to = 2, kind = "gift", id = "gift:2" },
		}))
		store:wipeData(player)
		local data = world.profiles[1].Data
		t:expectEqual(data.Coins, 0)
		t:expectEqual(data.MailInbox["gift:1"], 1)
		t:expectNotNil(data.MailOutbox["gift:2"])
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

	t:run()
end
