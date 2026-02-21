--[=[
	Tests for ServerStore replication logic.

	Since ServerStore.loadAsync requires a real ProfileStore session, these
	tests verify the private path filtering and schema-driven replication
	behavior at a unit level using ObservableTable directly.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerStore = require(ReplicatedStorage.Packages.PlayerStore)
local ObservableTable = require(ReplicatedStorage.Packages.PlayerStore.ObservableTable)
local TestRunner = require(ReplicatedStorage.Tests.Shared.TestRunner)

local schema = PlayerStore.schema
local map = PlayerStore.map
local private = PlayerStore.private

local t = TestRunner.new("Replication")

-- Helper: simulates the server's replication filter logic
local function isPrivatePath(privatePaths: { [string]: true }, path: string): boolean
	if privatePaths[path] then
		return true
	end

	local keys = string.split(path, "/")
	for i = 1, #keys - 1 do
		local ancestor = table.concat(keys, "/", 1, i)
		if privatePaths[ancestor] then
			return true
		end
	end

	return false
end

--------------------------------------------------------------------------------
-- Private path filtering
--------------------------------------------------------------------------------

t:test("top-level private path is filtered", function()
	local s = schema {
		Cash = 0,
		Settings = private {
			Volume = 0.75,
		},
	}

	t:expect(isPrivatePath(s.privatePaths, "Settings"), "Settings is private")
	t:expect(not isPrivatePath(s.privatePaths, "Cash"), "Cash is not private")
end)

t:test("children of private path are filtered", function()
	local s = schema {
		Settings = private {
			Volume = 0.75,
			Controls = {
				Sensitivity = 1.0,
			},
		},
	}

	t:expect(isPrivatePath(s.privatePaths, "Settings"), "Settings is private")
	t:expect(isPrivatePath(s.privatePaths, "Settings/Volume"), "child is private")
	t:expect(isPrivatePath(s.privatePaths, "Settings/Controls/Sensitivity"), "deep child is private")
end)

t:test("private(map {}) filters correctly", function()
	local s = schema {
		Codes = private(map {} :: { [string]: number }),
		Inventory = map {} :: { [string]: number },
	}

	t:expect(isPrivatePath(s.privatePaths, "Codes"), "Codes is private")
	t:expect(not isPrivatePath(s.privatePaths, "Inventory"), "Inventory is not private")
end)

--------------------------------------------------------------------------------
-- Replication simulation
--------------------------------------------------------------------------------

t:test("observable root bind sends only non-private data", function()
	local s = schema {
		Cash = 100,
		XP = 50,
		Settings = private {
			Volume = 0.75,
		},
	}

	local data = {
		Cash = 100,
		XP = 50,
		Settings = { Volume = 0.75 },
	}

	local obs = ObservableTable.wrap(data)
	local replicatedData: { [string]: any }? = nil

	obs:bind(function(value, _path, _sv, specificPath)
		if specificPath == "" then
			local filtered = {}
			for key, val in value do
				if not isPrivatePath(s.privatePaths, key) then
					filtered[key] = val
				end
			end
			replicatedData = filtered
		end
	end)

	task.wait()

	t:expectNotNil(replicatedData, "data was replicated")
	t:expectEqual(replicatedData.Cash, 100, "Cash replicated")
	t:expectEqual(replicatedData.XP, 50, "XP replicated")
	t:expectNil(replicatedData.Settings, "Settings NOT replicated")
end)

t:test("observable set on private path does not replicate", function()
	local s = schema {
		Cash = 0,
		Settings = private {
			Volume = 0.75,
		},
	}

	local data = { Cash = 0, Settings = { Volume = 0.75 } }
	local obs = ObservableTable.wrap(data)

	local replicated: { { path: string, value: any } } = {}
	local initialDone = false

	obs:bind(function(_value, _path, specificValue, specificPath)
		if not initialDone then
			initialDone = true
			return
		end
		if not isPrivatePath(s.privatePaths, specificPath) then
			table.insert(replicated, { path = specificPath, value = specificValue })
		end
	end)

	task.wait() -- initial bind fires

	obs:set("Cash", 50)
	task.wait()

	obs:set("Settings/Volume", 0.5)
	task.wait()

	t:expectEqual(#replicated, 1, "only one change replicated")
	t:expectEqual(replicated[1].path, "Cash", "Cash was replicated")
	t:expectEqual(replicated[1].value, 50, "correct value")
end)

t:test("map paths replicate table values correctly", function()
	local s = schema {
		Inventory = map {} :: { [string]: number },
	}

	local data = { Inventory = {} }
	local obs = ObservableTable.wrap(data)

	local lastReplicatedValue = nil
	local initialDone = false

	obs:bind(function(_v, _p, specificValue, specificPath)
		if not initialDone then
			initialDone = true
			return
		end
		if not isPrivatePath(s.privatePaths, specificPath) then
			lastReplicatedValue = specificValue
		end
	end)

	task.wait()

	obs:set("Inventory", { Sword = 1, Shield = 2 })
	task.wait()

	t:expectNotNil(lastReplicatedValue, "inventory change replicated")
	t:expectEqual(typeof(lastReplicatedValue), "table", "replicated as table")
	t:expectEqual(lastReplicatedValue.Sword, 1, "Sword in replicated data")
	t:expectEqual(lastReplicatedValue.Shield, 2, "Shield in replicated data")
end)

t:run()
