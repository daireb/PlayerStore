--[=[
	Tests for ObservableTable.luau
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)
local ObservableTable = require(ReplicatedStorage.Packages.PlayerStore.ObservableTable)
local Validation = require(ReplicatedStorage.Packages.PlayerStore.Validation)
local TestRunner = require(ReplicatedStorage.Tests.Shared.TestRunner)

local t = TestRunner.new("ObservableTable")

--------------------------------------------------------------------------------
-- get()
--------------------------------------------------------------------------------

t:test("get() returns entire table when no path given", function()
	local data = { Cash = 100, Name = "Test" }
	local obs = ObservableTable.wrap(data)

	local result = obs:get()
	t:expectEqual(result, data, "returns same table reference")
end)

t:test("get(path) returns value at path", function()
	local obs = ObservableTable.wrap({ Resources = { Cash = 50, XP = 10 } })

	t:expectEqual(obs:get("Resources/Cash"), 50, "nested get")
	t:expectEqual(obs:get("Resources/XP"), 10, "nested get XP")
end)

t:test("get(path) returns nil for missing path", function()
	local obs = ObservableTable.wrap({ Cash = 0 })

	t:expectNil(obs:get("Missing"), "missing key")
	t:expectNil(obs:get("Missing/Deep"), "missing nested key")
end)

t:test("get(path) returns sub-table", function()
	local data = { Resources = { Cash = 50 } }
	local obs = ObservableTable.wrap(data)

	local resources = obs:get("Resources")
	t:expectEqual(resources, data.Resources, "returns sub-table reference")
end)

--------------------------------------------------------------------------------
-- set()
--------------------------------------------------------------------------------

t:test("set() updates value in underlying table", function()
	local data = { Cash = 0 }
	local obs = ObservableTable.wrap(data)

	obs:set("Cash", 100)
	t:expectEqual(data.Cash, 100, "underlying table updated")
end)

t:test("set() updates nested value", function()
	local data = { Resources = { Cash = 0 } }
	local obs = ObservableTable.wrap(data)

	obs:set("Resources/Cash", 999)
	t:expectEqual(data.Resources.Cash, 999, "nested value updated")
end)

t:test("set() errors on invalid path", function()
	local obs = ObservableTable.wrap({ Cash = 0 })

	t:expectError(function()
		obs:set("Missing/Deep", 1)
	end, "should error on invalid path")
end)

--------------------------------------------------------------------------------
-- listen()
--------------------------------------------------------------------------------

t:test("listen(path, callback) fires on set", function()
	local obs = ObservableTable.wrap({ Cash = 0 })
	local fired = false
	local receivedValue = nil

	obs:listen("Cash", function(value)
		fired = true
		receivedValue = value
	end)

	obs:set("Cash", 42)
	task.wait() -- Signal fires via task.spawn

	t:expect(fired, "listener fired")
	t:expectEqual(receivedValue, 42, "received correct value")
end)

t:test("listen(callback) fires on any change (root listener)", function()
	local obs = ObservableTable.wrap({ Cash = 0, XP = 0 })
	local fireCount = 0

	obs:listen(function()
		fireCount += 1
	end)

	obs:set("Cash", 10)
	task.wait()
	obs:set("XP", 5)
	task.wait()

	t:expectEqual(fireCount, 2, "root listener fired twice")
end)

t:test("listen() fires at ancestor paths", function()
	local obs = ObservableTable.wrap({ Resources = { Cash = 0 } })
	local rootFired = false
	local resourcesFired = false
	local cashFired = false

	obs:listen(function()
		rootFired = true
	end)
	obs:listen("Resources", function()
		resourcesFired = true
	end)
	obs:listen("Resources/Cash", function()
		cashFired = true
	end)

	obs:set("Resources/Cash", 100)
	task.wait()

	t:expect(rootFired, "root listener fired")
	t:expect(resourcesFired, "Resources listener fired")
	t:expect(cashFired, "Cash listener fired")
end)

t:test("listen() provides specific path and value", function()
	local obs = ObservableTable.wrap({ Resources = { Cash = 0 } })
	local capturedSpecificPath = nil
	local capturedSpecificValue = nil

	obs:listen("Resources", function(_value, _path, specificValue, specificPath)
		capturedSpecificPath = specificPath
		capturedSpecificValue = specificValue
	end)

	obs:set("Resources/Cash", 77)
	task.wait()

	t:expectEqual(capturedSpecificPath, "Resources/Cash", "specific path")
	t:expectEqual(capturedSpecificValue, 77, "specific value")
end)

t:test("disconnect function stops listener", function()
	local obs = ObservableTable.wrap({ Cash = 0 })
	local fireCount = 0

	local disconnect = obs:listen("Cash", function()
		fireCount += 1
	end)

	obs:set("Cash", 1)
	task.wait()
	t:expectEqual(fireCount, 1, "fired once")

	disconnect()

	obs:set("Cash", 2)
	task.wait()
	t:expectEqual(fireCount, 1, "did not fire after disconnect")
end)

--------------------------------------------------------------------------------
-- bind()
--------------------------------------------------------------------------------

t:test("bind(path, callback) fires immediately with current value", function()
	local obs = ObservableTable.wrap({ Cash = 42 })
	local receivedValue = nil

	obs:bind("Cash", function(value)
		receivedValue = value
	end)

	task.wait()
	t:expectEqual(receivedValue, 42, "bind fired immediately")
end)

t:test("bind(callback) fires immediately with root", function()
	local data = { Cash = 1 }
	local obs = ObservableTable.wrap(data)
	local receivedValue = nil

	obs:bind(function(value)
		receivedValue = value
	end)

	task.wait()
	t:expectEqual(receivedValue, data, "bind fired with root table")
end)

--------------------------------------------------------------------------------
-- applyUpdate()
--------------------------------------------------------------------------------

t:test("applyUpdate with root path merges data", function()
	local obs = ObservableTable.wrap({ Cash = 0, XP = 0 })

	obs:applyUpdate("", { Cash = 100, XP = 50 })

	t:expectEqual(obs:get("Cash"), 100, "Cash updated")
	t:expectEqual(obs:get("XP"), 50, "XP updated")
end)

t:test("applyUpdate with sub-path creates intermediates", function()
	local obs = ObservableTable.wrap({})

	obs:applyUpdate("Resources/Cash", 200)

	t:expectEqual(obs:get("Resources/Cash"), 200, "value set through new intermediates")
end)

t:test("applyUpdate fires listeners", function()
	local obs = ObservableTable.wrap({ Cash = 0 })
	local fired = false

	obs:listen("Cash", function()
		fired = true
	end)

	obs:applyUpdate("Cash", 50)
	task.wait()

	t:expect(fired, "listener fired on applyUpdate")
end)

t:test("applyUpdate root fires root listener", function()
	local obs = ObservableTable.wrap({ Cash = 0 })
	local fired = false

	obs:listen(function()
		fired = true
	end)

	obs:applyUpdate("", { Cash = 99 })
	task.wait()

	t:expect(fired, "root listener fired")
end)

t:test("applyUpdate root fires sub-path listeners", function()
	local obs = ObservableTable.wrap({ Resources = { Cash = 0, XP = 0 } })
	local cashFired = false
	local cashValue = nil
	local resourcesFired = false

	obs:listen("Resources/Cash", function(value)
		cashFired = true
		cashValue = value
	end)

	obs:listen("Resources", function()
		resourcesFired = true
	end)

	obs:applyUpdate("", { Resources = { Cash = 500, XP = 10 } })
	task.wait()

	t:expect(cashFired, "Cash listener fired on root applyUpdate")
	t:expectEqual(cashValue, 500, "Cash listener received correct value")
	t:expect(resourcesFired, "Resources listener fired on root applyUpdate")
end)

t:test("bind before root applyUpdate fires twice with updated value", function()
	local obs = ObservableTable.wrap({ Cash = 0 })
	local values = {}

	obs:bind("Cash", function(value)
		table.insert(values, value)
	end)

	task.wait()
	t:expectEqual(#values, 1, "bind fired once with default")
	t:expectEqual(values[1], 0, "first fire has default value")

	obs:applyUpdate("", { Cash = 999 })
	task.wait()

	t:expectEqual(#values, 2, "bind fired again after root applyUpdate")
	t:expectEqual(values[2], 999, "second fire has real value")
end)

--------------------------------------------------------------------------------
-- Destroy()
--------------------------------------------------------------------------------

t:test("Destroy cleans up", function()
	local obs = ObservableTable.wrap({ Cash = 0 })

	obs:listen("Cash", function() end)
	obs:Destroy()

	t:expectError(function()
		obs:get("Cash")
	end, "should error after destroy")
end)

--------------------------------------------------------------------------------
-- Validator
--------------------------------------------------------------------------------

t:test("validator rejects invalid writes", function()
	local obs = ObservableTable.wrap({ Cash = 0 }, function(path, value)
		if path == "Cash" and typeof(value) ~= "number" then
			return false, "Cash must be a number"
		end
		return true, nil
	end)

	t:expectError(function()
		obs:set("Cash", "not a number")
	end, "should error on invalid write")
end)

t:test("validator allows valid writes", function()
	local data = { Cash = 0 }
	local obs = ObservableTable.wrap(data, function(_path, _value)
		return true, nil
	end)

	obs:set("Cash", 100)
	t:expectEqual(data.Cash, 100, "write went through")
end)

t:test("no validator means no validation", function()
	local data = { Cash = 0 }
	local obs = ObservableTable.wrap(data)

	obs:set("Cash", "anything goes")
	t:expectEqual(data.Cash, "anything goes", "no validator, no check")
end)

t:test("schema validator allows writes inside map paths", function()
	local testSchema = PlayerStore.schema {
		Cash = 0,
		Inventory = PlayerStore.map {} :: { [string]: number },
	}

	local data = { Cash = 0, Inventory = {} :: { [string]: number } }
	local obs = ObservableTable.wrap(data, function(path, value)
		return Validation.validateWrite(testSchema, path, value)
	end)

	obs:set("Inventory", { Sword = 1 })
	t:expectEqual(data.Inventory.Sword, 1, "setting whole map works")

	obs:set("Cash", 50)
	t:expectEqual(data.Cash, 50, "normal field still works")

	t:expectError(function()
		obs:set("Cash", "wrong type")
	end, "rejects wrong type on normal field")

	t:expectError(function()
		obs:set("FakePath", 123)
	end, "rejects nonexistent path")
end)

t:run()
