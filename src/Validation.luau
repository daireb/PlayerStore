--[=[
	Structural validation for player data against a schema template.
]=]

local Validation = {}

local DATA_VERSION_KEY = "_DataVersion"

--[=[
	Recursively validates that all keys in template exist in data with
	matching types. Allows extra keys in data. Skips deep validation
	for paths in mapPaths.
]=]
function Validation.validateData(
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

			local success, errorPath = Validation.validateData(dataValue, templateValue, mapPaths, currentPath)
			if not success then
				return false, errorPath
			end
		end
	end

	return true, nil
end

type Schema<T> = {
	template: T,
	mapPaths: { [string]: true },
	privatePaths: { [string]: true },
}

--[=[
	Checks whether a path/value pair is a valid write against the schema.
	Returns `true` if the path exists in the template (or is inside a map
	path) and the value type matches. Useful for validating admin commands
	or user input before calling `set()`.

	```lua
	local ok, err = PlayerStore.validateWrite(DataSchema, "Resources/Cash", 100)
	```
]=]
function Validation.validateWrite(schema: Schema<any>, path: string, value: any): (boolean, string?)
	local template = schema.template :: any
	local keys = string.split(path, "/")
	local current = template
	local builtPath = ""

	for i = 1, #keys do
		local key = keys[i]
		builtPath = if builtPath == "" then key else `{builtPath}/{key}`

		if i < #keys then
			if schema.mapPaths[builtPath] then
				return true, nil
			end

			local next = current[key]
			if next == nil or typeof(next) ~= "table" then
				return false, `Invalid path: {builtPath} does not exist in schema`
			end
			current = next
		else
			if schema.mapPaths[builtPath] then
				return true, nil
			end

			local ancestor = table.concat(keys, "/", 1, #keys - 1)
			if schema.mapPaths[ancestor] then
				return true, nil
			end

			local templateValue = current[key]
			if templateValue == nil then
				return false, `Invalid path: {builtPath} does not exist in schema`
			end

			local expectedType = typeof(templateValue)
			local actualType = typeof(value)
			if expectedType ~= actualType then
				return false, `Type mismatch at {builtPath}: expected {expectedType}, got {actualType}`
			end

			return true, nil
		end
	end

	return false, "Empty path"
end

return Validation
