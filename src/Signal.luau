--[=[
	Minimal signal implementation for internal use.
	Connect returns a disconnect function rather than a connection object.
]=]

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _callbacks = {} }, Signal)
end

function Signal:Fire(...: any)
	for _, callback in self._callbacks do
		task.spawn(callback, ...)
	end
end

function Signal:Connect(callback: (...any) -> ()): () -> ()
	table.insert(self._callbacks, callback)

	return function()
		local index = table.find(self._callbacks, callback)
		if index then
			table.remove(self._callbacks, index)
		end
	end
end

function Signal:Destroy()
	table.clear(self._callbacks)
end

return Signal
