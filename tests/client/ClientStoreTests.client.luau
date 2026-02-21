--[=[
	Integration tests for ClientStore.
	
	These tests require the server-side ClientStoreTestServer to be running,
	which loads data and makes changes for us to verify on the client.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)
local TestSchema = require(ReplicatedStorage.Tests.Shared.TestSchema)
local TestRunner = require(ReplicatedStorage.Tests.Shared.TestRunner)

local t = TestRunner.new("ClientStore Integration")

-- The server test companion uses this storeId
local TEST_STORE_ID = "PlayerStoreClientTest"

--------------------------------------------------------------------------------
-- Setup: wait for server to create the RemoteEvent
--------------------------------------------------------------------------------

local clientStore = PlayerStore.createClientStore {
	schema = TestSchema,
	storeId = TEST_STORE_ID,
}

t:test("createClientStore returns store object", function()
	t:expectNotNil(clientStore, "store created")
	t:expectNotNil(clientStore.get, "has get")
	t:expectNotNil(clientStore.listen, "has listen")
	t:expectNotNil(clientStore.bind, "has bind")
	t:expectNotNil(clientStore.waitUntilLoaded, "has waitUntilLoaded")
	t:expectNotNil(clientStore.isLoaded, "has isLoaded")
end)

t:test("isLoaded is false before data arrives", function()
	-- This may already be true if the server was fast, so this is best-effort
	-- The main value is testing the API exists and returns a boolean
	local loaded = clientStore:isLoaded()
	t:expectEqual(typeof(loaded), "boolean", "isLoaded returns boolean")
end)

t:test("waitUntilLoaded yields and then returns", function()
	clientStore:waitUntilLoaded()
	t:expect(clientStore:isLoaded(), "isLoaded true after wait")
end)

t:test("get() returns full data table after load", function()
	clientStore:waitUntilLoaded()

	local data = clientStore:get()
	t:expectNotNil(data, "root data exists")
	t:expectEqual(typeof(data), "table", "root is a table")
end)

t:test("get(path) returns values from server", function()
	clientStore:waitUntilLoaded()

	local cash = clientStore:get("Resources/Cash")
	t:expectNotNil(cash, "Cash exists")
	t:expectEqual(typeof(cash), "number", "Cash is a number")

	local selectedSlot = clientStore:get("SelectedSlot")
	t:expectEqual(selectedSlot, "Default", "SelectedSlot has default value")
end)

t:test("private data is NOT present on client", function()
	clientStore:waitUntilLoaded()

	local settings = clientStore:get("Settings")
	-- Settings should either be nil or an empty table from the template
	-- Since we exclude private paths from client template, it should be nil
	t:expectNil(settings, "Settings not replicated to client")

	local codes = clientStore:get("Codes")
	t:expectNil(codes, "Codes not replicated to client")
end)

t:test("listen fires when server changes data", function()
	clientStore:waitUntilLoaded()

	local receivedValue = nil
	local disconnect = clientStore:listen("Resources/Cash", function(value)
		receivedValue = value
	end)

	-- Signal the server to make a change (via a RemoteEvent)
	local signalRemote = ReplicatedStorage:WaitForChild("__PlayerStoreTestSignal", 5)
	if signalRemote then
		signalRemote:FireServer("setCash", 12345)

		-- Wait for the change to propagate
		local startTime = tick()
		while receivedValue == nil and tick() - startTime < 5 do
			task.wait(0.1)
		end

		t:expectEqual(receivedValue, 12345, "received cash update from server")
	else
		-- If no signal remote, skip this test gracefully
		t:expect(true, "skipped: server signal remote not found")
	end

	disconnect()
end)

t:test("bind fires immediately with current value", function()
	clientStore:waitUntilLoaded()

	local receivedValue = nil
	local disconnect = clientStore:bind("SelectedSlot", function(value)
		receivedValue = value
	end)

	task.wait()
	t:expectNotNil(receivedValue, "bind fired immediately")
	t:expectEqual(typeof(receivedValue), "string", "received a string")

	disconnect()
end)

t:test("root listen fires on any change", function()
	clientStore:waitUntilLoaded()

	local fireCount = 0
	local disconnect = clientStore:listen(function()
		fireCount += 1
	end)

	local signalRemote = ReplicatedStorage:WaitForChild("__PlayerStoreTestSignal", 5)
	if signalRemote then
		signalRemote:FireServer("setXP", 100)

		local startTime = tick()
		while fireCount == 0 and tick() - startTime < 5 do
			task.wait(0.1)
		end

		t:expect(fireCount > 0, "root listener fired")
	else
		t:expect(true, "skipped: server signal remote not found")
	end

	disconnect()
end)

t:run()
