--[=[
	Tests for Validation.luau
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Validation = require(ReplicatedStorage.Packages.PlayerStore.Validation)
local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)
local TestRunner = require(ReplicatedStorage.Tests.Shared.TestRunner)

local validate = Validation.validateData
local schema = PlayerStore.schema
local map = PlayerStore.map
local private = PlayerStore.private

local t = TestRunner.new("Validation")

--------------------------------------------------------------------------------
-- Valid data
--------------------------------------------------------------------------------

t:test("valid flat data passes", function()
	local template = { Cash = 0, Name = "Player", IsVIP = false }
	local data = { Cash = 100, Name = "Bob", IsVIP = true }

	local ok, err = validate(data, template, {})
	t:expect(ok, "should pass")
	t:expectNil(err, "no error")
end)

t:test("valid nested data passes", function()
	local template = { Resources = { Cash = 0, XP = 0 } }
	local data = { Resources = { Cash = 50, XP = 10 } }

	local ok, err = validate(data, template, {})
	t:expect(ok, "should pass")
	t:expectNil(err, "no error")
end)

t:test("extra keys in data are allowed", function()
	local template = { Cash = 0 }
	local data = { Cash = 100, ExtraField = "hello" }

	local ok, err = validate(data, template, {})
	t:expect(ok, "should pass with extra keys")
	t:expectNil(err, "no error")
end)

--------------------------------------------------------------------------------
-- Missing keys
--------------------------------------------------------------------------------

t:test("missing top-level key fails", function()
	local template = { Cash = 0, XP = 0 }
	local data = { Cash = 100 }

	local ok, err = validate(data, template, {})
	t:expect(not ok, "should fail")
	t:expectNotNil(err, "has error message")
	t:expect(string.find(err, "XP") ~= nil, "error mentions missing key")
end)

t:test("missing nested key fails", function()
	local template = { Resources = { Cash = 0, XP = 0 } }
	local data = { Resources = { Cash = 100 } }

	local ok, err = validate(data, template, {})
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Resources/XP") ~= nil, "error mentions full path")
end)

t:test("missing entire nested table fails", function()
	local template = { Resources = { Cash = 0 } }
	local data = {}

	local ok, err = validate(data, template, {})
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Resources") ~= nil, "error mentions missing table")
end)

--------------------------------------------------------------------------------
-- Type mismatches
--------------------------------------------------------------------------------

t:test("wrong type at top level fails", function()
	local template = { Cash = 0 }
	local data = { Cash = "not a number" }

	local ok, err = validate(data, template, {})
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Type mismatch") ~= nil, "mentions type mismatch")
	t:expect(string.find(err, "Cash") ~= nil, "mentions the field")
end)

t:test("wrong type nested fails", function()
	local template = { Resources = { Cash = 0 } }
	local data = { Resources = { Cash = true } }

	local ok, err = validate(data, template, {})
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Resources/Cash") ~= nil, "mentions full path")
end)

t:test("table where value expected fails", function()
	local template = { Cash = 0 }
	local data = { Cash = {} }

	local ok, err = validate(data, template, {})
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Type mismatch") ~= nil, "mentions type mismatch")
end)

t:test("value where table expected fails", function()
	local template = { Resources = { Cash = 0 } }
	local data = { Resources = "not a table" }

	local ok, err = validate(data, template, {})
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Type mismatch") ~= nil, "mentions type mismatch")
end)

--------------------------------------------------------------------------------
-- Map paths (skip deep validation)
--------------------------------------------------------------------------------

t:test("map path skips deep validation", function()
	local template = { Inventory = {} }
	local mapPaths = { Inventory = true }
	local data = { Inventory = { Sword = 1, Shield = 2 } }

	local ok, err = validate(data, template, mapPaths)
	t:expect(ok, "should pass — map path skips deep check")
	t:expectNil(err, "no error")
end)

t:test("map path still checks existence and type", function()
	local template = { Inventory = {} }
	local mapPaths = { Inventory = true }

	local ok1, _ = validate({}, template, mapPaths)
	t:expect(not ok1, "missing map field still fails")

	local ok2, _ = validate({ Inventory = "wrong" }, template, mapPaths)
	t:expect(not ok2, "wrong type for map field still fails")
end)

t:test("nested map path skips deep validation", function()
	local template = { Player = { Garage = { Vehicles = {} } } }
	local mapPaths = { ["Player/Garage/Vehicles"] = true }
	local data = { Player = { Garage = { Vehicles = { Car = "fast", Bike = "slow" } } } }

	local ok, err = validate(data, template, mapPaths)
	t:expect(ok, "should pass — nested map path skips deep check")
	t:expectNil(err, "no error")
end)

--------------------------------------------------------------------------------
-- _DataVersion key is ignored
--------------------------------------------------------------------------------

t:test("_DataVersion in template is ignored", function()
	local template = { Cash = 0, _DataVersion = -1 }
	local data = { Cash = 100 }

	local ok, err = validate(data, template, {})
	t:expect(ok, "should pass — _DataVersion skipped")
	t:expectNil(err, "no error")
end)

--------------------------------------------------------------------------------
-- Deeply nested structures
--------------------------------------------------------------------------------

t:test("deeply nested validation works", function()
	local template = { A = { B = { C = { D = 0 } } } }
	local data = { A = { B = { C = { D = 42 } } } }

	local ok, err = validate(data, template, {})
	t:expect(ok, "deep nesting passes")
	t:expectNil(err, "no error")
end)

t:test("deeply nested missing key fails with full path", function()
	local template = { A = { B = { C = { D = 0 } } } }
	local data = { A = { B = { C = {} } } }

	local ok, err = validate(data, template, {})
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "A/B/C/D") ~= nil, "error has full path")
end)

--------------------------------------------------------------------------------
-- validateWrite
--------------------------------------------------------------------------------

local testSchema = schema {
	Resources = { Cash = 0, XP = 0 },
	SelectedSlot = "Default",
	IsVIP = false,
	Inventory = map {} :: { [string]: number },
	Settings = private { MusicVolume = 0.75 },
}

t:test("validateWrite accepts valid path and value", function()
	local ok, err = Validation.validateWrite(testSchema, "Resources/Cash", 100)
	t:expect(ok, "should pass")
	t:expectNil(err, "no error")
end)

t:test("validateWrite accepts valid top-level path", function()
	local ok, err = Validation.validateWrite(testSchema, "SelectedSlot", "Warrior")
	t:expect(ok, "should pass")
	t:expectNil(err, "no error")
end)

t:test("validateWrite rejects wrong type", function()
	local ok, err = Validation.validateWrite(testSchema, "Resources/Cash", "not a number")
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Type mismatch") ~= nil, "mentions type mismatch")
end)

t:test("validateWrite rejects nonexistent path", function()
	local ok, err = Validation.validateWrite(testSchema, "Nonexistent/Path", 5)
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Invalid path") ~= nil, "mentions invalid path")
end)

t:test("validateWrite rejects nonexistent top-level key", function()
	local ok, err = Validation.validateWrite(testSchema, "FakeKey", 5)
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Invalid path") ~= nil, "mentions invalid path")
end)

t:test("validateWrite allows any key inside a map path", function()
	local ok, err = Validation.validateWrite(testSchema, "Inventory/Sword", 3)
	t:expect(ok, "should pass — map path allows any key")
	t:expectNil(err, "no error")
end)

t:test("validateWrite allows setting map path itself", function()
	local ok, err = Validation.validateWrite(testSchema, "Inventory", {})
	t:expect(ok, "should pass — setting the map itself")
	t:expectNil(err, "no error")
end)

t:test("validateWrite works with private paths", function()
	local ok, err = Validation.validateWrite(testSchema, "Settings/MusicVolume", 0.5)
	t:expect(ok, "should pass — private paths are still valid to write")
	t:expectNil(err, "no error")
end)

t:test("validateWrite rejects wrong type on private path", function()
	local ok, err = Validation.validateWrite(testSchema, "Settings/MusicVolume", "loud")
	t:expect(not ok, "should fail")
	t:expect(string.find(err, "Type mismatch") ~= nil, "mentions type mismatch")
end)

t:test("validateWrite rejects path through a non-table", function()
	local ok, err = Validation.validateWrite(testSchema, "IsVIP/Something", true)
	t:expect(not ok, "should fail — IsVIP is a boolean, not a table")
	t:expect(string.find(err, "Invalid path") ~= nil, "mentions invalid path")
end)

t:run()
