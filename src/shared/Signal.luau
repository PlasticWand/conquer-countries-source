--!strict
-- Minimal synchronous signal for pure modules (no Roblox dependency).
-- Handlers run in connection order; a handler may disconnect itself.
-- A handler that errors doesn't stop the others: the error goes to
-- Signal.onError (warn by default; the Lune test runner makes it raise).

export type Connection = { Disconnect: (self: Connection) -> (), connected: boolean }
export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
}

local Signal = {}

Signal.onError = function(message: any)
	warn(`Signal handler failed: {message}`)
end

function Signal.new<T...>(): Signal<T...>
	local handlers: { { fn: (T...) -> (), conn: Connection } } = {}
	local self = {}

	function self.Connect(_, fn: (T...) -> ()): Connection
		local conn = { connected = true } :: any
		local entry = { fn = fn, conn = conn }
		function conn.Disconnect(c: Connection)
			if not c.connected then
				return
			end
			c.connected = false
			local i = table.find(handlers, entry)
			if i then
				table.remove(handlers, i)
			end
		end
		table.insert(handlers, entry)
		return conn
	end

	function self.Fire(_, ...: T...)
		local snapshot = table.clone(handlers)
		for _, entry in snapshot do
			if entry.conn.connected then
				local ok, err = pcall(entry.fn :: any, ...)
				if not ok then
					Signal.onError(err)
				end
			end
		end
	end

	function self.DisconnectAll(_)
		for _, entry in handlers do
			entry.conn.connected = false
		end
		table.clear(handlers)
	end

	return self :: any
end

return Signal
