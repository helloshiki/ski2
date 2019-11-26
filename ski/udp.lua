local luv = require("luv")
local ski = require("ski.core")
local bit = require("bit")

local sig_recv_data = 1024
local sig_send_data = 2048

local band = bit.band
local ski_wakeup = ski.wakeup
local ski_cur_thread = ski.cur_thread
local table_insert = table.insert
local table_remove = table.remove


local method = {}
local mt = {__index = method}
function method:bind(host, port)
	assert(not self.isserver, "only server can bind!")

	local r, e = self.udp:bind(host, port)
	if not r then
		return nil, e
	end

	self.isserver = true
	return true
end

function method:set_broadcast(on)
	local r, e = self.udp:set_broadcast(on)
	if not r then
		return nil, e
	end
	return true
end

function method:recv()
	-- 如果缓存中有数据，直接返回
	local count = #self.cache
	if count > 0 then
		local item = table_remove(self.cache, 1)
		local _ = count > 20 and io.stderr:write("too many udp cache ", count, "\n")
		return unpack(item)
	end

	if self.err then
		return nil, self.err
	end

	local udp = assert(self.udp)

	local thread = ski_cur_thread()
	if not self.recv_thread then
		-- 只在第一次调用 recv_start 接收数据
		local r, e = udp:recv_start(function(e, d, a)
			if e then
				table_insert(self.cache, {nil, e})
				return ski_wakeup(thread, sig_recv_data)	-- 出错，唤醒因没有收到包而调用ski.wait()的调用者
			end

			if not (d and a) then
				return
			end

			table_insert(self.cache, {d, a.ip, a.port})
			return ski_wakeup(thread, sig_recv_data)	-- 收到包，唤醒因没有收到包而调用ski.wait()的调用者
		end)

		if not r then
			return nil, e
		end

		self.recv_thread = thread
	end

	assert(thread == self.recv_thread, "recv in two or more threads!!!!")

	if self.err then
		return nil, self.err
	end

	while self.udp do
		local signals = ski.wait_signals(ski.sigkill, sig_recv_data)
		if ski.iskill(signals) then
			-- 因 sigkill 唤醒
			if self.udp then
				print("kill udp recv")
				self.udp:recv_stop()
				self.err = "killed"
			end

			return nil, self.err
		end

		if band(signals, sig_recv_data) ~= 0 then
			-- 因 sig_recv_data 唤醒
			local item = table_remove(self.cache, 1)
			return unpack(item)
		end

		assert(false, "logical error: " .. signals)
	end
end

function method:send(host, port, data)
	if self.err then
		return nil, self.err
	end

	local cur, udp = ski_cur_thread(), assert(self.udp)

	-- 绑定第一个调用send的thread, 并且只允许在一个thread发送
	if not self.send_thread then
		self.send_thread = cur
	end
	assert(self.send_thread == cur, "send in two or more threads!!!!")

	local res
	local r, e = udp:send(data, host, port, function(e)
		res = e and e or true
		ski.wakeup(cur, sig_send_data)	-- 唤醒
	end)

	if not r then
		return nil, e
	end

	while self.udp do
		local signals = ski.wait_signals(ski.sigkill, sig_send_data)
		if ski.iskill(signals) then
			self.err = "killed"
			return nil, self.err
		end

		if band(signals, sig_send_data) ~= 0 then
			-- 因 sig_send_data 唤醒
			if res == true then
				return true
			end

			return nil, res
		end

		assert(false, "logical error: " .. signals)
	end
end

function method:close()
	self.err = "closed"
	--self.cache = {}

	--self.recv_thread = nil
	--self.send_thread = nil
	if self.recv_thread and self.recv_thread ~= ski_cur_thread() then
		ski.wakeup(self.recv_thread, ski.sigkill)
	end

	if self.send_thread and self.send_thread ~= ski_cur_thread()then
		ski.wakeup(self.send_thread, ski.sigkill)
	end

	if self.udp then
		self.udp:recv_stop()
		self.udp:close()
		self.udp = nil
	end
end

function method:set_name(name)
	self.name = name
end

local function new()
	local udp = luv.new_udp()
	local obj = {
		isserver = false,

		recv_thread = nil,
		send_thread = nil,

		cache = {},
		err = nil,
		udp = udp,
		name = tostring(udp),
	}

	setmetatable(obj, mt)
	return obj
end

return {new = new}

--[[
	recv/send能且仅能在一个thread调用
--]]
