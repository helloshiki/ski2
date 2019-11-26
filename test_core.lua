package.cpath = "./?.so;" .. package.cpath
package.path = "./?.lua"
local ski = require("ski")

local function test_sleep_signals()
    local thread = ski.go(function(m)
        local start = ski.millitime()
        print(ski.sleep(10))
        local diff = ski.millitime() - start
        assert(diff >= 10 * 1000)
        print("child exit")
    end)
    ski.set_name(thread, "sleep")

    for i = 1, 10 do
        ski.wakeup(thread, ski.sigusr1)
        ski.sleep(1)
    end
    print("normally exit")
end


local function test_sleep()
    local thread = ski.go(function()
        local start = ski.millitime()
        for i = 1, 2 do
            print("child", i)
            ski.sleep(5)
        end
        local diff = ski.millitime() - start
        assert(diff >= 10 * 1000)
        print("child exit")
    end)

    while "dead" ~= ski.status(thread) do
        print("threads:", ski.thread_count())
        ski.sleep(1)
    end

    print("normally exit")
end

local function test_wait_wakeup_simple()
    local t1, t2
    t1 = ski.go(function()
        local signals = ski.wait()
        print("round1 was wakeup", signals)
        assert(signals == 1)

        signals = ski.wait()
        print("round2 was wakeup", signals)
        assert(signals == 88)

        signals = ski.wait()
        print("round3 was wakeup", signals)
        assert(signals == 7)

        signals = ski.wait()
        print("round4 was wakeup", signals)
        assert(signals == 48)
    end)
    ski.set_name(t1, "thread 1111")
    ski.set_finalize(t1, function()
        print("thread t1 exit normally")
    end)

    t2 = ski.go(function ()
        print("test default signal")
        ski.wakeup(t1)
        ski.sleep(1)

        print("test self-defined signal")
        ski.wakeup(t1, 88)
        ski.sleep(1)

        print("test many signals")
        ski.wakeup(t1, 1)
        ski.wakeup(t1, 2)
        ski.wakeup(t1, 4)
        ski.sleep(1)

        print("test user signals")
        ski.wakeup(t1, ski.sigusr1)
        ski.wakeup(t1, ski.sigusr2)
        ski.sleep(1)
    end)

    ski.set_name(t2, "thread 2222")
    ski.set_finalize(t2, function()
        print("thread t2 exit normally")
    end)

    while not ("dead" == ski.status(t1) and "dead" == ski.status(t2)) do
        ski.sleep(1)
    end

    print("exit normally")
end

local function test_wait_wakeup()
    local t1, t2
    local cache = {}

    t1 = ski.go(function()
        print("consumer start")
        while true do
            for i, r in ipairs(cache) do
                print("consume", i, r)
            end
            cache = {}
            if not ski.wakeup(t2) then
                print("producer is too dead to wakeup")
                break
            end
            local signals = ski.wait()
            assert(signals == 1)
        end
        print("consumer exit")
    end)

    t2 = ski.go(function()
        print("producer start")
        local round = 1
        local index = 0
        while true do
            round = round + 1
            for i = 1, 10 do
                index = index + 1
                print("produce", index)
                table.insert(cache, index)
            end
            assert(ski.wakeup(t1))
            if round >= 2 then
                break
            end

            local signals = ski.wait()
            assert(signals == 1)
        end
        print("producer exit")
    end)

    ski.set_name(t1, "consumer")
    ski.set_name(t2, "producer")

    while "dead" == ski.status(t1) and "dead" == ski.status(t2) do
        print("threads:", ski.thread_count())
        local signals = ski.sleep(1)
        assert(signals == 2)
    end
end

local function test_wakeup_kill()
    local threads = {}
    for i = 1, 6 do
        local thread
        thread = ski.go(function()
            while true do
                print("I am waiting. thread " .. i)
                local signals = ski.wait()
                if ski.iskill(signals) then
                    print("recv kill signal. thread " .. i, signals)
                    break
                end
                print("recv other signal. thread " .. i, signals)
            end
        end)

        ski.set_name(thread, "thread " .. i)
        ski.set_finalize(thread, function()
            print("release thread " .. i)
        end)
        table.insert(threads, thread)
    end

    print("create threads ok")
    for _, thread in ipairs(threads) do
        ski.sleep(2)
        print("send signal usr1 to thread " .. ski.get_name(thread))
        ski.wakeup(thread, ski.sigusr1)

        ski.sleep(2)
        print("send signal kill to thread " .. ski.get_name(thread))
        ski.wakeup(thread, ski.sigkill)
    end

    print("test thread exit normally")
end

local function test_yield()
    local t1, t2
    local cache = {}
    t1 = ski.go(function()
        print("consumer start")
        while "dead" ~= ski.status(t2) do
            for i, r in ipairs(cache) do
                print("consume", i, r)
            end
            cache = {}
            ski.yield()
        end
        print("consumer exit")
    end)

    t2 = ski.go(function()
        print("producer start")
        local index = 0
        while index <= 10 do
            index = index + 1
            print("produce", index)
            table.insert(cache, index)
            ski.yield()
        end
        print("producer exit")
    end)

    ski.set_name(t1, "consumer")
    ski.set_name(t2, "producer")

    while "dead" == ski.status(t1) and "dead" == ski.status(t2) do
        print("threads:", ski.thread_count())
        ski.sleep(1)
    end
end

local function test_wait_signal()
    local thread = ski.go(function()
        print("begin wait signal sigkill", ski.time())

        local signals = ski.wait_signals(ski.sigusr2, ski.sigkill)
        print("1 wait signal sigkill", ski.time(), signals)
        assert(signals == ski.sigusr2)

        local signals = ski.wait_signals(ski.sigkill)
        print("2 wait signal sigkill", ski.time(), signals)
        assert(signals == ski.sigkill)
    end)

    ski.sleep(1)
    ski.wakeup(thread, ski.sigusr1)

    ski.sleep(1)
    ski.wakeup(thread, ski.sigusr2)

    ski.sleep(1)
    ski.wakeup(thread, ski.sigkill)

    while "dead" ~= ski.status(thread)  do
        ski.sleep(1)
    end
end

local function main()
    test_sleep()
    test_sleep_signals()
    test_wait_signal()
    test_wait_wakeup_simple()
    test_wait_wakeup()
    test_wakeup_kill()
    test_yield()
end

ski.run(main)
