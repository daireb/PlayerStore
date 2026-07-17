--[=[
	Recursively clones plain data tables so nested defaults are never shared
	between schema templates, profiles, or client stores.
]=]

local function deepClone<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end

	local clone = {} :: any
	for key, nestedValue in pairs(value) do
		clone[deepClone(key)] = deepClone(nestedValue)
	end

	return clone :: T
end

return deepClone
