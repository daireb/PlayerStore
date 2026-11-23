local task = require("@lune/task")

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
