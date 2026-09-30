-- ModuleScript: Signal/SmokeTests. No HTTP requests are made.
-- Studio server Command Bar: require(game.ServerScriptService.Signal.SmokeTests)()
return function()
    local Logger = require(script.Parent.Logger)
    local Config = require(script.Parent.Config)
    local function make(responder, overrides)
        local config = table.clone(Config)
        config.Console, config.StudioDelivery = false, true
        config.TrackPlayers, config.TrackCharacters = false, false
        config.CaptureServerErrors, config.CaptureWarnings = false, false
        for key, value in pairs(overrides or {}) do config[key] = value end
        return Logger.new(config, responder)
    end
    local function response(code, body, headers)
        return { StatusCode = code, Body = body or "", Headers = headers or {} }
    end
    local captured
    local logger = make(function(payload) captured = payload; return response(204) end)
    logger:Info("test.event", "Hello", { token = "DO_NOT_SEND", count = 4 })
    assert(logger:Step() and logger:GetStats().sent == 1, "successful delivery")
    assert(captured.embeds[1].description:find("[redacted]", 1, true), "key redaction")
    assert(not captured.embeds[1].description:find("DO_NOT_SEND", 1, true), "no secret leak")
    assert(#captured.allowed_mentions.parse == 0, "mentions disabled")
    logger:Debug("debug", "filtered")
    assert(logger:GetStats().queued == 0, "minimum level")

    local rate = make(function() return response(429, '{"retry_after":30}') end)
    rate:Warn("rate", "Test")
    local before = os.clock()
    rate:Step()
    assert(rate:GetStats().queued == 1 and rate.NextAttempt >= before + 30, "rate-limit delay")
    assert(not rate:Step(), "no early retry")

    local auth = make(function() return response(403) end)
    auth:Info("blocked", "Test"); auth:Step()
    assert(not auth:GetStats().deliveryEnabled and auth:GetStats().failed == 1, "stop on forbidden")
    auth:Info("after", "Output only")
    assert(auth:GetStats().queued == 0, "no queue while disabled")

    local transient = make(function() error("https://discord.com/api/webhooks/private/token") end, { MaxAttempts = 2 })
    transient:Info("retry", "Test"); transient:Step()
    assert(transient:GetStats().queued == 1, "transport retry retains batch")
    transient.NextAttempt = 0; transient:Step()
    assert(transient:GetStats().failed == 1 and transient:GetStats().queued == 0, "bounded retries")

    local overflow = make(function() return response(204) end, { MaxQueue = 6 })
    for _ = 1, 9 do overflow:Info("queue", "Test") end
    assert(overflow:GetStats().queued == 6 and overflow:GetStats().dropped == 3, "bounded queue")
    overflow:Step()
    assert(overflow:GetStats().sent == 6, "batch sends six")

    local concurrent
    concurrent = make(function()
        concurrent:Info("during", "Enqueued during send")
        return response(204)
    end)
    concurrent:Info("before", "Original batch"); concurrent:Step()
    assert(concurrent:GetStats().queued == 1 and concurrent.Queue[1].Event == "during", "new events retained")

    local timing = make(function() return response(204) end)
    local ok, value, empty, last = timing:Timed("work", function() return 7, nil, 9 end)
    assert(ok and value == 7 and empty == nil and last == 9, "timed return values")
    local failed = timing:Timed("work", function() error("expected") end)
    assert(failed == false, "timed failure")
    timing:_capture("ERROR", "error", "same")
    timing:_capture("ERROR", "error", "same")
    assert(timing:GetStats().suppressed == 1, "deduplication")

    local unicode = make(function(payload)
        local description = payload.embeds[1].description
        assert(utf8.len(description) and #description < 4096, "Unicode and payload bounds")
        return response(204)
    end)
    for _ = 1, 6 do unicode:Info(string.rep("界", 100), string.rep("界", 300), { x = string.rep("界", 300) }) end
    assert(unicode:Step(), "unicode batch")
    print("[Signal tests] 10 test groups passed. No network requests sent.")
    return true
end
