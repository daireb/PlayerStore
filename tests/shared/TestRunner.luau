--[=[
	Simple test runner.

	Usage:
		local TestRunner = require(path.to.TestRunner)
		local t = TestRunner.new("SuiteName")

		t:test("test name", function()
			t:expect(1 + 1 == 2, "math works")
			t:expectEqual(value, expected, "values match")
			t:expectNotNil(value, "value exists")
			t:expectError(function() error("boom") end, "should error")
		end)

		t:run()
]=]

local TestRunner = {}
TestRunner.__index = TestRunner

function TestRunner.new(suiteName: string)
	return setmetatable({
		_suiteName = suiteName,
		_tests = {} :: { { name: string, fn: () -> () } },
	}, TestRunner)
end

function TestRunner:test(name: string, fn: () -> ())
	table.insert(self._tests, { name = name, fn = fn })
end

function TestRunner:expect(condition: boolean, message: string?)
	if not condition then
		error(`Assertion failed: {message or "expected truthy value"}`, 2)
	end
end

function TestRunner:expectEqual(actual: any, expected: any, message: string?)
	if actual ~= expected then
		error(`Assertion failed: {message or "values not equal"} (got {tostring(actual)}, expected {tostring(expected)})`, 2)
	end
end

function TestRunner:expectNotNil(value: any, message: string?)
	if value == nil then
		error(`Assertion failed: {message or "expected non-nil value"}`, 2)
	end
end

function TestRunner:expectNil(value: any, message: string?)
	if value ~= nil then
		error(`Assertion failed: {message or "expected nil"} (got {tostring(value)})`, 2)
	end
end

function TestRunner:expectError(fn: () -> (), message: string?)
	local success = pcall(fn)
	if success then
		error(`Assertion failed: {message or "expected function to error"}`, 2)
	end
end

function TestRunner:run()
	local passed = 0
	local failed = 0
	local errors = {}

	print(`\n[TestRunner] Running suite: {self._suiteName} ({#self._tests} tests)`)
	print(string.rep("-", 60))

	for _, testCase in self._tests do
		local success, err = pcall(testCase.fn)
		if success then
			passed += 1
			print(`  PASS  {testCase.name}`)
		else
			failed += 1
			print(`  FAIL  {testCase.name}`)
			print(`        {err}`)
			table.insert(errors, { name = testCase.name, err = err })
		end
	end

	print(string.rep("-", 60))
	print(`[TestRunner] {self._suiteName}: {passed} passed, {failed} failed out of {#self._tests}`)

	if failed > 0 then
		print(`\n[TestRunner] FAILURES:`)
		for _, e in errors do
			print(`  - {e.name}: {e.err}`)
		end
	end

	print("")
end

return TestRunner
