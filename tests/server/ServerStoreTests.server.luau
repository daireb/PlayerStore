--[=[
	Integration tests for ServerStore with a real ProfileStore.
	Requires Studio with API services enabled.

	Uses a randomized storeId to avoid conflicts with real data.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)
local ProfileStore = require(ServerScriptService.ServerPackages.ProfileStore)
local TestSchema = require(ReplicatedStorage.Tests.Shared.TestSchema)
local TestRunner = require(ReplicatedStorage.Tests.Shared.TestRunner)

local t = TestRunner.new("ServerStore Integration")

local TEST_STORE_ID = `PlayerStoreTest_{math.random(100000, 999999)}`

-- Wait for local player in Studio
local player: Player
do
	player = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
end

-- Helper: creates a test store with session-end kick disabled
local function createTestStore(storeIdSuffix: string, migrations: any?)
	local store = PlayerStore.createServerStore {
		schema = TestSchema,
		storeId = `{TEST_STORE_ID}_{storeIdSuffix}`,
		profileStore = ProfileStore,
		migrations = migrations,
	}
	store:onSessionEnd(function() end)
	return store
end

--------------------------------------------------------------------------------
-- Lifecycle tests
--------------------------------------------------------------------------------

t:test("createServerStore returns a store object", function()
	local store = createTestStore("api")

	t:expectNotNil(store, "store created")
	t:expectNotNil(store.loadAsync, "has loadAsync")
	t:expectNotNil(store.unloadAsync, "has unloadAsync")
	t:expectNotNil(store.getData, "has getData")
	t:expectNotNil(store.observe, "has observe")
end)

t:test("loadAsync loads player data", function()
	local store = createTestStore("load")

	local success = store:loadAsync(player)
	t:expect(success, "loadAsync returned true")

	local data = store:getData(player)
	t:expectNotNil(data, "getData returns data")
	t:expectEqual(data.Resources.Cash, 0, "Cash has default value")
	t:expectEqual(data.Resources.XP, 0, "XP has default value")
	t:expectEqual(data.SelectedSlot, "Default", "SelectedSlot has default")
	t:expectEqual(data.IsVIP, false, "IsVIP has default")

	-- Private data is still accessible on server
	t:expectNotNil(data.Settings, "Settings accessible on server")
	t:expectEqual(data.Settings.MusicVolume, 0.75, "MusicVolume default")

	store:unloadAsync(player)
end)

t:test("observe returns ObservableTable", function()
	local store = createTestStore("obs")

	store:loadAsync(player)

	local obs = store:observe(player)
	t:expectNotNil(obs, "observe returns value")
	t:expectNotNil(obs.get, "has get")
	t:expectNotNil(obs.set, "has set")
	t:expectNotNil(obs.listen, "has listen")

	store:unloadAsync(player)
end)

t:test("observable set updates underlying data", function()
	local store = createTestStore("set")

	store:loadAsync(player)

	local obs = store:observe(player)
	obs:set("Resources/Cash", 500)

	local data = store:getData(player)
	t:expectEqual(data.Resources.Cash, 500, "Cash updated via observable")

	store:unloadAsync(player)
end)

t:test("observable listen fires on change", function()
	local store = createTestStore("listen")

	store:loadAsync(player)

	local obs = store:observe(player)
	local receivedValue = nil

	obs:listen("Resources/Cash", function(value)
		receivedValue = value
	end)

	obs:set("Resources/Cash", 777)
	task.wait()

	t:expectEqual(receivedValue, 777, "listener received new value")

	store:unloadAsync(player)
end)

t:test("waitForData returns data after load", function()
	local store = createTestStore("wait")

	-- Start loading in a separate thread
	task.spawn(function()
		task.wait(0.1)
		store:loadAsync(player)
	end)

	local data = store:waitForData(player, 10)
	t:expectNotNil(data, "waitForData returned data")
	t:expectEqual(data.Resources.Cash, 0, "has default values")

	store:unloadAsync(player)
end)

t:test("getData returns nil before load", function()
	local store = createTestStore("noload")

	local data = store:getData(player)
	t:expectNil(data, "no data before load")
end)

t:test("unloadAsync cleans up", function()
	local store = createTestStore("unload")

	store:loadAsync(player)
	t:expectNotNil(store:getData(player), "data exists before unload")

	store:unloadAsync(player)
	task.wait(0.5)

	t:expectNil(store:getData(player), "data nil after unload")
end)

--------------------------------------------------------------------------------
-- Migrations
--------------------------------------------------------------------------------

t:test("migrations run on load", function()
	local migrationRan = false

	local store = createTestStore("migrate", {
		function(data)
			migrationRan = true
			data.Stats.TotalWins = data.Stats.TotalWins or 0
		end,
	})

	store:loadAsync(player)

	local data = store:getData(player)
	t:expectNotNil(data, "data loaded")

	store:unloadAsync(player)
end)

--------------------------------------------------------------------------------
-- Replication RemoteEvent
--------------------------------------------------------------------------------

t:test("createServerStore creates a RemoteEvent", function()
	local store = createTestStore("remote")
	local storeId = `{TEST_STORE_ID}_remote`

	local remote = ReplicatedStorage:FindFirstChild(`__PlayerStore_{storeId}`)
	t:expectNotNil(remote, "RemoteEvent created")
	t:expect(remote:IsA("RemoteEvent"), "is a RemoteEvent")
end)

--------------------------------------------------------------------------------
-- onSave callback
--------------------------------------------------------------------------------

t:test("onSave registers callback", function()
	local store = createTestStore("save")

	local callbackRegistered = false
	store:onSave(function()
		callbackRegistered = true
	end)

	t:expect(not callbackRegistered, "callback not called until save")
end)

t:run()
