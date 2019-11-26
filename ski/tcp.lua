local luv = require("luv")
local ski = require("ski.core")
local bit = require("bit")

local sig_recv_data = 1024
local sig_send_data = 2048
local sig_new_client = 3072
local sig_connect = 4096
local sigkill = ski.sigkill

local band = bit.band
local ski_wakeup = ski.wakeup
local ski_cur_thread = ski.cur_thread
local table_insert = table.insert
local table_remove = table.remove
local table_concat = table.concat
local wait_signals = ski.wait_signals

local new_tcp_client

----------------------------------- cache ------------------------------------
local buffer_method = {}
local buffer_mt = {__index = buffer_method}
local function new_buffer()
	local obj = {
		buff = "",
		cache = {},
		err = nil,
	}
	setmetatable(obj, buffer_mt)
	return obj
end

function buffer_method:clear()
	self.err = nil
	self.buff = ""
	self.cache = {}
end

function buffer_method:append(data)
	table_insert(self.cache, data)
	if #self.cache > 100 then
		local msg = string.format("WARNING!! too many cache: %d\n", #self.cache)
		io.stderr:write(msg)
	end
end

function buffer_method:take(size)
	if size <= 0 then
		return "", "invalid size"
	end

	if #self.buff >= size then	-- have enough size
		--print(33333)
		local data, res = self.buff
		res, self.buff = data:sub(1, size), data:sub(size + 1)
		return res
	end

	if self.err then	-- have error
		--print("had have error")
		assert(#self.cache == 0 and #self.buff == 0)
		return "", self.err
	end

	local total = #self.buff
	local arr = {self.buff}

	local index = 0
	for i, data in ipairs(self.cache) do
		if type(data) ~= "string" then	-- error
			local err = assert(data[2])
			self.err = err	-- set error
			self.cache = {}	-- clear cache
			--print(1111)
			self.buff = ""
			return table_concat(arr), err
		end

		total = total + #data
		table_insert(arr, data)
		if total >= size then
			index = i
			--print("enough", total, size)
			break
		end
	end

	if total < size then
		--print("not enough", total, size)
		return "", "insufficient"
	end
	--print("sufficient")
	for i = 1, index do
		table_remove(self.cache, 1)
	end

	local data, res = table_concat(arr)
	res, self.buff = data:sub(1, size), data:sub(size + 1)
	return res
end

function buffer_method:take_all()
	if self.err then
		assert(#self.cache == 0 and #self.buff == 0)
		return "", self.err
	end

	local arr = {self.buff}
	self.buff = ""

	for _, data in ipairs(self.cache) do
		if type(data) ~= "string" then	-- error
			local err = assert(data[2])
			self.err = err	-- set error
			self.cache = {}	-- empty cache
			return table_concat(arr), err
		end
		table_insert(arr, data)
	end

	self.cache = {}		-- take all
	return table_concat(arr)
end

----------------------------------- tcp client ---------------------------------

local tcp_client_method = {}
local tcp_client_mt = {__index = tcp_client_method}

function new_tcp_client(raw_client)
	assert(raw_client)
	local obj = {
		raw_client = raw_client,
		recv_thread = nil,
		send_thread = nil,
		write_err = nil,
		read_err = nil,
		buffer = new_buffer(),
	}
	setmetatable(obj, tcp_client_mt)
	return obj
end

function tcp_client_method:_close()
	if self.raw_client then
		self.raw_client:close()
		self.raw_client = nil
	end
	self.write_err = "closed"
end

function tcp_client_method:close()
	self:_close()
	self.read_err = "closed"
end

function tcp_client_method:read(size)
	if self.read_err then
		return "", self.read_err
	end

	local buffer = self.buffer

	if size == nil then	-- take all
		local data, err = buffer:take_all()
		if err then
			return data, err
		end
		if #data > 0 then
			return data
		end
	else
		local data, err = buffer:take(size)
		if err then
			if err ~= "insufficient" then
				print("err", err)
				return data, err
			end
		else
			print("buffer take ok")
			return data
		end
	end

	print("not enough, wait ... ")

	local cur, raw_client = ski_cur_thread(), self.raw_client
	if not self.recv_thread then
		local ret, err = raw_client:read_start(function(err, data)
			if err then  	-- close
				print("account error", err)
				buffer:append({nil, err})
				self:_close()
				return ski_wakeup(cur, sig_recv_data)
			end

			if data == nil then
				--print(">>EOF")
				buffer:append({nil, "EOF"})
				self:_close()
				return ski_wakeup(cur, sig_recv_data)
			end

			if #data > 0 then
				--print("cache", data)
				buffer:append(data)
			end

			return ski_wakeup(cur, sig_recv_data)
		end)
		if not ret then
			self:_close()
			return "", err
		end
		self.set_recv_thread(cur)	-- bind recv thread
	end

	while true do
		local signals = wait_signals(sig_recv_data, sigkill)
		--print("signals", signals)
		if ski.iskill(signals) then
			print("kill connection")
			self:_close()
			return nil, "killed"
		end

		if band(signals, sig_recv_data) ~= 0 then
			if size == nil then
				local data, err = buffer:take_all()
				--print("call take all", data, err)
				if err then
					return data, err
				end

				if #data > 0 then
					return data
				end
			else
				local data, err = buffer:take(size)
				if not err then
					print("get enough", size)
					return data
				end

				if err ~= "insufficient" then
					print("other error", err)
					return data, err
				end
			end

			print("not enough, wait again")
		else
			assert(false, "logical error: " .. signals)
		end
	end
end

function tcp_client_method:write(data)
	if self.write_err then
		return nil, self.write_err
	end

	local cur, cli = ski_cur_thread(), self.raw_client
	self:set_send_thread(cur)

	local res
	local _, e = cli:write(data, function(err)
		if err then
			res = err
			return ski_wakeup(cur, sig_send_data)
		end

		res = true
		return ski_wakeup(cur, sig_send_data)
	end)
	if e then
		self:close()
		return nil, e
	end

	while true do
		local signals = wait_signals(sig_send_data, sigkill)
		if ski.iskill(signals) then
			print("kill connection")
			self:close()
			return nil, "killed"
		end

		if band(signals, sig_send_data) ~= 0 then
			if res == true then
				return true
			end

			print("stop connection", res)
			self:close()
			return nil, res
		end

		assert(false, "logical error: " .. signals)
	end
end

function tcp_client_method:set_send_thread(thread)
	if not self.send_thread then
		self.send_thread = thread
		return
	end

	assert(self.send_thread == thread, "send in two or more threads!!!!")
end

function tcp_client_method:set_recv_thread(thread)
	if not self.recv_thread then
		self.recv_thread = thread
		return
	end

	assert(self.recv_thread == thread, "recv in two or more threads!!!!")
end

----------------------------------- tcp server ---------------------------------

local tcp_server_method = {}
local tcp_server_mt = {__index = tcp_server_method}

local function new_tcp_server(raw_server, thread)
	local obj = {
		raw_server = raw_server,
		cache = {},
		err = nil,
		listen_thread = thread,
	}
	setmetatable(obj, tcp_server_mt)
	return obj
end

function tcp_server_method:close()
	if self.raw_server then
		print("close server", self.raw_server)
		self.raw_server:close()
		self.raw_server = nil
	end

	self.write_err = "closed"
	self.accept_err = "closed"
	for _, item in ipairs(self.cache) do
		local raw_client = item[1]
		if raw_client then
			print("close client", raw_client)
			raw_client:close()
		end
	end

	self.cache = {}
end

function tcp_server_method:accept()
	local cur = ski_cur_thread()
	assert(cur == self.listen_thread, "accept & listen should be in one thread!!")

	-- 缓存中已经有数据，直接返回
	if #self.cache > 0 then
		local item = table_remove(self.cache, 1)
		local raw_client, err = unpack(item)
		if err then
			return nil, err
		end

		return new_tcp_client(raw_client)
	end

	-- 检查是否已经出错
	if self.accept_err then
		return nil, self.accept_err
	end

	while true do
		local signals = wait_signals(sig_new_client, sigkill)
		if ski.iskill(signals) then
			-- 因 sigkill 唤醒
			print("kill accept server")
			self:close()
			return nil, self.accept_err
		end

		if band(signals, sig_new_client) ~= 0 then
			-- 因 sig_new_client 唤醒
			local item = table_remove(self.cache, 1)
			local raw_client, err = unpack(item)
			if err then
				return nil, err
			end
			--print("accept new client")
			return new_tcp_client(raw_client)
		end

		assert(false, "logical error: " .. signals)
	end
end

local function create_tcp_server(host, port)
	assert(host and port)

	local raw_server = luv.new_tcp()
	local r, err = raw_server:bind(host, port)	-- bind
	if not r then
		raw_server:close()
		return nil, err
	end

	local cur = ski_cur_thread()
	local server = new_tcp_server(raw_server, cur)

	local err_close = function(err)
		server.err = err
		table_insert(server.cache, {nil, err})
		server:close()
		return ski_wakeup(cur, sig_new_client)
	end

	-- listen
	local ret, err = raw_server:listen(128, function(err)
		assert(not server.err)		-- 出错后，不应该再会执行
		if err then
			return err_close(err)	-- 出错，关闭listen并返回
		end

		local client = luv.new_tcp()
		raw_server:accept(client)

		local _, err = client:nodelay(true)
		if err then
			return err_close(err)	-- 出错，关闭listen并返回
		end

		table_insert(server.cache, {client})
		return ski_wakeup(cur, sig_new_client)	-- 有新连接，wakeup
	end)

	if not ret then
		server:close()
		return nil, err
	end

	return server
end

local function tcp_connect(host, port)
	assert(host and port)

	local cur, raw_client = ski_cur_thread(), luv.new_tcp()

	local res
	local ret, err = raw_client:connect(host, port, function(err)
		if err then
			res = {nil, err}
			return ski_wakeup(cur, sig_connect)
		end

		local _, err = raw_client:nodelay(true)
		if err then
			res = {nil, err}
			return ski_wakeup(cur, sig_connect)
		end

		res = {true}
		ski_wakeup(cur, sig_connect)
	end)

	if not ret then
		raw_client:close()
		return nil, err
	end

	while true do
		local signals = wait_signals(sig_connect, sigkill)
		if ski.iskill(signals) then
			-- 因 sigkill 唤醒
			raw_client:close()
			return nil, "killed"
		end

		if band(signals, sig_connect) ~= 0 then
			-- 因 sig_connect 唤醒
			local ok, e = unpack(res)
			if ok then
				return new_tcp_client(raw_client), nil
			end

			raw_client:close()
			return nil, e
		end

		assert(false, "logical error: " .. signals)
	end
end

return {
	new_buffer = new_buffer,

	connect = tcp_connect,
	listen = create_tcp_server,
}

