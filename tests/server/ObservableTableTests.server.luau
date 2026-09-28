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
	local data: any = { Resources = { Cash = 0 } }
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

t:test("set() parent replacement notifies removed descendant", function()
	local obs = ObservableTable.wrap({
		Items = {
			gold = 100,
			gems = 10,
		},
	})
	local fired = false
	local receivedValue = 100
	local receivedSpecificPath = nil

	obs:listen("Items/gold", function(value, _path, _specificValue, specificPath)
		fired = true
		receivedValue = value
		receivedSpecificPath = specificPath
	end)

	obs:set("Items", { gems = 20 })
	task.wait()

	t:expect(fired, "removed descendant listener fired")
	t:expectNil(receivedValue, "removed descendant received nil")
	t:expectEqual(receivedSpecificPath, "Items", "parent replacement reported as specific change")
end)

--------------------------------------------------------------------------------
-- setMany()
--------------------------------------------------------------------------------

t:test("setMany() applies disjoint writes", function()
	local data: any = { Resources = { Cash = 100, XP = 0 }, Inventory = {} }
	local obs = ObservableTable.wrap(data)

	obs:setMany({
		{ path = "Resources/Cash", value = 25 },
		{ path = "Resources/XP", value = 50 },
		{ path = "Inventory/Sword", value = { Level = 2 } },
	})

	t:expectEqual(data.Resources.Cash, 25, "Cash updated")
	t:expectEqual(data.Resources.XP, 50, "XP updated")
	t:expectEqual(data.Inventory.Sword.Level, 2, "complete item assigned")
end)

t:test("setMany() supports nil deletion", function()
	local data = { Inventory = { Sword = 1, Shield = 1 } }
	local obs = ObservableTable.wrap(data)

	obs:setMany({
		{ path = "Inventory/Sword", value = nil },
		{ path = "Inventory/Shield", value = 2 },
	})

	t:expectNil(data.Inventory.Sword, "Sword deleted")
	t:expectEqual(data.Inventory.Shield, 2, "Shield updated")
end)

t:test("setMany() validates every write before mutation", function()
	local data = { Cash = 0, XP = 0 }
	local obs = ObservableTable.wrap(data, function(path, value)
		if typeof(value) ~= "number" then
			return false, `{path} must be a number`
		end
		return true, nil
	end)

	t:expectError(function()
		obs:setMany({
			{ path = "Cash", value = 100 },
			{ path = "XP", value = "invalid" },
		})
	end, "invalid batch should error")

	t:expectEqual(data.Cash, 0, "valid earlier write was not applied")
	t:expectEqual(data.XP, 0, "invalid write was not applied")
end)

t:test("setMany() rolls back on path failure", function()
	local data: any = { Resources = { Cash = 0 } }
	local obs = ObservableTable.wrap(data)

	t:expectError(function()
		obs:setMany({
			{ path = "Resources/Cash", value = 100 },
			{ path = "Missing/Deep", value = 1 },
		})
	end, "invalid path should error")

	t:expectEqual(data.Resources.Cash, 0, "earlier write rolled back")
	t:expectNil(data.Missing, "invalid path did not create data")
end)

t:test("setMany() notifies affected paths once with final state", function()
	local data = { Resources = { Cash = 0, XP = 0 }, Name = "Player" }
	local obs = ObservableTable.wrap(data)
	local rootCount = 0
	local resourcesCount = 0
	local cashCount = 0
	local xpCount = 0
	local nameCount = 0
	local sawFinalState = false
	local lastSpecificPath = nil
	local batchSize = nil

	obs:listen(function(value, _path, _specificValue, specificPath, updates)
		rootCount += 1
		sawFinalState = value.Resources.Cash == 100 and value.Resources.XP == 50
		lastSpecificPath = specificPath
		batchSize = if updates then #updates else nil
	end)
	obs:listen("Resources", function()
		resourcesCount += 1
	end)
	obs:listen("Resources/Cash", function()
		cashCount += 1
	end)
	obs:listen("Resources/XP", function()
		xpCount += 1
	end)
	obs:listen("Name", function()
		nameCount += 1
	end)

	obs:setMany({
		{ path = "Resources/Cash", value = 100 },
		{ path = "Resources/XP", value = 50 },
	})
	task.wait()

	t:expectEqual(rootCount, 1, "root listener fired once")
	t:expectEqual(resourcesCount, 1, "ancestor listener fired once")
	t:expectEqual(cashCount, 1, "Cash listener fired once")
	t:expectEqual(xpCount, 1, "XP listener fired once")
	t:expectEqual(nameCount, 0, "unaffected listener did not fire")
	t:expect(sawFinalState, "listener observed all final values")
	t:expectEqual(lastSpecificPath, "Resources/XP", "last relevant write provided")
	t:expectEqual(batchSize, 2, "full batch metadata provided")
end)

t:test("setMany() parent replacement notifies descendant once", function()
	local obs = ObservableTable.wrap({
		Items = {
			gold = 100,
			gems = 10,
		},
	})
	local fireCount = 0
	local receivedValue = 100

	obs:listen("Items/gold", function(value)
		fireCount += 1
		receivedValue = value
	end)

	obs:setMany({
		{ path = "Items", value = { gems = 20 } },
	})
	task.wait()

	t:expectEqual(fireCount, 1, "removed descendant listener fired once")
	t:expectNil(receivedValue, "removed descendant received final nil value")
end)

t:test("setMany() rejects duplicate and ancestor paths before mutation", function()
	local data = { Items = { gold = 1 }, Cash = 0 }
	local obs = ObservableTable.wrap(data)
	t:expectError(function()
		obs:setMany({ { path = "Cash", value = 1 }, { path = "Cash", value = 2 } })
	end, "duplicate paths rejected")
	t:expectError(function()
		obs:setMany({ { path = "Items", value = { gold = 2 } }, { path = "Items/gold", value = 3 } })
	end, "ancestor paths rejected")
	t:expectEqual(data.Cash, 0, "duplicate batch did not mutate")
	t:expectEqual(data.Items.gold, 1, "ancestor batch did not mutate")
end)

t:test("setMany() rejects malformed paths", function()
	local obs = ObservableTable.wrap({ Cash = 0 })
	for _, path in { "", "/Cash", "Cash/", "Cash//X" } do
		t:expectError(function()
			obs:setMany({ { path = path, value = 1 } })
		end, "malformed path rejected")
	end
end)

t:test("writes cannot add string keys inside a dense array", function()
	local data: any = { Cash = 0, Inventory = { Swords = { "A", "B" } } }
	local obs = ObservableTable.wrap(data)
	t:expectError(function()
		obs:set("Inventory/Swords/Name", "mixed")
	end, "single write rejected")
	t:expectError(function()
		obs:setMany({ { path = "Cash", value = 1 }, { path = "Inventory/Swords/Name", value = "mixed" } })
	end, "batch write rejected")
	t:expectEqual(data.Cash, 0, "batch rolled back")
	t:expectNil(data.Inventory.Swords.Name, "array remains dense")
end)

t:test("writes copy borrowed tables before attaching them", function()
	local testSchema = PlayerStore.schema { Inventory = PlayerStore.map {} }
	local data: any = { Inventory = { A = { Count = 1 }, B = { Count = 2 } } }
	local obs = ObservableTable.wrap(data, function(path, value)
		return Validation.validateWrite(testSchema, path, value)
	end)
	obs:set("Inventory/self", data.Inventory)
	t:expectNil(data.Inventory.self.self, "borrowed parent copied before attachment")
	obs:setMany({
		{ path = "Inventory/A/Ref", value = data.Inventory.B },
		{ path = "Inventory/B/Ref", value = data.Inventory.A },
	})
	t:expectEqual(data.Inventory.A.Ref.Count, 2, "first copied branch retained its value")
	t:expectEqual(data.Inventory.B.Ref.Count, 1, "second copied branch retained its value")
	t:expectNil(data.Inventory.A.Ref.Ref, "first copy is independent")
	t:expectNil(data.Inventory.B.Ref.Ref, "all batch values copied before mutation")
	t:expect(Validation.validateData(data, testSchema.template, testSchema.mapPaths), "data remains acyclic and valid")
end)

t:test("shared submitted branches cannot bypass fixed field validation or notifications", function()
	for _, method in { "set", "setMany" } do
		local testSchema = PlayerStore.schema { Record = { Dynamic = PlayerStore.map {}, Fixed = { Points = 0 } } }
		local data: any = { Record = { Dynamic = {}, Fixed = { Points = 0 } } }
		local obs = ObservableTable.wrap(data, function(path, value)
			return Validation.validateWrite(testSchema, path, value)
		end)
		local shared = { Points = 1 }
		local value = { Dynamic = shared, Fixed = shared }
		if method == "set" then
			obs:set("Record", value)
		else
			obs:setMany({ { path = "Record", value = value } })
		end
		local dynamicCalls, fixedCalls = 0, 0
		obs:listen("Record/Dynamic/Points", function()
			dynamicCalls += 1
		end)
		obs:listen("Record/Fixed/Points", function()
			fixedCalls += 1
		end)
		obs:set("Record/Dynamic/Points", false)
		task.wait()
		t:expectEqual(data.Record.Fixed.Points, 1, "dynamic write did not change the fixed field")
		t:expectEqual(shared.Points, 1, "submitted value is unchanged")
		t:expectEqual(dynamicCalls, 1, "changed field was notified")
		t:expectEqual(fixedCalls, 0, "unchanged fixed field was not notified")
		t:expect(Validation.validateData(data, testSchema.template, testSchema.mapPaths), "fixed types remain valid")
	end
end)

t:test("reusing one value across writes and batch members keeps branches independent", function()
	local obs = ObservableTable.wrap({ Inventory = {} })
	local value = { Count = 1 }
	obs:set("Inventory/A", value)
	obs:set("Inventory/B", value)
	obs:setMany({
		{ path = "Inventory/C", value = value },
		{ path = "Inventory/D", value = value },
	})
	obs:set("Inventory/A/Count", 2)
	obs:set("Inventory/C/Count", 3)
	t:expectEqual(obs:get("Inventory/B/Count"), 1, "previously submitted value was copied on reuse")
	t:expectEqual(obs:get("Inventory/D/Count"), 1, "each batch member owns its branch")
	t:expectEqual(value.Count, 1, "caller still owns the original value")
	value.Count = 99
	t:expectEqual(obs:get("Inventory/A/Count"), 2, "caller mutation did not change the first single write")
	t:expectEqual(obs:get("Inventory/B/Count"), 1, "caller mutation did not change the reused single write")
	t:expectEqual(obs:get("Inventory/C/Count"), 3, "caller mutation did not change the first batch member")
	t:expectEqual(obs:get("Inventory/D/Count"), 1, "caller mutation did not change the second batch member")
end)

t:test("frozen submitted values become mutable owned branches", function()
	for _, method in { "set", "setMany" } do
		local obs = ObservableTable.wrap({ Inventory = {} })
		local value = table.freeze({ Count = 1, Nested = table.freeze({ Count = 2 }) })
		if method == "set" then
			obs:set("Inventory/Item", value)
		else
			obs:setMany({ { path = "Inventory/Item", value = value } })
		end
		obs:setMany({
			{ path = "Inventory/Item/Count", value = 3 },
			{ path = "Inventory/Item/Nested/Count", value = 4 },
		})
		t:expectEqual(obs:get("Inventory/Item/Count"), 3, "copied root can be updated")
		t:expectEqual(obs:get("Inventory/Item/Nested/Count"), 4, "copied nested table can be updated")
		t:expectEqual(value.Count, 1, "frozen caller root is unchanged")
		t:expectEqual(value.Nested.Count, 2, "frozen caller descendant is unchanged")
	end
end)

t:test("batch rollback survives frozen existing write targets and intermediates", function()
	for _, case in { { "setMany", "Inventory/Frozen/Count" }, { "applyUpdates", "Inventory/Frozen/New/Count" } } do
		local data: any = { Cash = 0, Inventory = { Frozen = table.freeze({ Count = 1 }) } }
		local commits, notifications = 0, 0
		local obs = ObservableTable.wrap(data, nil, function()
			commits += 1
		end)
		obs:listen(function()
			notifications += 1
		end)
		t:expectError(function()
			(obs :: any)[case[1]](obs, { { path = "Cash", value = 100 }, { path = case[2], value = 2 } })
		end, "frozen target should reject the write")
		task.wait()
		t:expectEqual(data.Cash, 0, "earlier write rolled back despite frozen target")
		t:expectEqual(data.Inventory.Frozen.Count, 1, "frozen value remains unchanged")
		t:expectNil(data.Inventory.Frozen.New, "failed intermediate creation left no branch")
		t:expectEqual(commits, 0, "failed batch did not replicate")
		t:expectEqual(notifications, 0, "failed batch did not notify")
	end
end)

t:test("cyclic submissions fail before copying or committing without a schema validator", function()
	for _, useValidator in { false, true } do
		local data: any = { Cash = 0, Inventory = {} }
		local obs = ObservableTable.wrap(
			data,
			if useValidator
				then function()
					return true, nil
				end
				else nil
		)
		local cyclic: any = {}
		cyclic.self = cyclic
		t:expectError(function()
			obs:set("Inventory/Item", cyclic)
		end, "single cyclic submission rejected")
		t:expectError(function()
			obs:setMany({ { path = "Cash", value = 100 }, { path = "Inventory/Item", value = cyclic } })
		end, "cyclic batch submission rejected")
		t:expectEqual(data.Cash, 0, "earlier batch write was not committed")
		t:expectNil(data.Inventory.Item, "cyclic value was never attached")
	end
end)

t:test("commit hook runs before listeners and once per batch", function()
	local events = {}
	local obs = ObservableTable.wrap({ Cash = 0, XP = 0 }, nil, function(path, _value, updates)
		table.insert(events, if updates then "batch" else path)
	end)
	obs:listen(function()
		t:expect(#events >= 1, "commit hook ran before listener")
	end)
	obs:set("Cash", 1)
	obs:setMany({ { path = "Cash", value = 2 }, { path = "XP", value = 3 } })
	task.wait()
	t:expectEqual(events[1], "Cash", "single hook ran")
	t:expectEqual(events[2], "batch", "batch hook ran once")
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

t:test("disconnect during dispatch skips later listener", function()
	local obs = ObservableTable.wrap({ Cash = 0 })
	local called = false
	local disconnectLater
	obs:listen("Cash", function()
		disconnectLater()
	end)
	disconnectLater = obs:listen("Cash", function()
		called = true
	end)
	obs:set("Cash", 1)
	task.wait()
	t:expect(not called, "later callback was cancelled")
end)

t:test("listener paths share observer trie ancestors", function()
	local obs = ObservableTable.wrap({
		Items = {
			gold = 0,
			gems = 0,
		},
	})

	obs:listen("Items/gold", function() end)
	obs:listen("Items/gems", function() end)

	local observerRoot = (obs :: any)._observerRoot
	local itemsNode = observerRoot.children.Items

	t:expectNotNil(itemsNode, "shared Items node exists")
	t:expectNotNil(itemsNode.children.gold.signal, "gold signal stored under Items")
	t:expectNotNil(itemsNode.children.gems.signal, "gems signal stored under Items")
	t:expectEqual(itemsNode.children.gold.path, "Items/gold", "full path cached on node")
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

t:test("applyUpdate with root path replaces data", function()
	local obs = ObservableTable.wrap({ Cash = 0, XP = 0 })

	obs:applyUpdate("", { Cash = 100, XP = 50 })

	t:expectEqual(obs:get("Cash"), 100, "Cash updated")
	t:expectEqual(obs:get("XP"), 50, "XP updated")
end)

t:test("applyUpdate root snapshot clears omitted keys", function()
	local data = { Cash = 0, Old = 1 }
	local obs = ObservableTable.wrap(data)
	obs:applyUpdate("", { Cash = 100 })
	t:expectEqual(obs:get(), data, "root identity remains stable")
	t:expectNil(data.Old, "omitted key removed")
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

t:test("applyUpdate parent replacement notifies removed descendant", function()
	local obs = ObservableTable.wrap({
		Items = {
			gold = 100,
			gems = 10,
		},
	})
	local fired = false
	local receivedValue = 100

	obs:listen("Items/gold", function(value)
		fired = true
		receivedValue = value
	end)

	obs:applyUpdate("Items", { gems = 20 })
	task.wait()

	t:expect(fired, "replicated descendant listener fired")
	t:expectNil(receivedValue, "replicated descendant received nil")
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

t:test("applyUpdate root notifies removed descendant with nil", function()
	local obs = ObservableTable.wrap({
		Items = {
			gold = 100,
			gems = 10,
		},
	})
	local fired = false
	local receivedValue = 100

	obs:listen("Items/gold", function(value)
		fired = true
		receivedValue = value
	end)

	obs:applyUpdate("", { Items = { gems = 20 } })
	task.wait()

	t:expect(fired, "removed root descendant listener fired")
	t:expectNil(receivedValue, "removed root descendant received nil")
end)

t:test("applyUpdates creates intermediates and notifies after all writes", function()
	local obs = ObservableTable.wrap({})
	local receivedCash = nil
	local receivedXP = nil

	obs:listen("Resources/Cash", function(value)
		receivedCash = value
		receivedXP = obs:get("Resources/XP")
	end)

	obs:applyUpdates({
		{ path = "Resources/Cash", value = 100 },
		{ path = "Resources/XP", value = 50 },
	})
	task.wait()

	t:expectEqual(receivedCash, 100, "Cash listener received final value")
	t:expectEqual(receivedXP, 50, "Cash listener saw final XP value")
end)

t:test("applyUpdates rolls back created intermediates on failure", function()
	local data: any = { Other = 5 }
	local obs = ObservableTable.wrap(data)

	t:expectError(function()
		obs:applyUpdates({
			{ path = "Inventory/Sword", value = 1 },
			{ path = "Other/Deep", value = 2 },
		})
	end, "invalid ordered update should error")

	t:expectNil(data.Inventory, "created intermediates rolled back")
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

t:test("no validator permits scalar type changes", function()
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
