--[=[
	Tests for DeepClone.luau.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local deepClone = require(ReplicatedStorage.Packages.PlayerStore.DeepClone)
local TestRunner = require(ReplicatedStorage.Tests.Shared.TestRunner)

local t = TestRunner.new("DeepClone")

t:test("nested tables are cloned recursively", function()
	local original = {
		Stats = {
			Daily = {
				Wins = 1,
			},
		},
	}

	local cloned = deepClone(original)

	t:expect(cloned ~= original, "root table has a new identity")
	t:expect(cloned.Stats ~= original.Stats, "child table has a new identity")
	t:expect(cloned.Stats.Daily ~= original.Stats.Daily, "deep table has a new identity")
	t:expectEqual(cloned.Stats.Daily.Wins, 1, "deep value is preserved")
end)

t:test("mutating a clone does not change the source", function()
	local original = {
		Stats = {
			Daily = {
				Wins = 1,
			},
		},
	}

	local cloned = deepClone(original)
	cloned.Stats.Daily.Wins = 10

	t:expectEqual(original.Stats.Daily.Wins, 1, "source remains unchanged")
	t:expectEqual(cloned.Stats.Daily.Wins, 10, "clone accepts independent mutation")
end)

t:run()
