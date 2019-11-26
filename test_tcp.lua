package.cpath = "./?.so;" .. package.cpath
package.path = "./?.lua"
local ski = require("ski")
local tcp = require("ski")

local function test_listen_bind_dup()
    local server, err = tcp.listen("0.0.0.0", 33333)
    assert(server, err)

    local _, err = tcp.listen("0.0.0.0", 33333)
    assert(err and err:find("EADDRINUSE:"))

    server:close()
    print("test ok")
end

local function test_listen_accept_in_diff_threads()
    local server, err = tcp.listen("0.0.0.0", 33333)
    assert(server, err)

    -- FATAL
    --ski.go(function()
    --    local client, err = server:accept()
    --    print(client, err)
    --end)
    server:close()
end

local function test_listen_no_accept()
    local server, err = tcp.listen("0.0.0.0", 33333)
    assert(server, err)

    --ski.sleep(1)
    local cli, e = tcp.connect("127.0.0.1", 33333)
    assert(cli, e)
    local cli, e = tcp.connect("127.0.0.1", 33333)
    assert(cli, e)

    print(#server.cache == 2)
    print("test ok")
end

local function test_listen_accept_no_wait()
    local server, client
    server = ski.go(function()
        print("server start")
        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        ski.sleep(3)

        local start = ski.millitime()
        local cli, err = server:accept()
        assert(cli, err)
        local diff = ski.millitime() - start
        print("diff", diff)
        assert(diff <= 2)

        cli:close()
        server:close()

        assert(not server.raw_server)
        assert(server.accept_err == "closed")
        assert(server.write_err == "closed")
        assert(#server.cache == 0)
        assert(not cli.raw_client)

        cli:close()
        server:close()
        print("server exit")
    end)

    client = ski.go(function()
        print("client start")
        ski.sleep(1)
        local cli, e = tcp.connect("127.0.0.1", 33333)
        assert(cli, e)
        cli:close()

        assert(not cli.raw_client)

        cli:close()
        print("client exit")
    end)

    while not ("dead" == ski.status(server) and "dead" == ski.status(client)) do
        ski.sleep(0.2)
    end
end

local function test_listen_accept_wait()
    local server, client
    local wait_time = 1000
    server = ski.go(function()
        print("server start")
        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        local start = ski.millitime()
        local cli, err = server:accept()
        assert(cli, err)
        local diff = ski.millitime() - start
        print("diff", diff)
        assert(diff >= wait_time)

        cli:close()
        server:close()

        assert(not server.raw_server)
        assert(server.write_err == "closed")
        assert(server.accept_err == "closed")
        assert(#server.cache == 0)
        assert(not cli.raw_client)

        cli:close()
        server:close()
        print("server exit")
    end)

    client = ski.go(function()
        print("client start")
        ski.sleepms(wait_time)
        local cli, e = tcp.connect("127.0.0.1", 33333)
        assert(cli, e)
        cli:close()

        assert(not cli.raw_client)
        assert(cli.write_err == "closed")

        cli:close()
        assert(cli.write_err == "closed")
        print("client exit")
    end)

    while not ("dead" == ski.status(server) and "dead" == ski.status(client)) do
        ski.sleep(0.2)
    end
end

local function test_listen_accept_kill()
    local server, client
    local wait_time = 1000
    server = ski.go(function()
        print("server start")
        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        print("test 1")
        local start = ski.millitime()
        local cli, err = server:accept()
        assert(cli, err)
        local diff = ski.millitime() - start
        print("diff", diff)
        assert(diff >= wait_time)
        cli:close()

        print("test 2")
        local cli, err = server:accept()
        print(cli, err)
        assert(err == "closed")

        server:close()
        print("server exit")
    end)

    client = ski.go(function()
        print("client start")
        ski.sleepms(wait_time)
        local cli, e = tcp.connect("127.0.0.1", 33333)
        assert(cli, e)
        cli:close()

        ski.wakeup(server, ski.sigusr2)
        ski.sleep(1)
        ski.wakeup(server, ski.sigkill)

        print("client exit")
    end)

    while not ("dead" == ski.status(server) and "dead" == ski.status(client)) do
        ski.sleep(0.2)
    end
end

local function test_listen_accept_kill_with_cache()
    local server, client
    local wait_time = 1000
    server = ski.go(function()
        print("server start")
        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)
        ski.sleep(3)
        server:close()
        assert(not server.raw_server)
        assert(server.write_err == "closed")
        assert(server.accept_err == "closed")
        assert(server.listen_thread)
        print("server exit")
    end)

    client = ski.go(function()
        print("client start")
        ski.sleepms(wait_time)
        local cli, e = tcp.connect("127.0.0.1", 33333)
        assert(cli, e)
        cli:close()

        local cli, e = tcp.connect("127.0.0.1", 33333)
        assert(cli, e)
        cli:close()

        local cli, e = tcp.connect("127.0.0.1", 33333)
        assert(cli, e)
        cli:close()

        print("client exit")
    end)

    while not ("dead" == ski.status(server) and "dead" == ski.status(client)) do
        ski.sleep(0.2)
    end
end

local function test_buffer()
    print("======================== test take all")
    local buff = tcp.new_buffer()

    assert(buff:take_all() == "")

    buff:clear()
    buff:append("123456")
    assert(buff:take_all() == "123456")
    assert(buff:take_all() == "")

    buff:clear()
    buff:append("123456")
    buff:append("7890")
    assert(buff:take_all() == "1234567890")
    assert(buff:take_all() == "")

    buff:clear()
    buff:append("123456")
    buff:append({nil, "test_error"})
    local res, err = buff:take_all()
    assert(res == "123456")
    assert(err == "test_error")

    res, err = buff:take_all()
    assert(res == "")
    assert(err == "test_error")

    buff:clear()
    buff:append({nil, "test_error"})
    local res, err = buff:take_all()
    assert(res == "")
    assert(err == "test_error")

    print("======================== test take size")
    buff = tcp.new_buffer()
    buff:append("123456")
    res, err = buff:take(0)
    assert(res == "" and err == "invalid size")
    res, err = buff:take(2)
    assert(res == "12" and err == nil)
    res, err = buff:take(4)
    assert(res == "3456" and err == nil)
    res, err = buff:take(1)
    assert(res == "" and err == "insufficient")

    buff:clear()
    buff:append("123456")
    buff:append({nil, "custom_error"})
    res, err = buff:take(6)
    assert(res == "123456" and err == nil)
    res, err = buff:take_all()
    assert(res == "" and err == "custom_error")
    res, err = buff:take(6)
    assert(res == "" and err == "custom_error")

    buff:clear()
    buff:append({nil, "custom_error"})
    res, err = buff:take(6)
    assert(res == "" and err == "custom_error")

    buff:clear()
    buff:append("123")
    res, err = buff:take(6)
    assert(res == "" and err == "insufficient")
    buff:append("4567")
    res, err = buff:take(6)
    assert(res == "123456" and err == nil)
    res, err = buff:take(1)
    assert(res == "7" and err == nil)

    buff:clear()
    buff:append("123")
    res, err = buff:take(10)
    assert(res == "" and err == "insufficient")
    buff:append("456")
    res, err = buff:take(10)
    assert(res == "" and err == "insufficient")
    buff:append("789")
    res, err = buff:take(10)
    assert(res == "" and err == "insufficient")
    buff:append("012")
    res, err = buff:take(10)
    assert(res == "1234567890" and err == nil)

    buff:clear()
    buff:append("123456")
    buff:append({nil, "custom_error"})
    res, err = buff:take(7)
    assert(res == "123456" and err == "custom_error")
    res, err = buff:take_all()
    assert(res == "" and err == "custom_error")

    buff:clear()
    buff:append("123456")
    buff:append({nil, "custom_error"})
    res, err = buff:take_all()
    assert(res == "123456" and err == "custom_error")
    res, err = buff:take(7)
    assert(res == "" and err == "custom_error")

    print("test ok")
end

local function test_producer_consumer_take_all()
    local server
    local threads = {}
    local handle = function(cli)
        print("handle new connection")
        while true do
            local data, err = cli:read()
            if data then
                print("=== recv", data)
            end

            if err then
                print("=== read error", err)
                break
            end
        end
        local data, err = cli:read()
        assert(data == "" and err == "EOF")
        cli:close()
        local data, err = cli:read()
        assert(data == "" and err == "closed", err)
    end

    server = ski.go(function()
        print("server start")

        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        while true do
            local cli, err = server:accept()
            if err then
                server:close()
                break
            end

            local thread = ski.go(function()
                handle(cli)
            end)
            ski.set_name(thread, "handle-thread")

            table.insert(threads, thread)
        end

        print("server exit")
    end)
    ski.set_name(server, "server")

    for i = 1, 4 do
        local client = ski.go(function()
            print("client start", i)

            local cli, e = tcp.connect("127.0.0.1", 33333)
            assert(cli, e)

            for j = 1, 10 do
                ski.sleep(1)
                local r, e = cli:write("client publish " .. i .. " " .. j)
                assert(r, e)
            end

            cli:close()
            print("client exit", i)
        end)
        ski.set_name(client, "client_" .. i)

        table.insert(threads, client)
        ski.sleep(1)
    end

    while true do
        local thread = table.remove(threads, 1)
        if not thread then
            break
        end

        while "dead" ~= ski.status(thread) do
            ski.sleep(2)
            print(ski.get_name(thread))
        end
    end

    ski.wakeup(server, ski.sigkill)

    print("test ok")
end


local function test_echo_take_all()
    local server
    local threads = {}
    local handle = function(cli)
        print("handle new connection")
        while true do
            local data, err = cli:read()
            if data then
                print("=== server recv", data)
            end

            if err then
                print("=== server read error", err)
                break
            end

            local r, e = cli:write("echo " .. data)
            assert(r, e)
        end

        local data, err = cli:read()
        assert(data == "" and err == "EOF")

        local r, err = cli:write("xxx")
        assert(r == nil and err == "closed")

        cli:close()

        local data, err = cli:read()
        assert(data == "" and err == "closed")

        local r, err = cli:write("xxx")
        assert(r == nil and err == "closed")
    end

    server = ski.go(function()
        print("server start")

        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        while true do
            local cli, err = server:accept()
            if err then
                server:close()
                break
            end

            local thread = ski.go(function()
                handle(cli)
            end)
            ski.set_name(thread, "handle-thread")

            table.insert(threads, thread)
        end

        print("server exit")
    end)
    ski.set_name(server, "server")

    for i = 1, 4 do
        local client = ski.go(function()
            print("client start", i)

            local cli, e = tcp.connect("127.0.0.1", 33333)
            assert(cli, e)

            for j = 1, 10 do
                ski.sleep(1)
                local r, e = cli:write("client publish " .. i .. " " .. j)
                assert(r, e)
                local data, e = cli:read()
                assert(data, e)
                print("--- client recv", data)
            end

            cli:close()
            print("client exit", i)

            local data, err = cli:read()
            assert(data == "" and err == "closed")

            local r, err = cli:write("xxx")
            assert(r == nil and err == "closed")
        end)
        ski.set_name(client, "client_" .. i)

        table.insert(threads, client)
        ski.sleep(1)
    end

    while true do
        local thread = table.remove(threads, 1)
        if not thread then
            break
        end

        while "dead" ~= ski.status(thread) do
            ski.sleep(2)
            print(ski.get_name(thread))
        end
    end

    ski.wakeup(server, ski.sigkill)

    print("test ok")
end

local function test_producer_consumer_signals()
    local server
    server = ski.go(function()
        print("server start")

        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        local cli, err = server:accept()
        assert(cli, err)

        local data, err = cli:read()
        print(data, err)
        assert(data == "12345" and err == nil)

        ski.sleep(3)
        local data, err = cli:read()
        print(data, err)
        assert(data == "12345678910" and err == "EOF")

        cli:close()
        print("server exit")
    end)
    ski.set_name(server, "server")

    ski.sleepms(100)

    print("client start")
    local cli, e = tcp.connect("127.0.0.1", 33333)
    assert(cli, e)

    ski.sleepms(100)
    local r, e = cli:write("12345")
    assert(r, e)

    for i = 1, 10 do
        ski.sleepms(100)
        local r, e = cli:write(i)
        assert(r, e)
        ski.wakeup(server, ski.sigusr2)
    end

    cli:close()
    print("client exit")

    while "dead" ~= ski.status(server) do
        ski.sleepms(100)
    end
    print("test ok")
end

local function test_producer_consumer_take()
    local server
    server = ski.go(function()
        print("server start")

        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        local cli, err = server:accept()
        assert(cli, err)

        while true do
            local data, err = cli:read(2)
            if err then
                print("error ", data, err)
                break
            end
            local size = tonumber(data)
            local content, err = cli:read(size)
            assert(content, err)

            data, err = cli:read(2)
            if err then
                print("error ", data, err)
                break
            end
            local size = tonumber(data)
            local content, err = cli:read(size)
            assert(content == "1234567890", err)
        end

        cli:close()
        server:close()
        print("server exit")
    end)
    ski.set_name(server, "server")

    ski.sleepms(100)

    print("client start")
    local cli, e = tcp.connect("127.0.0.1", 33333)
    assert(cli, e)

    for i = 1, 10 do
        --ski.sleepms(100)

        local timestamp = tostring(os.time())
        local size_s = string.format("%02d", #timestamp)
        local r, e = cli:write(size_s)
        assert(r, e)
        r, e = cli:write(timestamp)
        assert(r, e)

        r, e = cli:write("10")
        assert(r, e)

        r, e = cli:write("12345678")
        assert(r, e)
        r, e = cli:write("90")
        assert(r, e)
    end

    cli:close()
    print("client exit")

    while "dead" ~= ski.status(server) do
        ski.sleepms(100)
    end
    print("test ok")
end

local function test_echo_take()
    local server
    server = ski.go(function()
        print("server start")

        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)
        for i = 1, 2 do
            local cli, err = server:accept()
            assert(cli, err)

            while true do
                local data, err = cli:read(2)
                if err then
                    print("error ", data, err)
                    break
                end
                local size = tonumber(data)
                local content, err = cli:read(size)
                assert(content == "1234567890", err)

                local r, e = cli:write(data .. content)
                assert(r, e)
            end

            cli:close()
        end

        server:close()
        print("server exit")
    end)
    ski.set_name(server, "server")

    for i = 1, 2 do
        ski.sleepms(100)
        print("====================> client start", i)

        local cli, e = tcp.connect("127.0.0.1", 33333)
        assert(cli, e)

        for i = 1, 10 do
            ski.sleepms(100)
            r, e = cli:write("10")
            assert(r, e)

            r, e = cli:write("12345678")
            assert(r, e)
            r, e = cli:write("90")
            assert(r, e)

            local data, e = cli:read(2)
            assert(data, e)
            local size = tonumber(data)
            local content, err = cli:read(size)
            assert(content == "1234567890", err)
        end

        cli:close()
        print("client exit")
    end

    while "dead" ~= ski.status(server) do
        ski.sleepms(100)
    end
    print("test ok")
end

local function test_many_cache_take()
    local server
    server = ski.go(function()
        print("server start")

        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        local cli, err = server:accept()
        assert(cli, err)

        local data, err = cli:read(12)
        assert(data, err)

        ski.sleep(5)
        while true do
            local data, err = cli:read(2)
            if err then
                print("error ", data, err)
                break
            end

            local size = tonumber(data)
            local content, err = cli:read(size)
            assert(content == "1234567890", err)
        end

        cli:close()
        server:close()
        print("server exit")
    end)
    ski.set_name(server, "server")

    ski.sleepms(100)
    print("====================> client start", i)

    local cli, e = tcp.connect("127.0.0.1", 33333)
    assert(cli, e)

    ski.sleepms(100)
    for i = 1, 100 do
        r, e = cli:write("10")
        assert(r, e)

        r, e = cli:write("12345678")
        assert(r, e)
        r, e = cli:write("90")
        assert(r, e)
    end

    cli:close()
    print("client exit")

    while "dead" ~= ski.status(server) do
        ski.sleepms(100)
    end
    print("test ok")
end

local function test_connect_closed_server()
    local server
    server = ski.go(function()
        print("server start")

        local server, err = tcp.listen("0.0.0.0", 33333)
        assert(server, err)

        local cli, err = server:accept()
        assert(cli, err)

        local data, err = cli:read(12)
        assert(data == "101234567890", err)

        cli:close()
        server:close()
        print("server exit")
    end)
    ski.set_name(server, "server")

    ski.sleepms(100)
    print("====================> client start", i)

    local cli, e = tcp.connect("127.0.0.1", 33333)
    assert(cli, e)

    ski.sleepms(100)
    local r, e = cli:write("10")
    assert(r, e)
    r, e = cli:write("12345678")
    assert(r, e)
    r, e = cli:write("90")
    assert(r, e)
    cli:close()

    local cli, e = tcp.connect("127.0.0.1", 33333)
    print(cli, e)
    assert(e == "ECONNREFUSED", e)

    print("client exit")

    while "dead" ~= ski.status(server) do
        ski.sleepms(100)
    end
    print("test ok")
end

local function main()
    --test_listen_bind_dup()
    --test_listen_accept_in_diff_threads()
    --test_listen_no_accept()
    --test_listen_accept_no_wait()
    --test_listen_accept_wait()
    --test_listen_accept_kill()
    --test_listen_accept_kill_with_cache()

   --test_buffer()

    --test_producer_consumer_take_all()
    --test_echo_take_all()
    --test_producer_consumer_signals()

    --test_producer_consumer_take()
    --test_echo_take()
    --test_many_cache_take()

    test_connect_closed_server()
end

ski.run(main)
