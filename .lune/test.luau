-- Runs the existing pure suites and actual store contracts without Studio or DataStore access.
local fs = require("@lune/fs")
local Runtime = require("../tests/support/Runtime")
local world = Runtime.new()
local runner = world.load(world.storage.Tests.Shared.TestRunner)
local failures = 0
local run = runner.run
runner.run = function(self)
	local _, failed = run(self)
	failures += failed
end
for _, suite in { "DeepClone", "Schema", "Validation", "ObservableTable" } do
	world.load(`tests/server/{suite}Tests.server.luau`)
end
for _, file in fs.readDir("tests/unit") do
	if file:sub(-5) == ".luau" then
		local suite = require("../tests/unit/" .. file:sub(1, -6))
		suite(Runtime, runner)
	end
end
assert(failures == 0, `{failures} PlayerStore tests failed`)
print("All PlayerStore checks passed (Lune; engine integration is separate).")
