--[=[
	Structural validation for player data against a schema template.
]=]

local DATA_VERSION_KEY = "_DataVersion"

--[=[
	Recursively validates that all keys in template exist in data with
	matching types. Allows extra keys in data. Skips deep validation
	for paths in mapPaths.
]=]
local function validate(
	data: { [string]: any },
	template: { [string]: any },
	mapPaths: { [string]: true },
	path: string?
): (boolean, string?)
	path = path or ""

	for key, templateValue in template do
		if key == DATA_VERSION_KEY then
			continue
		end

		local dataValue = data[key]
		local currentPath = if path == "" then key else `{path}/{key}`

		if dataValue == nil then
			return false, `Missing key: {currentPath}`
		end

		local templateType = typeof(templateValue)
		local dataType = typeof(dataValue)

		if templateType ~= dataType then
			return false, `Type mismatch at {currentPath}: expected {templateType}, got {dataType}`
		end

		if templateType == "table" then
			if mapPaths[currentPath] then
				continue
			end

			local success, errorPath = validate(dataValue, templateValue, mapPaths, currentPath)
			if not success then
				return false, errorPath
			end
		end
	end

	return true, nil
end

return validate
