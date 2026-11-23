--[=[
	Engine integration for save confirmation through a release and for messages, on ProfileStore.Mock.
	Mock never fails, so this checks ProfileStore's real signals and message paths, not failures;
	Lune's tests/unit/Transfers.luau covers those against the same ProfileStore source.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)
local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local TestRunner = require(ReplicatedStorage.Tests.Shared.TestRunner)

local t = TestRunner.new("Transfers Integration")

local MockProfileStore = {
	New = function(storeId, template)
		return ProfileStore.New(storeId, template).Mock
	end,
}
local TEST_STORE_ID = `PlayerStoreTransfers_{math.random(100000, 999999)}`
--- A UserId with no session in these tests: messages to it stay queued.
local OFFLINE_USER = 1
local stores = {}

local TransferSchema = PlayerStore.schema {
	Coins = 0,
	Receipts = PlayerStore.private(PlayerStore.map {}),
	MailInbox = PlayerStore.private(PlayerStore.map {}),
	MailOutbox = PlayerStore.private(PlayerStore.map {}),
}

local player: Player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()

local function createStore(suffix: string)
	local storeId = `{TEST_STORE_ID}_{suffix}`
	local store = PlayerStore.createServerStore {
		schema = TransferSchema,
		storeId = storeId,
		profileStore = MockProfileStore,
		mailbox = { inbox = "MailInbox", outbox = "MailOutbox" },
	}
	store:onSessionEnd(function() end)
	table.insert(stores, store)
	return store, ProfileStore.New(storeId).Mock
end

local function gift(_player, data, body)
	return { updates = { { path = "Coins", value = data.Coins + body.amount } } }
end

local function envelope(id: string, amount: number)
	-- PlayerStore's queue format, written raw to test delivery without a second Player.
	return { v = 1, id = id, kind = "gift", from = OFFLINE_USER, body = { amount = amount } }
end

local function waitFor(message: string, condition: () -> boolean, timeout: number?)
	local deadline = os.clock() + (timeout or 5)
	while not condition() do
		t:expect(os.clock() < deadline, `timed out: {message}`)
		task.wait()
	end
end

local function reload(store)
	store:unloadAsync(player)
	return store:loadAsync(player)
end

t:test("confirmation follows unloadAsync to the final save, which carries the release token", function()
	local store = createStore("release")
	t:expect(store:loadAsync(player))
	t:expect(store:trySet(player, "Receipts/r1", true))
	local result
	task.spawn(function()
		result = table.pack(store:confirmSavedAsync(player, function(data)
			return data.Receipts.r1 == true
		end, 10))
	end)
	store:unloadAsync(player)
	waitFor("confirmation", function()
		return result ~= nil
	end, 10)
	t:expectEqual(result[1], true, tostring(result[2]))
	t:expect(store:loadAsync(player), "reload after the release landed")
	t:expectEqual(store:getData(player).Receipts.r1, true)
	t:expectEqual(typeof(store:getData(player)._ReleaseToken), "string")
	store:unloadAsync(player)
end)

t:test("a message queued while offline applies once at load and is gone after a reload", function()
	local store, mock = createStore("offline")
	store:onMessage("gift", gift)
	t:expect(mock:MessageAsync(tostring(player.UserId), envelope("gift:1", 2)))
	t:expect(store:loadAsync(player))
	t:expectEqual(store:getData(player).Coins, 2)
	t:expect(reload(store), "reload")
	t:expectEqual(store:getData(player).Coins, 2, "not applied again")
	store:unloadAsync(player)
end)

t:test("a message to a session on this server applies at once, and a resend of its id does not", function()
	local store, mock = createStore("live")
	store:onMessage("gift", gift)
	t:expect(store:loadAsync(player))
	t:expect(mock:MessageAsync(tostring(player.UserId), envelope("gift:1", 3)))
	waitFor("applied after the save MessageAsync requested", function()
		return store:getData(player).Coins == 3
	end)
	t:expect(reload(store), "reload")
	t:expect(mock:MessageAsync(tostring(player.UserId), envelope("gift:1", 3)))
	task.wait(1)
	t:expectEqual(store:getData(player).Coins, 3, "a resend of the same id is not applied")
	store:unloadAsync(player)
end)

t:test("a player messaging themself goes through the outbox, then the entry is deleted", function()
	local store = createStore("self")
	store:onMessage("gift", gift)
	t:expect(store:loadAsync(player))
	t:expect(store:trySetMany(player, {
		store:outboxUpdate { to = player.UserId, kind = "gift", id = "gift:self", body = { amount = 4 } },
	}))
	t:expect(store:confirmSavedAsync(player, function(data)
		return data.MailOutbox["gift:self"] ~= nil
	end, 10))
	waitFor("applied and deleted", function()
		local data = store:getData(player)
		return data.Coins == 4 and data.MailOutbox["gift:self"] == nil
	end)
	store:unloadAsync(player)
end)

t:test("a reply reaches its offline sender's queue", function()
	local store, mock = createStore("reply")
	store:onMessage("gift", function(_player, _data, body, meta)
		return { send = { { to = meta.from, kind = "gift-return", id = `gift-return:{meta.id}`, body = body } } }
	end)
	t:expect(mock:MessageAsync(tostring(player.UserId), envelope("gift:1", 5)))
	t:expect(store:loadAsync(player))
	t:expectNotNil(store:getData(player).MailInbox["gift:1"])
	local queued
	waitFor("the reply reaches the sender's queue", function()
		local view = mock:GetAsync(tostring(OFFLINE_USER))
		for _, update in if view then view.global_updates else {} do
			local message = update[#update]
			if message.id == "gift-return:gift:1" then
				queued = message
			end
		end
		return queued ~= nil
	end, 10)
	t:expectEqual(queued.kind, "gift-return")
	t:expectEqual(queued.from, player.UserId)
	t:expectEqual(queued.body.amount, 5)
	store:unloadAsync(player)
end)

local _, failed = t:run()
for _, store in stores do
	store:Destroy()
end
assert(failed == 0, "Transfers integration failed")
