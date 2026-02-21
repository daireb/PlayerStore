--[=[
	Tests for Schema.luau: schema(), map(), private(), processSchema()
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)
local TestRunner = require(ReplicatedStorage.Tests.Shared.TestRunner)

local schema = PlayerStore.schema
local map = PlayerStore.map
local private = PlayerStore.private

local t = TestRunner.new("Schema")

t:test("schema() produces a template with plain values", function()
	local s = schema {
		Cash = 0,
		Name = "Player",
		IsVIP = false,
	}

	t:expectEqual(s.template.Cash, 0, "Cash default")
	t:expectEqual(s.template.Name, "Player", "Name default")
	t:expectEqual(s.template.IsVIP, false, "IsVIP default")
end)

t:test("schema() handles nested tables", function()
	local s = schema {
		Resources = {
			Cash = 100,
			XP = 0,
		},
	}

	t:expectNotNil(s.template.Resources, "Resources exists")
	t:expectEqual(s.template.Resources.Cash, 100, "nested Cash")
	t:expectEqual(s.template.Resources.XP, 0, "nested XP")
end)

t:test("map() resolves to default in template", function()
	local s = schema {
		Inventory = map {} :: { [string]: number },
	}

	t:expectNotNil(s.template.Inventory, "Inventory exists")
	t:expectEqual(typeof(s.template.Inventory), "table", "Inventory is table")
end)

t:test("map() registers path in mapPaths", function()
	local s = schema {
		Inventory = map {} :: { [string]: number },
		Stats = {
			Wins = 0,
		},
	}

	t:expect(s.mapPaths["Inventory"] == true, "Inventory is a map path")
	t:expectNil(s.mapPaths["Stats"], "Stats is not a map path")
	t:expectNil(s.mapPaths["Stats/Wins"], "Stats/Wins is not a map path")
end)

t:test("private() registers path in privatePaths", function()
	local s = schema {
		Settings = private {
			Volume = 0.75,
		},
		Cash = 0,
	}

	t:expect(s.privatePaths["Settings"] == true, "Settings is private")
	t:expectNil(s.privatePaths["Cash"], "Cash is not private")
end)

t:test("private() still resolves default in template", function()
	local s = schema {
		Settings = private {
			Volume = 0.75,
		},
	}

	t:expectNotNil(s.template.Settings, "Settings exists in template")
	t:expectEqual(s.template.Settings.Volume, 0.75, "Volume default preserved")
end)

t:test("private(map {}) composes correctly", function()
	local s = schema {
		Codes = private(map {} :: { [string]: number }),
	}

	t:expect(s.privatePaths["Codes"] == true, "Codes is private")
	t:expect(s.mapPaths["Codes"] == true, "Codes is a map")
	t:expectNotNil(s.template.Codes, "Codes exists in template")
end)

t:test("schema template is frozen", function()
	local s = schema {
		Cash = 0,
	}

	t:expectError(function()
		(s.template :: any).Cash = 999
	end, "template should be frozen")
end)

t:test("nested paths are tracked correctly", function()
	local s = schema {
		Player = {
			Garage = {
				Vehicles = map {} :: { [string]: string },
			},
		},
	}

	t:expect(s.mapPaths["Player/Garage/Vehicles"] == true, "deep map path tracked")
	t:expectNil(s.mapPaths["Player"], "parent not marked as map")
	t:expectNil(s.mapPaths["Player/Garage"], "mid-level not marked as map")
end)

t:run()
