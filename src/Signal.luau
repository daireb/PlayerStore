--[=[
	Minimal signal implementation for internal use.
	Connect returns a disconnect function rather than a connection object.
]=]

local Signal = {}
Signal.__index = Signal

export type Signal<T> = {
	Fire: (self: Signal<T>, ...T) -> (),
	Connect: (self: Signal<T>, callback: (...T) -> ()) -> () -> (),
	Destroy: (self: Signal<T>) -> (),
}

function Signal.new()
	return setmetatable({ _callbacks = {} }, Signal)
end

function Signal:Fire(...: any)
	local callbacks = table.clone(self._callbacks)
	for _, entry in callbacks do
		task.spawn(function(...)
			if entry.active then
				entry.callback(...)
			end
		end, ...)
	end
end

function Signal:Connect(callback: (...any) -> ()): () -> ()
	local entry = { callback = callback, active = true }
	table.insert(self._callbacks, entry)

	return function()
		entry.active = false
		local index = table.find(self._callbacks, entry)
		if index then
			table.remove(self._callbacks, index)
		end
	end
end

function Signal:Destroy()
	for _, entry in self._callbacks do
		entry.active = false
	end
	table.clear(self._callbacks)
end

return Signal
