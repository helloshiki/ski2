local luv = require("luv")
local bit = require("bit")

local co_yield = coroutine.yield
local co_create = coroutine.create
local co_status = coroutine.status
local co_resume = coroutine.resume
local table_insert = table.insert
local table_remove = table.remove

local bor = bit.bor
local band = bit.band

local sigdefault = 1	-- default signal
local sigsleep   = 2	-- sleep timeout
local sigkill    = 8	-- kill thread
local sigusr1    = 16	-- user signal 1
local sigusr2    = 32	-- user signal 2

---------------------------- status ----------------------------------------------

local wait_map = {}				-- 每轮运行期间，调用wait()让出CPU时，会记录下调用thread的索引，wakeup(thread)时会查找
local ski_thread_map = {}		-- 当前所有的thread

local ski_cur_thread			-- 当前正在运行的thread
local yield, go, run, sleep
local wait, wakeup, empty

------------------------------------- running item ---------------------------------

local running_list_method = {}
local running_list_mt = {__index = running_list_method}
local function new_running_list()
	local obj = {
		running_map = {},		-- 对应snatshot_map，下一轮的缓存　
		running_list = {},		-- 对应snatshot_list，下一轮的缓存　

		snatshot_map = nil,		-- 当前可以运行的thread, = {[thread] = number_signal_set}
		snatshot_list = nil,	-- 当前可以运行，但未resume的array, = {thread1, thread2}
	}
	setmetatable(obj, running_list_mt)
	return obj
end

-- running_xxx为下一轮的缓存
function running_list_method:append(thread, signal)
	assert(signal ~= nil)

	local running_map = self.running_map
	local signals = running_map[thread]	-- {[thread] = number_signal_set}
	if not signals then
		running_map[thread] = signal
		table_insert(self.running_list, thread)
		return
	end

	running_map[thread] = bor(signals, signal)
end

-- 冻结
function running_list_method:take_snatshot()
	if #self.running_list == 0 then
		assert(empty(self.running_map))
		return
	end

	self.snatshot_map = self.running_map
	self.snatshot_list = self.running_list
	self.running_map = {}
	self.running_list = {}
	--print("===== swap", #self.snatshot_list)
end

-- snatshot_xxx为当前轮要resume的
function running_list_method:pop()
	local snatshot_list = self.snatshot_list
	if #snatshot_list == 0 then
		return nil
	end

	local snatshot_map = self.snatshot_map
	local thread = table_remove(snatshot_list, 1)

	local signals = assert(snatshot_map[thread])
	snatshot_map[thread] = nil

	return thread, signals
end

function running_list_method:count()
	return #self.running_list
end

local running_list = new_running_list()

--------------------------------- basic operation ----------------------------------
-- 当前thread让出CPU
function wait()
	local cur = ski_cur_thread

	assert(ski_thread_map[cur])
	assert("running" == cur:_get_status())

	wait_map[cur] = 1	-- 登记正在等待
	return co_yield()	-- 让出CPU
end

-- 唤醒thread，加入可运行队列ski_running_list
function wakeup(thread, signal)
	assert(thread ~= ski_cur_thread, "cannot wakeup self!!")
	--print("wakeup", thread:_get_name(), signal)
	-- thread是否是存活的
	if not ski_thread_map[thread] then
		print("aleady dead!", thread:_get_name())
		return false
	end

	-- thread是否是正在等待被唤醒的
	if not wait_map[thread] then
		print("no waitting any more", thread:_get_name())
		return true
	end

	if signal == nil then
		signal = sigdefault
	end

	return thread:_wakeup(signal)	-- 唤醒
end

---------------------------- thread --------------------------------

local thread_method = {}
local thread_mt = {__index = thread_method}

function thread_method:_close()
	self._finalize()	-- 此时, thread已经死亡，不会再有机会resume．这里提供一个callback，让调用都可以释放资源

	self._timer:close()
	self._timer = nil

	assert(ski_thread_map[self])
	ski_thread_map[self] = nil
end

function thread_method:_resume(signals)
	local r, e = co_resume(self._co, signals)
	if not r then
		--print(r, e, signals)
		local msg = string.format("FATAL! name:%s sig:%d err:%s\n", self._name, signals, e)
		io.stderr:write(msg)
		os.exit(-1)
	end
end

function thread_method:_wakeup(signal)
	assert(co_status(self._co) ~= "dead")
	assert(signal ~= nil)

	running_list:append(self, signal)	-- 加入可resume队列
	return true
end

function thread_method:_set_name(name)
	self._name = name
	--print("assoc", self.co, name)
end

function thread_method:alive()
	return self._timer ~= nil
end

function thread_method:_get_name()
	return self._name
end

function thread_method:_get_status()
	return co_status(self._co)
end

function thread_method:_set_finalize(cb)
	self._finalize = cb
end

local function new_thread(f)
	local co = co_create(f)
	local thread =  {
		_co = co,
		_finalize = function() end,
		_name = tostring(co),
		_timer = luv.new_timer(),
	}
	setmetatable(thread, thread_mt)

	--print("new thread", thread._name)
	ski_thread_map[thread] = 1 		-- register in thread map

	running_list:append(thread, sigdefault)	-- 加入运行队列

	return thread
end

---------------------------- scheduler --------------------------------

local function _resume(next_thread, signals)
	local st = next_thread:_get_status()
	if st == "dead" then
		print("already dead", next_thread:_get_name())
		return
	end

	if st == "suspended" or st == "normal" then
		ski_cur_thread = next_thread	-- 正在运行的coroutine
		next_thread:_resume(signals)	-- 恢复运行
		ski_cur_thread = nil			-- cur运行结束，让出CPU，此时ski_cur_thread设置为nil, 回到schedule thread

		if next_thread:_get_status() == "dead" then
			next_thread:_close()		-- 自然死亡，close，释放资源
		end
		return
	end

	-- dead, running, or invalid
	assert(false, "invalid co status: " .. st)
end

--[[
每一个prepare的回调作为一轮
重要的数据结构为　
wait_map = {[thread] = 1}
running_list = {
	running_map = {},		-- 当前可以运行的thread, = {[thread] = number_signal_set}
	running_list = {},		-- 当前可以运行，但未resume的array, = {thread1, thread2}

	snatshot_map = nil,		-- 每一轮开始前，指向running_map, running_map重新开始　
	snatshot_list = nil,	-- 每一轮开始前，running_list, running_list　
}
以每轮处理开始为界限, running_list:take_snatshot()
把上一轮产生的 running_map/running_list 交换到 snatshot_map/snatshot_list,
snatshot_map/snatshot_list 作为本轮要 resume 的 thread 信息
本轮产生的新的可resume的thread，缓存到running_map/running_list

每个 thread，每轮最多 resume 一次，期间可能调用 wait() 让出CPU，也可能调用 wakeup(thread, signal) 唤醒其他的 thread (不能唤醒自己)
因此，在每个 thread 被 resume 前，也就是schedule thread在运行，其他 thread 被挂起期间, 清空对应的wait_map
wait_map[thread] = nil
直到下次被 resume 前，产生的唤醒都为有效，记录在running_list中
-- ]]
function run(f, ...)
	local thread = new_thread(f, {...})	-- 创建新的coroutine
	thread:_set_name("main thread")

	-- prepare: 每个loop调用一次
	local prepare = luv.new_prepare()
	local imme_timer = luv.new_timer()
	prepare:start(function()
		if empty(ski_thread_map) then
			return luv.stop()	--　没有更多的coroutine了，正常退出
		end
		--print("at prepare")

		-- 冻结，开始本轮 resume，新一轮的 resume 记录在running_list的缓存中
		running_list:take_snatshot()

		-- 按照FIFO，resume本轮的所有thread
		while true do
			local next_thread, signals = running_list:pop()
			if not next_thread then
				break	-- 处理完毕
			end

			wait_map[next_thread] = nil		-- 重新开始下一轮 wait

			_resume(next_thread, signals)	-- 收到的所有signals作为参数，resume next thread
		end

		if running_list:count() > 0 then
			imme_timer:start(0, 0, function()
				imme_timer:stop()
				--print("iiiiiiiiiiiii numb")
			end)
		end
	end)

	luv.run("default")
	print("schedule thread exit normally")
end

function go(f, ...)
	return new_thread(f, {...})	-- 创建新的coroutine
end

------------------------------- extend functions ----------------------------------

local function sleepms(ms)
	local end_ms = ms + luv.now() -- floor(luv.hrtime()/1000000)
	local do_once
	do_once = function()
		local left_ms = end_ms - luv.now() -- floor(luv.hrtime()/1000000)
		local cur = ski_cur_thread
		--print("left_ms", left_ms)

		cur._timer:start(left_ms, 0, function()
			wakeup(cur, sigsleep)
		end)

		local signals = wait()
		if band(signals, sigsleep) ~= 0 then
			return true
		end

		do_once()
	end

	do_once()
end

function sleep(n)
	return sleepms(n * 1000)
end

function yield()
	return sleepms(0)
end

local function time()
	local now = luv.now()
	return now / 1000
end

local function millitime()
	return luv.now()
end

local function cur_thread()
	return ski_cur_thread
end

local function thread_count()
	local count = 0
	for _, _ in pairs(ski_thread_map) do
		count = count + 1
	end
	return count
end

local function set_name(thread, name)
	thread:_set_name(name)
end

local function get_name(thread)
	return thread:_get_name()
end

local function set_finalize(thread, cb)
	thread:_set_finalize(cb)
end

local function get_status(thread)
	return thread:_get_status()
end

local function iskill(signal)
	assert(signal, debug.traceback())
	return band(signal, sigkill) ~= 0
end

local function isusr1(signal)
	return band(signal, sigusr1) ~= 0
end

local function isusr2(signal)
	return band(signal, sigusr2) ~= 0
end

local function issignal(signal, target)
	return band(signal, target) ~= 0
end

local function wait_signals(...)
	local sigs = {...}
	while true do
		local signals = wait()
		for _, signal in ipairs(sigs) do
			if band(signal, signals) ~= 0 then
				return signals
			end
		end
		print("recv other, again, signal", signals)
	end
end

function empty(t)
	for _ in pairs(t) do
		return false
	end
	return true
end

----------------------------------- export --------------------------

local ski ={
	go = go,		--
	run = run,		--

	set_name = set_name,
	get_name = get_name,
	set_finalize = set_finalize,
	status = get_status,

	time = time,	--
	millitime = millitime,
	cur_thread = cur_thread,
	thread_count = thread_count,

	yield = yield,	--
	sleep = sleep,
	sleepms = sleepms,

	wait = wait,
	wakeup = wakeup,
	wait_signals = wait_signals,

	sigusr1 = sigusr1,
	sigusr2 = sigusr2,
	sigkill = sigkill,
	iskill  = iskill,
	isusr1  = isusr1,
	isusr2  = isusr2,
	issignal = issignal,

	--new_chan = core.new_chan,	-- delete
}

return ski

