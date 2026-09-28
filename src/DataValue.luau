-- Values shared with ProfileStore and RemoteEvents must be plain, serializable data.
local DataValue = {}

function DataValue.path(path: any): (boolean, string?)
	if
		typeof(path) ~= "string"
		or path == ""
		or string.sub(path, 1, 1) == "/"
		or string.sub(path, -1) == "/"
		or string.find(path, "//", 1, true)
		or utf8.len(path) == nil
	then
		return false, "expected a non-empty path without empty segments"
	end
	return true, nil
end

local function validate(value: any, path: string, active: { [any]: boolean }): (boolean, string?)
	local kind = typeof(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return false, `Non-finite number at {path}`
		end
	elseif kind == "string" then
		if utf8.len(value) == nil then
			return false, `Invalid UTF-8 string at {path}`
		end
	elseif kind == "table" then
		if getmetatable(value) ~= nil then
			return false, `Metatable at {path}`
		end
		if active[value] then
			return false, `Cycle at {path}`
		end
		active[value] = true
		local keyKind = nil
		local count = 0
		local maximum = 0
		for key, nested in value do
			local currentKind = typeof(key)
			if currentKind ~= "string" and currentKind ~= "number" then
				return false, `Invalid key at {path}`
			end
			if keyKind ~= nil and keyKind ~= currentKind then
				return false, `Mixed table keys at {path}`
			end
			keyKind = currentKind
			if currentKind == "string" then
				if key == "" or string.find(key, "/", 1, true) or utf8.len(key) == nil then
					return false, `Invalid key at {path}`
				end
			else
				if key < 1 or key % 1 ~= 0 or key == math.huge then
					return false, `Invalid array index at {path}`
				end
				maximum = math.max(maximum, key)
			end
			count += 1
			local nestedPath = `{path}/{key}`
			local ok, err = validate(nested, nestedPath, active)
			if not ok then
				return false, err
			end
		end
		if keyKind == "number" and maximum ~= count then
			return false, `Sparse array at {path}`
		end
		active[value] = nil
	elseif kind ~= "boolean" then
		return false, `Unsupported {kind} at {path}`
	end
	return true, nil
end

function DataValue.validate(value: any, path: string?): (boolean, string?)
	return validate(value, path or "value", {})
end

return DataValue
