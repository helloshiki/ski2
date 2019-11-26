package.cpath = "./?.so;" .. package.cpath
package.path = "./?.lua"
local ski = require("ski")
local udp = require("ski.udp")

local function test_producer_consumer()
    local server, client

    server = ski.go(function()
        print("server start")
        local srv = udp.new()
        local r, e = srv:bind("127.0.0.1", 12345) 	assert(r, e)
        srv:set_name("server")

        while true do
            local r, e, p = srv:recv() 				--	assert(r, e)
            if not r and e then
                print("server ERROR", e)
                break
            end
            print("recv", r, e, p)
        end
        srv:close()
        srv:close()
        print("server exit")
    end)

    client = ski.go(function()
        print("client start")
        local cli = udp.new()
        cli:set_name("client")
        for i = 1, 10 do
            local r, e = cli:send("127.0.0.1", 12345, i) 	assert(r, e)
            ski.sleep(1)
        end
        cli:close()
        cli:close()
        ski.wakeup(server, ski.sigkill)
        print("client exit")
    end)

    ski.set_name(server, "server")
    ski.set_name(client, "client")

    while not ("dead" == ski.status(server) and "dead" == ski.status(client)) do
        ski.sleep(0.1)
    end
end

local function test_server_signals()
    local server, client

    server = ski.go(function()
        print("server start")
        local srv = udp.new()
        local r, e = srv:bind("127.0.0.1", 12345) 	assert(r, e)
        srv:set_name("server")

        while true do
            local r, e, p = srv:recv() 				--	assert(r, e)
            if not r and e then
                print("server error", e)
                break
            end
            print("recv", r, e, p)
        end
        srv:close()
        srv:close()
        print("server exit")
    end)

    client = ski.go(function()
        print("client start")

        local cli = udp.new()
        cli:set_name("client")

        local r, e = cli:send("127.0.0.1", 12345, os.date()) 	assert(r, e)

        ski.wakeup(server, ski.sigusr1)
        ski.sleep(1)

        ski.wakeup(server, ski.sigusr2)
        ski.sleep(1)

        cli:close()

        ski.wakeup(server, ski.sigkill)
        print("client exit")
    end)

    ski.set_name(server, "server")
    ski.set_name(client, "client")

    while not ("dead" == ski.status(server) and "dead" == ski.status(client)) do
        ski.sleep(0.1)
    end
end

local function test_server_recv_cache()
    local server, client

    server = ski.go(function()
        print("server start")
        local srv = udp.new()
        local r, e = srv:bind("127.0.0.1", 12345) 	assert(r, e)
        srv:set_name("server")

        local r, e, p = srv:recv() 				assert(r, e)

        local start = ski.millitime()
        print("before", start)
        ski.sleepms(3000)
        local diff = ski.millitime() - start
        print("after", ski.millitime(), diff)
        assert(diff >= 3000)

        while true do
            local r, e, p = srv:recv()
            if not r and e then
                print("server ERROR", e)
                break
            end
            print("recv", r, e, p)
        end
        srv:close()
        srv:close()
        print("server exit")
    end)

    client = ski.go(function()
        print("client start")

        local cli = udp.new()
        cli:set_name("client")

        for i = 1, 30 do
            local r, e = cli:send("127.0.0.1", 12345, os.date()) 	assert(r, e)
        end
        cli:close()

        ski.sleep(5)
        ski.wakeup(server, ski.sigkill)
        print("client exit")
    end)

    ski.set_name(server, "server")
    ski.set_name(client, "client")

    while not ("dead" == ski.status(server) and "dead" == ski.status(client)) do
        ski.sleep(0.2)
    end
end

local function test_server_close()
    local server, client

    local srv = udp.new()
    server = ski.go(function()
        print("server start")
        local r, e = srv:bind("127.0.0.1", 12345) 	assert(r, e)
        srv:set_name("server")

        local r, e, p = srv:recv() 			        assert(r, e)
        r, e, p = srv:recv()
        print("recv", r, e, p)
        assert(e == "closed")
        srv:close()

        r, e, p = srv:recv()
        print("recv", r, e, p)
        assert(e == "closed")

        print("server exit")
    end)

    client = ski.go(function()
        print("client start")

        local cli = udp.new()
        cli:set_name("client")

        local r, e = cli:send("127.0.0.1", 12345, os.date()) 	assert(r, e)
        cli:close()
        print("client exit")

        print("close srv")
        srv:close()
    end)

    ski.set_name(server, "server")
    ski.set_name(client, "client")

    while not ("dead" == ski.status(server) and "dead" == ski.status(client)) do
        ski.sleep(0.2)
    end
end

local function test_echo()
    local server
    server = ski.go(function()
        local srv = udp.new()
        local r, e = srv:bind("127.0.0.1", 33333) 		assert(r, e)

        while true do
            local data, host, port = srv:recv()
            if data then
                print("server echo", data, host, port)
                local r, e = srv:send(host, port, data)     assert(r, e)
            else
                assert(host == "killed", host)
                break
            end
        end

        srv:close()
        print("server exit normally")
    end)

    ski.set_name(server, "server")

    ski.sleep(1)

    local cli = udp.new()
    --local r, e = cli:bind("0.0.0.0", 33334)         assert(not e, e)

    for i = 1, 4 do
        local r, e = cli:send("127.0.0.1", 33333, "timestamp " .. ski.time()) 	assert(r, e)
        local data, e = cli:recv()      assert(data, e)
        print("client recv", data, e)
        ski.sleep(1)
    end
    cli:close()
    ski.wakeup(server, ski.sigkill)

    print("exit normally")
end


local function test_brocast()
    local server
    server = ski.go(function()
        local srv = udp.new()
        local r, e = srv:bind("127.0.0.1", 33333) 		assert(r, e)

        while true do
            local data, host, port = srv:recv()
            if data then
                print("server echo", data, host, port)
            else
                assert(host == "killed", host)
                break
            end
        end

        srv:close()
        print("server exit normally")
    end)

    ski.set_name(server, "server")

    ski.sleep(1)

    local cli = udp.new()
    local r, e = cli:bind("0.0.0.0", 33334)     assert(r, e)
    local r, e = cli:set_broadcast(true)        assert(r, e)

    for i = 1, 4 do
        local r, e = cli:send("127.0.0.1", 33333, "timestamp " .. ski.time())
        assert(r, e)
        ski.sleep(1)
    end

    cli:close()
    ski.wakeup(server, ski.sigkill)

    print("exit normally")
end

local function test_multi_recv_thread()
    local server1, server2
    local srv = udp.new()
    local r, e = srv:bind("127.0.0.1", 33333) 		assert(r, e)

    server1 = ski.go(function()
        local data, host, port = srv:recv()
    end)

    -- FATAL
    --server2 = ski.go(function()
    --    local data, host, port = srv:recv()
    --end)
end

local function test_multi_send_thread()
    local client1, client2
    local cli = udp.new()

    client1 = ski.go(function()
        local r, e = cli:send("127.0.0.1", 33333, "timestamp " .. ski.time())
        assert(r, e)
    end)

    -- FATAL
    --client2 = ski.go(function()
    --    local r, e = cli:send("127.0.0.1", 33333, "timestamp " .. ski.time())
    --    assert(r, e)
    --end)
end

local function test_send()
    local cli = udp.new()
    local r, e = cli:send("127.0.0.1", 33333, "timestamp " .. ski.time())
    assert(r, e)
    print("exit normally")
end

local function test_send_err()
    local cli = udp.new()
    cli.err = "custom error"
    local r, e = cli:send("127.0.0.1", 33333, "timestamp " .. ski.time())
    print(r, e)
    assert(e == "custom error")
    print("exit normally")
end

local function main()
    --test_producer_consumer()
    --test_server_signals()
    --test_server_recv_cache()
    --test_server_close()
    --test_echo()
    --test_brocast()
    --test_multi_recv_thread()
    --test_send()
    --test_send_err()
    test_multi_send_thread()
end

ski.run(main)
